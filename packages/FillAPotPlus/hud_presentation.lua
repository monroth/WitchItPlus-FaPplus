-- Host rules and waiting text; guests display the same facts, including late joins.
return function(S)
    local R,C=S.R,S.C
    local policy,remote
    local function reason(gs,mm,rules)
        if not rules.startReady and not rules.unequal then return end
        if mm.CurrentRound>0 and gs.State~=0 then return '' end
        local count,a,b,unselected,unready=0,0,0,false,false
        for _,ps in ipairs(S.players()) do
            if not ps.IsPendingDisconnect and not S.waiter(ps) then
                count=count+1
                if ps.ObjectiveTeam==1 then a=a+1 elseif ps.ObjectiveTeam==2 then b=b+1 else unselected=true end
                local ready=mm.CurrentRound==0 and ps.IsReadyObjectiveTeamSelection or mm.CurrentRound>0 and ps.IsReady
                if not ready then unready=true end
            end
        end
        if count==0 then return 'Waiting for players' end
        if unselected and mm.CurrentRound==0 and not rules.startReady then return 'Waiting for players to choose a team' end
        if not rules.startReady and (a==0 or b==0) then return 'Waiting for a player on each team' end
        return unready and 'Waiting for ready players' or 'Starting match'
    end
    function S.hudPolicy() return S.host() and policy or remote end
    function S.updateHUDPolicy()
        if not S.host() then return end
        local gs,mm,rules=C.session().gs,S.manager(),S.rules()
        local ceiling=S.ceiling or gs.CauldronTarget
        if policy and gs.CurrentRound==2 then ceiling=math.max(ceiling,policy.ceiling) end
        local next={round=gs.CurrentRound,infinite=rules.lives=='infinite',
            reason=reason(gs,mm,rules),ceiling=ceiling,target=gs.CauldronTarget}
        if policy then
            local same=true
            for _,key in ipairs({'round','infinite','reason','ceiling','target'}) do
                if policy[key]~=next[key] then same=false end
            end
            if same then return end
        end
        policy=next;C.net.publish('fap.hud',policy)
    end
    C.net.watch('fap.hud',function(value)
        if S.host() then return end
        remote=value;S.refreshHUD()
    end)
    for _,method in ipairs({'InitializeFromMatchPlayerState','SetTeamByRoundAndObjectiveTeam',
        'OnRep_IsReadyObjectiveTeamSelection','OnRep_IsDead'}) do
        S.onMatch.post(S.path(S.O,'B_ObjectivePlayerState',method),S.refreshHUD)
    end
    for _,method in ipairs({'OnPlayerJoinedMulti','OnPlayerLeftMulti','OnPlayerChangedTeamMulti'}) do
        S.onMatch.post(S.path(S.CORE,'B_GameState',method),S.refreshHUD)
    end
    S.onMatch.post(S.path(S.O,'B_ObjectiveGameMode','StartNewGameOverride'),S.refreshHUD)
    R.on('world_end',function() policy=nil;remote=nil end)
end
