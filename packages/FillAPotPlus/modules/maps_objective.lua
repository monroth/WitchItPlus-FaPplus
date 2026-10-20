-- Listen-host adapter. Native gameplay still generates WantedProp and handles delivery.
local M={}
local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
local PROP='/Game/Blueprints/Props/Bases/B_StaticMeshProp.B_StaticMeshProp_C'
local START='/Game/Blueprints/StaticProps/Placeable/Utility/BP_WitchPlayerStart.BP_WitchPlayerStart_C'
function M.init(X)
    local H,C=X.H,X.C; local O=X.OM
    local pool=dofile(dir..'maps_pool.lua').init(X)
    local api,states,clients,colourCache={}, {}, {}, {}
    local function markerRevision()
        local v=X.Registry.versions
        return v.BP_WitchCauldron_C+v.BP_WitchRuneStone01_C+v.BP_WitchPlayerStart_C+v.B_WitchPlayerStart_C+v.B_PlayerStart_C
    end
    local function discoveryRevision()
        return markerRevision()+X.Registry.versions.B_StaticMeshProp_C+X.Registry.versions.B_ObjectiveCauldron_C
            +X.Registry.versions.B_ObjectiveGameState_C
    end
    local clientObjects=-1
    local function context(o,host,knownMarkers)
        if not X.live(o) then return end
        local g=X.gameplay(); local gs=H.class(o,'B_ObjectiveGameState_C') and o or g:GetGameState(o)
        if not X.live(gs) or not H.class(gs,'B_ObjectiveGameState_C') then return end
        local ok,same=pcall(function() return X.same(gs:GetWorld(),o:GetWorld()) end)
        if not ok or not same then return end
        local gi=X.gi(o); local options=H.valid(gi) and gi.UsedMatchOptions
        local builtin=H.valid(options) and X.read(options.MapData,'IsBuiltInCustomMap_24_B260140C4981E09A0400EBBB5AF787AD')==true
        local custom=H.valid(options) and options.CustomMapSelected
        if not custom and not builtin then
            -- A client's GameInstance options can lag the actor/RPC stream. Only
            -- recognise a custom world from its allowlisted carrier signatures.
            if host or H.authority(gs) then return end
            local markers=knownMarkers or X.markers(gs); if #markers==0 then return end
        end
        local gm=g:GetGameMode(o)
        if host and (not H.class(gm,'B_ObjectiveGameMode_C') or not H.authority(gm)) then return end
        return gs,gm,options
    end
    function api.context(o,host) return context(o,host) end
    local function state(gs,gm,options)
        local id=gs:GetAddress(); local s=states[id]
        if not s or not X.same(s.gs,gs) then
            s={gs=gs,gm=gm,options=options,oldTimer=options.DisableStartMatchTimer,
                ready=false,reason='waiting for custom layout load',actors={},byMarker={},partial={}}
            states[id]=s
        end
        if C.CreativeMaps and not s.ready then options.DisableStartMatchTimer=true end
        return s
    end
    local function refuse(s,why)
        s.ready=false; s.reason=why; s.options.DisableStartMatchTimer=true; s.expired=s.deadline and os.time()>=s.deadline or false
        if s.lastMessage~=why then s.lastMessage=why; X.log('Start','Cannot start Fill a Pot: '..why);X.message(s.gm,'This map cannot start Fill a Pot. Open it in Creative and check map problems.') end
    end
    local function spawnJob(ctx,cls,transform,colour,info,done,began)
        local actor,g,shape
        local step=X.Work.sequence({function()
            shape=X.native(transform);g=X.gameplay()
            actor=g:BeginDeferredActorSpawnFromClass(ctx,X.asset(cls),shape,1,nil,2)
            assert(X.live(actor),'BeginDeferredActorSpawnFromClass returned invalid actor: '..cls)
            began(actor)
            return true
        end,function()
            actor:SetReplicates(true);actor.bAlwaysRelevant=true;actor.NetDormancy=1
            return true
        end,function()
            if colour then actor.Color=colour;actor.MinPropDistance=X.minDistance();X.applyTypeExclusions(actor,info) end
            return true
        end,function() g:FinishSpawningActor(actor,shape,2);return true end,function()
            if colour then actor.GameState=g:GetGameState(ctx);actor.Gamemode=g:GetGameMode(ctx) end
            return true
        end,function() if colour then actor:Init() end;return true end,function()
            if colour then actor.MinPropSphere:SetSphereRadius(X.minDistance(),false) end
            return true
        end,function()
            if colour and X.applyCauldronLook then X.applyCauldronLook(actor,info) end
            return true
        end,function()
            actor:ForceNetUpdate()
            -- Finished owned construction is tracked before validation, without
            -- waiting for the deferred constructor notification.
            X.Registry.track(actor)
            done(actor);return true
        end})
        return function()
            local ok,result=pcall(step)
            if not ok then
                if actor and X.Lifetime.rawValid(actor) then actor:K2_DestroyActor() end
                error(result)
            end
            return result
        end
    end
    local function hide(a)
        assert(H.authority(a),'refused client carrier changes')
        a:SetReplicates(true); a.bAlwaysRelevant=true; a.NetDormancy=1
        a:SetActorHiddenInGame(true); a:SetActorEnableCollision(false)
        a:FlushNetDormancy(); a:ForceNetUpdate()
    end
    -- Explicit native load rebuild; no sampling or transient GameState receiver.
    function api.refresh(gs,knownMarkers)
        if not context(gs,false,knownMarkers) then return end
        local step=pool.job(gs,function()
            X.log('Discovery','full native pool published')
        end)
        if FAPP_TEST_NO_THROTTLE then X.Work.finish(step)
        else X.Work.submit('pool:'..gs:GetAddress(),'native pool',step) end
    end
    local function validateJob(s,done)
        -- Trust native eligibility/copy/geometry discovery. Only our N+1 reserve
        -- and per-pot exclusions need an extra check; never inspect actor copies.
        local names={}; local classes=0; local why
        return X.Work.sequence({X.Work.defer(function()
            return X.Work.array(s.gs.ValidProps,X.get,function(cls)
                classes=classes+1
                names[#names+1]=X.text(X.object('/Script/Engine.Default__KismetSystemLibrary'):GetClassDisplayName(cls))
            end)
        end),X.Work.defer(function()
            return X.Work.array(s.gs.Cauldrons,X.get,function(pot,i)
                local avoid={}
                for _,name in ipairs(X.values(pot.PropClassesToAvoid)) do avoid[X.text(name)]=true end
                local count=0; for _,name in ipairs(names) do if not avoid[name] then count=count+1 end end
                if count<X.requiredClasses(s.pots) then why='native prop pool: cauldron '..i..' has '..count..' usable classes; needs '..X.requiredClasses(s.pots) end
            end)
        end),function()
            local pots=s.gs.Cauldrons; local count=pots.GetArrayNum and pots:GetArrayNum() or #pots
            if #s.pots<3 then why='at least 3 cauldron markers are required'
            elseif #s.respawns==0 then why='no Witch respawn markers or normal witch player starts'
            elseif count~=#s.pots then why='native cauldron discovery incomplete'
            elseif classes<X.requiredClasses(s.pots) then
                why='native prop pool: layout has '..classes..' distinct playable classes with >=2 copies; needs '..X.requiredClasses(s.pots)
            end
            done(why==nil,why,classes); return true
        end})
    end
    local function syncColoursJob(gs,done,knownMarkers)
        local markers,pots,synced=knownMarkers,nil,0
        return X.Work.sequence({X.Work.defer(function()
            if markers then return function() return true end end
            return X.markersJob(gs,function(found) markers=found end)
        end),X.Work.defer(function()
            return X.actorsJob(gs,O..'B_ObjectiveCauldron.B_ObjectiveCauldron_C',function(found) pots=found end)
        end),X.Work.defer(function()
            return X.Work.each(pots,function(pot)
            local match; local position=X.location(pot)
            for _,marker in ipairs(markers) do
                if X.distance2(marker.position,position)<1 then
                    assert(not match,'two colour markers at the same cauldron position'); match=marker
                end
            end
            if match and match.info.colour then
                local c=match.info.colour; local key=pot:GetAddress()
                local colourSig=string.pack('<fff',c.R,c.G,c.B)
                local sig=colourSig..string.pack('<I2I2',match.info.decalDown,match.info.decalUp)..table.concat(X.exclusionPaths(match.info.excluded),'\n')
                local r=colourCache[key]
                local actual=X.read(pot,'Color')
                local matches=actual and string.pack('<fff',actual.R,actual.G,actual.B)==colourSig
                if not r or not X.same(r.actor,pot) or r.signature~=sig or not matches then
                    pot.Color=c; pot.MinPropDistance=X.minDistance(); if H.authority(pot) then X.applyTypeExclusions(pot,match.info) end; pot:Init()
                    pot.MinPropSphere:SetSphereRadius(X.minDistance(),false)
                    if X.applyCauldronLook then X.applyCauldronLook(pot,match.info) end
                    colourCache[key]={actor=pot,signature=sig}
                    X.log('ColourSync','applied replicated marker colour to '..pot:GetFullName())
                end
                synced=synced+1
            end
            end)
        end),function() done(#markers,#pots,synced); return true end})
    end
    function api.queueClient(gs)
        if not X.live(gs) or not H.class(gs,'B_ObjectiveGameState_C') then return end
        local id=gs:GetAddress()
        if H.authority(gs) and (not states[id] or not states[id].ready) then return end
        if not clients[id] then clients[id]={gs=gs,deadline=os.time()+30,last='',stable=0} end
    end
    local function adaptJob(gm)
        local gs,options,s,markerChanged,pots,respawns,retiring,retired,sources
        local points={}; local stopped=false
        local work=X.Work.sequence({function()
        local gameState,_,matchOptions=context(gm,true); gs=gameState; options=matchOptions
        if not gs then stopped=true; return true end
        s=state(gs,gm,options); s.loaded=true
        markerChanged=s.markerRevision~=markerRevision(); s.markerRevision=markerRevision()
        return true
    end,X.Work.defer(function() return X.markersJob(gm,function(found,starts) pots=found; respawns=starts end) end),function()
        local ids={}; for _,list in ipairs({pots,respawns}) do for _,p in ipairs(list) do ids[#ids+1]=tostring(p.id) end end
        table.sort(ids); local layoutKey=table.concat(ids,',')
        if s.layoutKey==layoutKey and s.converted then
            if markerChanged then api.queueClient(gs) end -- late metadata on existing host markers
            stopped=true; return true
        end
        if s.layoutKey~=layoutKey then
            s.layoutKey=layoutKey; s.converted=false; s.ready=false; s.lastMessage=nil
            s.reason='adapting custom layout'; s.deadline=os.time()+30; s.attempts=0; s.expired=false
            options.DisableStartMatchTimer=true
            s.nativeLoaded=false; s.poolKey=nil; s.checkedKey=nil; s.pendingReason=nil; s.mismatchLogged=nil
        end
        return true
    end,X.Work.defer(function()
        local steps={}
        for _,cls in ipairs({START,'/Game/Blueprints/Player/PlayerStarts/B_WitchPlayerStart.B_WitchPlayerStart_C',
            '/Game/Blueprints/Player/PlayerStarts/B_PlayerStart.B_PlayerStart_C'}) do
            steps[#steps+1]=X.Work.defer(function()
                if #respawns>0 then return function() return true end end
                local actors
                return X.Work.sequence({X.actorsJob(gm,cls,function(found) actors=found end),X.Work.defer(function()
                    return X.Work.each(actors,function(actor)
                        respawns[#respawns+1]={actor=actor,position=X.location(actor),id=actor:GetAddress(),fallback=true}
                    end)
                end),function()
                    if #respawns>0 then X.once('fallback:'..gs:GetAddress()..s.layoutKey,'Respawn','witch respawn fallback '..cls:match('%.([^%.]+)$')..' count='..#respawns) end
                    return true
                end})
            end)
        end
        return X.Work.sequence(steps)
    end),function()
        -- A layout can be reloaded without replacing the GameState. Retire only
        -- actors this adapter owns whose source markers have gone away.
        sources={}
        for _,list in ipairs({pots,respawns}) do for _,p in ipairs(list) do sources[p.id]=true end end
        retired=0; retiring={}
        for id,actor in pairs(s.byMarker) do retiring[#retiring+1]={id=id,actor=actor} end
        return true
    end,X.Work.defer(function()
        return X.Work.each(retiring,function(entry)
            local id,actor=entry.id,entry.actor
            if not sources[id] then
                if X.live(actor) then actor:K2_DestroyActor(); retired=retired+1 end
                s.byMarker[id]=nil
            end
        end)
    end),function()
        if retired>0 then X.log('Adapter','retired '..retired..' owned actors from previous layout') end
        local _,reason=X.validation(pots,respawns,{})
        if #pots<3 or #respawns==0 then refuse(s,reason); stopped=true; return true end
        return true
    end,X.Work.defer(function()
        local potIndex,nextIndex=1,2
        return function()
            local p=pots[potIndex]
            if not p or potIndex>=#pots then return true end
            if X.distance2(p.position,pots[nextIndex].position)<1 then
                refuse(s,'overlapping cauldron markers'); stopped=true; return true
            end
            nextIndex=nextIndex+1
            if nextIndex>#pots then potIndex=potIndex+1; nextIndex=potIndex+1 end
            return potIndex>=#pots
        end
    end),X.Work.defer(function() return X.coloursJob(gm,pots) end),X.Work.defer(function()
        local index,step=0,nil
        return function()
            if step then if step() then step=nil end;return false end
            index=index+1;local p=pots[index];if not p then return true end
            local owned=s.byMarker[p.id]
            local function remember(actor)
                s.byMarker[p.id]=actor;s.actors[#s.actors+1]=actor
            end
            step=X.Work.sequence({function()
                X.stamp(p.actor,1,p.colour,p.authored,true,p.source);return true
            end,X.Work.defer(function()
                if s.partial[p.id] then return s.partial[p.id] end
                if owned and X.live(owned) then return function() return true end end
                s.partial[p.id]=spawnJob(gm,O..'B_ObjectiveCauldron.B_ObjectiveCauldron_C',p.actor:GetTransform(),p.colour,p.info,function() s.partial[p.id]=nil end,remember)
                return s.partial[p.id]
            end),function()
                s.byMarker[p.id].Color=p.colour;hide(p.actor);return true
            end,function()
                if p.light then hide(p.light) end;return true
            end})
            return false
        end
    end),function()
        X.log('Cauldrons','converted '..#pots..' markers; SetReplicates + always relevant; MinPropDistance='..X.minDistance())
        return true
    end,X.Work.defer(function()
        local index,step=0,nil
        return function()
            if step then if step() then step=nil end;return false end
            index=index+1;local p=respawns[index];if not p then return true end
            local owned=s.byMarker[p.id]
            step=X.Work.sequence({X.Work.defer(function()
                if s.partial[p.id] then return s.partial[p.id] end
                if owned and X.live(owned) then return function() return true end end
                s.partial[p.id]=spawnJob(gm,O..'B_ObjectiveWitchRespawnPoint.B_ObjectiveWitchRespawnPoint_C',p.actor:GetTransform(),nil,nil,function() s.partial[p.id]=nil end,function(actor)
                    s.byMarker[p.id]=actor;s.actors[#s.actors+1]=actor
                end)
                return s.partial[p.id]
            end),function()
                points[#points+1]=s.byMarker[p.id];if not p.fallback then hide(p.actor) end;return true
            end})
            return false
        end
    end),function()
        -- HandleStartSeekOverride discovers these points natively at round start.
        gm.AllWitchRespawnPoints=points -- also ready before native round discovery
        X.log('Respawn','converted '..#points..' points; native random respawn / farthest revive totem selection')
        s.pots=pots; s.respawns=respawns; s.converted=true
        s.reason='waiting for layout props to settle'; s.deadline=s.deadline or os.time()+30
        X.log('Load','converted layout once; markers='..#pots..'/'..#respawns)
        api.queueClient(gs)
        return true
    end})
        local pass,epoch,live
        return function()
            if pass~=X.Work.pass or epoch~=X.Lifetime.epoch then
                pass=X.Work.pass; epoch=X.Lifetime.epoch; live=X.live(gm)
            end
            if stopped or not live then return true end
            return work()
        end
    end
    function api.adapt(gm)
        if not X.live(gm) then return end
        if FAPP_TEST_NO_THROTTLE then return X.Work.finish(adaptJob(gm)) end
        X.Work.submit('adapt:'..gm:GetAddress(),'Adapter',adaptJob(gm))
    end
    local function discoverJob(s,ownerKey)
        local key,wasReady,ok,why,eligible,round; local stopped=false
        local function validated(success,reason,count) ok=success; why=reason; eligible=count end
        local work=X.Work.sequence({function()
        -- Actor identity catches same-count replacements as well as late spawns;
        -- moving props or transforming players must not restart the settle window.
        key=X.Registry.versions.B_StaticMeshProp_C
        if key~=s.poolKey then
            if not s.ready then s.nativeLoaded=false end
            s.poolKey=key; s.checkedKey=nil
            X.log('Load','prop membership revision='..key..'; validating native membership snapshot')
        end
        if s.checkedKey==key then
            if not s.ready and os.time()>=s.deadline then refuse(s,s.pendingReason or s.reason) end
            stopped=true; return true
        end
            wasReady=s.ready; return true
        end,X.Work.defer(function()
            if s.nativeLoaded then return function() return true end end
            return pool.job(s.gs,function() s.nativeLoaded=true; s.reloaded=false end,ownerKey or 'discovery:'..s.gs:GetAddress())
        end),X.Work.defer(function() return validateJob(s,validated) end),X.Work.defer(function()
            if ok then return function() return true end end
            return pool.reportJob(s.gs)
        end),X.Work.defer(function()
            if not ok or wasReady then return function() return true end end
            return X.Work.array(s.gs.Cauldrons,X.get,function(pot) pot:CheckIsInitializeForPlayers() end)
        end),function()
            if ok and key==X.Registry.versions.B_StaticMeshProp_C and X.Targets then X.Targets.apply(s.gm,s.pots) end
            return true
        end,function()
            if key~=X.Registry.versions.B_StaticMeshProp_C then s.checkedKey=nil; s.recheck=true; return true end
            -- Native load notifications invalidate checkedKey; acknowledge only
            -- after native discovery and bounded validation complete.
            s.checkedKey=key; s.pendingReason=why; s.recheck=false
            local gi=X.gi(s.gs); local mm=H.valid(gi) and X.read(gi,'ObjectiveMatchManager')
            round=H.valid(mm) and X.get(X.read(mm,'CurrentRound')) or 0
            if ok then
                s.ready=true; s.reason=nil; s.options.DisableStartMatchTimer=s.oldTimer
                X.log('Validation',(wasReady and 'REVALIDATED' or 'READY')..'; cauldrons='..#s.pots..' respawns='..#s.respawns..' eligible classes='..eligible..
                    ' native classes='..eligible)
            elseif wasReady and round>0 then
                -- A late spawn can be checked during a round, but cannot reopen
                -- its start gate or trigger a second StartFirstRound.
                X.log('Validation','late props: '..why..'; current round unchanged')
            else
                s.ready=false; s.reason=why; s.options.DisableStartMatchTimer=true
                X.once('pool:'..s.gs:GetAddress(),'Validation','waiting/refused: '..why)
            end
        -- Allow late spawns to change the fingerprint even after a failed gate;
        -- unchanged failures wait for actor/native-load changes, never completeness retries.
        if not s.ready and os.time()>=s.deadline then refuse(s,s.pendingReason or s.reason) end
            return true
        end,function()
            if ok and s.checkedKey==key then
                if not wasReady then
                    -- Every peer runs the package. Actor/material arrivals drive
                    -- its own bounded pool job; no delayed full-world rebuild RPC.
                    local owned={}; for _,actor in pairs(s.byMarker) do owned[#owned+1]=actor end
                    X.Work.submit('replication:'..s.gs:GetAddress(),'layout replication',X.Work.each(owned,function(actor)
                        if X.live(actor) then actor:FlushNetDormancy(); actor:ForceNetUpdate() end
                    end))
                end
                api.queueClient(s.gs)
            end
            return true
        end,function()
            -- Readiness, target setup and peer scheduling finish before restart.
            if ok and s.checkedKey==key and not wasReady then pcall(function()
                local gm=X.gameplay():GetGameMode(s.gs)
                if H.valid(gm) and H.authority(gm) then
                    if round==0 then gm:StartFirstRound(); X.log('Validation','re-ran native StartFirstRound after READY')
                    elseif s.gs.State==0 then gm:StartGame(); X.log('Validation','re-ran native StartGame after READY') end
                end
            end) end
            return true
        end})
        local pass,epoch,live
        return function()
            -- A drain is one uninterrupted game-thread pass. Revalidate hosts
            -- once per pass/epoch, rather than walking both outer chains for
            -- every pure distance comparison or array cursor increment.
            if pass~=X.Work.pass or epoch~=X.Lifetime.epoch then
                pass=X.Work.pass; epoch=X.Lifetime.epoch
                live=X.live(s.gs) and X.live(s.gm) and states[s.gs:GetAddress()]==s
            end
            if stopped or not live then return true end
            return work()
        end
    end
    local function gate(self,out)
        local gs,gm,options=context(self:get(),true); if not gs then return end
        local s=state(gs,gm,options)
        if not options.CustomMapSelected and not s.loaded then
            s.loaded=true; s.deadline=os.time()+15; s.reason='adapting built-in custom world'
            api.adapt(gm)
        end
        if not s.ready then out:set(false); X.once('gate:'..gs:GetAddress(),'Validation','readiness blocked: '..s.reason) end
    end
    X.hook('Adapter','/Game/Blueprints/Core/','B_GameMode','LoadPropLayoutFromSaveGame',function(self)
        local gm=self:get(); if not context(gm,true) then return end
        -- Only a changed marker identity set invalidates the converted layout.
        api.loadComplete(gm,true) -- actual native load: complete before revealing the map
    end)
    function api.loadComplete(gm,loadBarrier)
        if not context(gm,true) then return end
        local gs=X.gameplay():GetGameState(gm)
        local key='layout:ready:'..gm:GetAddress()
        local step=X.Work.sequence({adaptJob(gm),X.Work.defer(function()
            local s=states[gs:GetAddress()]
            if s and s.converted then return discoverJob(s,key) end
            return function() return true end
        end)})
        if loadBarrier then
            -- Only the saved-layout loader may block. Finish THIS layout's finite
            -- conversion/native discovery, never flush unrelated catalog/UI jobs.
            X.Work.cancel('adapt:'..gm:GetAddress())
            X.Work.cancel('discovery:'..gs:GetAddress())
            X.Work.cancel('layout:ready:'..gm:GetAddress())
            X.Work.finish(step)
        elseif FAPP_TEST_NO_THROTTLE then X.Work.finish(step)
        else X.Work.submit(key,'custom layout ready',step) end
    end
    X.hook('Validation',O,'B_ObjectiveGameMode','AreAllPlayersReadyWithTeamSelection',gate)
    X.hook('Validation','/Game/Blueprints/Core/','B_GameMode','HandleShouldGameStart',gate)
    X.hook('Discovery',O,'B_ObjectiveGameState','LoadPropsAndCauldrons',function(self)
        local gs=self:get()
        if pool.isLoading(gs) then return end -- our native continuation owns this rebuild
        local id=gs:GetAddress()
        X.log('Pool/native','LoadPropsAndCauldrons: AllProps='..gs.AllProps:GetArrayNum()..' ValidProps='..gs.ValidProps:GetArrayNum()..
            ' registry='..#X.Registry.list('B_StaticMeshProp_C')..' world='..tostring(X.Lifetime.worldKey(gs)))
        -- Native regeneration can relocate TMap entries/embedded TArrays. Retire
        -- every cursor holding borrowed storage before any later timer resumes.
        X.Work.cancel('discovery:'..id)
        X.Work.cancel('client-discovery:'..id)
        X.Work.cancel('client-native-load:'..id)
        local current=states[id]
        if current then X.Work.cancel('layout:ready:'..current.gm:GetAddress()) end
        api.queueClient(gs)
        if context(gs,false) then
            local s=states[gs:GetAddress()]; if s then s.nativeLoaded=true; s.reloaded=true; s.checkedKey=nil; s.recheck=true end -- accept the engine-built pool; revalidate without another scan
        end
    end)
    X.hook('Discovery',O,'B_ObjectivePlayerController','LoadPropsAndCauldrons',function(self)
        local gs=X.gameplay():GetGameState(self:get()); if X.live(gs) then api.queueClient(gs) end
    end)
    X.hook('Discovery',O,'B_ObjectiveGameState','ReceiveBeginPlay',function(self)
        api.queueClient(self:get())
    end)
    function api.poll()
        if X.Lifetime and X.Lifetime.transition then return end
        -- Client BeginPlay/load RPCs may arrive before metadata, or the first
        -- bounded wait may expire before replicated actors arrive. Actual actor
        -- membership/readiness changes create a fresh bounded wait, never an idle scan.
        local objects=discoveryRevision()
        if C.CreativeMaps and clientObjects~=objects then
            clientObjects=objects
            for _,gs in ipairs(X.findAll('B_ObjectiveGameState_C')) do
                if X.live(gs) and not H.authority(gs) then api.queueClient(gs) end
            end
        end
        for _,gm in ipairs(C.CreativeMaps and X.findAll('B_ObjectiveGameMode_C') or {}) do
            local gs=context(gm,true)
            if gs and not states[gs:GetAddress()] then X.guard('Adapter/destination',api.adapt)(gm) end
        end
        for id,s in pairs(states) do
            if not X.live(s.gs) or not X.live(s.gm) or not X.same(X.gameplay():GetGameState(s.gm),s.gs) then states[id]=nil; clients[id]=nil
            elseif not C.CreativeMaps then
                s.options.DisableStartMatchTimer=s.oldTimer; states[id]=nil
            elseif s.loaded and H.authority(s.gm) and H.authority(s.gs) then
                if s.markerRevision~=markerRevision() then
                    X.guard('Adapter/late markers',api.adapt)(s.gm)
                end
                local props=X.Registry.versions.B_StaticMeshProp_C
                if s.converted and not s.ready and s.expired and s.propRevision~=props then
                    s.expired=false; s.deadline=os.time()+30; s.checkedKey=nil
                end
                s.propRevision=props
                if s.converted then
                    -- After READY the pool only changes on round loads (hooked); a
                    -- full prop scan every second cost >1 s per poll (1 FPS in matches).
                    -- No periodic rescans after READY: only after a native prop reload
                    -- (hook sets s.recheck) until the new pool has settled and validated.
                    if not s.ready or s.recheck then
                        X.Work.submit('discovery:'..id,'Discovery/host',discoverJob(s))
                    end
                elseif not s.deadline or os.time()<s.deadline then
                    s.attempts=(s.attempts or 0)+1; X.guard('Adapter/retry',api.adapt)(s.gm)
                else refuse(s,s.reason=='adapting custom layout' and 'adapter failed; inspect [Maps] FAILED logs' or s.reason) end
            end
        end
        for id,r in pairs(clients) do
            if not C.CreativeMaps or not X.live(r.gs) or not X.same(X.gameplay():GetGameState(r.gs),r.gs) then clients[id]=nil
            else
                local markers,pots,synced,knownMarkers; local stopped=false
                local work=X.Work.sequence({X.Work.defer(function()
                    return X.markersJob(r.gs,function(found) knownMarkers=found end)
                end),function()
                    if not context(r.gs,false,knownMarkers) then
                        if os.time()>r.deadline then
                            clients[id]=nil
                            X.log('Discovery','no Creative metadata arrived; retained native Objective discovery (check replication if this was a custom layout)')
                        end
                        stopped=true; return true
                    end
                    return true
                end,X.Work.defer(function()
                    return syncColoursJob(r.gs,function(found,count,coloured) markers=found; pots=count; synced=coloured end,knownMarkers)
                end),function()
                    local propKey=X.Registry.versions.B_StaticMeshProp_C
                    local array=r.gs.AllProps
                    local props=array.GetArrayNum and array:GetArrayNum() or #array
                    local gi=X.gi(r.gs); local ui=H.valid(gi) and X.read(gi,'IngameUIManager')
                    local hudRoot=H.valid(ui) and X.read(ui,'HUDUserWidget')
                    local hud=H.valid(hudRoot) and X.read(hudRoot,'ObjectiveHud')
                    local signature=markers..'/'..pots..'/'..synced..'/props='..props..'/hud='..tostring(H.valid(hud))
                    if signature~=r.last or propKey~=r.propKey then
                        r.last=signature; r.propKey=propKey; r.stable=0
                        if not H.authority(r.gs) then
                            X.Work.submit('client-native-load:'..id,'Discovery/client',pool.job(r.gs,nil,'client-native-load:'..id))
                        end
                    else
                        r.stable=r.stable+1
                        -- Same N+1 rule as host validation; a complete four/five
                        -- type pool on a three-pot map must settle, not reload.
                    end
                    if markers>=3 and markers==pots and synced==pots and (r.gs.ValidProps.GetArrayNum and r.gs.ValidProps:GetArrayNum() or #r.gs.ValidProps)>=pots+1 and H.valid(hud) and r.stable>=2 then
                        clients[id]=nil; X.log('Discovery','client discovery + colour metadata settled: '..signature)
                    elseif os.time()>r.deadline then
                        clients[id]=nil; X.log('Discovery','FAILED timed out waiting for replicated actors/colour metadata: '..signature)
                    end
                    return true
                end})
                local pass,epoch,live
                X.Work.submit('client-discovery:'..id,'Discovery/client',function()
                    if pass~=X.Work.pass or epoch~=X.Lifetime.epoch then
                        pass=X.Work.pass; epoch=X.Lifetime.epoch; live=X.live(r.gs)
                    end
                    if stopped or clients[id]~=r or not live then return true end
                    return work()
                end)
            end
        end
        if FAPP_TEST_NO_THROTTLE then while X.Work.pending() do X.Work.drain() end end
        for id,r in pairs(colourCache) do if not X.live(r.actor) then colourCache[id]=nil end end
    end
    function api.status(o)
        local gs,gm,options=context(o,true)
        if gs then return state(gs,gm,options) end
    end
    X.Objective=api
    X.log('Adapter','module ready; custom Objective listen-host conversion + readiness gate')
    function api.reset()
        -- Buffers are worldless rooted UObjects. Clear their actor references
        -- and reuse the bounded pool across travel rather than leaking roots.
        states={}; clients={}; colourCache={}; clientObjects=-1
    end
    X.cachedPoll(api,function()
        if next(clients) then return true end
        for _,s in pairs(states) do if (s.loaded and not s.ready and not s.expired) or s.recheck then return true end end
        return false
    end)
    return api
end
return M
