return function(S)
    local R,C=S.R,S.C
    local preview
    local witch='/Game/Blueprints/Player/Pawns/B_Witch.B_Witch_C'
    local propPawn='/Game/Blueprints/Player/Pawns/B_PropPawnPhysics.B_PropPawnPhysics_C'
    local function now() return StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetTimeSeconds(C.session().world) end
    local function draw(p)
        local actor=p.native
        actor.Stacks=p.stacks;actor.Active=p.active;actor.Filled=p.stacks==2
        actor.WantedProp=p.active and p.wanted and p.wanted.class or nil
        actor.VisualCirclelFill=p.active and 1 or p.progress/4
        actor.WitchInCircleTime=p.active and 4 or p.progress
        actor.DecalMaterial:SetScalarParameterValue(FName('Fill'),actor.VisualCirclelFill)
        actor.RuneRays:SetScalarParameterValueOnMaterials(FName('Fill'),actor.VisualCirclelFill)
        actor.Fluid.RelativeLocation.Z=-90+45*p.stacks
        actor.Fluid:SetAbsolute(true,false,false);actor.Fluid:SetAbsolute(false,false,false)
        actor:OnRep_Stacks()
        if p.active then actor:UpdateWantedPropMulti() end
        if p.stacks==2 then actor:ActivateLightMulti() end
        p.ui.WB_CauldronFillstate.Stacks=p.stacks
    end
    local function assign(s,p)
        local used={}
        for _,other in ipairs(s.pots) do if other.wanted then used[other.wanted.path]=true end end
        local candidates={}
        for _,group in ipairs(p.pool) do
            if not used[group.path] and group.path~=p.last then candidates[#candidates+1]=group end
        end
        p.wanted=#candidates>0 and candidates[math.random(#candidates)] or nil
    end
    local function feedback(s)
        local pawn=s.pc:K2_GetPawn()
        local position=pawn:K2_GetActorLocation()
        local own=pawn:IsA(propPawn) and pawn.ControllingProp or nil
        local closest=4000000
        for _,p in ipairs(s.pots) do
            if p.active and p.wanted then
                for _,prop in ipairs(p.wanted.props) do
                    if R.valid(prop.actor) and S.freeProp(prop.actor,own) then closest=math.min(closest,S.distance(position,prop.actor:K2_GetActorLocation())) end
                end
            end
        end
        s.orb.Percentage=S.calc.closePercent(closest,4000000)
    end
    local function returnWitch(s,delivery)
        local pawn,prop=delivery.pawn,delivery.prop
        if R.valid(prop) then prop:SetActorHiddenInGame(delivery.hidden) end
        if R.valid(pawn) then
            pawn.IsRespawn=delivery.respawn;pawn:SetActorHiddenInGame(false);pawn:SetActorEnableCollision(true)
            if s.pc.CurrentPlayMode==3 then
                s.pc:Possess(pawn)
                local t=delivery.transform
                for _,point in ipairs(s.starts) do
                    local destination=S.ground(point.actor)
                    if destination then t=S.transform(point.actor,destination.witch);break end
                end
                pawn:SetWitch(t)
            else pawn:MultiSwitchBack() end
            pawn:K2_DestroyActor()
        elseif s.pc.CurrentPlayMode==3 then s.pc:RespawnPlayerPawnServer(0) end
        delivery.camera:K2_DestroyActor();s.delivery=nil
    end
    local function deliver(s,p,other)
        if s.delivery or not p.active or not p.wanted or p.stacks==2 then return end
        local pawn=s.pc:K2_GetPawn()
        if not pawn:IsA(propPawn) then return end
        local prop=pawn.ControllingProp
        if prop:GetAddress()~=other:GetAddress() or not prop.IsControlledByWitch or prop:GetClass():GetAddress()~=p.wanted.class:GetAddress() then return end
        local d={pawn=pawn,prop=prop,hidden=prop.bHidden,respawn=pawn.IsRespawn,transform=pawn:GetTransform()}
        d.camera=R.native.spawn(S.path(S.O,'B_CauldronPawn'),s.pc,p.position,function(a)
            a.Instigator=pawn;a:SetReplicates(false);a:SetActorEnableCollision(false)
        end)
        s.delivery=d
        pawn.IsRespawn=false;pawn:OnKilledMulti();pawn:SetActorHiddenInGame(true);pawn:SetActorEnableCollision(false)
        prop:SetActorHiddenInGame(true);s.pc:Possess(d.camera)
        d.cancel=R.after(3000,function() returnWitch(s,d) end)
        p.last=p.wanted.path;p.wanted=nil;p.active=false;p.progress=0;p.at=now();p.stacks=p.stacks+1
        if p.cancel then p.cancel();p.cancel=nil end
        p.native:ResetUIMulti()
        if p.stacks<2 then assign(s,p) end
        draw(p);feedback(s)
    end
    local function settle(p)
        local time=now()
        p.progress=math.max(0,math.min(4,p.progress+(time-p.at)*(p.count>0 and p.count or -1)))
        p.at=time
    end
    local function schedule(s,p)
        if p.cancel then p.cancel();p.cancel=nil end
        if p.active or p.stacks==2 or not p.wanted or p.count==0 then return end
        p.cancel=R.after(math.max(1,math.ceil((4-p.progress)/p.count*1000)),function()
            p.cancel=nil;settle(p);p.progress=4;p.active=true;draw(p);feedback(s)
            local pawn=s.pc:K2_GetPawn()
            if pawn:IsA(propPawn) then
                local prop=pawn.ControllingProp
                if R.valid(prop) and p.deliverySphere:IsOverlappingActor(prop) then deliver(s,p,prop) end
            end
        end)
    end
    local function trigger(s,p,radius,z,callback)
        local point={X=p.position.X,Y=p.position.Y,Z=p.position.Z+z}
        local actor=R.native.spawn('/Script/Engine.TriggerSphere',s.pc,point,function(a)
            a:SetReplicates(false);a:SetActorTickEnabled(false);a:SetActorEnableCollision(false);a:SetActorHiddenInGame(true)
        end)
        s.actors[#s.actors+1]=actor
        local sphere=actor:GetComponentByClass(S.asset('/Script/Engine.SphereComponent'))
        sphere:SetCollisionProfileName(FName('OverlapAllDynamic'),false)
        sphere:SetCollisionEnabled(0);sphere:SetGenerateOverlapEvents(false);sphere:SetSphereRadius(radius,true)
        s.stops[#s.stops+1]=R.native.on_overlap(actor,function(other,begin)
            if R.valid(other) then callback(other,begin) end
        end)
        s.triggers[#s.triggers+1]={actor=actor,component=sphere}
        return sphere
    end
    function S.stopPreview()
        local s=preview
        if not s then return end
        preview=nil
        for _,stop in ipairs(s.stops) do stop() end
        for _,p in ipairs(s.pots) do if p.cancel then p.cancel() end end
        if s.delivery then s.delivery.cancel();returnWitch(s,s.delivery) end
        for _,actor in ipairs(s.actors) do actor:K2_DestroyActor() end
        for _,row in ipairs(s.markers) do row.actor:SetActorHiddenInGame(row.hidden) end
        s.overlay:RemoveFromParent()
    end
    function S.startPreview()
        if preview then return end
        local session=C.session()
        local _,_,pots,starts,pairs=S.checkMap()
        local s={pc=session.pc,pots=pots,starts=starts,actors={},triggers={},stops={},markers={}}
        for _,row in ipairs(S.markers()) do
            if row.info.kind<=2 then
                s.markers[#s.markers+1]={actor=row.actor,hidden=row.actor.bHidden}
                row.actor:SetActorHiddenInGame(true)
            end
        end
        preview=s
        local create=StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary')
        s.overlay=create:Create(s.pc,S.asset('/Game/UserInterface/UIElements/WB_TooltipTextContent.WB_TooltipTextContent_C'),s.pc)
        local canvas=S.new('/Script/UMG.CanvasPanel',s.overlay.WidgetTree);s.overlay.WidgetTree.RootWidget=canvas
        s.orb=create:Create(s.pc,S.asset('/Game/UserInterface/ObjectiveMode/WB_DivineOrb.WB_DivineOrb_C'),s.pc)
        local slot=canvas:AddChildToCanvas(s.orb)
        slot:SetAnchors({Minimum={X=1,Y=1},Maximum={X=1,Y=1}});slot:SetAlignment({X=.5,Y=1})
        slot:SetPosition({X=-140,Y=-175});slot:SetSize({X=96,Y=96})
        s.overlay:AddToViewport(1000);s.overlay:SetAnchorsInViewport({Minimum={X=0,Y=0},Maximum={X=1,Y=1}})
        s.overlay:SetVisibility(4);s.orb:SetVisibility(4);s.orb.Percentage=0
        for _,p in ipairs(pots) do
            p.progress=0;p.count=0;p.at=now();p.stacks=0;p.witches={};p.active=false
            p.native=R.native.spawn(S.path(S.O,'B_ObjectiveCauldron'),s.pc,p.position,function(a)
                a.Color=p.info.colour;a.MaxStacks=2;a:SetReplicates(false);a:SetActorTickEnabled(false);a:SetActorEnableCollision(false)
            end)
            p.native:SetActorTickEnabled(false);p.native:SetActorEnableCollision(false)
            s.actors[#s.actors+1]=p.native
            p.ui=create:Create(s.pc,S.asset('/Game/UserInterface/ObjectiveMode/WB_CauldronUI.WB_CauldronUI_C'),s.pc)
            p.native.Widget:SetWidget(p.ui);p.native.Widget:SetOwnerPlayer(s.pc.Player)
            local colour={SpecifiedColor=p.info.colour,ColorUseRule=0}
            p.ui.Cauldron=p.native;p.ui.Color=colour;p.ui.Team=s.pc.PlayerState.Team
            p.ui.WB_RequiredPropIcon.Cauldron=p.native;p.ui.WB_RequiredPropIcon.Color=colour
            S.potAppearance(p.native,p.info)
            p.actor:SetActorHiddenInGame(true)
            assign(s,p)
            trigger(s,p,200,120,function(other,begin)
                if not other:IsA(witch) then return end
                settle(p);p.witches[other:GetAddress()]=begin and true or nil
                p.count=0;for _ in pairs(p.witches) do p.count=p.count+1 end
                schedule(s,p);draw(p);feedback(s)
            end)
            p.deliverySphere=trigger(s,p,90,138.49224853515625,function(other,begin) if begin then deliver(s,p,other) end end)
            draw(p)
        end
        for _,t in ipairs(s.triggers) do
            t.component:SetGenerateOverlapEvents(true);t.component:SetCollisionEnabled(1);t.actor:SetActorEnableCollision(true)
        end
        for _,zone in ipairs(S.portals(pairs)) do s.actors[#s.actors+1]=zone end
    end
    S.onModeHost.post(S.path(S.CR,'B_CreativePlayerController','ChangePlayerMode'),function(pc)
        if pc.CurrentPlayMode==3 and C.session().gs.IsPlayTestMode then S.startPreview() else S.stopPreview() end
    end)
    for _,entry in ipairs({{'B_CreativeGameMode','BeginPlayTest'},{'B_CreativeGameState','OnRep_IsPlayTestMode'}}) do
        S.onModeHost.post(S.path(S.CR,entry[1],entry[2]),function()
            local session=C.session()
            if session.gs.IsPlayTestMode and session.pc.CurrentPlayMode==3 then S.startPreview() end
        end)
    end
    R.pre(S.path(S.CR,'B_CreativeGameMode','EndPlayTest'),S.stopPreview)
    R.on('world_end',function() preview=nil end)
end
