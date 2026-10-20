-- FillAPotPlus package gameplay -- UE4SS experimental e3ba1016 / Witch It UE 5.7.1.
-- BP RegisterHook callbacks are POST hooks. Never rely on them to cancel a body.
local OM = "/Game/Blueprints/Gamemodes/ObjectiveMode/"
local CORE = "/Game/Blueprints/Core/"
local function log(s) FAPP_API.log(s) end
local source = debug.getinfo(1, "S").source
local directory = source:match("^@(.+[\\/])")
local okConfig, C = pcall(function()
    if directory then return dofile(directory .. "config.lua") end
    return require("config")
end)
if not okConfig or type(C) ~= "table" then
    log("ERROR config.lua could not be loaded: " .. tostring(C)); return
end
local Settings
if directory then
    local ok,s=pcall(function() return dofile(directory.."settings.lua").init(C,directory,log) end)
    if ok then Settings=s else log("ERROR settings loader: "..tostring(s)); return end
end
if not C.Enabled then log("disabled by config"); return end
local function number(value, name, low, high, integer)
    assert(type(value) == "number" and value == value and value >= low and value <= high
        and (not integer or value == math.floor(value)), "invalid config " .. name)
    return value
end
if C.StartWhenEveryoneReady==nil then C.StartWhenEveryoneReady=false end
if C.ReviveTotemsPerDeadWitch==nil then C.ReviveTotemsPerDeadWitch=1 end
if C.ReviveAtFilledCauldrons==nil then C.ReviveAtFilledCauldrons=false end
local validConfig, configError = pcall(function()
    for _, key in ipairs({"Enabled", "UnequalTeams", "AllowEmptyTeams", "StartWhenEveryoneReady", "LateJoinSpectators",
        "NormalizeInfiniteLifeScore", "Diagnostics", "PauseNotification", "SettingsUI",
        "CreativeMaps", "ReviveAtFilledCauldrons"}) do
        assert(type(C[key]) == "boolean", "invalid config " .. key)
    end
    for _, key in ipairs({"ManualPauseKey"}) do
        assert(type(C[key])=="string" and C[key]~="", "invalid config "..key)
    end
    assert(type(C.reconnect)=="table" and type(C.SoftLocks)=="table","invalid integration config")
    if C.reconnect.trace_native_flow==nil then C.reconnect.trace_native_flow=true end
    for _, key in ipairs({"enabled","pause_timer","preserve_alive_witch_lives","trace_native_flow"}) do
        assert(type(C.reconnect[key])=="boolean","invalid config reconnect."..key)
    end
    number(C.reconnect.max_wait_seconds,"reconnect.max_wait_seconds",0,86400)
    for _, key in ipairs({"hostRoundAdvance","clientRetrySelection","clientRebindSkillBlock",
        "hostWardrobeReenable","clientRepairCustomization","hostCancelOldKillSpectators"}) do
        assert(type(C.SoftLocks[key])=="boolean","invalid config SoftLocks."..key)
    end
    if C.MaxLives ~= "infinite" then number(C.MaxLives, "MaxLives", 1, 255, true) end
    number(C.InfiniteLivesReserve, "InfiniteLivesReserve", 2, 255, true)
    number(C.HudLivesCap, "HudLivesCap", 1, 20, true)
    number(C.RespawnSeconds, "RespawnSeconds", 0, 3600)
    number(C.ReviveTotemsPerDeadWitch,"ReviveTotemsPerDeadWitch",0,5,true)
    number(C.TotemReviveSeconds, "TotemReviveSeconds", 0.01, 3600)
    number(C.CreativeMapMinPropDistance, "CreativeMapMinPropDistance", 0, 10000, true)
    number(C.HookRetryMs, "HookRetryMs", 100, 60000, true)
    number(C.MaintenanceMs, "MaintenanceMs", 50, 60000, true)
    number(C.DiagnosticRepeatSeconds, "DiagnosticRepeatSeconds", 1, 3600)
    number(C.BalanceGuardQuota, "BalanceGuardQuota", 100000, 100000000, true)
    number(C.UiRequiredPlayersPerTeam, "UiRequiredPlayersPerTeam", 2, 100, true)
    assert(type(C.Properties) == "table" and type(C.Properties.TotemReviveSeconds) == "string",
        "invalid config Properties")
end)
if not validConfig then log("ERROR " .. tostring(configError)); return end
local infinite = C.MaxLives == "infinite"
local lives = infinite and C.InfiniteLivesReserve or C.MaxLives
local hudLives = math.min(lives, C.HudLivesCap, 5)
local function matchSettings(mm)
    return Settings and Settings.forMatch(mm) or C
end
local function freeTeamSelection(mm)
    local s=matchSettings(mm)
    return s.UnequalTeams or s.StartWhenEveryoneReady
end
local function syncLives(mm)
    infinite=matchSettings(mm).MaxLives=="infinite"
    lives=infinite and C.InfiniteLivesReserve or matchSettings(mm).MaxLives
    hudLives=math.min(lives,C.HudLivesCap,5)
end
local errors, installed, hooks, waiting, pendingTimers = {}, {}, {}, {}, {}
local R, Hold, Integration, SettingsUI, Extras, Restore, Maps, WinnerOrder, ReviveRules, Hud
local propertyChanged
local initializeModules
local modulesReady=false
local balanceOwners={}
local appliedRules={}
local installDecisions, installLoaded
local chosenSpectators={}
local changing = false
local Lifetime=FAPP_SERVICES.lifetime
local Registry=FAPP_SERVICES.registry
local Events=FAPP_SERVICES.events
local Identity=FAPP_SERVICES.match_identity
local Evidence=dofile(directory..'event_log.lua').init({log=log})
local Clock=FAPP_SERVICES.event_clock
local HookPolicy=dofile(directory..'hook_policy.lua')
local coreDirty=true
local retryDirty=true
local menuDirty=true
local Settlement=FAPP_API.shared('Core').tick.new(FAPP_API,function() menuDirty=true end,
    {external_driver=true,interval=300,passes=4})
local Work=assert(FAPP_WORK,'Core work queue required')
local hookNotifications={}
local retryAssets={}
local coreTriggers={EnsureInitialize=true,InitializeOverride=true,ReceiveBeginPlay=true,
    UpdateCustomGameMatchOptions=true,HandleStartMatchOverride=true,K2_PostLogin=true,
    K2_OnLogout=true,TearDown=true,StartNewGameOverride=true,SetObjectiveTeam=true,
    SetReadyObjectiveTeamSelection=true,InitializeFromMatchPlayerState=true,
    SetTeamByRoundAndObjectiveTeam=true}

local valid=Lifetime.valid
local function unwrap(p) return p:get() end
local function name(o) return valid(o) and o:GetFullName() or "<invalid>" end
local function class(o, cls)
    return valid(o) and o:GetClass():GetFName():ToString() == cls
end
local function authority(o)
    return valid(o) and not name(o):find("Default__", 1, true) and o:HasAuthority() == true
end
local function diagnostic(key, message)
    local t = os.time()
    if not errors[key] or t - errors[key] >= C.DiagnosticRepeatSeconds then
        errors[key] = t; log("ERROR " .. key .. ": " .. tostring(message))
    end
end
-- Temporary profiler (lag hunt): log any guarded call slower than 15 ms,
-- at most once per 2 s per key, plus the slowest key every 10 s.
FAPP_PROF = rawget(_G,'FAPP_PROF') or {last={}, worst={}, since=os.clock(), wall=os.time(), topMs=0, depth=0}
function FAPP_SLOW(key, ms)
    local P = FAPP_PROF; local t = os.clock()
    if ms>30 then P.overruns=(P.overruns or 0)+1 end
    P.sum = P.sum or {}; local a = P.sum[key] or {n=0, ms=0}; a.n = a.n + 1; a.ms = a.ms + ms; P.sum[key] = a
    if ms > (P.worst[key] or 0) then P.worst[key] = ms end
    if ms >= 15 and t - (P.last[key] or -10) >= 2 then
        P.last[key] = t; print(string.format('[FillAPotPlus][PROF] %s %.1f ms\n', key, ms))
    end
    if os.time() - P.wall >= 10 then
        local k, w = nil, 0
        for name, v in pairs(P.worst) do if v > w then k, w = name, v end end
        if k then print(string.format('[FillAPotPlus][PROF] worst 10s: %s %.1f ms\n', k, w)) end
        local list = {}
        for name, v in pairs(P.sum or {}) do list[#list+1] = {name, v.n, v.ms, P.worst[name] or 0} end
        table.sort(list, function(x, y) return x[3] > y[3] end)
        local parts = {}
        -- Keep every hook (even cheap callbacks) for the >5/s frequency audit,
        -- plus expensive stages and high-frequency internal work.
        for i,v in ipairs(list) do
            if i<=12 or v[1]:sub(1,1)=='/' or v[2]>50 then parts[#parts+1]=string.format('%s n=%d %.0fms max=%.1fms',v[1],v[2],v[3],v[4]) end
        end
        local seconds=math.max(1,os.time()-P.wall)
        print(string.format('[FillAPotPlus][PROF] budget: wall=%.1fs guarded=%.1fms duty=%.2f%% >30ms=%d (includes native calls; nested sum keys overlap)\n',seconds,P.topMs,P.topMs/(seconds*10),P.overruns or 0))
        P.wall=os.time(); P.topMs=0
        P.overruns=0
        print('[FillAPotPlus][PROF] sum 10s: ' .. table.concat(parts, ' | ') .. '\n')
        P.worst = {}; P.sum = {}; P.since = t
    end
end
local function guard(key, fn)
    return function(...)
        local args = table.pack(...)
        local P=FAPP_PROF; P.depth=P.depth+1
        local t0 = os.clock()
        local result = table.pack(pcall(function() return fn(table.unpack(args, 1, args.n)) end))
        local ms=(os.clock()-t0)*1000
        P.depth=P.depth-1
        if P.depth==0 then P.topMs=P.topMs+ms end
        if not result[1] then
            -- A terminal Native fault has already revoked ordinary delivery.
            -- Do not print, diagnose, or enter cleanup after that boundary.
            if WIR_RUNTIME and not WIR_RUNTIME.is_healthy() then error(result[2],0) end
            -- Quiesce the owner BEFORE diagnostics can invoke error metamethods
            -- or optional profiling can reenter a callback from that owner.
            if FAPP_API and FAPP_API.fail then
                pcall(FAPP_API.fail,'guarded operation '..key)
            end
            -- Owned teardown itself can encounter a terminal Native fault.
            if WIR_RUNTIME and not WIR_RUNTIME.is_healthy() then error(result[2],0) end
            pcall(FAPP_SLOW,key,ms) -- optional logging cannot replace the owned error
            pcall(diagnostic,key,result[2]) -- formatting cannot replace the owned error
            error(result[2],0)
        end
        FAPP_SLOW(key,ms) -- preserve the successful handler's existing profiling behavior
        return table.unpack(result,2,result.n) -- includes false and trailing nils
    end
end
local function object(path)
    local o = StaticFindObject(path)
    assert(valid(o), "not loaded: " .. path)
    return o
end
local function gameplay() return object("/Script/Engine.Default__GameplayStatics") end
local function system() return object("/Script/Engine.Default__KismetSystemLibrary") end
local function world(o)
    if Lifetime.transition or not valid(o) then return end
    local g = gameplay()
    local gm = class(o, "B_ObjectiveGameMode_C") and o or g:GetGameMode(o)
    if not class(gm, "B_ObjectiveGameMode_C") or not authority(gm) then return end
    local gi = g:GetGameInstance(gm)
    local mm = valid(gi) and gi.ObjectiveMatchManager
    local gs = g:GetGameState(gm)
    if not valid(mm) or not class(gs, "B_ObjectiveGameState_C") or not authority(gs)
        or (Lifetime.world and not Lifetime.sameWorld(gm,gs)) then return end
    return gm, mm, gs
end
local function managerWorld(mm)
    -- Manager is a transient UObject, not an Actor: authority comes from its GM.
    for _, gm in ipairs(Registry.list("B_ObjectiveGameMode_C") or {}) do
        if authority(gm) then
            local g, m, s = world(gm)
            if g and Lifetime.key(m)==Lifetime.key(mm) then return g, m, s end
        end
    end
end
local function players(gs)
    local result = {}
    local function collect(p)
        local ps=unwrap(p)
        if class(ps, "B_ObjectivePlayerState_C") and authority(ps)
            and (not Lifetime.world or Lifetime.sameWorld(ps,gs)) then result[#result+1]=ps end
    end
    local array=gs.PlayerArray
    if type(array)=='table' and not array.ForEach then for _,p in ipairs(array) do collect(p) end
    else array:ForEach(function(_,p) collect(p) end) end
    return result
end
local function waiter(ps)
    if not valid(ps) then return end
    local w = waiting[ps:GetAddress()]
    if w and Lifetime.key(w.ps)==Lifetime.key(ps) and valid(w.state) then return w end
end
-- ObjectiveTeam=0 is also the untouched/default choice. Only the native
-- SelectObjectiveTeam RPC proves the player explicitly clicked Spectators.
local function chosenSpectator(ps,mm)
    local manager=chosenSpectators[Lifetime.key(ps)]
    return manager~=nil and ps.ObjectiveTeam==0 and manager==Lifetime.key(mm)
end
local function readyChosenSpectator(pc,mm)
    local ps=pc.PlayerState
    if mm.CurrentRound~=0 or not matchSettings(mm).StartWhenEveryoneReady
        or not authority(pc) or not authority(ps) or ps.IsPendingDisconnect or waiter(ps)
        or not chosenSpectator(ps,mm) or ps.IsReadyObjectiveTeamSelection~=false then return end
    local state=ps.ObjectiveMatchPlayerState
    if not valid(state) or state.ObjectiveTeam~=0 then return end
    -- Native public zero-arg toggle owns replication and guarded StartFirstRound.
    -- Never change base IsReady or toggle an already-ready spectator back off.
    pc:ToggleTeamSelectionReady()
end
local function set(o, key, value)
    if o[key] == value then return false end
    o[key] = value
    log(name(o) .. "." .. key .. " = " .. tostring(value))
    return true
end
local function dirty(o, index, key)
    assert(authority(o), "refused non-authority replication write")
    local old = changing; changing = true
    local ok, err = pcall(function()
        o:FlushNetDormancy()
        object("/Script/Engine.Default__NetPushModelHelpers"):
            MarkPropertyDirtyFromRepIndex(o, index, FName(key))
        o:ForceNetUpdate()
    end)
    changing = old
    if not ok then error(err) end
end
local function replicated(o, key, value, index, notify)
    assert(authority(o), "refused non-authority property write")
    if set(o, key, value) then
        dirty(o, index, key)
        if notify then o[notify](o) end
    end
end
local function apply(gm)
    local g, mm, gs = world(gm)
    if not g then return end
    syncLives(mm)
    local key=mm:GetAddress()
    if freeTeamSelection(mm) then
        if mm.RequiredPlayersPerTeam~=C.BalanceGuardQuota then
            local previous=balanceOwners[key]
            balanceOwners[key]={quota=mm.RequiredPlayersPerTeam,ignore=mm.IgnorePlayersPerTeamRequirement,
                uiQuota=gs.RequiredPlayersPerTeam}
            if previous then balanceOwners[key].ignore=previous.ignore end
        end
        set(mm, "IgnorePlayersPerTeamRequirement", true)
        set(mm, "RequiredPlayersPerTeam", C.BalanceGuardQuota)
        replicated(gs, "RequiredPlayersPerTeam", C.UiRequiredPlayersPerTeam, 51)
        if mm.CurrentRound == 0 and gm.TimerIsCounting then
            gm:TimerStop(); log("stopped native selection countdown/equalizer")
        end
    elseif balanceOwners[key] then
        local old=balanceOwners[key]
        if mm.RequiredPlayersPerTeam==C.BalanceGuardQuota then set(mm,"RequiredPlayersPerTeam",old.quota) end
        set(mm,"IgnorePlayersPerTeamRequirement",old.ignore)
        replicated(gs,"RequiredPlayersPerTeam",old.uiQuota,51)
        balanceOwners[key]=nil
    end
    if C.LateJoinSpectators then
        set(gm, "JoinAsHunter", false)
        local spectator = StaticFindObject(OM .. "B_ObjectiveSpectator.B_ObjectiveSpectator_C")
        if valid(spectator) then set(gm, "SpectatorPawn", spectator) end
    end
    replicated(gs, "MaxLives", hudLives, 47, "OnRep_MaxLives")
    appliedRules[tostring(gm:GetAddress())..'|'..gm:GetFullName()]={mm=mm,gs=gs,
        ready=matchSettings(mm).StartWhenEveryoneReady}
end
local function spectatorState(ps)
    local gm, mm = world(ps)
    if not gm or not authority(ps) or mm.CurrentRound <= 0 then return end
    local w = waiter(ps)
    if w then return w.state end
    if not C.LateJoinSpectators then return end
    -- Never AddPlayerWithId here: that inserts the waiter into the active roster.
    local state = StaticConstructObject(object(OM ..
        "B_ObjectiveMatchPlayerState.B_ObjectiveMatchPlayerState_C"), ps)
    assert(valid(state), "could not construct detached spectator state")
    state:Initialize(name(ps)) -- creates a valid zeroed ScoreStatManager
    state.ScoreStatManager.PlayerState = ps
    state.ObjectiveTeam = 0
    state.IsDead = false
    ps.ObjectiveMatchPlayerState = state -- reflected strong reference keeps it alive
    waiting[ps:GetAddress()] = {ps = ps, state = state, manager = mm}
    log("waiting until next match: " .. name(ps) .. " (detached from match roster)")
    return state
end
local function enforceWaiter(ps)
    local gm = world(ps)
    if not gm or not authority(ps) or not waiter(ps) then return end
    local pc = ps.PlayerController
    if authority(pc) then
        set(pc, "IsBeingKickedDueMatchHasStarted", false)
        set(pc, "IsRejoiningMatch", false)
    end
    ps.ObjectiveMatchPlayerState = waiter(ps).state
    replicated(ps, "ObjectiveTeam", 0, 50)
    replicated(ps, "Team", 2, 21, "OnRep_Team")
    replicated(ps, "SelectedTeam", 2, 22, "OnRep_SelectedTeam")
    replicated(ps, "Lives", 0, 49)
    replicated(ps, "IsDead", false, 24)
    if FAPP_SERVICES.runtime.read(ps,'IsReady')==true then waiter(ps).ready=true end
    replicated(ps, "IsReady", false, 23) -- do NOT OnRep: it can enter midgame spawn
    replicated(ps, "IsTeamInitialized", false, 52)
    replicated(ps, "IsReadyObjectiveTeamSelection", false, 51)
    set(ps, "IsWitchTeam", false)
    set(ps, "WantsToSpectate", true)
    set(ps, "GrantExpForThisRound", false)
    set(ps, "StartExpTime", 0)
end
local function releaseWaiter(ps)
    local w=waiter(ps)
    if not w then return end
    waiting[ps:GetAddress()]=nil
    ps.WantsToSpectate=false
    ps.GrantExpForThisRound=true
    -- Quarantine may have intercepted the one native readiness acknowledgement.
    -- Reapply only that acknowledgement, never fabricate readiness at login.
    if w.ready then replicated(ps,'IsReady',true,23) end
    log('released returning participant from waiter: '..name(ps))
end
local function refill(ps)
    local gm, mm = world(ps)
    if gm then syncLives(mm) end
    if not infinite or not gm or not authority(ps) or mm.CurrentRound <= 0
        or ps.IsPendingDisconnect or waiter(ps) or not ps.IsWitchTeam then return end
    replicated(ps, "Lives", lives, 49)
    local state = ps.ObjectiveMatchPlayerState
    if valid(state) then set(state, "Lives", lives) end
end
local function neutralTeam(ps)
    if not authority(ps) or not world(ps) then return end
    replicated(ps, "Team", 2, 21, "OnRep_Team")
    replicated(ps, "SelectedTeam", 2, 22, "OnRep_SelectedTeam")
    replicated(ps, "Lives", 0, 49)
    set(ps, "IsWitchTeam", false)
end
local function teamCounts(gs)
    local a, b = 0, 0
    for _, ps in ipairs(players(gs)) do
        if not ps.IsPendingDisconnect and not waiter(ps) then
            local team = ps.ObjectiveTeam
            if team == 1 then a = a + 1 elseif team == 2 then b = b + 1 end
        end
    end
    return a, b
end
local function eligible(gs,mm)
    local a, b = teamCounts(gs)
    local settings=matchSettings(mm)
    return a+b>0 and (settings.StartWhenEveryoneReady or settings.AllowEmptyTeams or (a>0 and b>0))
end
local function retime(s)
    local gm, mm, gs = world(s)
    if not gm or not authority(s) then return true end
    local pc = s:GetController()
    if not authority(pc) or Lifetime.key(pc.Pawn)~=Lifetime.key(s) then return true end
    local ps = pc.PlayerState
    if waiter(ps) or ps.IsPendingDisconnect or ps.Lives <= 0 or (gs.State ~= 1 and gs.State ~= 2)
        or mm.CurrentRound <= 0 then return true end
    local k = system()
    -- Same object + function binding as the BP delegate; replacement resets it.
    -- Only touch an EXISTING timer; do not invent extra TimerFinished/death calls.
    if not k:K2_TimerExists(s, "TimerFinished") then return end
    local remaining = k:K2_GetTimerRemainingTime(s, "TimerFinished")
    local elapsed = math.max(0, k:K2_GetTimerElapsedTime(s, "TimerFinished"))
    if math.abs(remaining + elapsed - C.RespawnSeconds) < 0.001 then return true end
    local delay = C.RespawnSeconds - elapsed
    if delay <= 0 then
        k:K2_ClearTimer(s, "TimerFinished")
        k:K2_SetTimerForNextTick(s, "TimerFinished")
    else
        k:K2_SetTimer(s, "TimerFinished", delay, false, false, 0, 0)
    end
    log("respawn timer on " .. name(s) .. " = " .. C.RespawnSeconds .. " seconds")
    return true
end
local function spawnSpectator(gm, pc)
    if not authority(gm) or not authority(pc) or not waiter(pc.PlayerState) then return end
    local pawn = pc.Pawn
    if class(pawn, "B_ObjectiveSpectator_C") then return end
    set(gm, "SpectatorPawn", object(OM .. "B_ObjectiveSpectator.B_ObjectiveSpectator_C"))
    -- Use game's SpawnNewPlayerPawn and configured SpectatorPawn, including handshake.
    local result = {}
    gm:SpawnNewPlayerPawn(2, pc, result)
    local p = result.PlayerPawn
    assert(class(p, "B_ObjectiveSpectator_C"), "SpectatorPawn did not produce B_ObjectiveSpectator_C")
    pc:Possess(p)
    if authority(pawn) then pawn:K2_DestroyActor(); log("removed replaced pawn " .. name(pawn)) end
    log("possessed Objective spectator for " .. name(pc))
end
local function promote(mm)
    local gm = managerWorld(mm)
    if not gm or mm.CurrentRound ~= 0 then return end
    for key, w in pairs(waiting) do
        if Lifetime.key(w.manager)==Lifetime.key(mm) then
            if authority(w.ps) and not w.ps.IsPendingDisconnect then
                local out = {}
                mm:GetObjectiveMatchPlayerState(w.ps, out)
                assert(valid(out.ObjectiveMatchPlayerState), "next roster record unavailable")
                w.ps.ObjectiveMatchPlayerState = out.ObjectiveMatchPlayerState
                waiting[key] = nil -- release only after a genuine NEXT-roster record exists
                w.ps:InitializeFromMatchPlayerState()
                set(w.ps, "WantsToSpectate", false)
                replicated(w.ps, "IsTeamInitialized", false, 52)
                replicated(w.ps, "IsReadyObjectiveTeamSelection", false, 51)
                log("released into next match team selection: " .. name(w.ps))
            else
                waiting[key] = nil
            end
        end
    end
end
-- Menu drivers may only hook menu UI: gameplay classes are loaded there only
-- transiently (Custom Match reads their defaults) and get unloaded -> crash.
local MENU_SAFE = {"/Game/UserInterface/Play/", "/Game/UserInterface/Maps/", "/Game/UserInterface/UIElements/", "/Script/"}
local function menuSafe(path)
    for _, prefix in ipairs(MENU_SAFE) do if path:sub(1, #prefix) == prefix then return true end end
    return false
end
local function installHook(h)
    if h.installed then return end
    local f=StaticFindObject(h.path)
    if Lifetime.rawValid(f) then
        local method=h.path:match(':([^:]+)$')
        local ok,pre,post=pcall(FAPP_SERVICES.runtime.subscribe,h.path,h.callback,h.post,{
            priority=h.priority,override=HookPolicy.replacements[method]==true,
            out_params=HookPolicy.outputs[method] or {},
        })
        if ok then h.installed=true; installed[h.path]={pre,post}; log('hooked '..h.path)
        else diagnostic('register '..h.path,pre) end
    end
end
local function hook(path, callback, post, validateSelf, priority)
    assert(not Events.forbiddenHook(path),'refused hot hook: '..path)
    if path:sub(1,6)=='/Game/' and not Events.hot(path) and not path:match(':ReceiveEndPlay$') and not path:match(':ReceiveDestroyed$') then
        local fn=callback
        local diag=path:find('/UserInterface/',1,true)~=nil; local said={}
        local method=path:match(':([^:]+)$')
        local playtest=method=='BeginPlayTest' or method=='EndPlayTest' or method=='OnRep_IsPlayTestMode'
            or method=='ChangePlayerMode'
        callback=function(self,...)
            if not Events.passiveUiEvent(path,unwrap(self)) then Events.changed() end
            if coreTriggers[path:match(":([^:]+)$")] and path:find("B_Objective",1,true) then coreDirty=true end
            Registry.track(unwrap(self))
            local accepted=not Lifetime.transition and (validateSelf or valid)(unwrap(self))
            if playtest then
                log('playtest hook '..method..': entered; decision='..(accepted and 'dispatch' or 'skip')
                    ..'; transition='..tostring(Lifetime.transition)..'; epoch='..tostring(Lifetime.epoch)
                    ..(accepted and '' or '; reason='..(Lifetime.transition and 'world transition' or 'invalid self')))
            end
            if accepted then return fn(self,...) end
            if diag then -- one line per reason: why a UI hook was muted
                local why=Lifetime.transition and 'transition' or 'invalid self'
                if not said[why] then said[why]=true; log('UI hook muted ('..why..'): '..path) end
            end
        end
    end
    -- Assets/classes may arrive after BeginPlay (skills, respawn pawns, UI).
    -- Construction only queues a game-thread retry; menu retries stay menu-only.
    local asset=path:match('^(/Game/[^:]+):')
    if asset and not hookNotifications[asset] then
        hookNotifications[asset]=true
        FAPP_API.notify(asset,function()
            if FAPP_MODE.work(asset) then
                retryAssets[asset]=true; retryDirty=true
                if installLoaded and FAPP_MODE.state.mode=='objective' then installLoaded(asset) end
            end
        end)
    end
    local h={path=path,callback=guard(path,callback),
        post=post and guard(path.." post",post),priority=priority or 0,
        decision=HookPolicy.decisions[path:match(':([^:]+)$')]==true}
    hooks[#hooks+1]=h
    -- A re-enabled package may have missed every class/BeginPlay notification.
    -- Resolve resident functions now; notifications only cover absent targets.
    if FAPP_MODE.state.mode~='menu' or menuSafe(path) then installHook(h) end
end
local function bp(asset, fn, cb) hook(OM .. asset .. "." .. asset .. "_C:" .. fn, cb) end
local function core(asset, fn, cb) hook(CORE .. asset .. "." .. asset .. "_C:" .. fn, cb) end

local LIFE_WIDGET = "/Game/UserInterface/ObjectiveMode/WB_LifeBlock.WB_LifeBlock_C:"
local function lifeVisibility(w)
    if Lifetime.transition or not valid(w) then return end
    -- This admitted live widget is the native WorldContext. Icon visibility
    -- doesn't need world()'s repeated GM/GS/manager owner-chain validation.
    local g=gameplay(); local gm=g:GetGameMode(w); local gs=g:GetGameState(w)
    if not Lifetime.alive(gm) or gm:GetClass():GetFName():ToString()~='B_ObjectiveGameMode_C'
        or gm:HasAuthority()~=true or not Lifetime.alive(gs)
        or gs:GetClass():GetFName():ToString()~='B_ObjectiveGameState_C' then return end
    local gi=g:GetGameInstance(w); local mm=Lifetime.alive(gi) and gi.ObjectiveMatchManager
    if not Lifetime.alive(mm) then return end
    local pc=w:GetOwningPlayer(); local ps=Lifetime.alive(pc) and pc.PlayerState
    w:SetVisibility(matchSettings(mm).MaxLives=='infinite' and 1 or (Lifetime.alive(ps) and ps.Team==0 and 0 or 1))
end

for _,fn in ipairs({'Construct','CreateLiveIcons','MaxLivesChanged'}) do hook(LIFE_WIDGET..fn,function(self) lifeVisibility(unwrap(self)) end) end

-- Narrow native notifications plus retained-roster property observations.
-- The global dirty helper executes for every replicated property in the game.
propertyChanged=function(o,key)
    if changing then return end
    if key=='Stacks' then
        if Hold then Hold.stacks(o) end
        if WinnerOrder then WinnerOrder.stacks(o) end
        if ReviveRules then ReviveRules.stacks(o) end
        return
    end
    if Hud then Hud.changed() end
    if R and R.changed then R.changed() end
    if Hold and Hold.changed and key=='State' then Hold.changed() end
    if Restore and Restore.changed then Restore.changed(o,key) end
        if key=="IsDead" and ReviveRules then ReviveRules.deadChanged(o) end
        -- Only rule-relevant properties need authority and world resolution.
        if key ~= "Lives" and key ~= "MaxLives" and key ~= "RequiredPlayersPerTeam"
            and key ~= "Team" and key ~= "SelectedTeam" and key ~= "IsReady"
            and key ~= "IsDead" and key ~= "ObjectiveTeam" and key ~= "IsTeamInitialized"
            and key ~= "IsReadyObjectiveTeamSelection" then return end
        if not valid(o) then return end
        local cls = o:GetClass():GetFName():ToString()
        if cls ~= "B_ObjectivePlayerState_C" and cls ~= "B_ObjectiveGameState_C" then return end
        if cls == "B_ObjectiveGameState_C" and key ~= "MaxLives"
            and key ~= "RequiredPlayersPerTeam" then return end
        if cls == "B_ObjectivePlayerState_C" and not waiter(o)
            and (key ~= "Lives" or not infinite) then return end
        if not authority(o) then return end
        local gm,mm = world(o)
        if not gm then return end
        syncLives(mm)
        if class(o, "B_ObjectivePlayerState_C") then
            if waiter(o) then enforceWaiter(o)
            elseif key == "Lives" then refill(o) end
        elseif class(o, "B_ObjectiveGameState_C") then
            if key == "MaxLives" then
                -- GS initializes by notifying BEFORE marking dirty. Notify again
                -- after clamping so the listen host rebuilds the capped icon block.
                if set(o, "MaxLives", hudLives) then o:OnRep_MaxLives() end
            elseif key == "RequiredPlayersPerTeam" and freeTeamSelection(mm) then
                set(o, "RequiredPlayersPerTeam", C.UiRequiredPlayersPerTeam)
            end
        end
end
local observedProperties={}
local function observeProperties(o,keys)
    if not Lifetime.rawValid(o) then return end
    local id=o:GetAddress(); local r=observedProperties[id]
    if not r or r.name~=o:GetFullName() then r={name=o:GetFullName()}; observedProperties[id]=r end
    for _,key in ipairs(keys) do
        local value=o[key]
        if r[key]~=value then r[key]=value; propertyChanged(o,key); r[key]=o[key] end
    end
end
local playerProperties={'Lives','Team','SelectedTeam','ObjectiveTeam','IsDead','IsReady','IsReadyObjectiveTeamSelection','IsPendingDisconnect','IsTeamInitialized'}
local rosterCache,rosterRevision,rosterEpoch,rosterEvents={},-1,-1,-1
local function observeRosterJob()
    local stages={}
    if rosterRevision~=Registry.revision or rosterEpoch~=Lifetime.epoch or rosterEvents~=Events.revision then
        local revision,epoch,events=Registry.revision,Lifetime.epoch,Events.revision
        local records={}
        for _,gameMode in ipairs(Registry.list('B_ObjectiveGameMode_C')) do
            stages[#stages+1]=Work.defer(function()
                local activeMode,manager,gameState=world(gameMode)
                if not activeMode then return function() return true end end
                local record={gm=activeMode,mm=manager,gs=gameState,players={},key=tostring(activeMode:GetAddress())..'|'..activeMode:GetFullName()}; records[#records+1]=record
                local states=FAPP_SERVICES.runtime.values(gameState.PlayerArray)
                return Work.each(states,function(playerState)
                    if class(playerState,'B_ObjectivePlayerState_C') and authority(playerState)
                        and (not Lifetime.world or Lifetime.sameWorld(playerState,gameState)) then
                        record.players[#record.players+1]=playerState
                    end
                end)
            end)
        end
        stages[#stages+1]=function()
            rosterCache=records; rosterRevision=revision; rosterEpoch=epoch; rosterEvents=events
            return true
        end
    end
    stages[#stages+1]=Work.defer(function()
        local observations={}
        local function properties(actor,keys)
            observations[#observations+1]=function() observeProperties(actor,keys); return true end
        end
        for _,record in ipairs(rosterCache) do
            properties(record.gs,{'State','MaxLives','RequiredPlayersPerTeam','CurrentRound'})
            for _,playerState in ipairs(record.players) do properties(playerState,playerProperties) end
        end
        return Work.sequence(observations)
    end)
    stages[#stages+1]=function() if Hud then Hud.poll() end; return true end
    return Work.sequence(stages)
end
for _,fn in ipairs({'OnRep_Team','OnRep_SelectedTeam','OnRep_IsReady'}) do
    hook('/Game/Blueprints/Player/B_PlayerState.B_PlayerState_C:'..fn,function(self)
        observeProperties(unwrap(self),playerProperties)
    end)
end
bp('B_ObjectivePlayerState','OnRep_IsReadyObjectiveTeamSelection',function(self) observeProperties(unwrap(self),playerProperties) end)
bp('B_ObjectiveGameState','OnRep_MaxLives',function(self) propertyChanged(unwrap(self),'MaxLives') end)
bp('B_ObjectiveCauldron','OnRep_Stacks',function(self) propertyChanged(unwrap(self),'Stacks') end)
hook('/Game/Blueprints/Player/Components/B_DamageHandler.B_DamageHandler_C:RemoveTeamAndSetDead',function(self)
    local ps=unwrap(self).OwnerPlayerState
    if class(ps,'B_ObjectivePlayerState_C') then propertyChanged(ps,'IsDead') end
end)
for _,fn in ipairs({'ReceivePossessed','HandleClientProcessed'}) do
    bp('B_ObjectiveKillSpectator',fn,function(self)
        local actor=unwrap(self); local pc=actor:GetController()
        if valid(pc) and class(pc.PlayerState,'B_ObjectivePlayerState_C') then observeProperties(pc.PlayerState,playerProperties) end
    end)
end

Hud=dofile(directory.."hud_lives_status.lua").init({
    valid=valid,class=class,world=world,settings=matchSettings,players=players,waiter=waiter,
    chosenSpectator=chosenSpectator,
    object=object,hook=hook,guard=guard,Lifetime=Lifetime,Registry=Registry,
    visibility=lifeVisibility,
    revision=function() return Settings and Settings.revision or 0 end,
})

for _, fn in ipairs({"EnsureInitialize", "InitializeOverride", "ReceiveBeginPlay",
    "UpdateCustomGameMatchOptions"}) do
    bp("B_ObjectiveGameMode", fn, function(self) apply(unwrap(self)) end)
end
bp("B_ObjectiveGameMode", "IsPlayerTeamSelectionBalanced", function(self, _, balanced)
    local gm, mm, gs = world(unwrap(self))
    if gm and freeTeamSelection(mm) then balanced:set(eligible(gs,mm)); log("balance output = " .. tostring(eligible(gs,mm))) end
end)
bp("B_ObjectiveGameMode","CheckTimerForMatchStart",function(self)
    -- Observation, not an invalidation: no inventory/lifetime walk or apply here.
    if Lifetime.transition then return end
    local gm=unwrap(self)
    local record=appliedRules[tostring(gm:GetAddress())..'|'..gm:GetFullName()]
    if not record then coreDirty=true; return end
    if record.ready and record.mm.CurrentRound==0 and gm.TimerIsCounting then gm:TimerStop() end
end)
bp("B_ObjectiveGameMode","AreAllPlayersReadyWithTeamSelection",function(self,out)
    local gm,mm,gs=world(unwrap(self))
    if not gm or mm.CurrentRound~=0 or not matchSettings(mm).StartWhenEveryoneReady then return end
    local present,ready=false,true
    for _,ps in ipairs(players(gs)) do
        if not ps.IsPendingDisconnect and not waiter(ps)
            and not (chosenSpectator(ps,mm) and ps.IsReadyObjectiveTeamSelection==true) then
            present=true
            if (ps.ObjectiveTeam~=1 and ps.ObjectiveTeam~=2) or ps.IsReadyObjectiveTeamSelection~=true then ready=false end
        end
    end
    out:set(present and ready)
end)
bp("B_ObjectiveGameMode", "HandleStartMatchOverride", function(self)
    local gm, _, gs = world(unwrap(self))
    if not gm then return end
    apply(gm)
    for _, ps in ipairs(players(gs)) do
        if waiter(ps) then enforceWaiter(ps)
        elseif not ps.IsPendingDisconnect and ps.Team == 0 then
            replicated(ps, "Lives", lives, 49)
            if valid(ps.ObjectiveMatchPlayerState) then set(ps.ObjectiveMatchPlayerState, "Lives", lives) end
        end
    end
end)
-- The spectator decrements Lives and calls CheckEndMatchWitchesDead before its
-- POST hook. Repair at the specific alive query's return boundary, where the
-- native caller still has not made its end decision. Finite mode returns early.
bp('B_ObjectiveGameMode','CheckWitchesAlive',function(self,out)
    if not infinite then return end
    local gm,mm,gs=world(unwrap(self)); if not gm then return end
    syncLives(mm); if not infinite then return end
    local alive=false
    for _,ps in ipairs(players(gs)) do
        if ps.IsWitchTeam and not ps.IsPendingDisconnect and not waiter(ps) then refill(ps); alive=true end
    end
    if alive then out:set(true) end
end)
bp("B_ObjectiveGameMode", "GetTotalWitchesLives", function(self, total)
    local gm,mm=world(unwrap(self))
    if gm then syncLives(mm) end
    if gm and infinite and C.NormalizeInfiniteLifeScore then
        total:set(0); log("infinite lives round-result total = 0")
    end
end)
bp("B_ObjectiveMatchManager", "CanTeamSurrender", function(self, team, gsParam, allowed)
    local gm,mm=managerWorld(unwrap(self))
    if not gm or not freeTeamSelection(mm) then return end
    if R and R.is_waiting() then allowed:set(false); return end
    local gs, count = unwrap(gsParam), 0
    if not authority(gs) then return end
    for _, ps in ipairs(players(gs)) do
        if not waiter(ps) and not ps.IsPendingDisconnect
            and ps.ObjectiveTeam ~= 0 and ps.Team == unwrap(team) then count = count + 1 end
    end
    -- Preserve the native UI's single-member rule, without an equal-quota test.
    allowed:set(count == 1); log("surrender eligibility = " .. tostring(count == 1))
end)
bp("B_ObjectiveMatchManager", "GetObjectiveMatchPlayerState", function(self, psParam, out)
    local mm, ps = unwrap(self), unwrap(psParam)
    if not managerWorld(mm) or not authority(ps) then return end
    if R and R.pending_login(ps.PlayerController) and R.enabled() then
        local retained=Identity.member(mm,unwrap(out))
        if retained then
            releaseWaiter(ps)
            ps.ObjectiveMatchPlayerState=retained
            R.admit(ps.PlayerController)
            return
        end
    end
    local w = waiter(ps)
    if not C.LateJoinSpectators and not w then return end
    if mm.CurrentRound > 0 and (w or not valid(unwrap(out))) then
        local state = w and w.state or spectatorState(ps)
        if state then
            out:set(state); log("supplied detached state for " .. name(ps))
            enforceWaiter(ps)
        end
    end
end)
bp("B_ObjectiveMatchManager", "IsPlayerInMatch", function(self, psParam, out)
    if managerWorld(unwrap(self)) and waiter(unwrap(psParam)) then
        if unwrap(out) then
            out:set(false); log("excluded waiter from active match membership")
        end -- connected != participant; do not fool reconnect/death checks
    end
end)
bp("B_ObjectiveMatchManager", "TearDown", function(self)
    local mm=unwrap(self)
    if managerWorld(mm) then
        if Settings then Settings.resetMatch(mm) end
        if mm.CurrentRound==0 then
            local manager=Lifetime.key(mm)
            for key,value in pairs(chosenSpectators) do if value==manager then chosenSpectators[key]=nil end end
        end
    end
    promote(mm)
end)
bp("B_ObjectiveGameMode", "K2_PostLogin", function(self, pcParam)
    local gm, mm = world(unwrap(self))
    local pc = unwrap(pcParam)
    if not gm or not authority(pc) or not C.LateJoinSpectators or mm.CurrentRound <= 0 then return end
    local ps = pc.PlayerState
    if not authority(ps) then return end
    if R and R.login(pc) then return end -- resolve before waiter quarantine/parent handshake
    spectatorState(ps)
    enforceWaiter(ps) -- clear kick flag BEFORE the controller's next tick/0.5s Delay
    -- Objective PostLogin skips the common handler for nonparticipants. Execute it
    -- once to register the session, send server info and run the loading handshake.
    object(CORE .. "B_GameMode.B_GameMode_C:K2_PostLogin")(gm, pc)
    enforceWaiter(ps)
    spawnSpectator(gm, pc)
end)
bp("B_ObjectivePlayerController","SelectObjectiveTeam",function(self,team)
    local pc=unwrap(self)
    local gm,mm=world(pc)
    if not gm or not authority(pc) or mm.CurrentRound~=0 then return end
    local ps=pc.PlayerState
    if not authority(ps) or ps.IsPendingDisconnect or waiter(ps) then return end
    local selected=unwrap(team)
    local state=ps.ObjectiveMatchPlayerState
    if not valid(state) or state.ObjectiveTeam~=selected or ps.ObjectiveTeam~=selected then return end
    chosenSpectators[Lifetime.key(ps)]=selected==0 and Lifetime.key(mm) or nil
    if Hud then Hud.changed() end
    if selected==0 then readyChosenSpectator(pc,mm) end
end)
for _, fn in ipairs({"SetObjectiveTeam", "SetReadyObjectiveTeamSelection"}) do
    bp("B_ObjectivePlayerController", fn, function(self)
        local pc = unwrap(self)
        local gm,mm=world(pc)
        if authority(pc) and gm then
            if waiter(pc.PlayerState) then enforceWaiter(pc.PlayerState)
            elseif fn=="SetObjectiveTeam" then
                local ps=pc.PlayerState
                if authority(ps) and (ps.ObjectiveTeam==1 or ps.ObjectiveTeam==2) then
                    chosenSpectators[Lifetime.key(ps)]=nil
                end
            elseif fn=="SetReadyObjectiveTeamSelection" then readyChosenSpectator(pc,mm) end
        end
    end)
end
for _, fn in ipairs({"InitializeFromMatchPlayerState", "SetTeamByRoundAndObjectiveTeam", "SaveDataToMatchPlayerState"}) do
    bp("B_ObjectivePlayerState", fn, function(self)
        local ps = unwrap(self)
        if world(ps) and authority(ps) then
            if waiter(ps) then enforceWaiter(ps)
            elseif fn == "SetTeamByRoundAndObjectiveTeam" and ps.ObjectiveTeam == 0 then neutralTeam(ps)
            else refill(ps) end
        end
    end)
end
bp("B_ObjectiveGameMode", "GetPlayerPlayTime", function(self, ps, playtime)
    if world(unwrap(self)) and waiter(unwrap(ps)) and unwrap(playtime) ~= 0 then
        playtime:set(0); log("waiter playtime output = 0")
    end
end)
core("B_GameMode", "CanJoinAsMidgameHunter", function(self, out)
    if world(unwrap(self)) and C.LateJoinSpectators and unwrap(out) then
        out:set(false); log("midgame hunter joining output = false")
    end
end)
core("B_GameMode", "CheckIfAllPlayersAreReady", function(self, out)
    local gm, mm, gs = world(unwrap(self))
    if not gm or mm.CurrentRound <= 0 or gs.State ~= 0 then return end
    local explicitReady=matchSettings(mm).StartWhenEveryoneReady
    local hasWaiter, hasParticipant, ready = false, false, true
    for _, ps in ipairs(players(gs)) do
        if FAPP_SERVICES.runtime.read(ps,'IsPendingDisconnect')~=true then
            if waiter(ps) then hasWaiter = true
            elseif not explicitReady or not chosenSpectator(ps,mm) then
                hasParticipant = true
                -- Preserve the base game's PlayerId=0 readiness exception.
                if FAPP_SERVICES.runtime.read(ps,'IsReady')~=true and (explicitReady or ps:GetPlayerId()~=0) then ready=false end
            end
        end
    end
    if (hasWaiter or explicitReady) and unwrap(out) ~= (hasParticipant and ready) then
        out:set(hasParticipant and ready)
        log("preparation readiness excludes waiters = " .. tostring(hasParticipant and ready))
    end
end)
core("B_GameMode", "RandomizeTeamSelection", function(self)
    local gm, mm, gs = world(unwrap(self))
    if not gm or not freeTeamSelection(mm) then return end
    -- Core HandleStartMatch can apply the generic hunter-ratio lottery after
    -- Objective's team setup. Its body only selects teams; restore before the
    -- calling HandleStartMatch continues into spawning/XP initialization.
    for _, ps in ipairs(players(gs)) do
        if waiter(ps) then enforceWaiter(ps)
        elseif ps.ObjectiveTeam == 0 and not ps.IsPendingDisconnect then neutralTeam(ps)
        elseif FAPP_SERVICES.runtime.read(ps,'IsPendingDisconnect')~=true then ps:SetTeamByRoundAndObjectiveTeam() end
    end
    log("restored Objective teams after generic hunter-ratio randomization")
end)
bp("B_ObjectiveGameMode", "K2_OnLogout", function(self, exitingParam)
    local gm, mm, gs = world(unwrap(self))
    if not gm then return end
    local pc = unwrap(exitingParam)
    if valid(pc) and valid(pc.PlayerState) then
        waiting[pc.PlayerState:GetAddress()] = nil; chosenSpectators[Lifetime.key(pc.PlayerState)]=nil
    end
    if mm.CurrentRound <= 0 or (gs.State ~= 1 and gs.State ~= 2) then return end
    if not valid(pc) or not Identity.participant(mm,pc.PlayerState) then return end
    local participants, spectators = 0, 0
    for _, ps in ipairs(players(gs)) do
        if FAPP_SERVICES.runtime.read(ps,'IsPendingDisconnect')~=true then
            if waiter(ps) then spectators = spectators + 1
            else
                if Identity.participant(mm,ps) then participants = participants + 1 end
            end
        end
    end
    if participants == 0 and spectators > 0 and not (R and R.is_waiting()) then
        -- Original IsMatchDead marks IsMatchOver but can leave a live round with
        -- connected nonparticipants. Abandon this empty roster and restart;
        -- do not manufacture a missing second-round result state.
        set(mm, "IsMatchOver", true)
        gm:StartNewGame(false)
        log("restarted abandoned match after all participants disconnected")
    end
end)
bp("B_ObjectiveGameMode", "StartNewGameOverride", function(self, byJoin, out)
    local gm, mm, gs = world(unwrap(self))
    if gm and (C.LateJoinSpectators or next(waiting)~=nil) and mm.CurrentRound > 0 and unwrap(byJoin) then
        out:set(false); log("prevented join-triggered match restart")
    end
    if gm and not unwrap(byJoin) and unwrap(out)==true and gs.State==3 then
        pendingTimers={}
        -- The accepted override is immediately before the native wrapper's travel.
        -- Do not restore props or retime an old death pawn after this boundary.
        if Restore then Restore.reset() end
    end
end)
for _, fn in ipairs({"ReceivePossessed", "HandleClientProcessed", "TimerFinished"}) do
    bp("B_ObjectiveKillSpectator", fn, function(self)
        local s = unwrap(self)
        if authority(s) and world(s) then
            -- The BP can install the timer in a DelayFrames continuation. Poll
            -- until it exists, replace ONCE, then remove this pending item.
            pendingTimers[Lifetime.key(s)] = {actor=s,deadline=Clock.now()+6}
            if retime(s) then pendingTimers[Lifetime.key(s)] = nil end
        end
    end)
end
bp("B_ReviveTotem", "ReceiveBeginPlay", function(self)
    local totem = unwrap(self)
    if authority(totem) and world(totem) then
        set(totem, C.Properties.TotemReviveSeconds, C.TotemReviveSeconds)
    end
end)

installDecisions=function(asset)
    for _,h in ipairs(hooks) do
        if h.decision and not h.installed and (not asset or h.path:match('^([^:]+):')==asset) then installHook(h) end
    end
end
installLoaded=function(asset)
    for _,h in ipairs(hooks) do
        if not h.installed and (not asset or h.path:match('^([^:]+):')==asset) then installHook(h) end
    end
end
FAPP_API.on('world_ready',function() if FAPP_MODE.state.mode=='objective' then installLoaded() end end,{ungated=true})
local function tryHooks(menuOnly,assets)
    local install=Work.each(hooks,function(h)
            if not h.installed and (not assets or assets[h.path:match('^([^:]+):')])
                and (not menuOnly or menuSafe(h.path)) then guard('hooks:install',installHook)(h) end
    end)
    if FAPP_TEST_NO_THROTTLE then return Work.finish(install) end
    local queued=Work.submit(menuOnly and 'hooks:menu' or 'hooks:world','hook installation',install)
    if not queued then retryDirty=true end -- a load notification during an older pass needs a later retry
end

local lastObjects=-1
local lastSettings=-1
local function subsystem(key,api,fn)
    if api then guard('maintenance/'..key,api[fn or 'poll'])() end
end
local function maintenance()
    if Lifetime.transition then return end
    local function submit(key,label,step)
        if FAPP_TEST_NO_THROTTLE then Work.finish(step) else Work.submit(key,label,step) end
    end
    local stages={Work.defer(observeRosterJob)}
    for _,entry in ipairs({{'settings',SettingsUI},{'capabilities',Extras},{'possession',Restore},
        {'maps',Maps},{'reconnect',R},{'pause',Hold},{'softlocks',Integration}}) do
        stages[#stages+1]=function() subsystem(entry[1],entry[2]); return true end
    end
    stages[#stages+1]=function()
        if not coreDirty and lastObjects==Registry.revision and (not Settings or lastSettings==Settings.revision) then return true end
        coreDirty=false; lastObjects=Registry.revision; lastSettings=Settings and Settings.revision
        submit('maintenance:HUD','maintenance/HUD',Hud.discoverJob())
        submit('maintenance:rules','maintenance/rules',Work.each(Registry.list('B_ObjectiveGameMode_C'),function(gm)
            local key=Lifetime.key(gm)
            if not key then return end
            submit('maintenance:players:'..key,'maintenance/players',Work.defer(function()
                local g,mm,gs=world(gm)
                if not g then return function() return true end end
                apply(gm)
                if mm.CurrentRound==0 then promote(mm) end
                return Work.each(players(gs),function(ps)
                    if valid(ps) then
                        if waiter(ps) then enforceWaiter(ps); spawnSpectator(gm,ps.PlayerController) else refill(ps) end
                    end
                end)
            end))
        end))
        submit('maintenance:totems','maintenance/totems',Work.each(Registry.list('B_ReviveTotem_C'),function(totem)
            if authority(totem) and world(totem) then set(totem,C.Properties.TotemReviveSeconds,C.TotemReviveSeconds) end
        end))
        return true
    end
    stages[#stages+1]=Work.defer(function()
        local timers={}; for key,record in pairs(pendingTimers) do timers[#timers+1]={key=key,record=record} end
        return Work.each(timers,function(entry)
            local record=entry.record
            if pendingTimers[entry.key]==record and (Clock.now()>record.deadline or not valid(record.actor) or retime(record.actor)) then
                pendingTimers[entry.key]=nil
            end
        end)
    end)
    local step=Work.sequence(stages)
    if FAPP_TEST_NO_THROTTLE then
        Work.finish(step)
    else Work.submit('maintenance','maintenance',step) end
end
-- Register on the game thread; no UObject mutation/registration on the async loop.
-- BeginPlay PRE installs hooks before new Objective PS/PC script initialization.
local beginClasses={B_ObjectiveGameMode_C=true,B_ObjectiveGameState_C=true,B_ObjectivePlayerController_C=true,
    B_ObjectivePlayerState_C=true,B_ObjectiveKillSpectator_C=true,B_ReviveTotem_C=true,
    B_PlayerController_C=true,B_MenuPlayerController_C=true,B_CreativeGameMode_C=true,
    B_CreativeGameState_C=true,B_CreativePlayerController_C=true,B_RandomPropLayoutPicker_C=true}
local beginAnchor
local function actorWork(label,actor,fn,fullName)
    if FAPP_TEST_NO_THROTTLE then return fn() end
    local key=tostring(actor:GetAddress())..'|'..(fullName or actor:GetFullName())
    Work.submit(label..':'..key,label,function()
        if Lifetime.alive(actor) then fn() end
        return true
    end)
end
FAPP_API.on('begin_play_pre',guard("BeginPlay", function(actorParam,cls,fullName)
    local a = unwrap(actorParam)
    -- Destination actors can arrive before heartbeat registration finishes.
    -- Adopt their world using raw lifetime checks, otherwise valid() rejects
    -- every new actor against the departing menu world and bootstrap never runs.
    if not cls then cls=a:GetClass():GetFName():ToString() end
    -- Install loaded decision paths before this actor's Blueprint BeginPlay.
    if FAPP_MODE.state.mode=='objective' then installDecisions() end
    if cls=="B_ObjectiveGameMode_C" or cls=="B_ObjectiveGameState_C"
            or cls=="B_ObjectivePlayerController_C" or cls=="B_PlayerController_C"
            or cls=="B_CreativePlayerController_C" then
        if Lifetime.rawValid(a) then
            Lifetime.observe(a, gameplay():GetTimeSeconds(a))
            beginAnchor=a
        end
    end
    if C.CreativeMaps and Maps and Maps.begin
        and (cls=='B_RandomPropLayoutPicker_C' or cls=='B_CreativeGameMode_C') then Maps.begin(a) end
    actorWork('BeginPlay/inventory',a,function()
        Registry.track(a)
        if Lifetime.rawValid(a) then Registry.track(gameplay():GetGameInstance(a)) end
        coreDirty=true; retryDirty=true
        if initializeModules then initializeModules(true) end
        if cls=="B_ObjectiveGameMode_C" or cls=="B_ObjectiveGameState_C"
            or cls=="B_ObjectivePlayerState_C" or cls=="B_ObjectivePlayerController_C"
            or cls=="B_ObjectiveKillSpectator_C" or cls=="B_ReviveTotem_C"
            or cls=="B_PlayerController_C" or cls=="B_CreativePlayerController_C" then
            tryHooks()
            if Extras and (cls=="B_ObjectiveGameMode_C" or cls=="B_ObjectiveGameState_C") then
                Extras.beginPlay(a)
            end
        end
    end,fullName)
end),{class_filter=function(name) return beginClasses[name]==true end})
-- Constructors and BeginPlay PRE can precede final components/world/metadata.
-- A distinct readiness event wakes cached consumers even if membership is unchanged.
local births={}
FAPP_API.on('begin_play_post',guard('BeginPlay/ready',function(actorParam,cls,fullName)
    local actor=unwrap(actorParam)
    if beginClasses[cls] then
        actorWork('BeginPlay/ready',actor,function() Registry.ready(actor) end,fullName)
    elseif FAPP_TEST_NO_THROTTLE then Registry.ready(actor)
    else
        births[#births+1]=actor
        Work.submit('inventory:births','inventory readiness',function()
            local nextActor=table.remove(births) -- one constructor completion per step
            if nextActor then Registry.ready(nextActor) end
            return #births==0
        end)
    end
end),{class_filter=function(name) return beginClasses[name]==true or Registry.classes[name]==true end})
-- All periodic work uses runtime native game-thread delays (async Lua raced and
-- corrupted the shared Lua state: "bad argument #2 to 'for iterator'").
local lastMaint = Clock.now()-C.MaintenanceMs/1000
local function runRetry(menuOnly)
    retryDirty=false
    local assets=next(retryAssets) and retryAssets or nil; retryAssets={}
    guard("hook retry", tryHooks)(menuOnly,assets)
    if menuOnly and SettingsUI then
        Work.submit('settings:discovery','UI discovery',function() SettingsUI.discover(); return true end)
        Work.submit('settings:poll','UI poll',function() SettingsUI.poll(); return true end)
    end
end
local function runMaintenance() lastMaint = Clock.now(); guard("maintenance", maintenance)() end
local lastMenuTick = 0
local menuContext
local function inGameplay()
    -- Clients have a GameState but no authoritative GameMode. World registry
    -- membership decides the gate; a recent timer must not extend itself forever
    -- after traveling into a menu.
    if Lifetime.transition then return false end
    -- Shared service containers implement pairs; raw next cannot see a leased view.
    for _,short in ipairs({'B_ObjectiveGameMode_C','B_CreativeGameMode_C',
        'B_ObjectiveGameState_C','B_CreativeGameState_C',
        'B_ObjectivePlayerController_C','B_CreativePlayerController_C'}) do
        for _ in pairs(Registry.buckets[short]) do return true end
    end
    return false
end
local function menuDriver(self)
    local t = Clock.now()
    if inGameplay() or (not menuDirty and not next(FAPP_PENDING_KEYS or {}) and not (Maps and Maps.menuPending and Maps.menuPending())) then return end
    if t - lastMenuTick < 0.3 then return end
    lastMenuTick = t; menuDirty=false
    -- Release the travel latch in menus too (only gameplay ticks did this before,
    -- so all Maps hooks stayed muted in the main menu).
    pcall(function()
        local b = self:get()
        if Lifetime.rawValid(b) then Lifetime.observe(b,t) end -- adopt destination before ordinary same-world validation
    end)
    menuDirty=Lifetime.transition -- settlement needs a second distinct-time observation
    if initializeModules then guard("init modules", initializeModules)() end
    if FAPP_RUN_PENDING_KEYS then guard("menu keys", FAPP_RUN_PENDING_KEYS)() end
    runRetry(true) -- menu-UI hook registration (map list, Custom Match) + settings UI
    if Extras then guard("menu capabilities",Extras.poll)() end
    if Maps then guard("maps menu commands",Maps.menuPoll)() end
    if SettingsUI then guard("UI poll", SettingsUI.poll)() end
    -- No Maps.poll here: map maintenance is match/editor work and crashed the menu.
end
for _,asset in ipairs({'/Game/UserInterface/Play/WB_Custommatch.WB_Custommatch_C',
    '/Game/UserInterface/Play/GameRules/WB_GameRulesTabs.WB_GameRulesTabs_C'}) do
    FAPP_API.notify(asset,function(widget)
        Registry.track(widget)
        menuContext=widget; menuDirty=true; retryDirty=true; Settlement.wake()
    end)
    FAPP_API.hook(asset..':Construct',function(self)
        local widget=self:get()
        Registry.ready(widget); menuContext=widget; menuDirty=true; retryDirty=true; Settlement.wake()
    end)
end
FAPP_PENDING_KEYS = FAPP_PENDING_KEYS or {}
local function runPendingKeys()
    for key, fn in pairs(FAPP_PENDING_KEYS) do
        if fn then FAPP_PENDING_KEYS[key] = nil; guard("key " .. key, fn)() end
    end
end
FAPP_RUN_PENDING_KEYS = runPendingKeys
local function heartbeat(delta)
    -- This delta belongs to an actual steady-clock timer, never a BP callback.
    Clock.tick(delta)
    local t=Clock.now()
    Settlement.advance(t*1000)
    local anchor
    for _,short in ipairs({'B_ObjectiveGameMode_C','B_CreativeGameMode_C','B_ObjectiveGameState_C','B_CreativeGameState_C','B_ObjectivePlayerController_C','B_CreativePlayerController_C','B_GameInstance_C'}) do
        for _,o in pairs(Registry.buckets[short] or {}) do
            if Lifetime.rawValid(o) then anchor=o; break end
        end
        if anchor then break end
    end
    if not anchor and Lifetime.rawValid(menuContext) then anchor=menuContext end
    if not anchor and Lifetime.rawValid(beginAnchor) then anchor=beginAnchor end
    -- Travel/reset can precede actor notifications (including a same-world
    -- round transition). Resolve one GameState from the retained GameInstance,
    -- never a global scan, so interrupted HUD construction can settle too.
    if anchor and not inGameplay() then
        local gs=gameplay():GetGameState(anchor)
        if Lifetime.rawValid(gs) then
            local cls=gs:GetClass():GetFName():ToString()
            if cls=='B_ObjectiveGameState_C' or cls=='B_CreativeGameState_C' then
                Lifetime.observe(gs,t); Registry.track(gs); anchor=gs
            end
        end
    end
    if Lifetime.transition and (not anchor or not Lifetime.observe(anchor,t)) then return end
    if initializeModules then initializeModules() end
    runPendingKeys()
    local backlogged=Work.pending()
    if inGameplay() then
        if R and R.pending() then Work.submit('deadline:reconnect','reconnect heartbeat',function() R.poll(); return true end) end
    if Restore and Restore.pending() then Work.submit('deadline:possession','possession heartbeat',function() Restore.tick(); return true end) end
    if Integration and Integration.pending() then Work.submit('deadline:softlocks','softlock heartbeat',function() Integration.poll(); return true end) end
        if Maps and Maps.deadlinePending() then Work.submit('deadline:maps','maps heartbeat',function() Maps.tick(); return true end) end
        -- Dirty events wait for this timer too: no frame/event bypass of the cap.
        if (FAPP_TEST_NO_THROTTLE or not backlogged) and t-lastMaint>=math.max(.5,C.MaintenanceMs/1000) then runMaintenance() end
        if retryDirty then runRetry() end
    elseif anchor then
        menuDriver({get=function() return anchor end})
    end
    -- Core drains finite cursors once per native game-thread frame; heartbeat
    -- only produces 500 ms maintenance, never a second drain in the same frame.
end
local armHeartbeat
local heartbeatCancel,heartbeatTicket,heartbeatDue=nil,0,nil
local timedHeartbeat=guard('heartbeat/timer',heartbeat)
armHeartbeat=function()
    if not FAPP_API.is_live() then
        -- Owned runtime timers are already canceled by package retirement.
        -- Only invalidate local tickets/references; never create an inactive timer.
        heartbeatTicket=heartbeatTicket+1
        heartbeatCancel=nil; heartbeatDue=nil
        return false
    end
    -- One ticket invalidates a canceled/lost callback even if native delivery
    -- arrives late. The closure retains scalars/services, never an actor.
    if heartbeatCancel then heartbeatCancel(); heartbeatCancel=nil end
    heartbeatTicket=heartbeatTicket+1
    local ticket=heartbeatTicket
    local delay=500 -- finite cursors have their own game-thread frame driver
    heartbeatDue=os.time()+delay/1000
    heartbeatCancel=FAPP_API.delay(delay,function()
        if ticket~=heartbeatTicket then return end
        heartbeatCancel=nil
        timedHeartbeat(delay/1000)
        if ticket==heartbeatTicket then armHeartbeat() end
    end)
end
local heartbeatDormant=not FAPP_API.is_active()
local watchdogStop,checkHeartbeat
local function armWatchdog()
    if not FAPP_API.is_live() then watchdogStop=nil; return false end
    if watchdogStop then watchdogStop() end
    watchdogStop=FAPP_API.loop(2000,function() checkHeartbeat() end)
end
checkHeartbeat=function()
    -- Independent low-rate sentinel: a native registry failure can discard the
    -- heartbeat handoff without entering Lua or the runtime's error handler.
    -- Gated contexts hold their timer normally; do not restart them here.
    if heartbeatDormant or not FAPP_API.is_active() or not heartbeatDue or os.time()<heartbeatDue+2 then return end
    log('heartbeat watchdog: overdue timer; rearming')
    armHeartbeat()
    armWatchdog()
end
armWatchdog()
-- Rare producers also recover if the sentinel's native handoff was lost.
-- These callbacks retain no UObject/RemoteUnrealParam from event arguments.
FAPP_API.on('context_changed',function()
    local active=FAPP_API.is_active()
    -- resume_timers runs before this event; a held sentinel may be resumed
    -- before the held heartbeat. Give normal gate reactivation its own grace.
    if active and heartbeatDormant then heartbeatDue=os.time()+.5 end
    heartbeatDormant=not active
    checkHeartbeat()
end)
FAPP_API.on('world_ready',checkHeartbeat,{ungated=true})
FAPP_API.hook('/Game/UserInterface/UIElements/WB_BaseControl.WB_BaseControl_C:ButtonClicked',checkHeartbeat)
-- Modules use the same relative-file mechanism as config.lua. No game paths written.
local function module(filename)
    assert(directory, "gameplay module source directory unavailable for module " .. filename)
    return dofile(directory .. filename .. ".lua")
end
local booting=false
local startupStep
initializeModules=function(critical)
    if modulesReady then return end
    if booting then
        if critical and startupStep then Work.finish(startupStep); Work.cancel('package:initialize') end
        return
    end
    booting=true
    local prepare=Work.sequence({function()
    Evidence.emit("session_start",{grace=C.reconnect.max_wait_seconds,automatic_hold=C.reconnect.pause_timer})
    Hold = Hold or module("timer_hold").init(C, {
        log=log, world=world, authority=authority, valid=valid, readObject=object,
        hook=hook, guard=guard,
    })
    return true
    end,function()
    R = R or module("reconnect").init(C, log, {
        timer=Hold, addHook=function(path,callback,post,validateSelf)
            return hook(path,callback,post,validateSelf,10)
        end, isInstalled=function(p) return installed[p] ~= nil end,
        world=world, isWaiter=waiter, releaseWaiter=releaseWaiter, events=Evidence,
        abandon=function(gm) gm:StartNewGame(false) end,
        isInfinite=function() return infinite end,
    })
    return true
    end,function()
    Integration = Integration or module("integration").init(C, {
        log=log, world=world, authority=authority, valid=valid, class=class,
        object=object, hook=hook, guard=guard, waiter=waiter, reconnect=R,
        timer=Hold, helpers=module("softlock_helpers"),
    })
    return true
    end,function()
    Restore=Restore or module("possession_restore").init(C,{
        log=log,valid=valid,class=class,authority=authority,world=world,object=object,
        hook=hook,guard=guard,
    })
    return true
    end,function()
    Extras=Extras or module("extras").init(C,{
        log=log,valid=valid,class=class,authority=authority,world=world,object=object,
        hook=hook,guard=guard,settings=matchSettings,retryHooks=tryHooks,
        installed=function(p) return installed[p]~=nil end,
    })
    return true
    end,function()
    WinnerOrder=WinnerOrder or module("winner_order").init(C,{
        log=log,valid=valid,class=class,world=world,managerWorld=managerWorld,object=object,Lifetime=Lifetime,
        hook=hook,waiter=waiter,installed=function(p) return installed[p]~=nil end,
    })
    return true
    end,function()
    ReviveRules=ReviveRules or module("revive_rules").init(C,{
        log=log,valid=valid,class=class,authority=authority,world=world,object=object,
        hook=hook,settings=matchSettings,managerWorld=managerWorld,players=players,waiter=waiter,
    })
    return true
    end,function()
    if not Maps then Maps=module("maps_runtime").init(C,{
        directory=directory,
        log=function(s) print("[FillAPotPlus]"..tostring(s).."\n") end,valid=valid,class=class,authority=authority,object=object,hook=hook,
        retryHooks=tryHooks,loadHooks=installLoaded,installed=function(p) return installed[p]~=nil end,
        resultpreview=function() return WinnerOrder.resultpreview() end,
    },module,true) end
    return true
    end})
    local build=Work.sequence({function()
    return Maps.initialize()
    end,function()
    if Settings and C.SettingsUI then SettingsUI=SettingsUI or module("settings_ui").init(C,Settings,{
        log=log,valid=valid,class=class,object=object,hook=hook,guard=guard,
        retryHooks=tryHooks,
    }) end
    modulesReady=true
    Work.items=512
    booting=false
    -- No BeginPlay/class event is replayed when enabling in an existing world.
    -- The native tick supplies the actual current local controller/world.
    local activation=assert(FAPP_API.Native.scope(FAPP_API.id),'current world Native scope unavailable')
    assert(activation.on_tick(function(_,context)
        local gm,pc=FAPP_API.module('current_world').adopt(FAPP_API,FAPP_SERVICES,FAPP_MODE,context)
        if pc then
            beginAnchor=pc
            if Lifetime.rawValid(gm) then Maps.begin(gm) end
            coreDirty=true; retryDirty=true; menuDirty=true
            log('adopted current world; current world actor/widget queries complete; markers='
                ..#Registry.list('BP_WitchCauldron_C')..'/'..#Registry.list('BP_WitchRuneStone01_C')
                ..'; scenery='..#Registry.list('B_StaticMeshProp_C'))
            Maps.poll() -- evaluate the fully populated registry, including cached modules
        end
        maintenance() -- activation's synchronous intake precedes initial evaluation
        return false -- one activation pass; ordinary births own future worlds
    end),'current world activation callback unavailable')
    return true
    end})
    -- Startup is resumable. An actual gameplay birth is a synchronous decision
    -- boundary and may finish the remaining declarations before native execution.
    startupStep=Work.sequence({prepare,build})
    if critical then return guard('integration load',function() Work.finish(startupStep) end)() end
    Work.submit('package:initialize','package initialization',guard('integration load',startupStep),true)
end
Lifetime.onReset(function()
    -- Drop any old heartbeat ticket before the departing-world queue resets.
    -- The next callback only resolves current Core inventory after settlement.
    armHeartbeat()
    armWatchdog()
    waiting={}; chosenSpectators={}; pendingTimers={}; balanceOwners={}; appliedRules={}; FAPP_PENDING_KEYS={}; observedProperties={}; menuContext=nil; beginAnchor=nil
    births={}; coreDirty=true; retryDirty=true; menuDirty=true; lastObjects=-1; rosterCache={}; rosterRevision=-1; Work.reset(); Settlement.reset()
    for _,api in pairs({R,Hold,Integration,SettingsUI,Extras,Restore,Maps,WinnerOrder,ReviveRules}) do
        if api.reset then api.reset() end
    end
end)
Lifetime.install()
FAPP_INITIALIZE_GAMEPLAY=initializeModules
initializeModules()
guard("initial hooks",tryHooks)(true)
log("loaded; lives=" .. tostring(C.MaxLives) .. ", HUD icons=" .. hudLives ..
    ", respawn=" .. C.RespawnSeconds .. "s; Objective authority only")

armHeartbeat()
