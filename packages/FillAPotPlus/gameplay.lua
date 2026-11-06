return function(S)
    local R,C=S.R,S.C
    local O=S.O
    local manual=false
    local counting
    local function togglePause()
        local s=C.session()
        -- The pause belongs to a hosted Fill a Pot+ match, rounds and the time between them.
        if not S.inMatch() or not S.host() then return end
        if not manual then counting=s.gm.TimerIsCounting end
        manual=not manual;s.gm.TimerIsCounting=not manual and counting~=false
        local message=FText(manual and 'Round timer paused' or 'Round timer resumed')
        s.gs:SendGameMessageMulticast(message,message,10)
    end
    R.key('fap.pause','F8',togglePause)
    S.U.menu_entry('/Game/UserInterface/WB_IngameMenu.WB_IngameMenu_C','Settings','Pause timer',togglePause,nil,
        function() return S.inMatch() and S.host() end,function() return manual and 'Resume timer' or 'Pause timer' end)
    S.onMatchHost.post(S.path(S.CORE,'B_GameMode','TimerStart'),function(gm)
        if manual then gm.TimerIsCounting=false end
    end)
    R.on('world_end',function() manual=false;counting=nil end)
    -- With a choice of sides, team 1 is the witch side of the first round.
    S.onMatchHost.post(S.path(O,'B_ObjectiveMatchManager','RandomizeTeamAStartsAsWitch'),function(mm)
        if S.rules().roleChoice then mm.TeamAStartsAsWitch=true end
    end)
    function S.applyGameplay()
        local session=C.session()
        local gm,gs,mm=session.gm,session.gs,S.manager()
        local rules=S.rules()
        if rules.unequal or rules.startReady then
            mm.IgnorePlayersPerTeamRequirement=true;mm.RequiredPlayersPerTeam=1000000
            S.write(gs,'RequiredPlayersPerTeam',2,51)
            if mm.CurrentRound==0 then gm:TimerStop() end
        end
        S.allowSkills()
        gm.JoinAsHunter=false
        gm.SpectatorPawn=S.asset(S.path(O,'B_ObjectiveSpectator'))
        S.write(gs,'MaxLives',rules.lives=='infinite' and 0 or math.min(5,rules.lives),47)
        gs:OnRep_MaxLives()
    end
    for _,method in ipairs({'EnsureInitialize','InitializeOverride','ReceiveBeginPlay','UpdateCustomGameMatchOptions'}) do
        S.onMatchHost.post(S.path(O,'B_ObjectiveGameMode',method),S.applyGameplay)
    end
    local function ready(property,skipDisconnected)
        local count=0
        for _,ps in ipairs(S.players()) do
            if not S.waiter(ps) and (not skipDisconnected or not ps.IsPendingDisconnect) then
                count=count+1
                if not ps[property] then return false end
            end
        end
        return count>0
    end
    S.onMatchHost.post(S.path(O,'B_ObjectiveGameMode','IsPlayerTeamSelectionBalanced'),function(gm,_,out)
        local r=S.rules()
        if r.startReady then out:set(#S.players()>0);return end
        if not r.unequal then return end
        local a,b=0,0
        for _,ps in ipairs(S.players()) do
            if not ps.IsPendingDisconnect then
                if ps.ObjectiveTeam==1 then a=a+1 elseif ps.ObjectiveTeam==2 then b=b+1 end
            end
        end
        out:set(a>0 and b>0)
    end)
    S.onMatchHost.post(S.path(O,'B_ObjectiveGameMode','AreAllPlayersReadyWithTeamSelection'),function(gm,out)
        out:set(ready('IsReadyObjectiveTeamSelection',S.rules().startReady))
    end)
    S.onMatchHost.post(S.path(S.CORE,'B_GameMode','CheckIfAllPlayersAreReady'),function(gm,out)
        if S.rules().startReady then out:set(ready('IsReady',true));return end
        local present,all=false,true
        for _,ps in ipairs(S.players()) do
            if not ps.IsPendingDisconnect and not S.waiter(ps) then
                present=true
                if not ps.IsReady and ps:GetPlayerId()~=0 then all=false end
            end
        end
        out:set(present and all)
    end)
    S.onMatchHost.post(S.path(S.CORE,'B_GameMode','RandomizeTeamSelection'),function(gm)
        if not (S.rules().unequal or S.rules().startReady) then return end
        for _,ps in ipairs(S.players()) do
            if not ps.IsPendingDisconnect then
                if ps.ObjectiveTeam==0 then
                    S.write(ps,'Team',2,21);S.write(ps,'SelectedTeam',2,22)
                    ps.IsWitchTeam=false
                else ps:SetTeamByRoundAndObjectiveTeam() end
            end
        end
    end)
    S.onMatchHost.post(S.path(O,'B_ObjectiveGameMode','HandleStartMatchOverride'),function(gm)
        S.applyGameplay()
        local lives=S.rules().lives=='infinite' and 99 or S.rules().lives
        for _,ps in ipairs(S.players()) do
            if ps.Team==0 and not ps.IsPendingDisconnect and not S.waiter(ps) then
                S.write(ps,'Lives',lives,49);ps.ObjectiveMatchPlayerState.Lives=lives
            end
        end
    end)
    S.onMatchHost.post(S.path(O,'B_ObjectiveGameMode','CheckWitchesAlive'),function(gm,out)
        if S.rules().lives~='infinite' then return end
        local alive=false
        for _,ps in ipairs(S.players()) do
            if ps.IsWitchTeam and not ps.IsPendingDisconnect and not S.waiter(ps) then
                S.write(ps,'Lives',99,49);ps.ObjectiveMatchPlayerState.Lives=99;alive=true
            end
        end
        if alive then out:set(true) end
    end)
    S.onMatchHost.post(S.path(O,'B_ObjectiveGameMode','GetTotalWitchesLives'),function(gm,out)
        if S.rules().lives=='infinite' then out:set(0) end
    end)
    S.onMatchHost.post(S.path(S.CORE,'B_GameMode','CanJoinAsMidgameHunter'),function(gm,out)
        out:set(false)
    end)
    for _,method in ipairs({'ReceivePossessed','HandleClientProcessed'}) do
        S.onMatchHost.post(S.path(O,'B_ObjectiveKillSpectator',method),function(pawn)
            local timer=StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
            if timer:K2_TimerExists(pawn,'TimerFinished') then
                timer:K2_ClearTimer(pawn,'TimerFinished')
                if S.rules().respawn==0 then timer:K2_SetTimerForNextTick(pawn,'TimerFinished')
                else timer:K2_SetTimer(pawn,'TimerFinished',S.rules().respawn,false,false,0,0) end
            end
        end)
    end
    local groups,pending,filled={},{},{}
    local onCauldron=false
    local function destroy(p) p:SetActorEnableCollision(false);p:K2_DestroyActor() end
    local function totem(transform)
        local g=StaticFindObject('/Script/Engine.Default__GameplayStatics')
        local p=g:BeginDeferredActorSpawnFromClass(C.session().gm,S.asset(S.path(O,'B_ReviveTotem')),transform,0,nil,0)
        p.WitchInCircleTimeNeeded=S.rules().revive
        g:FinishSpawningActor(p,transform,0)
        return R.valid(p) and not p:IsActorBeingDestroyed() and p or nil
    end
    S.onMatchHost.post(S.path(O,'B_ReviveTotem','ReceiveBeginPlay'),function(p)
        -- A filled cauldron's totem stands on the cauldron, not on ground beside it.
        if not onCauldron and not S.groundTotem(p) then return end
        p.WitchInCircleTimeNeeded=S.rules().revive;pending[#pending+1]=p
    end)
    S.onMatchHost.post(S.path(O,'B_ObjectiveGameMode','SpawnReviveTotem'),function(gm,ps)
        if not R.valid(ps) then return end
        local native=pending;pending={}
        local count=S.rules().totems
        local points={}
        if count==1 then points=native else for _,p in ipairs(native) do destroy(p) end end
        if count>1 then
            local starts=S.values(gm.AllWitchRespawnPoints)
            for i=#starts,2,-1 do local j=math.random(i);starts[i],starts[j]=starts[j],starts[i] end
            for i=1,math.min(count,#starts) do points[#points+1]=totem(starts[i]:GetTransform()) end
            pending={}
        end
        groups[ps:GetAddress()]={owner=ps,points=points}
        if count==0 and not S.rules().filledRevive then C.session().gs:ResetReviveHelpServer() end
    end)
    function S.reviveChanged(ps)
        if ps.IsDead then S.filledCircles();return end
        local firing,spent,owner
        for key,group in pairs(groups) do
            for _,p in ipairs(group.points) do if p.RespawningState==ps then firing=p;spent=key end end
        end
        if spent then
            local group=groups[spent];groups[spent]=nil;owner=group.owner
            for _,p in ipairs(group.points) do if p~=firing then destroy(p) end end
        end
        local own=groups[ps:GetAddress()]
        if own then
            groups[ps:GetAddress()]=nil
            if owner and owner~=ps and owner.IsDead then
                own.owner=owner;groups[owner:GetAddress()]=own
            else for _,p in ipairs(own.points) do destroy(p) end end
        end
        for key,p in pairs(filled) do if p.RespawningState==ps then filled[key]=nil end end
        S.filledCircles()
    end
    S.onMatchHost.post(S.path(O,'B_ObjectivePlayerState','OnRep_IsDead'),S.reviveChanged)
    function S.filledCircles()
        if not S.rules().filledRevive then return end
        local dead=false
        for _,ps in ipairs(S.players()) do if ps.IsDead and not ps.IsPendingDisconnect and not S.waiter(ps) then dead=true end end
        if not dead then
            for key,p in pairs(filled) do destroy(p);filled[key]=nil end
            return
        end
        for _,pot in ipairs(S.values(C.session().gs.Cauldrons)) do
            if pot.Filled and not filled[pot:GetAddress()] then
                onCauldron=true
                local p=totem(pot:GetTransform());filled[pot:GetAddress()]=p;pending={}
                onCauldron=false
            end
        end
    end
    S.onMatchHost.post(S.path(O,'B_ObjectiveCauldron','ActivateLightMulti'),S.filledCircles)
    R.on('world_end',function() groups={};pending={};filled={} end)
end
