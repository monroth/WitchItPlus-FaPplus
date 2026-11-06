return function(S)
    local R,C=S.R,S.C
    local originals={}
    local pawn='/Game/Blueprints/Player/Pawns/B_PropPawnPhysics.B_PropPawnPhysics_C:'
    local function capture(body)
        local prop=R.valid(body.ControllingProp)
        if not prop or prop:GetAddress()~=body.PropTemplate:GetAddress() or prop.IsDecoy or prop.SpawnedFromPropPawnPhysics then return end
        local key=prop:GetAddress()
        if originals[key] then originals[key].active=true;return end
        local p,r,scale=prop:K2_GetActorLocation(),prop:K2_GetActorRotation(),prop:GetActorScale3D()
        originals[key]={active=true,class=prop:GetClass(),pose={X=p.X,Y=p.Y,Z=p.Z,Pitch=r.Pitch,Yaw=r.Yaw,Roll=r.Roll,
            ScaleX=scale.X,ScaleY=scale.Y,ScaleZ=scale.Z},
            frozen=prop.IsFreezed,awake=prop.StartAwake,sleeping=prop.IsSleeping}
    end
    S.onMatchHost.post(pawn..'OnRep_ControllingProp',capture)
    S.onMatchHost.post(pawn..'PropPossessed',capture)
    -- The engine end-play hook is global; restoring a prop belongs to a hosted Plus match.
    RegisterEndPlayPreHook(function(actor,reason)
        actor=R.valid(actor)
        if not actor then return end
        reason=reason:get()
        local key=actor:GetAddress()
        local original=originals[key];originals[key]=nil
        if not original or not original.active or reason~=0 or not S.inMatch() or not S.host() then return end
        local gs=C.session().gs
        local meshField='MeshList_3_9A021886472783B7C6D4C1A40C1D892E'
        local allIndex,meshIndex
        gs.AllProps:ForEach(function(i,value)if value:get():GetAddress()==key then allIndex=i end end)
        local meshes=gs.Proplist:Find(original.class):get()[meshField]
        meshes:ForEach(function(i,value)if value:get():GetAddress()==key then meshIndex=i end end)
        R.next_frame(function()
            local prop=R.native.spawn(original.class,C.session().gm,original.pose,function(a)
                a:SetReplicates(true);a.bAlwaysRelevant=true;a.NetDormancy=1
                a.SpawnedFromPropPawnPhysics=false
                a.IsFreezed=original.frozen;a.StartAwake=original.awake;a.InitialIsSleeping=original.sleeping
            end)
            prop:SetUncontrolledByWitch()
            prop.IsFreezed=original.frozen;prop.StartAwake=original.awake
            prop:AutoSetInitialPhysicsState()
            if original.sleeping then prop:PutToSleep();prop:HandleSleepServer()
            else prop:WakeFromSleep();prop:HandleWakeServer() end
            if original.frozen then prop:UpdateFromFrozenState() end
            prop:FlushNetDormancy();prop:ForceNetUpdate()
            prop.AliveTime=0;prop.IsFadingIn=true;prop:SetActorTickEnabled(true)
            gs.AllProps[allIndex]=prop
            gs.Proplist:Find(original.class):get()[meshField][meshIndex]=prop
            original.active=false;originals[prop:GetAddress()]=original
        end)
    end)
    R.on('world_end',function() originals={} end)
end
