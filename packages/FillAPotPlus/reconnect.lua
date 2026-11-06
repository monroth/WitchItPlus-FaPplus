return function(S)
    local R,C=S.R,S.C
    local records,waiters={},{}
    function S.waiter(ps) return waiters[ps:GetAddress()] end
    function S.participant(ps)
        -- The manager resolves UniqueNetId, before the account fields arrive.
        local out={}
        S.manager():GetObjectiveMatchPlayerState(ps,out)
        local mps=R.valid(out.ObjectiveMatchPlayerState)
        if mps and (mps.ObjectiveTeam==1 or mps.ObjectiveTeam==2) then return mps,S.text(mps.PlayerId),mps end
        return nil,nil,mps
    end
    local function waiting(witch)
        for _,r in pairs(records) do if r.waiting and (witch==nil or r.witch==witch) then return true end end
        return false
    end
    local function witchTeam(mm)
        local team={};mm:GetWinnerForRound(mm.CurrentRound==1,team)
        return team.WinnerTeam
    end
    local function halfLives(witch)
        return witch and (S.rules().lives=='infinite' and 99 or S.rules().lives) or 0
    end
    local function startHalf(mps,witch)
        mps.Lives=halfLives(witch);mps.IsDead=false;mps.HealthPercental=1
    end
    local function outcome()
        local s=C.session();local mm=S.manager()
        if mm.IsMatchOver then return end
        local counts,roles={[1]=0,[2]=0},{}
        for _,ps in ipairs(S.players()) do
            if not ps.IsPendingDisconnect and not S.waiter(ps) and ps.ObjectiveTeam>0 then
                counts[ps.ObjectiveTeam]=counts[ps.ObjectiveTeam]+1;roles[ps.ObjectiveTeam]=ps.Team
            end
        end
        for _,r in pairs(records) do
            if r.waiting then counts[r.team]=counts[r.team]+1;roles[r.team]=r.witch and 0 or 1 end
        end
        if counts[1]>0 and counts[2]>0 then s.gm:CheckEndMatchWitchesDead();return end
        mm.IsMatchOver=true
        if counts[1]+counts[2]==0 then s.gm:StartNewGame(false);return end
        mm.CurrentRound=2;S.write(s.gs,'CurrentRound',2,49)
        s.gm:HandleEndMatch(roles[counts[1]>0 and 1 or 2],s.gs.State==3)
    end
    S.onMatchHost.pre(S.path(S.O,'B_ObjectiveGameMode','UnregisterPlayerOverride'),function(gm,pc)
        if not R.valid(pc) then return end
        local ps,mm=pc.PlayerState,S.manager()
        if not R.valid(ps) or mm.CurrentRound==0 or mm.IsMatchOver then return end
        local mps,id=S.participant(ps)
        if not mps or S.waiter(ps) then return end
        local witch=mps.ObjectiveTeam==witchTeam(mm)
        local lives=(ps.SelectedTeam==0)==witch and ps.Lives or halfLives(witch)
        local r={mps=mps,witch=witch,
            team=mps.ObjectiveTeam,waiting=S.rules().rejoin~=false and S.rules().grace>0 and (not witch or lives>0)}
        records[id]=r
        if r.waiting then
            local manager=mm:GetAddress()
            r.cancel=R.after(S.rules().grace*1000,function()
                r.waiting=false
                -- A deadline can outlive its match; act only on the match that started it.
                if S.inMatch() and S.host() and S.manager():GetAddress()==manager then outcome() end
            end,true)
        end
        -- Native UnregisterPlayerOverride saves the additive score exactly once.
    end)
    S.onMatchHost.post(S.path(S.O,'B_ObjectiveGameMode','StartNewGameOverride'),function(gm,restartByPlayerJoin)
        local mm=S.manager()
        S.log('StartNewGame byJoin=%s round=%d over=%s players=%d',tostring(restartByPlayerJoin),mm.CurrentRound,tostring(mm.IsMatchOver),#S.players())
        if restartByPlayerJoin then return end
        if mm.CurrentRound~=2 or mm.IsMatchOver then return end
        -- The native half transition advances the roster before travelling, but
        -- HandleStartMatchOverride initializes only connected PlayerStates.
        local team=witchTeam(mm)
        mm.Players:ForEach(function(_,value)
            local mps=value:get()
            if mps.ObjectiveTeam==1 or mps.ObjectiveTeam==2 then startHalf(mps,mps.ObjectiveTeam==team) end
        end)
        for _,r in pairs(records) do
            if r.waiting then r.witch=r.team==team end
        end
    end)
    S.onMatchHost.post(S.path(S.O,'B_ObjectivePlayerState','SaveDataToMatchPlayerState'),function(ps)
        local mm=S.manager()
        local mps=R.valid(ps.ObjectiveMatchPlayerState)
        if not mps or mm.CurrentRound~=2 then return end
        -- Halftime reuses GameState; a pending player keeps the previous
        -- SelectedTeam. Native deaths change Team, leaving SelectedTeam intact.
        -- Keep additive scores, but not a previous role's reserve or health.
        if mps.ObjectiveTeam==1 or mps.ObjectiveTeam==2 then
            local witch=mps.ObjectiveTeam==witchTeam(mm)
            if (ps.SelectedTeam==0)~=witch then startHalf(mps,witch) end
        end
    end)
    for _,method in ipairs({'IsMatchDead','IsMatchIntact'}) do
        S.onMatchHost.post(S.path(S.O,'B_ObjectiveMatchManager',method),function(mm,gs,out)
            if waiting() then out:set(method=='IsMatchIntact') end
        end)
    end
    S.onMatchHost.post(S.path(S.O,'B_ObjectiveMatchManager','CanTeamSurrender'),function(mm,_,gs,out)
        if waiting() then out:set(false) end
    end)
    S.onMatchHost.post(S.path(S.CORE,'B_GameMode','GetHuntersCount'),function(gm,out)
        if waiting(false) then out:set(math.max(1,out:get())) end
    end)
    S.onMatchHost.post(S.path(S.O,'B_ObjectiveGameMode','CheckWitchesAlive'),function(gm,out)
        if waiting(true) then out:set(true) end
    end)
    local function quarantine(ps)
        S.write(ps,'ObjectiveTeam',0,50);S.write(ps,'Team',2,21);S.write(ps,'SelectedTeam',2,22)
        S.write(ps,'Lives',0,49);S.write(ps,'IsDead',false,24)
        S.write(ps,'IsTeamInitialized',false,52)
        ps.IsWitchTeam=false;ps.WantsToSpectate=true;ps.GrantExpForThisRound=false;ps.StartExpTime=0
        ps:OnRep_Team();ps:OnRep_SelectedTeam()
    end
    local function newWaiter(ps)
        local state=S.new(S.path(S.O,'B_ObjectiveMatchPlayerState'),ps)
        state:Initialize(ps:GetPlayerName());state.ScoreStatManager.PlayerState=ps
        state.ObjectiveTeam=0;state.IsDead=false
        waiters[ps:GetAddress()]=state
        return state
    end
    S.onMatchHost.pre(S.path(S.O,'B_ObjectiveGameMode','K2_PostLogin'),function(gm,pc)
        if not R.valid(pc) or S.manager().CurrentRound==0 then return end
        local ps=pc.PlayerState
        if not R.valid(ps) then return end
        local mps,id,native=S.participant(ps)
        local rejoin=S.rules().rejoin~=false
        if (not mps or not rejoin) and S.rules().lateSpectate==false then
            -- Native policy refuses newcomers once the match has started.
            StaticFindObject(S.path(S.CORE,'B_GameMode','K2_PostLogin'))(gm,pc)
            pc.IsBeingKickedDueMatchHasStarted=true
            return true
        end
        local parent=StaticFindObject(S.path(S.CORE,'B_GameMode','K2_PostLogin'))
        parent(gm,pc)
        pc.IsBeingKickedDueMatchHasStarted=false;pc.IsRejoiningMatch=false
        if mps and rejoin then
            local r=records[id] or {mps=mps,team=mps.ObjectiveTeam}
            records[id]=r;r.pc=pc
            ps.ObjectiveMatchPlayerState=mps
            ps:InitializeFromMatchPlayerState();r.witch=ps.Team==0;r.lives=mps.Lives
            -- Active-round native selection offers no Ready action. The roster
            -- attachment is complete; let the native controller respawn it.
            r.armed=true;pc.RejoinInitialized=false;pc.IsRejoiningMatch=true
        else
            -- An unassigned roster entry can survive a previous lobby. Remember
            -- this admission on its native identity, across halftime PlayerStates.
            if native then
                local key=S.text(native.PlayerId)
                records[key]=records[key] or {}
                records[key].spectating=true
            end
            ps.ObjectiveMatchPlayerState=waiters[ps:GetAddress()] or newWaiter(ps)
            quarantine(ps)
            local pawn=R.native.spawn(S.path(S.O,'B_ObjectiveSpectator'),gm,gm:K2_GetActorLocation())
            pc:Possess(pawn)
        end
        return true
    end)
    S.onMatchHost.post(S.path(S.O,'B_ObjectiveMatchManager','GetObjectiveMatchPlayerState'),function(mm,ps,out)
        if not R.valid(ps) then return end
        local state=S.waiter(ps)
        local native=R.valid(out:get())
        local record=native and records[S.text(native.PlayerId)]
        -- Halftime waiters are unassigned. A selected lobby team can still be
        -- awaiting native roster insertion when the first player advances.
        if not state and ps.ObjectiveTeam==0 and mm.CurrentRound>0 and S.rules().lateSpectate~=false
            and (not native or record and record.spectating) then
            state=newWaiter(ps);quarantine(ps)
        end
        if state then out:set(state) end
    end)
    S.onMatchHost.post(S.path(S.O,'B_ObjectiveMatchManager','IsPlayerInMatch'),function(mm,ps,out)
        if R.valid(ps) and S.waiter(ps) then out:set(false) end
    end)
    local function restored(ps,id,r)
        if r.cancel then r.cancel() end
        r.waiting=false;r.armed=false;records[id]=nil
        r.mps.Lives=r.lives;S.write(ps,'Lives',r.lives,49)
    end
    S.onMatchHost.post('/Script/Engine.Controller:Possess',function(pc)
        local ps=pc.PlayerState
        if not R.valid(ps) then return end
        local _,id=S.participant(ps);local r=id and records[id]
        if not r or r.pc~=pc or not r.armed then return end
        -- Witch rejoin subtracts a life AFTER Possess, then marks Lives dirty.
        if r.witch and r.lives>0 then r.possessed=true else restored(ps,id,r) end
    end)
    -- Called by events.lua when a PlayerState's Lives are marked dirty.
    function S.livesWritten(ps)
        for id,r in pairs(records) do
            if r.armed and r.possessed and r.pc.PlayerState==ps then restored(ps,id,r);return end
        end
    end
    S.onMatchHost.post(S.path(S.O,'B_ObjectiveGameMode','GetPlayerPlayTime'),function(gm,ps,out)
        if R.valid(ps) and S.waiter(ps) then out:set(0) end
    end)
    -- Called by events.lua when the match manager tears down.
    function S.clearReconnect()
        for _,r in pairs(records) do if r.cancel then r.cancel() end end
        records={}
        for _,ps in ipairs(S.players()) do
            if S.waiter(ps) then ps.WantsToSpectate=false;ps.GrantExpForThisRound=true end
        end
        waiters={}
    end
    R.on('world_end',function() waiters={} end)
end
