-- One owner for TimerIsCounting. Manual and reconnect holds cannot resume each other.
local M={}
function M.init(C,H)
    local Registry=FAPP_SERVICES.registry
    local api, tokens, snapshot = {}, {}, nil
    local function same(a,b) return H.valid(a) and H.valid(b) and FAPP_SERVICES.lifetime.same(a,b) end
    local function context(gm)
        local g,m,s=H.world(gm)
        if g and m.CurrentRound>0 and not m.IsMatchOver and (s.State==1 or s.State==2) then
            return g,m,s
        end
    end
    local function notify(gs,text)
        if C.PauseNotification and H.authority(gs) then
            -- Core B_GameState:812 + B_GameMode:945 (existing system-message type 10).
            local ok,err=pcall(function() gs:SendGameMessageMulticast(FText(text),FText(text),10) end)
            if not ok then H.log("pause notification unavailable: "..tostring(err)) end
        end
    end
    function api.notice(gm,text)
        local _,_,gs=context(gm)
        if gs then notify(gs,text) end
    end
    local function releaseSnapshot()
        if not snapshot then return end
        local p=snapshot
        local g,m,s=context(p.gm)
        if g and same(g,p.gm) and m.CurrentRound==p.round and s.State==p.state then
            g.TimerIsCounting=p.counting
            if p.overtime then s.IsInOvertime=true end
            H.log("timer resumed counting="..tostring(p.counting))
        end
        snapshot=nil
    end
    local dirty=false
    function api.poll()
        if not dirty and not snapshot then return end
        dirty=false
        local gm=snapshot and snapshot.gm
        if not gm then
            for _,g in pairs(tokens) do gm=g; break end
        end
        if not gm then return end
        local g,m,s=context(gm)
        if not g or (snapshot and (m.CurrentRound~=snapshot.round or s.State~=snapshot.state)) then
            tokens={}; snapshot=nil
            H.log("pause holds cleared at world/round/phase boundary")
            return
        end
        if next(tokens) then
            if not snapshot then
                snapshot={gm=g,round=m.CurrentRound,state=s.State,counting=FAPP_SERVICES.runtime.read(g,'TimerIsCounting')==true,overtime=s.IsInOvertime==true}
                H.log("timer held; gameplay continues")
            end
            -- Native Objective Tick calls CheckForOverTime (and two world scans)
            -- whenever this flag is true. Suspend that gate while held, retaining
            -- logical overtime for resume; other native win events still operate.
            if s.IsInOvertime==true then snapshot.overtime=true; s.IsInOvertime=false end
            if FAPP_SERVICES.runtime.read(g,'TimerIsCounting')==true then g.TimerIsCounting=false end
        else releaseSnapshot() end
    end
    function api.acquire(token,gm)
        local g=context(gm)
        if not g then return false end
        tokens[token]=g; dirty=true; api.poll(); return true
    end
    function api.release(token)
        local existed=tokens[token]~=nil
        tokens[token]=nil; dirty=true
        if not next(tokens) then releaseSnapshot() else api.poll() end
        return existed
    end
    function api.has(token) return tokens[token]~=nil end
    function api.status()
        return "manual="..tostring(api.has("manual"))..",reconnect="..
            tostring(api.has("reconnect"))
    end
    function api.toggle()
        local gm
        for _,g in ipairs(Registry.list("B_ObjectiveGameMode_C") or {}) do
            if H.authority(g) and context(g) then gm=g; break end
        end
        if not gm then return end -- menu, clients, other modes, preparation/results
        dirty=true; api.poll() -- discard stale epoch before deciding whether this is a resume
        local _,m,s=context(gm)
        if api.has("manual") then
            if not api.release("manual") then return end
            notify(s,api.has("reconnect") and "PAUSED (reconnect grace)" or "RESUMED")
            H.log("manual pause OFF; "..api.status())
            return
        end
        api.acquire("manual",gm); notify(s,api.has('reconnect') and 'PAUSED (manual + reconnect grace)' or 'PAUSED')
        H.log("manual pause ON; "..api.status())
    end
    H.hook("/Game/Blueprints/Core/B_GameMode.B_GameMode_C:TimerStart",function(self)
        local gm=self:get()
        -- A legitimate new timer/cauldron update supersedes the counting snapshot.
        dirty=true; api.poll()
        if snapshot and same(gm,snapshot.gm) and H.authority(gm) then
            snapshot.counting=true; gm.TimerIsCounting=false
        end
    end)
    for _,fn in ipairs({'HandleEndMatchOverride','HandleStartMatchOverride','HandleStartSeek','StartNewGameOverride'}) do
        H.hook('/Game/Blueprints/Gamemodes/ObjectiveMode/B_ObjectiveGameMode.B_ObjectiveGameMode_C:'..fn,function()
            dirty=true; api.poll()
        end)
    end
    function api.stacks(pot)
        if not snapshot or not snapshot.overtime or pot.Stacks<pot.MaxStacks then return end
        local g,_,s=H.world(pot)
        if g and same(g,snapshot.gm) then
            -- OnRep_Stacks is called BEFORE the full-pot native continuation.
            -- Restore its overtime branch for this delivery: native code replaces
            -- remaining time with ExtraTime and clears the flag itself.
            snapshot.overtime=false; s.IsInOvertime=true
        end
    end
    function api.changed() dirty=true; api.poll() end
    function api.reset() tokens={}; snapshot=nil; dirty=false end
    return api
end
return M
