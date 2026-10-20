local M={label='Fill a Pot+',vanilla='Fill a Pot (Experimental)'}
local GI='/Game/Blueprints/Core/B_GameInstance.B_GameInstance_C:'
local GM='/Game/Blueprints/Core/B_GameMode.B_GameMode_C:'
local read=FAPP_SERVICES.runtime.read
local call=FAPP_SERVICES.runtime.call
local unwrap=FAPP_SERVICES.runtime.unwrap
local function valid(object) return call(object,'IsValid')==true end
local text=FAPP_SERVICES.runtime.text
local function class(object)
    if not valid(object) then return '' end
    return text(call(call(object,'GetClass'),'GetFName'))
end
function M.new(api)
    local identity=FAPP_SERVICES.lifetime
    local key=identity.key
    local state={mode='menu',plus=false,authority=false,pending=false,options={},recover=true}
    local producer={state=state,key=key,read=read,call=call,text=text,valid=valid,class=class}
    local Core=api.shared('Core')
    local mutation={};local recovered;local recovery;local labelOwner;local plusAdmission=0
    local writers=setmetatable({},{__mode='k'})
    local function invalidate() mutation={} end
    local function resetEnrollment()
        invalidate()
        if labelOwner then labelOwner.clear('mode ownership reset') end
    end
    local function walk()
        local stamp=mutation
        local function held() return mutation==stamp end
        return Core.guarded_native.new(api,identity,held),held
    end
    identity.onReset(resetEnrollment)
    api.on('load_map_pre',resetEnrollment,{ungated=true})
    api.on('world_changed',resetEnrollment,{ungated=true})
    local function refresh(guard)
        local stamp=mutation
        local function held()
            return stamp==mutation and (not guard or guard()) and api.is_live()==true and stamp==mutation
                and (not guard or guard())
        end
        if not held() then return false end
        local context=api.context()
        if not held() then return false end
        if state.mode=='objective' and not state.authority then
            local fact=labelOwner and labelOwner.snapshot()
            if not held() then return false end
            state.plus=fact~=nil and fact.status=='applied' and fact.label==M.label and fact.key==state.gs
                and not state.finished and not state.destination
        end
        if state.mode=='objective' then
            local fact=labelOwner and labelOwner.snapshot() or {}
            local host=state.hostSelection
            local inputs='mode='..state.mode..' authority='..tostring(state.authority)
                ..' plus='..tostring(state.plus)..' gi='..tostring(state.gi)..' gs='..tostring(state.gs)
                ..' used='..tostring(state.used)..':'..tostring(state.options[state.used])
                ..' next='..tostring(state.next)..':'..tostring(state.options[state.next])
                ..' pending='..tostring(state.pending)..' pendingCommit='..tostring(state.pendingCommit)
                ..' inMatch='..tostring(state.inMatch)..' recover='..tostring(state.recover)
                ..' finished='..tostring(state.finished)..' destination='..tostring(state.destination)
                ..' host='..tostring(host and host.gi)..':'..tostring(host and host.plus)
                ..' label='..tostring(fact.label)..' status='..tostring(fact.status)..' source='..tostring(fact.source)
            if state.plusDecision~=inputs then state.plusDecision=inputs;api.log('Plus decision '..inputs) end
            if not held() then return false end
        end
        context.mode=state.mode;context.authority=state.authority;context.fapp_plus=state.plus
        if not held() then return false end
        WIR_RUNTIME.set_context(context)
        return held()
    end
    producer.refresh=refresh
    -- The pass owns an admission; each visit owns exactly one publication.
    -- A newer same-label publication may hand off an unconsumed position,
    -- never revive the old walk or invoke a second inventory scan.
    local function passCurrent(pass)
        return recovery==pass and state.plus and not state.authority
            and plusAdmission==pass.admission and state.gs==pass.key
            and not state.finished and not state.destination
    end
    local function leaseCurrent(pass,lease)
        return passCurrent(pass) and pass.lease==lease and lease.current()
            and labelOwner.current(lease.fact.generation,lease.fact.sequence)
            and passCurrent(pass) and pass.lease==lease
    end
    local function recoverObject(pass,object)
        while passCurrent(pass) do
            local lease=pass.lease
            if not leaseCurrent(pass,lease) then return end
            local G=Core.guarded_native.new(api,identity,function() return leaseCurrent(pass,lease) end)
            local dispatched=false
            if G.current() and G.valid(object) and G.current()
                and G.worldKey(object)==lease.fact.world and G.current() then
                -- This position is consumed at dispatch, even when the external
                -- registry callback publishes a successor before returning.
                dispatched=true
                FAPP_SERVICES.registry.track(object)
                if not G.current() then return end
            end
            if dispatched or G.current() then return end
            -- Native result discarded. Only an explicitly delivered newer lease
            -- on this same admission can start a NEW visit of this position.
            -- No timeout, retry, scan restart or reflection determines handoff.
            if not passCurrent(pass) or pass.lease==lease then return end
        end
    end
    labelOwner=api.module('mode_label_owner').new(api,Core,identity,function(fact,current)
        if not current() then return end
        state.enrollment=fact or {status='owner_revoked'}
        if not fact then
            recovery=nil
            if not state.authority then state.plus=false end
            refresh(current);return
        end
        if fact.key~=state.gs or state.mode~='objective' or state.finished or state.destination then
            recovery=nil;return
        end
        local wasPlus=state.plus
        if not state.authority then state.plus=fact.status=='applied' and fact.label==M.label
        elseif fact.status=='label_revoked' then state.plus=false
        elseif fact.source=='authority_local_final_write' then state.plus=fact.label==M.label
        elseif state.recover and fact.status=='applied' and fact.label==M.label then
            state.plus=true;state.recover=false
            if state.next then state.options[state.next]=true end
            if state.used then state.options[state.used]=true end
        end
        if state.plus and not wasPlus and not state.authority then plusAdmission=plusAdmission+1 end
        state.plus_admission=plusAdmission
        if not state.plus or state.authority then recovery=nil
        elseif recovery and recovery.admission==plusAdmission and recovery.generation==fact.generation
            and recovery.key==fact.key and recovery.world==fact.world then
            -- Invalidate the previous visit before context or registry callbacks.
            recovery.lease={fact=fact,current=current}
        else recovery=nil end
        refresh(current)
        if not current() or not state.plus or state.authority or recovered==plusAdmission
            or not FAPP_SERVICES.registry then return end
        local pass={admission=plusAdmission,generation=fact.generation,key=fact.key,
            world=fact.world,lease={fact=fact,current=current}}
        recovered=pass.admission;recovery=pass
        local initial=pass.lease
        local intake=Core.guarded_native.new(api,identity,function() return leaseCurrent(pass,initial) end)
        if not intake.current() then return end
        FAPP_SERVICES.registry.eachExisting(WIR_RUNTIME.input and WIR_RUNTIME.input.controller,
            function(object) recoverObject(pass,object) end)
        -- Future births use the ordinary class subscriptions.
    end)
    state.enrollment={status='provider_unbound'}
    producer.bind_label_provider=labelOwner.bind_provider
    producer.label_snapshot=labelOwner.snapshot
    function producer.authority_operation(gm,guard)
        if not state.authority or state.finished or state.destination then return end
        local stamp=mutation
        local modeValue,authorityValue,plusValue,gsKey,gmKey=state.mode,state.authority,state.plus,state.gs,state.gm
        if not gmKey then return end
        local decision={mode=modeValue,authority=authorityValue,plus=plusValue,gs=gsKey,gm=gmKey}
        local _,publication=labelOwner.capture()
        local function contextHeld()
            return stamp==mutation and state.mode==modeValue and state.authority==authorityValue
                and state.plus==plusValue and state.gs==gsKey and state.gm==gmKey
                and not state.finished and not state.destination
        end
        local function accepted()
            return contextHeld() and (not guard or guard()==true) and publication()
                and contextHeld() and (not guard or guard()==true)
        end
        local G=Core.guarded_native.new(api,identity,accepted)
        if not G.current() or G.key(gm)~=gmKey or not G.current() then return end
        return G,decision
    end
    function producer.label_write(gs,gm,guard)
        local G,held=walk()
        local keyValue,gmKey=G.key(gs),G.key(gm)
        if not G.current() or not state.authority or not state.plus or keyValue~=state.gs or gmKey~=state.gm then return end
        local fact=labelOwner.snapshot()
        local publication=labelOwner.hold(fact.generation,fact.sequence)
        local function modeCurrent()
            return held() and (not guard or guard()==true) and state.authority and state.plus and state.gs==keyValue
                and state.gm==gmKey and not state.finished and not state.destination
                and held() and (not guard or guard()==true)
        end
        local function accepted()
            return modeCurrent() and publication() and modeCurrent()
                and labelOwner.current(fact.generation,fact.sequence) and modeCurrent()
        end
        if not accepted() then return end
        writers[fact]={current=modeCurrent,accepted=accepted,generation=fact.generation,sequence=fact.sequence}
        return Core.guarded_native.new(api,identity,accepted),accepted,fact
    end
    function producer.label_committed(gs,G,accepted,label,expected)
        local record=writers[expected];writers[expected]=nil
        if not record or accepted~=record.accepted or not accepted() or not G.current() then return false end
        if not labelOwner.authority_commit(gs,G,accepted,label,record.generation,record.sequence) then return false end
        -- Our final publication consumed the writer's old sequence. Remaining
        -- session work must acquire exactly its own successor publication.
        local successor=labelOwner.hold(record.generation,record.sequence+1)
        local function renewed() return record.current() and successor() and record.current() end
        if not renewed() then return false end
        return true,Core.guarded_native.new(api,identity,renewed)
    end

    function producer.selected(options) return state.options[key(options)]==true end
    function producer.optionPlus(options)
        local id=key(options)
        if id==state.used and state.mode=='objective' then return state.plus end
        return state.options[id]==true
    end
    function producer.remember(gi)
        invalidate()
        local G=walk()
        local id=G.key(gi);if not G.current() or not id then return false end
        local used,nextOptions=G.key(G.read(gi,'UsedMatchOptions')),G.key(G.read(gi,'NextMatchOptions'))
        if not G.current() then return false end
        if state.gi~=id then
            labelOwner.clear('GI replaced')
            if not G.current() then return false end
            FAPP_SERVICES.match_identity.forget_key(state.gi)
            if not G.current() then return false end
            state.gi=id;state.plus=false;state.pending=false;state.pendingCommit=nil
            state.options={};state.hostSelection=nil;state.recover=true;state.finished=false;state.gs=nil
            state.inMatch=false;state.matchOver=false
        end
        state.used=used;state.next=nextOptions
        if FAPP_SERVICES.registry and G.current() then FAPP_SERVICES.registry.track(gi) end
        return G.current()
    end
    function producer.work(path)
        if state.mode=='objective' and not state.authority then
            local fact=labelOwner.snapshot()
            return state.plus and fact.status=='applied' and fact.key==state.gs and fact.label==M.label
        end
        if state.mode=='objective' then return state.plus end
        if state.mode~='menu' and state.mode~='creative' then return false end
        if path and (path:find('/ObjectiveMode/',1,true) or path:find('/ObjectiveMode.',1,true)) then return false end
        return true
    end
    function producer.select(gi,options,plus)
        if not producer.remember(gi) then return end
        invalidate()
        local G=walk();local id=G.key(options)
        if not G.current() then return end
        state.pending=plus==true;state.options[id or 'missing']=state.pending;state.recover=false
    end
    -- UsedMatchOptions can still describe the previous match at CreateSession.
    -- Preserve the local selection for this GI until the session ends.
    function producer.hosting()
        invalidate()
        if not state.gi then return false end
        local selected=state.next and state.options[state.next]
        if selected==nil then selected=state.plus end
        state.hostSelection={gi=state.gi,plus=selected==true}
        state.plus=state.hostSelection.plus
        return state.plus
    end
    function producer.commit(gi,options)
        invalidate()
        local G=walk();local id,option=G.key(gi),G.key(options)
        if not G.current() or not id then return end
        if state.gi~=id then state.gi=id;state.plus=false;state.pending=false;state.options={};state.hostSelection=nil end
        state.plus=state.options[option]==true;state.finished=false;state.inMatch=false;state.recover=false
        refresh()
    end
    function producer.copy(destination,source)
        invalidate()
        local G=walk();local id,sourceId=G.key(destination),G.key(source)
        if not G.current() or not id then return end
        state.options[id]=state.options[sourceId]==true
        if id==state.used then
            state.pendingCommit=state.options[id]
            if state.mode=='menu' then
                state.plus=state.pendingCommit;state.pendingCommit=nil
                state.finished=false;state.recover=false;refresh()
            end
        end
    end
    function producer.finish()
        invalidate()
        local G=walk()
        labelOwner.clear('match finished')
        if not G.current() then return end
        local nextPlus=state.next and state.options[state.next]
        FAPP_SERVICES.match_identity.forget_key(state.gi)
        if not G.current() then return end
        state.plus=false;state.pending=false;state.pendingCommit=nil
        state.options={};if state.next and nextPlus==true then state.options[state.next]=true end
        state.hostSelection=nil
        state.finishedGS=state.gs;state.finishedGeneration=WIR_RUNTIME.world_generation
        state.finished=true;state.inMatch=false;state.recover=false;refresh()
    end
    local function boundary()
        if state.pendingCommit==nil or state.inMatch and not state.matchOver then return end
        if state.matchOver then FAPP_SERVICES.match_identity.forget_key(state.gi) end
        if state.hostSelection and state.hostSelection.gi==state.gi and state.matchOver then
            state.hostSelection.plus=state.pendingCommit
        end
        state.plus=state.pendingCommit; state.pendingCommit=nil
        state.finished=false; state.inMatch=false; state.recover=false; refresh()
    end
    function producer.observe(object,observedClass)
        if observedClass=='B_MenuPlayerController_C' then
            object=unwrap(object)
            if identity.born(object)=='menu' then identity.menuReady(object) end
        end
        invalidate()
        local G,held=walk()
        local function current() return held() and G.current() end
        object=G.unwrap(object)
        if not current() or not G.valid(object) then return end
        local function cls(o)
            if not G.valid(o) then return '' end
            return G.text(G.call(G.call(o,'GetClass'),'GetFName')) or ''
        end
        local objectClass=type(observedClass)=='string' and observedClass or cls(object)
        if not current() then return end
        if not objectClass:find('GameMode',1,true) and not objectClass:find('GameState',1,true)
            and not objectClass:find('PlayerController',1,true) and objectClass~='B_IngameUIManager_C' then return end
        local gameplay=StaticFindObject('/Script/Engine.Default__GameplayStatics')
        if not current() then return end
        local context=object;local gi
        if objectClass=='B_IngameUIManager_C' then
            gi=FAPP_SERVICES.match_context.instance(object,'IngameUIManager')
            if not current() or not G.valid(gi) then return end
            context=gi
        else gi=G.call(gameplay,'GetGameInstance',object) end
        local gs=G.call(gameplay,'GetGameState',context)
        local gm=G.call(gameplay,'GetGameMode',context)
        if not current() then return end
        local validGS,validGM=G.valid(gs),G.valid(gm)
        if not current() or not validGM and not validGS and not objectClass:find('Menu',1,true) then return end
        local id,gsKey,gmKey=G.key(gi),G.key(gs),G.key(gm)
        local used,nextOptions=G.key(G.read(gi,'UsedMatchOptions')),G.key(G.read(gi,'NextMatchOptions'))
        local modeClass=cls(gm)
        if modeClass=='' then modeClass=G.text(G.call(G.read(gs,'GameModeClass'),'GetFName')) or '' end
        if modeClass=='' then modeClass=objectClass end
        local authority=validGM and G.call(gm,'HasAuthority')==true
        local manager=G.read(gi,'ObjectiveMatchManager')
        local matchOver=G.read(manager,'IsMatchOver')==true
            or G.read(gs,'CurrentRound')==2 and G.read(gs,'State')==3
        if not current() then return end
        if modeClass=='GameModeBase' or modeClass=='GameMode' or modeClass=='GameStateBase' or modeClass=='GameState' then return end
        if id and state.gi~=id then
            labelOwner.clear('GI replaced')
            if not current() then return end
            FAPP_SERVICES.match_identity.forget_key(state.gi)
            if not current() then return end
            state.gi=id;state.plus=false;state.pending=false;state.pendingCommit=nil
            state.options={};state.hostSelection=nil;state.recover=true;state.finished=false;state.gs=nil
            state.inMatch=false;state.matchOver=false
        end
        if id then state.used=used;state.next=nextOptions end
        local changedGS=gsKey and state.gs~=gsKey
        if changedGS then
            labelOwner.clear('GS replaced')
            if not current() then return end
            state.gs=gsKey;state.inMatch=false
        end
        state.authority=authority;state.matchOver=matchOver;state.gm=gmKey
        if modeClass=='B_ObjectiveGameMode_C' or modeClass=='B_ObjectiveGameState_C' then
            state.mode='objective'
            if not authority and state.finished and (gsKey~=state.finishedGS
                or WIR_RUNTIME.world_generation>(state.finishedGeneration or WIR_RUNTIME.world_generation)) then
                state.finished=false;state.finishedGS=nil;state.finishedGeneration=nil;state.inMatch=false
            end
            if authority and not state.finished then
                local host=state.hostSelection
                if id and host and host.gi==id then state.plus=host.plus
                elseif not state.inMatch and state.used and state.options[state.used]~=nil then
                    state.plus=state.options[state.used]
                end
            end
            state.inMatch=true;state.destination=false
            -- Label facts have a separate owner. Ordinary heartbeat observations
            -- never read GamemodeDisplayName or restart a snapshot/provider.
            refresh()
            if current() and validGS and not state.finished then labelOwner.admit(gs,authority,G,current) end
            return current() -- exact local context observation receipt, not label application
        end
        labelOwner.clear('objective mode left')
        if not current() then return end
        FAPP_SERVICES.match_identity.forget_key(state.gi)
        if not current() then return end
        if modeClass:find('Creative',1,true) then
            state.mode='creative';state.plus=false;state.inMatch=false
            if state.used then state.options[state.used]=false end
        elseif modeClass:find('Menu',1,true) or not validGM and not validGS then
            if state.inMatch then
                local nextPlus=state.next and state.options[state.next]
                state.plus=false;state.pending=false;state.pendingCommit=nil
                state.options={};if state.next and nextPlus==true then state.options[state.next]=true end
                state.hostSelection=nil
                state.finishedGS=state.gs;state.finishedGeneration=WIR_RUNTIME.world_generation
                state.finished=true;state.inMatch=false;state.recover=false
            end
            state.mode='menu';state.plus=false
        else
            state.mode='other';state.plus=false;state.inMatch=false
            if state.used then state.options[state.used]=false end
        end
        state.destination=false;refresh()
        return current() -- held context commit only
    end
    local function contextClass(name)
        return name:find('GameMode',1,true)~=nil or name:find('GameState',1,true)~=nil
            or name:find('PlayerController',1,true)~=nil or name=='B_IngameUIManager_C'
    end
    api.on('begin_play_pre',producer.observe,{ungated=true,class_filter=contextClass})
    api.on('world_ready',producer.observe,{ungated=true})
    function producer.installBoundary()
        api.on('load_map_pre',boundary,{ungated=true})
        api.on('world_changed',function() state.destination=true; boundary() end,{ungated=true})
    end
    api.hook(GM..'Initialize',function(self) producer.observe(self) end,{ungated=true})
    api.hook('/Game/Blueprints/Gamemodes/ObjectiveMode/B_ObjectiveGameMode.B_ObjectiveGameMode_C:HandleEndMatchOverride',producer.observe,{ungated=true})
    api.hook(GI..'UnregisterSession',producer.finish,{ungated=true})
    refresh()
    api.game_thread(function()
        local states=api.find_all('B_ObjectiveGameState_C') or {}
        if #states==0 then states=api.find_all('B_CreativeGameState_C') or {} end
        if states[1] then producer.observe(states[1]) end
    end)
    return producer
end
return M
