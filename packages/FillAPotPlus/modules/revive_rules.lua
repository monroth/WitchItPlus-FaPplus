-- REV2: one-use groups of native revive circles, never modifies spare-life respawns.
local M={}
local O='/Game/Blueprints/Gamemodes/ObjectiveMode/'
local TOTEM=O..'B_ReviveTotem.B_ReviveTotem_C'
local PROP='/Game/Blueprints/Props/Bases/B_StaticMeshProp.B_StaticMeshProp_C'
-- Repeated native-style draw: random among the three farthest remaining points.
-- Ties keep distinct actor identities rather than native distance-map overwrites.
function M.choose(points,witches,n,random)
    local ranked,positions={},{}
    for _,w in ipairs(witches) do positions[#positions+1]=w:K2_GetActorLocation() end
    for _,p in ipairs(points) do
        local v=p:K2_GetActorLocation(); local distance=10000000000
        for _,a in ipairs(positions) do
            distance=math.min(distance,(a.X-v.X)^2+(a.Y-v.Y)^2+(a.Z-v.Z)^2)
        end
        ranked[#ranked+1]={point=p,distance=math.floor(distance+.5),order=#ranked+1}
    end
    table.sort(ranked,function(a,b) return a.distance>b.distance or (a.distance==b.distance and a.order<b.order) end)
    local result={}
    for _=1,math.min(n,#ranked) do
        local index=random(math.min(3,#ranked))+1
        assert(index>=1 and index<=math.min(3,#ranked) and index%1==0,'invalid native random index')
        result[#result+1]=table.remove(ranked,index).point
    end
    return result
end
function M.init(C,H)
    local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
    local L=FAPP_SERVICES.lifetime
    local Registry=FAPP_SERVICES.registry
    local api,ctx,selected,reports={},nil,nil,{}
    local storageLevel,storageActor,constructing
    local read=FAPP_SERVICES.runtime.read
    local get=FAPP_SERVICES.runtime.unwrap
    local function live(o) return H.valid(o) and not o:GetFullName():find('Default__',1,true) end
    local function same(a,b) return live(a) and live(b) and L.key(a)==L.key(b) end
    local function usable(c,o) return live(o) and L.sameWorld(o,c.gm) end
    local function once(s) if not reports[s] then reports[s]=true; H.log('REV2 '..s) end end
    local function enabled(s) return (s.ReviveTotemsPerDeadWitch or 1)~=1 or s.ReviveAtFilledCauldrons==true end
    local function context(o)
        if L.transition or not enabled(ctx and ctx.settings or selected or C) then return end
        local gm,mm,gs=H.world(o)
        if not gm or not H.authority(gm) or not H.authority(gs) or not H.authority(o)
            or not H.class(gm,'B_ObjectiveGameMode_C') or not L.sameWorld(o,gm)
            or mm.CurrentRound<=0 or (gs.State~=1 and gs.State~=2) then return end
        local settings=H.settings(mm); if not enabled(settings) then return end
        if not ctx or ctx.epoch~=L.epoch or not same(ctx.gm,gm) or ctx.round~=mm.CurrentRound then
            ctx={gm=gm,mm=mm,gs=gs,round=mm.CurrentRound,epoch=L.epoch,settings=settings,
                groups={},dead={},pots={},pending={}}
        end
        return ctx
    end
    local function full(p)
        local stacks,max=read(p,'Stacks'),read(p,'MaxStacks')
        return type(stacks)=='number' and type(max)=='number' and max>0 and stacks>=max
    end
    local function storage()
        -- Same isolated, rooted data-only storage as possession_restore; never spawned in a world.
        if not L.rawValid(storageActor) then
            assert(EObjectFlags and EInternalObjectFlags,'construction flags unavailable')
            if not L.rawValid(storageLevel) then
                storageLevel=StaticConstructObject(H.object('/Script/Engine.Level'),H.object('/Engine/Transient'),
                    FName('None'),EObjectFlags.RF_Transient,EInternalObjectFlags.RootSet)
                assert(L.rawValid(storageLevel),'native data level unavailable')
            end
            storageActor=StaticConstructObject(H.object(PROP),storageLevel,FName('None'),
                EObjectFlags.RF_Transient,EInternalObjectFlags.RootSet)
            assert(L.rawValid(storageActor),'native data actor unavailable')
        end
        local t,t2=storageActor.InitialSleepTransform,storageActor.CurrentSleepTransform
        assert(type(t)=='userdata' and type(t2)=='userdata','native transform storage unavailable')
        return t,t2
    end
    local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
    local function fillVector(v,x,y,z)
        assert(type(v)=='userdata' and finite(x) and finite(y) and finite(z),'invalid native vector')
        v.X=x; v.Y=y; v.Z=z
    end
    local function safeTransform(c,pot)
        local t=storage(); local a=t.Translation
        local witch=H.object(O..'B_ObjectiveWitch.B_ObjectiveWitch_C'):GetCDO()
        assert(L.rawValid(witch),'native witch CDO unavailable')
        local capsule=witch.CapsuleComponent
        local radius,height=capsule:GetScaledCapsuleRadius(),capsule:GetScaledCapsuleHalfHeight()
        local sub=H.object('/Script/Engine.Default__SubsystemBlueprintLibrary'):GetWorldSubsystem(c.gm,
            H.object('/Game/Blueprints/Match/GameRules/MatchRules/B_MatchParametersSubsystem.B_MatchParametersSubsystem_C'))
        local multiplier=sub.WitchMatchParameters.PlayerSizeMultiplier
        assert(finite(multiplier) and multiplier>0,'native witch size unavailable')
        radius=radius*multiplier+2; height=height*multiplier+2
        assert(finite(radius) and finite(height) and radius>0 and height>=radius,'invalid native capsule')
        local pos=pot:K2_GetActorLocation(); local scale=pot:GetActorScale3D()
        local offset=math.max(500,500*math.max(math.abs(scale.X),math.abs(scale.Y)))+radius
        local system=H.object('/Script/Engine.Default__KismetSystemLibrary')
        local filter=H.object('/Script/Engine.PrimitiveComponent')
        local function overlap(x,y,z,r,h)
            fillVector(a,x,y,z)
            -- UObject component OUT arrays contain no soft/weak struct members.
            local blocked=system:CapsuleOverlapComponents(c.gm,a,r,h,{0,1,2,3},filter,{c.gm},{})
            assert(type(blocked)=='boolean','native overlap did not return bool')
            return blocked
        end
        local function line(x,y,z)
            -- A one-unit vertical capsule locates solid ground without an
            -- FHitResult OUT. Reject side contacts again with the full capsule.
            local top=pos.Z+512
            return overlap(x,y,(top+z)/2,1,(top-z)/2+1)
        end
        for i=0,7 do
            local angle=i*math.pi/4; local x,y=pos.X+offset*math.cos(angle),pos.Y+offset*math.sin(angle)
            if line(x,y,pos.Z-512) and not line(x,y,pos.Z+511) then
                local low,high=pos.Z-512,pos.Z+511
                -- Bisection consumes only overlap booleans and strong component OUT arrays.
                for _=1,11 do local z=(low+high)/2; if line(x,y,z) then low=z else high=z end end
                local z=high+height+2
                local blocked=overlap(x,y,z,radius,height)
                if not blocked then
                    for _,v in ipairs({'X','Y','Z'}) do t.Scale3D[v]=1; t.Rotation[v]=0 end
                    t.Rotation.W=1
                    return t
                end
            end
        end
    end
    local function destroy(c,p)
        if usable(c,p) then
            -- Retire siblings synchronously before another actor tick can complete its circle.
            p:SetActorTickEnabled(false); p:SetActorEnableCollision(false); p:K2_DestroyActor()
        end
    end
    local function retire(c,g,except)
        for _,p in ipairs(g.points) do if not same(p,except) then destroy(c,p) end end
    end
    local function spawn(c,t)
        local p; constructing=true
        local ok,err=pcall(function()
            local cls=H.object(TOTEM)
            assert(cls:GetCDO().bReplicates==true,'native totem replication unavailable')
            local g=H.object('/Script/Engine.Default__GameplayStatics')
            p=g:BeginDeferredActorSpawnFromClass(c.gm,cls,t,0,nil,0)
            assert(usable(c,p),'native totem spawn failed')
            g:FinishSpawningActor(p,t,0)
            p.WitchInCircleTimeNeeded=C.TotemReviveSeconds
        end)
        constructing=false
        if not ok then destroy(c,p); once('totem skipped: '..tostring(err)); return end
        return p
    end
    local function pointTransform(p)
        local t=storage(); local source=p:GetTransform()
        for _,k in ipairs({'X','Y','Z'}) do
            assert(finite(source.Translation[k]) and finite(source.Scale3D[k]),'invalid point transform')
            t.Translation[k]=source.Translation[k]; t.Scale3D[k]=source.Scale3D[k]
        end
        for _,k in ipairs({'X','Y','Z','W'}) do
            assert(finite(source.Rotation[k]),'invalid point rotation'); t.Rotation[k]=source.Rotation[k]
        end
        return t
    end
    local function potPoint(c,pot)
        local id=L.key(pot); local r=c.pots[id]
        if not full(pot) then if r then destroy(c,r.point); c.pots[id]=nil end; return end
        local ok,t=pcall(safeTransform,c,pot)
        if not ok or not t then
            if r then destroy(c,r.point); c.pots[id]=nil end
            once('filled cauldron skipped: '..tostring(ok and 'no grounded clear offset' or t)); return
        end
        if r and usable(c,r.point) then
            local pos=r.point:K2_GetActorLocation(); local target=t.Translation
            if math.abs(pos.X-target.X)<.01 and math.abs(pos.Y-target.Y)<.01 and math.abs(pos.Z-target.Z)<.01 then return end
            -- A relocated circle starts fresh; its old progress must not move to another position.
            destroy(c,r.point); c.pots[id]=nil
        end
        local p=spawn(c,t)
        if p then c.pots[id]={pot=pot,point=p}; H.log('REV2 filled circle: '..pot:GetFullName()) end
    end
    local function syncDead(c,exclude)
        local dead={}
        for _,ps in ipairs(H.players(c.gs)) do
            local pc=read(ps,'PlayerController'); local pawn=read(pc,'Pawn')
            if not same(ps,exclude) and usable(c,ps) and H.authority(ps) and ps.IsDead==true
                and not ps.IsPendingDisconnect and not H.waiter(ps) and usable(c,pawn)
                and H.class(pawn,'B_ObjectiveKillSpectator_C') then dead[L.key(ps)]=ps end
        end
        c.dead=dead
        for id,g in pairs(c.groups) do if not dead[id] then retire(c,g); c.groups[id]=nil end end
    end
    local function pots(c)
        if not next(c.dead) or not c.settings.ReviveAtFilledCauldrons then
            for _,r in pairs(c.pots) do destroy(c,r.point) end; c.pots={}; return
        end
        local seen={}
        for _,p in ipairs(Registry.list('B_ObjectiveCauldron_C')) do
            if usable(c,p) then seen[L.key(p)]=true; potPoint(c,p) end
        end
        for id,r in pairs(c.pots) do if not seen[id] then destroy(c,r.point); c.pots[id]=nil end end
    end
    local function draw(c,n)
        local points,seen,witches={},{},{}
        local array=c.gm.AllWitchRespawnPoints
        local function add(p)
            p=get(p); local id=L.key(p)
            if usable(c,p) and H.class(p,'B_ObjectiveWitchRespawnPoint_C') and not seen[id] then
                seen[id]=true; points[#points+1]=p
            end
        end
        if type(array)=='table' and not array.ForEach then for _,p in ipairs(array) do add(p) end
        elseif array then array:ForEach(function(_,p) add(p) end) end
        for _,ps in ipairs(H.players(c.gs)) do
            local pawn=read(read(ps,'PlayerController'),'Pawn')
            if usable(c,pawn) and not ps.IsPendingDisconnect and ps.IsDead~=true
                and (H.class(pawn,'B_Witch_C') or H.class(pawn,'B_PropPawnPhysics_C')) then witches[#witches+1]=pawn end
        end
        return M.choose(points,witches,n,function(k)
            return H.object('/Script/Engine.Default__KismetMathLibrary'):RandomInteger(k)
        end)
    end
    function api.start(o)
        local gm,mm=H.world(o)
        if not gm or not H.authority(gm) or not H.class(gm,'B_ObjectiveGameMode_C') then return end
        selected=H.settings(mm); context(o)
    end
    function api.begin(o)
        if constructing then return end
        local c=context(o); if c then c.pending[#c.pending+1]=o end
    end
    function api.spawned(o,ps)
        local c=context(o); if not c then return end
        ps=get(ps); local pending=c.pending; c.pending={}
        syncDead(c)
        local id=L.key(ps)
        if not id or not c.dead[id] or c.groups[id] then
            for _,p in ipairs(pending) do destroy(c,p) end; pots(c); return
        end
        local n=c.settings.ReviveTotemsPerDeadWitch or 1
        local group={owner=ps,points={}}; c.groups[id]=group
        if n==1 then -- filled-cauldron option alone retains the original native point choice
            for _,p in ipairs(pending) do if usable(c,p) then group.points[#group.points+1]=p end end
        else
            for _,p in ipairs(pending) do destroy(c,p) end
        end
        if n>1 or (n==1 and #group.points==0) then
            local ok,points=pcall(draw,c,n)
            if ok then for _,point in ipairs(points) do
                local made,t=pcall(pointTransform,point)
                if made then local p=spawn(c,t); if p then group.points[#group.points+1]=p end
                else once('point skipped: '..tostring(t)) end
            end else once('point draw failed: '..tostring(points)) end
        end
        H.log('REV2 totems='..#group.points..' requested='..n..' dead='..ps:GetFullName())
        pots(c)
        if n==0 and not c.settings.ReviveAtFilledCauldrons then
            -- Native OnRevivePossible was already broadcast; retire its tutorial hint too.
            local ok,err=pcall(function() c.gs:ResetReviveHelpServer() end)
            if not ok then once('revive help reset failed: '..tostring(err)) end
        end
    end
    function api.deadChanged(ps)
        if not enabled(ctx and ctx.settings or selected or C) then return end
        if not H.class(ps,'B_ObjectivePlayerState_C') then return end
        local c=context(ps); if not c then return end
        local id=L.key(ps)
        if ps.IsDead==false then
            local firing,spent
            -- RespawningState is a reflected instance field set BEFORE native IsDead=false.
            -- Do not consume RevieWitch OUT or hook each native tick.
            for _,g in pairs(c.groups) do for _,p in ipairs(g.points) do
                if usable(c,p) and same(read(p,'RespawningState'),ps) then firing=p; spent=g end
            end end
            local own=c.groups[id]
            if spent then
                local issuer=L.key(spent.owner)
                c.groups[issuer]=nil
                retire(c,spent,firing) -- firing actor continues native ResetReviveHelpServer + destroy
                H.log('REV2 group consumed; totems='..#spent.points..' revived='..ps:GetFullName())
                if issuer~=id then
                    c.groups[id]=nil
                    if own and c.dead[issuer] then
                        own.owner=spent.owner; c.groups[issuer]=own
                        H.log('REV2 unused group transferred to '..spent.owner:GetFullName())
                    end
                end
            elseif own then
                retire(c,own); c.groups[id]=nil -- filled circle or another native revival
            end
            -- A filled circle can revive again, but only while another witch remains fully dead.
            -- Leave a currently executing native circle alone until its own body destroys it.
            for potId,r in pairs(c.pots) do
                if usable(c,r.point) and same(read(r.point,'RespawningState'),ps) then c.pots[potId]=nil end
            end
            syncDead(c); pots(c)
        else syncDead(c); pots(c) end
    end
    function api.stacks(pot)
        if not (ctx and ctx.settings or selected or C).ReviveAtFilledCauldrons then return end
        if not H.class(pot,'B_ObjectiveCauldron_C') then return end
        local c=context(pot); if c then syncDead(c); pots(c) end
    end
    function api.logout(o,pc)
        local c=context(o); if not c then return end
        syncDead(c,read(get(pc),'PlayerState')); pots(c)
    end
    function api.endRound(o)
        local c=ctx; if not c then return end
        local gm=H.world(o)
        if same(gm,c.gm) then
            for _,g in pairs(c.groups) do retire(c,g) end
            for _,r in pairs(c.pots) do destroy(c,r.point) end
            for _,p in ipairs(c.pending) do destroy(c,p) end
        end
        ctx=nil
    end
    local function hook(asset,fn,cb) H.hook(O..asset..'.'..asset..'_C:'..fn,cb) end
    hook('B_ObjectiveGameMode','HandleStartMatchOverride',function(self) api.start(get(self)) end)
    hook('B_ReviveTotem','ReceiveBeginPlay',function(self) api.begin(get(self)) end)
    hook('B_ObjectiveGameMode','SpawnReviveTotem',function(self,ps) api.spawned(get(self),ps) end)
    hook('B_ObjectiveGameMode','K2_OnLogout',function(self,pc) api.logout(get(self),pc) end)
    hook('B_ObjectiveGameMode','HandleEndMatchOverride',function(self) api.endRound(get(self)) end)
    hook('B_ObjectiveMatchManager','TearDown',function(self)
        if ctx then local gm=H.managerWorld(get(self)); if gm then api.endRound(gm) end end
        api.reset()
    end)
    function api.reset() ctx=nil; selected=nil; reports={}; constructing=false end
    function api.poll() end -- no reflected reads or engine calls in steady state
    -- Reuse the existing EndPlay signal; never reconcile the world from a tick.
    L.onRetire=L.onRetire or {}
    L.onRetire[#L.onRetire+1]=function(o)
        local c=ctx
        if not c or L.transition or c.epoch~=L.epoch then return end
        local ok,address,name=pcall(function() return o:GetAddress(),o:GetFullName() end)
        local id=ok and address and name and (tostring(address)..':'..name)
        local r=id and c.pots[id]
        if r and H.authority(c.gm) then c.pots[id]=nil; destroy(c,r.point) end
    end
    L.onReset(api.reset)
    return api
end
return M
