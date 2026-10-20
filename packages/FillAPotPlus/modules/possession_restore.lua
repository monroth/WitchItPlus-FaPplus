-- Host-only possession ledger. Native destruction owns the return deadline.
-- Snapshot scalar data; never retain/call with borrowed RPC structs, table structs or OUT containers.
local M={}
local PROP="/Game/Blueprints/Props/Bases/B_StaticMeshProp.B_StaticMeshProp_C"
local PAWN="/Game/Blueprints/Player/Pawns/B_PropPawnPhysics.B_PropPawnPhysics_C"
local SKILL="/Game/Blueprints/Skills/Witch/Possess/B_PossessSkill.B_PossessSkill_C"
local O="/Game/Blueprints/Gamemodes/ObjectiveMode/"
function M.init(C,H)
    dofile(assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))..'possession_diagnostics.lua').init(H)
    local Clock=FAPP_SERVICES.event_clock
    local Lifetime=FAPP_SERVICES.lifetime
    local api,ctx,generation,reports={},nil,0,{}
    local generated={}
    local Work=assert(FAPP_WORK,'Core work queue required')
    local storageActor,storageLevel -- rooted, data-only objects outside every playable world
    local read=FAPP_SERVICES.runtime.read
    local function same(a,b) return Lifetime.rawValid(a) and Lifetime.rawValid(b) and FAPP_SERVICES.lifetime.same(a,b) end
    -- Layout props live in streamed sublevels (PropLayouts/<Map>NN); the generic
    -- world-identity check rejects them. Liveness here = raw object alive, not a
    -- CDO, not being destroyed, and in the same UWorld as the GameMode/GameState.
    local function live(a)
        if not Lifetime.rawValid(a) then return false end
        local ok,res=pcall(function()
            return not a:GetFullName():find("Default__",1,true) and not a:IsActorBeingDestroyed()
                and Lifetime.rawValid(a:GetWorld())
        end)
        return ok and res
    end
    local function auth(a) if not live(a) then return false end; local ok,v=pcall(function() return a:HasAuthority() end); return ok and v==true end
    local function once(key,s)
        if not reports[key] then reports[key]=true; H.log("Possession restore: "..s) end
    end
    local function gameplay() return H.object("/Script/Engine.Default__GameplayStatics") end
    local function host(o)
        local gm,mm,gs=H.world(o)
        if gm and live(gm) and live(gs) and H.authority(gm) and H.authority(gs) then return gm,mm,gs end
    end
    local function clock(c) return Clock.now() end
    local function current(c)
        if not c or c.cancelled then return false end
        local gm,mm,gs=host(c.gs)
        return same(gm,c.gm) and same(gs,c.gs) and same(mm,c.mm)
    end
    local function session(o)
        local gm,mm,gs=host(o); if not gm then return end
        if not ctx or not same(ctx.gs,gs) or ctx.name~=gs:GetFullName() then
            generation=generation+1
            ctx={gm=gm,mm=mm,gs=gs,name=gs:GetFullName(),generation=generation,epoch=Lifetime.epoch,
                records={},byActor={},work=false,poolEpoch=0,repairs={}}
        end
        if not ctx.cancelled then return ctx end
    end
    local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
    local function xyz(v)
        assert(v and finite(v.X) and finite(v.Y) and finite(v.Z),"invalid prop vector")
        return {X=v.X,Y=v.Y,Z=v.Z} -- Lua-only ledger, never passed back into Unreal
    end
    local function snapshot(c,a,accepted)
        if not live(a) then once('snap-dead','snapshot skipped: target not live'); return end
        if not auth(a) then once('snap-auth','snapshot skipped: no authority on '..a:GetFullName()); return end
        if not accepted and read(a,"IsControlledByWitch")==true then once('snap-ctl','snapshot skipped: IsControlledByWitch already true on '..a:GetFullName()); return end
        if generated[Lifetime.key(a)] or read(a,'IsDecoy')==true then return end
        if not same(gameplay():GetGameState(a),c.gs) then once('snap-gs','snapshot skipped: GameState differs for '..a:GetFullName()); return end
        local id=a:GetAddress(); local old=c.byActor[id]
        if old and same(old.actor,a) and old.actorName==a:GetFullName() then return old end
        local rotation=a:K2_GetActorRotation()
        assert(finite(rotation.Pitch) and finite(rotation.Yaw) and finite(rotation.Roll),"invalid prop rotation")
        local flagv={}
        for _,key in ipairs({"IsFreezed","StartAwake","IsSleeping"}) do
            flagv[key]=read(a,key)
            if type(flagv[key])~="boolean" then once('flag:'..key,'prop flag '..key..' not reflected live; restore keeps native default'); flagv[key]=nil end
        end
        local r={actor=a,actorAddress=id,actorName=a:GetFullName(),class=a:GetClass(),source=a:GetFullName(),
            position=xyz(a:K2_GetActorLocation()),scale=xyz(a:GetActorScale3D()),
            rotation={Pitch=rotation.Pitch,Yaw=rotation.Yaw,Roll=rotation.Roll},
            frozen=flagv.IsFreezed,awake=flagv.StartAwake,sleeping=flagv.IsSleeping,status="idle",generation=c.generation}
        c.records[#c.records+1]=r; c.byActor[id]=r
        return r
    end
    local function inUse(r)
        local body=r.body
        if not live(body) or not same(read(body,"ControllingProp"),r.actor) then return false end
        local pc=body:GetController()
        if not live(pc) or not same(pc:K2_GetPawn(),body) then return false end
        local ps=read(body,"PlayerState")
        return not (H.valid(ps) and (read(ps,"IsDead")==true or read(ps,"IsPendingDisconnect")==true))
    end
    -- Abandonment does not change the native timer, physics, collision or fade.
    -- MRPP may retime/cancel DissolvePropServer; actual destruction is authoritative.
    local function release(c,r,why)
        if r.status~='active' then return end
        r.status='abandoned'; r.body=nil
        H.log('Possession restore: waiting for native despawn '..r.source..' ('..why..')')
    end
    local function despawn(c,r)
        if r.status=='pending' or r.status=='returning' then return end
        r.status='pending'; r.due=clock(c)
        c.work=true
        H.log('Possession restore: native dissolve '..r.source..'; returning now')
        api.tick()
    end
    local function commit(body,a)
        local c=session(body)
        if not c then once('commit-session','commit skipped: no host session for '..(H.valid(body) and body:GetFullName() or 'invalid body')); return end
        if not H.authority(body) then return end -- remote copy; the host commits
        -- Only accepted native mutation observers call commit. Both assigned
        -- references must identify the same map actor; a target/hover field or
        -- an absent optional member cannot establish acceptance.
        local controlling=read(body,'ControllingProp')
        local template=read(body,'PropTemplate')
        if not live(a) then a=controlling end -- BP POST input may be gone
        if not live(a) or not same(controlling,a) or not same(template,a) then
            once('commit-unassigned','commit skipped: accepted map identity not assigned to ControllingProp/PropTemplate')
            return
        end
        -- PossessedProp is optional here, after positive assigned-identity proof.
        -- A reflected but different value still rejects an older/copy event.
        local possessed=read(body,'PossessedProp')
        if possessed~=nil and not same(possessed,a) then once('commit-other','commit skipped: PossessedProp differs from assigned map identity'); return end
        -- Preserve the accepted mutation's snapshot timing and original ledger
        -- pose; repeated events must never recapture an already moved actor.
        if not c.byActor[a:GetAddress()] then snapshot(c,a,true) end
        local r=c.byActor[a:GetAddress()]
        for _,other in ipairs(c.records) do
            if other~=r and other.status=="active" and same(other.body,body) then release(c,other,"prop switch") end
        end
        if not r or not same(r.actor,a) or r.actorName~=a:GetFullName() then
            if read(a,'SpawnedFromPropPawnPhysics')~=true then
                once('unsnapshotted:'..a:GetFullName(),'no pre-control snapshot for '..a:GetFullName()..'; no guessed-position spawn')
            end
            return
        end
        if r.status=="active" and same(r.body,body) then return end
        r.status="active"; r.body=body; r.round=c.mm.CurrentRound; r.due=nil
        H.log("Possession restore: committed "..r.source)
    end
    local function storage(c)
        assert(current(c),"lost authority before native data storage")
        if not Lifetime.rawValid(storageActor) then
            -- A transient level with no owning UWorld keeps this data-only actor
            -- out of native GetAllActorsOfClass discovery. Neither object is spawned,
            -- initialized, registered, begun or ticked. Root once for mod/process life
            -- so a cached struct wrapper can never outlive its backing memory.
            assert(EObjectFlags and EInternalObjectFlags,"UE4SS construction flags unavailable")
            if not Lifetime.rawValid(storageLevel) then
                storageLevel=StaticConstructObject(H.object("/Script/Engine.Level"),H.object("/Engine/Transient"),
                    FName("None"),EObjectFlags.RF_Transient,EInternalObjectFlags.RootSet)
                assert(Lifetime.rawValid(storageLevel),"could not allocate isolated native data level")
            end
            storageActor=StaticConstructObject(H.object(PROP),storageLevel,
                FName("None"),EObjectFlags.RF_Transient,EInternalObjectFlags.RootSet)
            assert(Lifetime.rawValid(storageActor),"could not allocate native transform storage")
        end
        local transform=storageActor.InitialSleepTransform
        local rotation=storageActor.ActorStartRotation
        assert(type(transform)=="userdata" and type(rotation)=="userdata","native struct storage unavailable")
        return transform,rotation
    end
    local function transformFor(c,r)
        local t,rotation=storage(c)
        rotation.Pitch=r.rotation.Pitch; rotation.Yaw=r.rotation.Yaw; rotation.Roll=r.rotation.Roll
        local q=H.object("/Script/Engine.Default__KismetMathLibrary"):Conv_RotatorToQuaternion(rotation)
        -- Getter returns may be Lua tables in e3ba1016. Read scalars only; no table input.
        for _,k in ipairs({"X","Y","Z"}) do t.Translation[k]=r.position[k]; t.Scale3D[k]=r.scale[k] end
        for _,k in ipairs({"X","Y","Z","W"}) do assert(finite(q[k]),"invalid quaternion"); t.Rotation[k]=q[k] end
        return t,rotation
    end
    local function flags(a,r,beforeSpawn)
        assert(auth(a),"refused client prop flags")
        if r.frozen~=nil then a.IsFreezed=r.frozen end
        if r.awake~=nil then a.StartAwake=r.awake end
        if beforeSpawn and r.sleeping~=nil then a.InitialIsSleeping=r.sleeping end
    end
    -- One phase per Core work step. No collision probes, cosmetic actors or
    -- whole-world pool regeneration: those old paths blocked native despawn.
    local function restoreCurrent(c)
        assert(c==ctx and not Lifetime.transition and c.epoch==Lifetime.epoch,'return owner retired during native phase')
    end
    local function spawnCurrent(c,r,a)
        restoreCurrent(c)
        assert(r.spawned==a,'partial return ownership changed during native phase')
    end
    local function spawnedLive(c,r,a)
        spawnCurrent(c,r,a)
        local valid=Lifetime.rawValid(a);spawnCurrent(c,r,a)
        if not valid then return false end
        local name=a:GetFullName();spawnCurrent(c,r,a)
        local dying=a:IsActorBeingDestroyed();spawnCurrent(c,r,a)
        if name:find('Default__',1,true) or dying then return false end
        local world=a:GetWorld();spawnCurrent(c,r,a)
        local worldValid=Lifetime.rawValid(world);spawnCurrent(c,r,a)
        return worldValid
    end
    local function restoreJob(c,r)
        -- storageActor is shared by every concurrent return: fill it right before
        -- each native call that reads it, never across a work-step boundary.
        local a
        return Work.sequence({function()
            local t=transformFor(c,r)
            a=gameplay():BeginDeferredActorSpawnFromClass(c.gm,r.class,t,1,nil,2)
            -- Own the raw returned allocation before any reflected identity or
            -- liveness validation can throw. An unreadable identity stays quarantined.
            r.spawned=a;restoreCurrent(c)
            assert(a,'deferred prop spawn failed')
            local address=a:GetAddress();spawnCurrent(c,r,a)
            if address==0 then r.spawned=nil;error('deferred prop spawn returned null') end
            r.spawnedAddress=address
            local name=a:GetFullName();spawnCurrent(c,r,a)
            assert(type(name)=='string' and name~='','deferred prop identity unavailable')
            r.spawnedName=name
            assert(spawnedLive(c,r,a),'deferred prop spawn failed')
            a:SetReplicates(true);restoreCurrent(c);a.bAlwaysRelevant=true; a.NetDormancy=1
            a.SpawnedFromPropPawnPhysics=false; flags(a,r,true)
            return true
        end,function()
            gameplay():FinishSpawningActor(a,transformFor(c,r),2)
            restoreCurrent(c);assert(spawnedLive(c,r,a),'restored actor destroyed during Finish'); return true
        end,function()
            a:SetUncontrolledByWitch();restoreCurrent(c);flags(a,r,false)
            a:AutoSetInitialPhysicsState();restoreCurrent(c)
            if r.sleeping then a:PutToSleep();restoreCurrent(c);a:HandleSleepServer();restoreCurrent(c)
            else a:WakeFromSleep();restoreCurrent(c);a:HandleWakeServer();restoreCurrent(c) end
            if r.frozen then a:UpdateFromFrozenState();restoreCurrent(c) end
            a:FlushNetDormancy();restoreCurrent(c);a:ForceNetUpdate();restoreCurrent(c);return true
        end,function()
            -- Native appear effect of witch-spawned props: Dissolve() on tick runs
            -- the fade-in branch while IsFadingIn, then clears it after DissolveTime.
            a.AliveTime=0; a.IsFadingIn=true; a:SetActorTickEnabled(true);restoreCurrent(c);return true
        end,function()
            local oldAddress,oldName=r.actorAddress,r.actorName
            c.byActor[oldAddress]=nil
            r.actor=a; r.actorAddress=a:GetAddress(); r.actorName=a:GetFullName()
            c.byActor[r.actorAddress]=r; r.status='restored'; r.spawned=nil; r.spawnedAddress=nil; r.spawnedName=nil; r.body=nil
            c.repairs[#c.repairs+1]={oldAddress=oldAddress,oldName=oldName,actor=a,
                classAddress=r.class:GetAddress(),className=r.class:GetFullName(),epoch=c.poolEpoch,index=1}
            H.log('Possession restore: returned '..r.source..' at original pose')
            return true
        end})
    end
    local function cleanupSpawn(c,r)
        if not r.spawned then return true end
        local function abandoned()
            return c~=ctx or Lifetime.transition or c.epoch~=Lifetime.epoch
        end
        local function forget(status)
            r.spawned=nil;r.spawnedAddress=nil;r.spawnedName=nil;r.cleanupError=nil;r.status=status
        end
        -- Reset/travel only abandons Lua ownership. Never inspect the old actor.
        if abandoned() then forget('abandoned');return true end
        r.status='cleanup_pending'
        local ok,err=pcall(function()
            local a=r.spawned
            -- Never recapture a name/address from an unknown allocation on retry:
            -- it could now identify a different object. Native world teardown is
            -- the only admitted completion for this quarantined raw handle.
            assert(r.spawnedAddress and r.spawnedAddress~=0 and r.spawnedName,
                'partial prop has no admitted identity; waiting for native owner teardown')
            local valid=a:IsValid();spawnCurrent(c,r,a)
            if valid==false then return end -- positive native dead-object proof
            assert(valid==true,'partial prop liveness unavailable')
            local address=a:GetAddress();spawnCurrent(c,r,a)
            local name=a:GetFullName();spawnCurrent(c,r,a)
            assert(r.spawnedAddress==address and r.spawnedName==name,'partial prop identity changed')
            local dying=a:IsActorBeingDestroyed();spawnCurrent(c,r,a)
            if dying==true then return end -- native destruction already owns it
            assert(dying==false,'partial prop destruction state unavailable')
            local gm,mm,gs=host(c.gs);spawnCurrent(c,r,a)
            assert(same(gm,c.gm) and same(mm,c.mm) and same(gs,c.gs),'partial prop cleanup outside original owner')
            spawnCurrent(c,r,a)
            local gs=gameplay():GetGameState(a);spawnCurrent(c,r,a)
            assert(same(gs,c.gs),'partial prop cleanup outside original world');spawnCurrent(c,r,a)
            a:K2_DestroyActor();spawnCurrent(c,r,a)
            local remaining=a:IsValid();spawnCurrent(c,r,a)
            if remaining~=false then
                assert(remaining==true,'partial prop liveness unavailable after destroy')
                local destroyed=a:IsActorBeingDestroyed();spawnCurrent(c,r,a)
                assert(destroyed==true,'native partial prop destruction refused')
            end
        end)
        if abandoned() then forget('abandoned');return true end
        if not ok then
            r.cleanupError=tostring(err);once('cleanup:'..r.source,'partial return cleanup pending: '..r.cleanupError)
            return false
        end
        forget('failed')
        return true
    end
    local MESH_LIST='MeshList_3_9A021886472783B7C6D4C1A40C1D892E'
    local element=FAPP_SERVICES.runtime.unwrap
    local function length(a)
        local ok,n=pcall(function() return a:GetArrayNum() end)
        if not ok then n=#a end
        assert(type(n)=='number' and n>=0,'native repair array length unavailable')
        return n
    end
    local function repair(c,job)
        -- Never keep a struct/array view through a native pool regeneration.
        if job.epoch~=c.poolEpoch then return true end -- native regeneration already owns the new inventory
        if not job.arrays then
            local map=c.gs.Proplist
            if not read(map,'ForEach') then return false end
            local list
            map:ForEach(function(key,value)
                local cls=element(key)
                if cls and cls:GetAddress()==job.classAddress and cls:GetFullName()==job.className then list=read(element(value),MESH_LIST) end
            end)
            if not list then return false end -- singleton/new class: native generation owns its struct
            job.arrays={c.gs.AllProps,list}; job.array=1
        end
        local started=os.clock()
        while job.array<=#job.arrays do
            local array=job.arrays[job.array]
            assert(read(array,'ForEach') or read(array,'GetArrayNum'),'pool getter returned a Lua copy, not a native array view')
            local count=length(array)
            while job.index<=count do
                local i=job.index; job.index=i+1
                -- UObject references go into an EXISTING native TArray. No table
                -- containers/structs are assigned or passed to any UFunction.
                local actor=element(array[i])
                -- EndPlay ends Actor liveness before UObject collection. The
                -- e3ba1016 UObject IsValid checks global-object-map membership
                -- and Unreachable; a freshly read native-array wrapper is safe
                -- to identify, without treating a destroyed Actor as playable.
                if actor and actor:IsValid()==true and actor:GetAddress()==job.oldAddress and actor:GetFullName()==job.oldName then
                    array[i]=job.actor; job.found=true
                end
                if (os.clock()-started)*1000>=1.5 then return nil end
            end
            if not job.found then return false end -- native reload pruned this class/reference
            job.array=job.array+1; job.index=1; job.found=false
        end
        H.log('Possession restore: repaired native pool references; no world rediscovery')
        return true
    end
    function api.poll() end -- inventory capture occurs only at native control mutation
    function api.pending()
        return ctx~=nil and ctx.work==true
    end
    function api.tick()
        local c=ctx; if not c or not c.work then return end
        local now=clock(c); local work=false
        for _,r in ipairs(c.records) do
            if r.status=='pending' then
                work=true
                if now+1e-6>=r.due then
                    r.status='returning'
                    local step=restoreJob(c,r)
                    Work.submit('possession:'..r.actorAddress,'Possession',function()
                        if c~=ctx or Lifetime.transition or c.epoch~=Lifetime.epoch or not current(c) then
                            -- A queued continuation cannot touch a departing native world.
                            r.spawned=nil; r.spawnedAddress=nil; r.spawnedName=nil
                            return true
                        end
                        local ok,done=pcall(step)
                        if not ok then
                            r.status='failed'; once('restore:'..r.source,'return failed: '..tostring(done))
                            cleanupSpawn(c,r) -- one immediate rollback attempt; no retry job
                            return true
                        end
                        return done
                    end)
                end
            elseif r.status=='returning' then work=true end
        end
        if #c.repairs>0 then
            local job=table.remove(c.repairs,1)
            Work.submit('possession-pool:'..job.oldAddress,'Possession',function()
                if c~=ctx or not current(c) then return true end
                -- Missing/pruned native entries stay native; never regenerate a
                -- live world's pool just to insert a replacement.
                return repair(c,job)~=nil
            end)
        end
        c.work=work or #c.repairs>0
    end
    -- Declare acceptance observers synchronously in the Objective world. They
    -- must not wait behind the background hook-installation queue, including
    -- when a skill/pawn class first becomes available in a destination world.
    local decisions,declared={},false
    local function decision(path,fn)
        decisions[#decisions+1]={path=path,fn=H.guard(path,fn)}
    end
    local function installDecisions()
        if declared or FAPP_MODE.state.mode~='objective' then return end
        declared=true
        for _,h in ipairs(decisions) do FAPP_SERVICES.runtime.hook(h.path,h.fn) end
    end
    -- SwitchPropServerFunction POST also runs on refusal. CurrentTargetProp
    -- and owner.TargetProp are requests, not acceptance; even matching assigned
    -- fields can belong to an earlier possession. Do not acquire from that POST.
    -- Cooked acceptance synchronously assigns PropTemplate/ControllingProp and
    -- invokes OnRep_ControllingProp, then PropPossessed, before the server returns.
    -- These existing mutation boundaries own acquisition. BP POST parameters
    -- may be gone, so commit verifies the pawn's assigned native identities.
    decision(PAWN..':PropPossessed',function(self,prop)
        local ok,a=pcall(function() return prop:get() end)
        -- pcall only decodes the optional BP input; success is not acceptance.
        commit(self:get(),ok and live(a) and a or nil)
    end)
    -- Ordinary SwitchProp spawns a COPY: PropTemplate remains the map actor,
    -- whereas ControllingProp becomes SpawnProp's result before OnRep. Possess
    -- itself assigns both fields to the same map actor. No empty OUT reads.
    decision(PAWN..':OnRep_ControllingProp',function(self)
        local body=self:get(); if not live(body) or not H.authority(body) then return end
        local a=read(body,'ControllingProp'); local template=read(body,'PropTemplate')
        if live(a) and live(template) and not same(a,template) then generated[Lifetime.key(a)]=true; return end
        commit(body)
    end)
    FAPP_API.on('context_changed',installDecisions)
    FAPP_API.on('world_ready',installDecisions,{ungated=true})
    FAPP_API.on('begin_play_pre',function()
        installDecisions()
        if declared and FAPP_MODE.state.mode=='objective' then FAPP_API.retry_hooks() end
    end,{class_filter=function(name) return name=='B_PropPawnPhysics_C' or name=='B_ObjectiveWitch_C' or name=='B_Witch_C' end})
    for _,path in ipairs({PAWN,SKILL}) do
        FAPP_API.notify(path,function()
            installDecisions()
            if declared and FAPP_MODE.state.mode=='objective' then FAPP_API.retry_hooks() end
        end)
    end
    installDecisions()
    for _,fn in ipairs({"SwitchProp","SwitchPropBack","ReceiveDestroyed","RemoveControllingProp"}) do
        H.hook(PAWN..":"..fn,function(self)
            local body=self:get(); local c=ctx
            if not current(c) then return end
            for _,r in ipairs(c.records) do
                if (r.status=="active" or r.status=="pending") and same(r.body,body) and (fn~="SwitchProp" or not inUse(r)) then release(c,r,fn) end
            end
        end)
    end
    H.hook(PROP..':StartDestroyCountdown',function(self)
        local c=ctx; if not current(c) then return end
        local a=self:get(); local r=c.byActor[a:GetAddress()]
        if r and same(r.actor,a) then release(c,r,'native countdown') end
    end)
    -- The original returns the moment the abandoned prop starts dissolving
    -- (native timer or MRPP retime); EndPlay covers destruction without a dissolve.
    H.hook(PROP..':DissolvePropServer',function(self)
        local c=ctx; if not current(c) then return end
        local a=self:get(); local r=c.byActor[a:GetAddress()]
        if r and same(r.actor,a) and (r.status=='active' or r.status=='abandoned') then despawn(c,r) end
    end)
    -- Actor EndPlay is inherited/overridden by prop subclasses. A hook on the
    -- base Blueprint ReceiveEndPlay does not observe every native destruction.
    FAPP_API.on('end_play_pre',function(self,reason)
        local c=ctx; if not c then return end
        local a=self:get(); local address=a:GetAddress(); local r=c.byActor[address]
        if not r or r.actorName~=a:GetFullName() then return end
        local why=reason and reason:get()
        if why~=0 then c.cancelled=true; c.work=false; return end
        if not current(c) then return end
        if r.status=='active' or r.status=='abandoned' then despawn(c,r) end
    end)
    H.hook(O.."B_ObjectiveGameState.B_ObjectiveGameState_C:LoadPropsAndCauldrons",function(self)
        local c=session(self:get()); if c then c.poolEpoch=c.poolEpoch+1 end
    end)
    for _,fn in ipairs({"HandleEndMatch","HandleEndMatchOverride"}) do
        H.hook(O.."B_ObjectiveGameMode.B_ObjectiveGameMode_C:"..fn,function(self)
            local c=session(self:get()); if c then
                for _,r in ipairs(c.records) do release(c,r,"round end") end
            end
        end)
    end
    local function releasedPlayer(pc,ps,why)
        local c=ctx; if not c then return end
        for _,r in ipairs(c.records) do if r.status=='active' or r.status=='pending' then
            local body=r.body
            if not live(body) or (ps and same(read(body,'PlayerState'),ps)) or (pc and same(body:GetController(),pc)) then release(c,r,why) end
        end end
    end
    H.hook('/Script/Engine.Controller:UnPossess',function(self)
        releasedPlayer(self:get(),nil,'unpossess')
    end)
    H.hook(O..'B_ObjectiveGameMode.B_ObjectiveGameMode_C:K2_OnLogout',function(_,pc)
        releasedPlayer(pc:get(),nil,'logout')
    end)
    function api.changed(o,key)
        if not ctx then return end
        if (key=='IsDead' or key=='IsPendingDisconnect') and read(o,key)==true then releasedPlayer(nil,o,key)
        elseif key=='State' and same(o,ctx.gs) and read(o,'State')==3 then
            for _,r in ipairs(ctx.records) do release(ctx,r,'round state') end
        end
    end
    function api.cleanupFailed()
        local c=ctx; if not c then return true end
        local errors={}
        for _,r in ipairs(c.records) do
            if r.spawned and not cleanupSpawn(c,r) then errors[#errors+1]='possession prop '..tostring(r.spawnedName or r.source)..': '..tostring(r.cleanupError) end
        end
        return #errors==0,table.concat(errors,' | ')
    end
    function api.cleanupPending()
        if ctx then for _,r in ipairs(ctx.records) do if r.status=='cleanup_pending' then return true end end end
        return false
    end
    function api.reset() ctx=nil; generated={}; generation=generation+1; reports={} end
    function api.cleanup()
        local c=ctx
        if c then
            c.cancelled=true; c.work=false
            for _,r in ipairs(c.records) do Work.cancel('possession:'..r.actorAddress) end
            for _,r in ipairs(c.repairs) do Work.cancel('possession-pool:'..r.oldAddress) end
        end
        local complete,why=api.cleanupFailed()
        if complete then api.reset() end
        return complete,why
    end
    if FAPP_API and FAPP_API.own then FAPP_API.own(api.cleanup,api.reset) end
    if FAPP_API and type(FAPP_API.command)=='function' then
        FAPP_API.command('fapprestorecleanup',function() return api.cleanupFailed() end)
    end
    return api
end
return M
