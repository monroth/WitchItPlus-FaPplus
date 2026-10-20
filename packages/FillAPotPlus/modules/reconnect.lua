local Registry=FAPP_SERVICES.registry
-- Host-only UE4SS module; RECON4 fixes the group-test login timing failure.
-- Real PS references survive nested initialization without granting membership.
-- Timer holds share ownership with manual pause; default pause_timer=false.
-- init accepts either these options or a main-mod config with a `reconnect` table.
-- Call init before the match. Integration appends session evidence; IDs/assets stay native.
-- BP RegisterHook callbacks run AFTER the function. Out params use param:set(),
-- NOT callback return values. Registration is retried once classes are loaded.
local M = {}
local OM = "/Game/Blueprints/Gamemodes/ObjectiveMode/"
local CORE = "/Game/Blueprints/Core/"
local function path(folder, cls, fn) return folder .. cls .. "." .. cls .. "_C:" .. fn end
local GM = "B_ObjectiveGameMode"
local MM = "B_ObjectiveMatchManager"
local dir=debug.getinfo(1,'S').source:match('^@(.+[\\/])')
local Lifetime=FAPP_SERVICES.lifetime
local valid=Lifetime.valid
local Events=FAPP_SERVICES.events
local Identity=FAPP_SERVICES.match_identity
local read=FAPP_SERVICES.runtime.read
local function addr(o)
    if valid(o) then return Lifetime.key(o) end
end
local function first(cls)
    for _, o in ipairs(Registry.list(cls) or {}) do
        if valid(o) and not o:GetFullName():find("Default__",1,true)
            and o:HasAuthority() then return o end
    end
end

function M.init(config, log, integration)
    if M.instance then return M.instance end -- one installation per Lua state
    config = config or {}
    assert(integration and integration.addHook and integration.isInstalled,'owned reconnect integration required')
    local cfg = type(config.reconnect) == "table" and config.reconnect
        or type(config.Reconnect) == "table" and config.Reconnect or config
    log = log or function(s) print("[FillAPotPlus] Reconnect: " .. s .. "\n") end
    local function say(s) log("Reconnect: " .. s) end
    local errors={}
    local function diagnostic(key,err)
        local t=os.time()
        if not errors[key] or t-errors[key]>=30 then
            errors[key]=t; say(key .. ": " .. tostring(err))
        end
    end
    local api = {}
    local dirty=true
    local running=true -- stop() owns lifecycle; UI enabled flag gates admission/grace.
    local function enabled() return running and cfg.enabled~=false and cfg.Enabled~=false and config.Enabled~=false end
    local function maxWait() return math.max(0,tonumber(cfg.max_wait_seconds or cfg.MaxWaitSeconds) or 120) end
    local pollMs=math.max(100,tonumber(cfg.poll_ms or config.MaintenanceMs) or 250)
    local function pauseTimer() return cfg.pause_timer==true or cfg.PauseTimer==true end
    local function preserveLives()
        if cfg.preserve_alive_witch_lives==false then return false end
        if integration.isInfinite then return not integration.isInfinite() end
        return config.MaxLives~="infinite"
    end
    -- os.time measures wall time; os.clock measures CPU time and is unsuitable.
    -- A custom monotonic clock may be supplied. Wall-clock jumps affect default.
    local now = cfg.now or FAPP_SERVICES.event_clock.now
    local parentSeen={}
    local specs={}
    local ready = false
    local records, pause, worldKey, roundKey = {}, nil, nil, nil
    local gm, manager
    local logoutScope, leavingSeen, logoutProbe = nil, {}, false
    local observedPlayers={}
    local pendingLogins={}
    -- Unproven logins retry at 1 Hz: each retry scans for the GameMode and roster
    -- (~30 ms live), and the heartbeat otherwise runs it at 12 Hz (live 2026-10-07).
    local nextLoginRetry=0
    local lifetimeEpoch=Lifetime.epoch
    local traceBuffer, traceCounts, traceSequence, traceLive = {}, {}, 0, false
    local endCause
    local function evidence(event,ps,r,extra)
        if not integration.events then return end
        local fields={id=r and r.id or Identity.id(ps) or "unknown",
            team=r and r.team or (valid(ps) and read(ps,"Team")) or "unknown",
            round=roundKey or 0}
        for k,v in pairs(extra or {}) do fields[k]=v end
        integration.events.emit(event,fields)
    end
    local function resetTrace()
        traceBuffer={}; traceCounts={}; traceLive=false
    end
    function api.reset()
        for _,record in pairs(records) do record.armed=nil; record.bumped=nil end
        records={}; pause=nil; gm=nil; manager=nil; worldKey=nil; roundKey=nil
        logoutScope=nil; leavingSeen={}; logoutProbe=false; observedPlayers={}; pendingLogins={}
        lifetimeEpoch=Lifetime.epoch; dirty=true; api.lastEnd=nil; resetTrace()
    end
    local function authority()
        return valid(gm) and gm:HasAuthority()
    end
    local function currentContext()
        if not (running and ready and authority() and valid(manager)
            and (tonumber(read(manager, "CurrentRound")) or 0) > 0) then return false end
        if integration.world then
            local g,m=integration.world(gm)
            if not g or addr(m)~=addr(manager) then return false end
        end
        return true
    end
    local function active() return currentContext() and read(manager,'IsMatchOver')~=true end
    local function state() return read(read(gm, "ObjectiveGameState"), "State") end
    local function playing() return state() == 1 or state() == 2 end -- hide/seek
    local function departureValid(ps)
        if valid(ps) then return true end
        if Lifetime.transition or lifetimeEpoch~=Lifetime.epoch or not Lifetime.alive(ps) then return false end
        local key=Lifetime.key(ps)
        if not key or not observedPlayers[key] or not currentContext() then return false end
        local world=Lifetime.worldKey(ps)
        return world~=nil and world==Lifetime.worldKey(gm)
    end
    local function resolve(ps,departure)
        local validatePlayer=departure and departureValid or valid
        if not validatePlayer(ps) or not ps:HasAuthority() or not valid(manager) then return nil end
        if integration.isWaiter and integration.isWaiter(ps) then return nil end
        return Identity.participant(manager,ps,validatePlayer)
    end
    local function trace(step,ps,value)
        if cfg.trace_native_flow==false then return end
        local count=traceCounts[step] or 0
        if count>=(step=='IsPlayerInMatch' and 8 or 2) then return end
        traceCounts[step]=count+1; traceSequence=traceSequence+1
        local line='RC3_FLOW seq='..traceSequence..' round='..tostring(roundKey)..
            ' epoch='..Lifetime.epoch..' native_round='..tostring(read(manager,'CurrentRound'))..
            ' step='..step..' boundary=post id='..tostring(Identity.id(ps,departureValid) or '-')..
            ' pending='..tostring(departureValid(ps) and read(ps,'IsPendingDisconnect') or false)..
            ' value='..tostring(value)
        if traceLive then say(line) else
            traceBuffer[#traceBuffer+1]=line
            if #traceBuffer>24 then table.remove(traceBuffer,1) end
        end
    end
    local function openTrace()
        if traceLive or cfg.trace_native_flow==false then return end
        traceLive=true
        for _,line in ipairs(traceBuffer) do say(line) end
        traceBuffer={}
    end
    local function remember(ps)
        local key=Lifetime.key(ps)
        if key and valid(ps) and ps:HasAuthority() then observedPlayers[key]=ps end
    end
    local function observePlayers(gs)
        local players=read(gs,'PlayerArray')
        if players then players:ForEach(function(_,value) remember(value:get()) end) end
    end
    local function waiting()
        if not enabled() then return false end
        local t = now()
        for _, r in pairs(records) do
            if r.waiting and t < r.deadline then return true end
        end
        return false
    end
    local function releaseTimer()
        if integration.timer then integration.timer.release("reconnect"); pause=nil; return end
        if pause then
            if valid(pause.gm) and pause.gm:HasAuthority()
                and addr(pause.gm) == worldKey and roundKey == pause.round
                and read(manager,"CurrentRound") == pause.round
                and read(manager,"IsMatchOver") ~= true
                and playing() and state() == pause.state then
                pause.gm.TimerIsCounting = pause.counting
                if pause.overtime then read(pause.gm,'ObjectiveGameState').IsInOvertime=true end
                -- Do not TimerStart(saved): it resets TimerInitialTime and
                -- discards cauldron bonus time added while gameplay continued.
            end
            pause = nil
            say("timer released")
        end
    end
    local function updateTimer()
        if integration.timer then
            if active() and playing() and pauseTimer() and waiting() then
                integration.timer.acquire("reconnect",gm)
            else integration.timer.release("reconnect") end
            return
        end
        if active() and playing() and pauseTimer() and waiting() then
            if not pause then
                pause = {gm=gm, counting=gm.TimerIsCounting,
                         round=roundKey, state=state(), overtime=read(read(gm,'ObjectiveGameState'),'IsInOvertime')==true}
                say("timer held (gameplay continues)")
            end
            local gs=read(gm,'ObjectiveGameState')
            if gs.IsInOvertime==true then pause.overtime=true; gs.IsInOvertime=false end
            gm.TimerIsCounting = false -- stops decrement AND TimerFinished
        else releaseTimer() end
    end
    local function notice(text)
        if not active() or not playing() or config.PauseNotification==false then return end
        local manual=integration.timer and integration.timer.has('manual')
        local automatic=integration.timer and integration.timer.has('reconnect') or pause~=nil
        local reason=manual and automatic and 'manual + reconnect' or manual and 'manual' or 'reconnect'
        local message='RECONNECT: '..text..'; timer '..((manual or automatic) and 'PAUSED ('..reason..')' or 'RUNNING')
        if integration.timer and integration.timer.notice then integration.timer.notice(gm,message)
        else
            local gs=read(gm,'ObjectiveGameState')
            pcall(function() gs:SendGameMessageMulticast(FText(message),FText(message),10) end)
        end
    end
    local function refresh()
        if integration.isInstalled then
            ready=true
            for _,spec in ipairs(specs) do if not integration.isInstalled(spec.p) then ready=false; break end end
        end
        local found = first(GM .. "_C")
        if not valid(found) then
            pause=nil; gm=nil; manager=nil; records={}; worldKey=nil; roundKey=nil; observedPlayers={}; pendingLogins={}; resetTrace()
            return
        end
        gm = found
        if integration.world then
            local live, mm = integration.world(found)
            if not live then
                releaseTimer(); gm=nil; manager=nil; records={}; worldKey=nil; roundKey=nil; observedPlayers={}; pendingLogins={}; resetTrace()
                return
            end
            manager=mm
        else
        -- Match manager is a UObject, not an Actor. Get it through GameInstance.
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        manager = gs:GetGameInstance(gm).ObjectiveMatchManager
        end
        local key, round = addr(gm), read(manager, "CurrentRound")
        if key ~= worldKey or round ~= roundKey or lifetimeEpoch~=Lifetime.epoch then
            pause=nil
            local instance=StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetGameInstance(gm)
            records=Identity.records(instance,'reconnect_round_'..tostring(round),{mps=true,pc=true,oldPawn=true}) or {}
            observedPlayers={}; pendingLogins={}; leavingSeen={}; logoutScope=nil; logoutProbe=false; resetTrace()
            if key ~= worldKey or lifetimeEpoch~=Lifetime.epoch then parentSeen = {}; api.lastEnd=nil end
            if round==0 then api.lastEnd=nil end
            worldKey, roundKey, lifetimeEpoch = key, round, Lifetime.epoch
            say("new world/round; retained scalar facts bound, world handles rebuilt")
        end
    end
    local function depart(ps)
        if not enabled() or not active() then return end
        local mps, id = resolve(ps,true)
        if not mps then return end
        local playerKey=Lifetime.key(ps)
        local team,lives=read(ps,'Team'),tonumber(read(ps,'Lives')) or 0
        -- Lives is a witch respawn reserve. Native hunter rejoin uses Team=1
        -- directly, so its ordinary zero lives must not disqualify grace.
        if (team~=0 and team~=1) or (team==0 and lives<=0) then
            records[id]=nil
            evidence('grace_skip',ps,{id=id,team=team},{lives=lives,reason=team==2 and 'spectator' or 'no_lives'})
            updateTimer()
            return
        end
        openTrace()
        local r = records[id]
        -- Duplicate logout/unregister paths must not extend the grace deadline.
        if r and r.departing == playerKey then return end
        if not r or r.departing ~= playerKey then
            r = {id=id,team=read(ps,"Team"),objectiveTeam=read(mps,"ObjectiveTeam"),
                 mps=mps, departing=playerKey,
                waiting=maxWait()>0, deadline=now()+maxWait(),
                 wasAlive=read(ps,"IsDead") == false,
                 witch=read(ps,"IsWitchTeam") == true, lives=read(ps,"Lives")}
            records[id] = r
            r=records[id]
            say("participant disconnected; grace " .. maxWait() .. "s")
            evidence("grace_start",ps,r,{seconds=maxWait(),lives=r.lives})
        end
        updateTimer()
        if r.waiting then notice('grace '..maxWait()..'s; '..(pauseTimer() and 'gameplay continues' or 'pot/time outcomes remain active')) end
        -- Do NOT SaveDataToMatchPlayerState here: native logout saves once,
        -- additively merging score/playtime. Saving twice doubles those values.
    end
    local function capturePending(gs)
        if not logoutProbe then return end
        logoutProbe=false
        if not active() or not valid(gs) then return end
        -- EnsureInitialize arms exactly one pass. Native UnregisterPlayerOverride
        -- has marked its leaving PS pending BEFORE it calls IsMatchDead. Leaving
        -- controller/state names in that function are locals, not GM properties.
        observePlayers(gs)
        for key,ps in pairs(observedPlayers) do
            if not departureValid(ps) then observedPlayers[key]=nil
            elseif read(ps,"IsPendingDisconnect")==true and not leavingSeen[key] then
                leavingSeen[key]=true
                local mps,id=resolve(ps,true)
                logoutScope={spectator=not mps,ps=ps}
                openTrace()
                evidence("logout",ps,mps and {id=id,team=read(ps,'Team')},
                    {participant=mps~=nil,source="native_pending_disconnect"})
                depart(ps)
            end
        end
    end
    local function spectatorLogout() return logoutScope and logoutScope.spectator end
    local function expireOutcome()
        if not active() then return end
        local counts={[1]=0,[2]=0}; local role={}
        local gs=read(gm,"ObjectiveGameState")
        read(gs,"PlayerArray"):ForEach(function(_,v)
            local ps=v:get()
            if valid(ps) and read(ps,"IsPendingDisconnect")~=true then
                local mps=resolve(ps)
                if mps then
                    local team=read(mps,"ObjectiveTeam")
                    counts[team]=counts[team]+1; role[team]=read(ps,"Team")
                end
            end
        end)
        for _,r in pairs(records) do
            if r.waiting and now()<r.deadline and r.objectiveTeam then
                counts[r.objectiveTeam]=counts[r.objectiveTeam]+1
                role[r.objectiveTeam]=r.team
            end
        end
        if counts[1]>0 and counts[2]>0 then gm:CheckEndMatchWitchesDead(); return end
        endCause="grace_expired_team_empty"
        if counts[1]==0 and counts[2]==0 then
            manager.IsMatchOver=true
            evidence("match_abandoned",nil,nil,{cause=endCause})
            if integration.abandon then integration.abandon(gm) end
            endCause=nil; return
        end
        -- Same terminal branch as native UnregisterPlayerOverride, without a
        -- second additive SaveDataToMatchPlayerState/session unregister.
        local winner=role[counts[1]>0 and 1 or 2]
        if winner~=0 and winner~=1 then return end
        local force=roundKey==1 and state()==3
        manager.IsMatchOver=true; manager.CurrentRound=2
        gs:FlushNetDormancy(); gs.CurrentRound=2
        local push=StaticFindObject("/Script/Engine.Default__NetPushModelHelpers")
        push:MarkPropertyDirtyFromRepIndex(gs,49,FName("CurrentRound"))
        gm:HandleEndMatch(winner,force)
        endCause=nil
    end
    local function finish(r)
        local ps = read(r.pc, "PlayerState")
        if r.bumped and valid(r.mps) then
            r.mps.Lives = r.lives
            if valid(ps) and ps:HasAuthority() then ps:InitializeFromMatchPlayerState() end
            r.bumped = nil
        end
        if valid(r.oldPawn) and r.oldPawn:HasAuthority() and addr(r.oldPawn) ~= addr(read(r.pc,"Pawn")) then
            local owner = read(r.oldPawn,"Controller")
            if not valid(owner) or addr(owner) == addr(r.pc) then
                r.oldPawn:K2_DestroyActor()
            end
        end
        r.waiting = false
        r.complete = true
        evidence("grace_restore",ps,r,{lives=r.lives,role=r.witch and "witch" or "hunter"})
    end
    -- Public mutation methods and init must be called from the main mod/game thread.
    local function admit(pc)
        if not enabled() or not active() or not valid(pc) or not pc:HasAuthority() then return end
        local ps = read(pc, "PlayerState")
        -- A waiter may be an early login whose identity has only just arrived.
        -- Membership must be proven against the roster before releasing it.
        local mps, id = Identity.participant(manager,ps)
        if not mps or read(ps,'IsPendingDisconnect')==true then return false end
        if integration.releaseWaiter then integration.releaseWaiter(ps) end
        pc.IsBeingKickedDueMatchHasStarted = false
        local r = records[id]
        if r and r.pc and Lifetime.key(r.pc)==Lifetime.key(pc) then return true end
        local newRecord=not r
        r = r or {id=id,team=read(ps,"Team"),deadline=now()+maxWait(),
            waiting=false, mps=mps}
        r.pc, r.mps = pc, mps
        if not r.departing then r.lives, r.wasAlive = mps.Lives, mps.IsDead == false end
        r.witch = read(ps,"IsWitchTeam") == true
        records[id] = r
        r=records[id]
        -- Midround BP login currently skips its parent. Call the specific parent
        -- UFunction once; gm:K2_PostLogin(pc) would recurse into this override.
        if not parentSeen[addr(pc)] then
            local f = StaticFindObject(path(CORE,"B_GameMode","K2_PostLogin"))
            assert(valid(f), "parent K2_PostLogin not loaded")
            f(gm, pc) -- pinned UE4SS callable UFunction, explicit context
            parentSeen[addr(pc)] = true
        end
        ps.ObjectiveMatchPlayerState = mps
        ps:InitializeFromMatchPlayerState() -- teams/skills/lives + push-model marks
        r.witch = ps.IsWitchTeam == true
        -- Before retained initialization a returning hunter can still be Team=2.
        if newRecord then
            r.waiting=maxWait()>0 and (ps.Team==1 or (tonumber(r.lives) or 0)>0)
        end
        if not playing() then r.waiting=false; return true end -- registered, no results spawn
        -- Wait for IsReady before enabling the dormant controller rejoin path.
        -- That path waits 5s, sends LoadPropsAndCauldrons, then possesses Witch,
        -- Hunter, or ObjectiveKillSpectator and initializes XP tracking.
        updateTimer()
        say("retained participant admitted; waiting for readiness")
        evidence('rejoin_admit',ps,r,{lives=r.lives})
        dirty=true
        return true
    end
    function api.enabled() return enabled() end
    function api.pending()
        if not running then return false end
        if dirty or next(pendingLogins) and now()>=nextLoginRetry then return true end
        for _,record in pairs(records) do
            if record.waiting or record.armed and not record.complete then return true end
        end
        return false
    end
    function api.pending_login(pc)
        if not next(pendingLogins) then return false end
        local key=Lifetime.key(pc)
        return key and pendingLogins[key]~=nil or false
    end
    function api.admit(pc)
        if admit(pc) then pendingLogins[Lifetime.key(pc)]=nil; return true end
        return false
    end
    function api.login(pc)
        refresh()
        if not enabled() or not active() or not valid(pc) or not pc:HasAuthority() then return false end
        if api.admit(pc) then return true end
        local key=Lifetime.key(pc)
        -- Retry only this login, at maintenance cadence, for a finite window.
        -- Parent login/handshake is still executed by main's spectator path.
        if key and not pendingLogins[key] then
            pendingLogins[key]={pc=pc,deadline=now()+maxWait()}
            evidence('identity_pending',read(pc,'PlayerState'))
        end
        return false
    end
    local function drive()
        local expired=false
        for _,r in pairs(records) do if r.waiting and now()>=r.deadline then expired=true; break end end
        local loginsDue=next(pendingLogins)~=nil and now()>=nextLoginRetry
        if not dirty and not expired and not loginsDue then return end
        if next(pendingLogins) then nextLoginRetry=now()+1 end
        dirty=false
        refresh()
        if not active() then pendingLogins={}; releaseTimer(); return end
        for key,p in pairs(pendingLogins) do
            local ps=read(p.pc,'PlayerState')
            if not enabled() or now()>=p.deadline or not valid(p.pc) or not valid(ps)
                or read(ps,'IsPendingDisconnect')==true then
                pendingLogins[key]=nil
                evidence('identity_expire',ps)
            elseif admit(p.pc) then pendingLogins[key]=nil end
        end
        observePlayers(read(gm,'ObjectiveGameState'))
        local outcomeExpired=false
        local restored=false
        for _, r in pairs(records) do
            if r.pc and valid(r.pc) and r.pc:HasAuthority() and not r.complete then
                local ps = read(r.pc,"PlayerState")
                if valid(ps) and ps:HasAuthority() and ps.IsReady == true and not r.armed and playing() and enabled() then
                    -- Native rejoin charges a life. Positive-life living witches
                    -- receive a temporary +1, rolled back after possession.
                    if preserveLives() and r.witch and r.wasAlive and r.lives>0 then
                        if r.lives < 255 then r.mps.Lives = r.lives + 1 end
                        -- At 255 the branch already succeeds; restore after it.
                        r.bumped = true
                        ps:InitializeFromMatchPlayerState()
                    end
                    r.oldPawn = read(r.pc,"Pawn")
                    r.pc.RejoinInitialized = false
                    r.pc.IsRejoiningMatch = true
                    r.armed = true
                    say("native rejoin armed")
                end
                if r.armed and r.pc.IsRejoiningMatch == false then
                    local pawn = read(r.pc,"Pawn")
                    local name = valid(pawn) and pawn:GetFullName() or ""
                    local expected = r.witch and ((r.wasAlive or r.lives>0)
                        and "B_ObjectiveWitch" or "B_ObjectiveKillSpectator") or "B_Hunter"
                    if name:find(expected,1,true) then
                        finish(r)
                        restored=true
                        say("native rejoin completed; verify client loading")
                    elseif r.witch and (r.wasAlive or r.lives>0) then
                        -- RespawnWitch may reject every spawn near hunters.
                        -- Roll back temporary lives before another native attempt.
                        if r.bumped then
                            r.mps.Lives=r.lives; ps:InitializeFromMatchPlayerState()
                            r.bumped=nil
                        end
                        r.armed=nil
                        dirty=true
                        say("witch spawn failed; retrying native rejoin")
                    end
                end
            end
            if r.waiting and now() >= r.deadline then
                if r.bumped and valid(r.mps) then
                    r.mps.Lives=r.lives; r.bumped=nil
                    local ps=read(r.pc,'PlayerState')
                    if valid(ps) then ps:InitializeFromMatchPlayerState() end
                end
                r.waiting = false
                say("grace expired; native outcome reevaluated")
                evidence("grace_expire",nil,r)
                outcomeExpired=true
            end
        end
        logoutScope=nil; logoutProbe=false -- synchronous unregister calls have returned
        updateTimer()
        if restored then notice('participant restored') end
        if outcomeExpired then notice('grace expired') end
        resetTrace()
        if outcomeExpired then expireOutcome() end
    end
    local function add(p, cb, validateSelf)
        specs[#specs+1] = {p=p, validateSelf=validateSelf, cb=function(...)
            if not running then return end
            if not Events.hot(p) then dirty=true end
            local args = {...}
            local ok, err = pcall(function() cb(table.unpack(args)) end)
            if not ok then diagnostic(p,err) end
        end}
    end
    add(path(CORE,"B_GameMode","K2_PostLogin"), function(_, pc)
        refresh()
        local p=pc:get()
        if authority() and valid(p) and p:HasAuthority() then parentSeen[addr(p)] = true end
    end)
    for _,folder in ipairs({CORE,OM}) do
        add(path(folder,folder==CORE and "B_GameMode" or GM,"EnsureInitialize"),function(self)
            refresh(); if addr(self:get())==worldKey then
                logoutProbe=true
                trace(folder==CORE and 'Core.EnsureInitialize' or 'Objective.EnsureInitialize')
            end
        end)
    end
    for _,step in ipairs({'HandlePlayerLeft','K2_OnLogout','UnregisterPlayer'}) do
        add(path(CORE,'B_GameMode',step),function(self,pc)
            if addr(self:get())~=worldKey or not currentContext() then return end
            trace('Core.'..step,read(pc:get(),'PlayerState'))
        end)
    end
    add(path(OM,GM,'UnregisterPlayerOverride'),function(self,pc)
        if addr(self:get())==worldKey and currentContext() then trace('UnregisterPlayerOverride',read(pc:get(),'PlayerState')) end
    end)
    add(path(OM,'B_ObjectivePlayerState','SaveDataToMatchPlayerState'),function(self)
        if not currentContext() then return end
        local ps=self:get()
        if not observedPlayers[Lifetime.key(ps)] then return end
        trace('SaveDataToMatchPlayerState',ps)
    end,departureValid)
    add(path(OM,GM,"K2_OnLogout"),function(self,pc)
        if addr(self:get())~=worldKey then return end
        local ps=read(pc:get(),"PlayerState")
        if currentContext() then trace('Objective.K2_OnLogout',ps); openTrace() end
        -- Some direct logout routes lack the common handler; participants are
        -- already captured by RemovePlayerWhenMatchNotStarted in those routes.
        local key=Lifetime.key(ps)
        if key and not leavingSeen[key] then
            leavingSeen[key]=true; evidence("logout",ps,nil,{source="K2_OnLogout"})
        end
        logoutScope=nil; logoutProbe=false
        resetTrace()
    end)
    add(path(OM,GM,"HandleEndMatch"),function(self,winner,force)
        if addr(self:get())~=worldKey then return end
        local gs=read(gm,"ObjectiveGameState")
        local cause=endCause
        if not cause then
            if (tonumber(read(manager,"SurrenderedTeam")) or 0)~=0 then cause="surrender"
            elseif logoutScope then cause="logout_team_empty"
            elseif (tonumber(read(gs,"CauldronTarget")) or 256)<=(tonumber(read(gs,"CauldronsFilled")) or 0) then cause="cauldrons"
            elseif (tonumber(read(gm,"TimerRemainingSeconds")) or 1)<=0 then cause="timer_or_overtime"
            elseif winner:get()==0 then cause="hunters_dead"
            else cause="witches_dead" end
        end
        -- HandleEndMatch may be called again after State=3. Only record the
        -- accepted end/forced final result once, using a Lua event key.
        local key=tostring(worldKey)..":"..tostring(roundKey)..":"..tostring(force:get())
        if api.lastEnd~=key then
            api.lastEnd=key
            evidence("round_end",nil,nil,{cause=cause,winner=winner:get(),force=force:get(),
                native_round=read(manager,"CurrentRound"),seconds=read(gm,"TimerRemainingSeconds")})
        end
    end)
    add(path(OM,MM,"IsPlayerInMatch"),function(self,ps,out)
        if not logoutProbe then return end
        if addr(self:get())~=addr(manager) then return end
        local player=ps:get()
        -- Objective logout asks membership immediately after EnsureInitialize.
        -- Keep real PS references across the nested EnsureInitialize calls.
        -- Neither absence nor membership alone is a departure signal.
        remember(player)
        trace('IsPlayerInMatch',player,out and out:get())
        if integration.isWaiter and integration.isWaiter(player) then
            logoutScope={spectator=true,ps=player}
        end
    end)
    -- This inner BP call runs before Objective UnregisterPlayerOverride can end
    -- the match, unlike a post-hook on K2_OnLogout (which is too late).
    add(path(OM,MM,"RemovePlayerWhenMatchNotStarted"), function(self, ps)
        refresh(); if addr(self:get()) == addr(manager) and active() then
            remember(ps:get()); trace('RemovePlayerWhenMatchNotStarted',ps:get()); depart(ps:get())
        end
    end)
    add(path(OM,MM,"IsMatchDead"), function(self, gs, out)
        if not logoutProbe and not waiting() and not spectatorLogout() then return end
        if addr(self:get()) ~= addr(manager) then return end
        local native=out:get()
        capturePending(gs:get())
        if active() and (waiting() or spectatorLogout()) then out:set(false) end
        trace('IsMatchDead',logoutScope and logoutScope.ps,tostring(native)..'->'..tostring(out:get()))
    end)
    add(path(OM,MM,"IsMatchIntact"), function(self, gs, out)
        if not logoutProbe and not waiting() and not spectatorLogout() then return end
        if addr(self:get()) ~= addr(manager) then return end
        local native=out:get()
        capturePending(gs:get())
        if active() and (waiting() or spectatorLogout()) then out:set(true) end
        trace('IsMatchIntact',logoutScope and logoutScope.ps,tostring(native)..'->'..tostring(out:get()))
    end)
    add(path(OM,MM,"CanTeamSurrender"), function(self, _, _, out)
        if addr(self:get()) ~= addr(manager) then return end
        if active() and waiting() then out:set(false) end
    end)
    -- Core UnregisterPlayer also invokes CheckEndMatchHuntersDead AFTER the
    -- Objective integrity branch. Blocking IsMatchIntact alone is insufficient.
    add(path(CORE,"B_GameMode","GetHuntersCount"),function(self,out)
        if not waiting() and not spectatorLogout() then return end
        if addr(self:get())~=worldKey or not active() then return end
        local native=out:get()
        local protected=spectatorLogout()
        if not protected then
            for _,r in pairs(records) do
                if r.waiting and now()<r.deadline and r.witch==false then protected=true; break end
            end
        end
        if protected then out:set(math.max(1,native)) end
        trace('GetHuntersCount',logoutScope and logoutScope.ps,tostring(native)..'->'..tostring(out:get()))
    end)
    add(path(OM,GM,"CheckWitchesAlive"), function(self, out)
        if not waiting() and not spectatorLogout() then return end
        if addr(self:get()) ~= worldKey then return end
        if not active() then return end
        local native=out:get()
        if spectatorLogout() then out:set(true)
        elseif waiting() then
            for _, r in pairs(records) do
                if r.waiting and now()<r.deadline and r.witch
                    and (r.wasAlive or (tonumber(r.lives) or 0)>0) then
                    out:set(true); break
                end
            end
        end
        trace('CheckWitchesAlive',logoutScope and logoutScope.ps,tostring(native)..'->'..tostring(out:get()))
    end)
    if not integration.timer then
        add(path(OM,'B_ObjectiveCauldron','OnRep_Stacks'),function(self)
            local pot=self:get()
            if pause and pause.overtime and pot.Stacks>=pot.MaxStacks and addr(read(pot,'Gamemode'))==worldKey then
                pause.overtime=false; read(gm,'ObjectiveGameState').IsInOvertime=true
            end
        end)
    end
    add(path(OM,GM,"K2_PostLogin"), function(self, pc)
        refresh()
        if addr(self:get()) == worldKey then
            if currentContext() then remember(read(pc:get(),'PlayerState')) end
            evidence("login",read(pc:get(),"PlayerState"),nil,{participant=resolve(read(pc:get(),"PlayerState"))~=nil})
            api.login(pc:get())
        end
    end)
    add(path(CORE,"B_GameMode","TimerStart"), function(self)
        refresh() -- new round may start its timer before the polling callback
        if pause and addr(self:get()) == worldKey and waiting() then
            pause.counting = true; self:get().TimerIsCounting = false
        end
    end)
    add(path(OM,MM,"TearDown"), function(self)
        if addr(self:get()) ~= addr(manager) then return end
        releaseTimer(); records, parentSeen = {}, {}; roundKey=nil
        logoutScope=nil; logoutProbe=false; leavingSeen={}; observedPlayers={}; pendingLogins={}; api.lastEnd=nil; resetTrace()
    end)
    function api.is_waiting() return waiting() and active() end
    function api.status()
        local n=0; for _, r in pairs(records) do if r.waiting then n=n+1 end end
        local installedCount=0
        for _,s in ipairs(specs) do if integration.isInstalled(s.p) then installedCount=installedCount+1 end end
        return {enabled=enabled(), ready=ready, waiting=n,
                timer_held=integration.timer and integration.timer.has("reconnect") or pause~=nil,
                hooks=installedCount, required_hooks=#specs, round=roundKey}
    end
    function api.clear_round_deaths()
        -- Called only at the proven round-1 -> round-2 boundary by integration.
        if not authority() or not integration.world then return end
        local g,m,s=integration.world(gm)
        if not g or m.IsMatchOver or m.CurrentRound~=2 or s.CurrentRound~=1 or s.State~=3 then return end
        for _,r in pairs(records) do
            if valid(r.mps) then r.mps.IsDead=false end
        end
    end
    function api.player_status(ps)
        if not active() or not valid(ps) then return "none" end
        local mps=read(ps,"ObjectiveMatchPlayerState")
        local id=valid(mps) and Identity.text(read(mps,"PlayerId"))
        local r=id and records[id]
        if not r then return "none" end
        return r.complete and "complete" or r.armed and "loading" or
            (r.waiting and now()<r.deadline) and "grace" or "expired"
    end
    function api.stop()
        running=false; pendingLogins={}; releaseTimer()
        for _, r in pairs(records) do
            if authority() and (not integration.world or integration.world(gm)) and r.bumped and valid(r.mps) then
                r.mps.Lives=r.lives
                local ps=read(r.pc,"PlayerState")
                if valid(ps) and ps:HasAuthority() then pcall(function() ps:InitializeFromMatchPlayerState() end) end
            end
        end
        M.instance=nil
    end
    -- Main mod can hold timer for its own explicitly admitted loading player.
    -- These holds never grant membership; callers must release each token.
    function api.hold_loading(token)
        dirty=true
        if active() then
            records["loading:"..tostring(token)] = {waiting=maxWait()>0, deadline=now()+maxWait()}
            updateTimer()
        end
    end
    function api.release_loading(token)
        dirty=true
        records["loading:"..tostring(token)]=nil; updateTimer()
    end
    integration.addHook('/Script/Engine.Controller:Possess',function() dirty=true end)
    integration.addHook('/Game/Blueprints/Player/Pawns/B_Spectator.B_Spectator_C:HandleClientProcessed',function() dirty=true end)
    function api.changed()
        dirty=true
    end
    M.instance=api
        for _, s in ipairs(specs) do integration.addHook(s.p,s.cb,nil,s.validateSelf) end
        local lastReady
        function api.poll()
            if not running then return end
            ready=true
            for _,s in ipairs(specs) do
                if not integration.isInstalled(s.p) then ready=false; break end
            end
            if ready~=lastReady then
                dirty=true
                lastReady=ready
                local status=api.status()
                say("hooks "..status.hooks.."/"..status.required_hooks.." ready="..tostring(ready))
            end
            -- Only the rejoin completion flag has no player-state notify.
            for _,r in pairs(records) do
                if r.armed and not r.complete and Lifetime.rawValid(r.pc) and r.pc.IsRejoiningMatch==false then dirty=true; break end
            end
            drive()
        end
        say("integrated; forfeit grace="..maxWait().."s, automatic timer hold="..tostring(pauseTimer()))
    return api
end
return M
