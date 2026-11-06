-- Native events that several Fill a Pot+ modules react to. Each event has one
-- handler here, so the order of reactions is written down in one place.
return function(S)
    local R=S.R
    local cauldron=S.path(S.O,'B_ObjectiveCauldron')
    local objectivePlayer=S.path(S.O,'B_ObjectivePlayerState')
    local objectiveState=S.path(S.O,'B_ObjectiveGameState')
    local player='/Game/Blueprints/Player/B_PlayerState.B_PlayerState_C'
    local dirty='/Script/Engine.NetPushModelHelpers:MarkPropertyDirtyFromRepIndex'
    -- Replication indices: Cauldron Stacks 10, VisualCirclelFill 12, Filled 15;
    -- PlayerState IsDead 24, Lives 49; GameState CauldronTarget 46, MaxLives 47.
    S.onMatchHost.post(dirty,function(_,object,index)
        if not R.valid(object) then return end
        if index==49 then S.livesWritten(object) end
        if index==10 and object:IsA(cauldron) then S.countStacks(object) end
        if index==24 and object:IsA(objectivePlayer) then S.reviveChanged(object) end
    end)
    S.onMatch.post(dirty,function(_,object,index)
        if not R.valid(object) then return end
        if object:IsA(cauldron) and (index==10 or index==15)
            or object:IsA(objectiveState) and (index==46 or index==47)
            or object:IsA(player) and index==49 then S.refreshHUD() end
    end)
    local teardown=S.path(S.O,'B_ObjectiveMatchManager','TearDown')
    S.onMatchHost.post(teardown,function()
        S.endMatch()
        S.clearReconnect()
    end)
    S.onMatch.post(teardown,S.refreshHUD)
end
