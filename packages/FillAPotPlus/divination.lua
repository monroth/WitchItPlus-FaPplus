return function(S)
    local R,C=S.R,S.C
    local propPawn='/Game/Blueprints/Player/Pawns/B_PropPawnPhysics.B_PropPawnPhysics_C'
    function S.freeProp(prop,own)
        return prop~=own and not prop.IsControlledByWitch and not R.valid(prop.Witch)
    end
    S.onMatch.post('/Game/UserInterface/ObjectiveMode/WB_ObjectiveHudExtension.WB_ObjectiveHudExtension_C:GetPropClosePercent',function(widget)
        local pawn=R.valid(widget:GetOwningPlayerPawn())
        if not pawn then return 0 end
        local own=pawn:IsA(propPawn) and pawn.ControllingProp or nil
        local origin=pawn:K2_GetActorLocation()
        local maximum=widget.MaxDistanceSq
        local closest=maximum
        local gs=C.session().gs
        for _,pot in ipairs(S.values(gs.Cauldrons)) do
            local class=pot.WantedProp
            if pot.Active and not pot.Filled and R.valid(class) and gs.Proplist:Contains(class) then
                local list=gs.Proplist:Find(class):get().MeshList_3_9A021886472783B7C6D4C1A40C1D892E
                for _,actor in ipairs(S.values(list)) do
                    if R.valid(actor) and S.freeProp(actor,own) then
                        closest=math.min(closest,S.distance(origin,actor:K2_GetActorLocation()))
                    end
                end
            end
        end
        return 1-math.sqrt(closest/maximum)
    end)
end
