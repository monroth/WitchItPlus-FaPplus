return function(S)
    local R,C=S.R,S.C
    local ghosts={}
    local function vec(x,y,z) return {X=x,Y=y,Z=z} end
    function S.transform(actor,point,scale,yaw,pitch)
        local t=actor:GetTransform()
        local y,p=math.rad(yaw or actor:K2_GetActorRotation().Yaw)/2,math.rad(pitch or 0)/2
        t.Translation=point;t.Scale3D=scale or vec(1,1,1)
        t.Rotation={X=math.sin(p)*math.sin(y),Y=-math.sin(p)*math.cos(y),Z=math.cos(p)*math.sin(y),W=math.cos(p)*math.cos(y)}
        return t
    end
    function S.capsule(actor)
        local witch=S.asset(S.path(S.O,'B_ObjectiveWitch')):GetCDO()
        local sub=StaticFindObject('/Script/Engine.Default__SubsystemBlueprintLibrary'):GetWorldSubsystem(actor,
            S.asset('/Game/Blueprints/Match/GameRules/MatchRules/B_MatchParametersSubsystem.B_MatchParametersSubsystem_C'))
        local m=sub.WitchMatchParameters.PlayerSizeMultiplier
        return witch.CapsuleComponent:GetScaledCapsuleRadius()*m,
            witch.CapsuleComponent:GetScaledCapsuleHalfHeight()*m,m
    end
    function S.ground(actor)
        local anchor=actor:K2_GetActorLocation()
        local radius,height,m=S.capsule(actor)
        local source
        local function probe(a,b,r,h) return R.native.capsule_probe(actor,actor,a,b,r,h) end
        local function at(x,y)
            for _,up in ipairs({16,48,96,128}) do
                local hit=probe(vec(x,y,anchor.Z+up),vec(x,y,anchor.Z-128),1,1)
                if hit.blocked and not hit.penetrating then
                    local g=hit.position
                    if hit.normal.Z<.7 or math.abs(g.Z-anchor.Z)>128 then return end
                    if x==anchor.X and y==anchor.Y then source=g end
                    local center=vec(x,y,g.Z+height+2)
                    local clear=probe(center,vec(x,y,center.Z+.01),radius+2,height)
                    local foot=vec(x,y,g.Z+radius+4)
                    if not clear.blocked and not probe(foot,vec(x,y,foot.Z+.01),radius+2,radius+2).blocked then
                        return {ground=vec(x,y,g.Z),marker=vec(x,y,g.Z+80),witch=center}
                    end
                    return
                elseif not hit.blocked then return end
            end
        end
        local result=at(anchor.X,anchor.Y)
        if not result then
            for ring=1,3 do
                for i=0,7 do
                    local a=i*math.pi/4
                    result=at(anchor.X+ring*64*math.cos(a),anchor.Y+ring*64*math.sin(a))
                    if result then return result,source,height,m end
                end
            end
        end
        return result,source,height,m
    end
    function S.clearGhost(actor)
        local key=actor:GetAddress()
        for _,component in ipairs(ghosts[key] or {}) do component:K2_DestroyComponent(actor) end
        ghosts[key]=nil
    end
    function S.ghost(actor)
        local key=actor:GetAddress()
        S.clearGhost(actor)
        local list={};ghosts[key]=list
        local destination,source,height,m=S.ground(actor)
        local anchor=actor:K2_GetActorLocation()
        local ground=source or vec(anchor.X,anchor.Y,anchor.Z-80)
        local center=destination and destination.witch or vec(ground.X,ground.Y,ground.Z+height+2)
        local c=destination and {R=0,G=1,B=0,A=.3} or {R=1,G=0,B=0,A=.3}
        local material=S.asset('/Engine/EngineDebugMaterials/M_SimpleUnlitTranslucent.M_SimpleUnlitTranslucent')
        local yaw=actor:K2_GetActorRotation().Yaw
        local function component(class,point,scale,angle,pitch)
            local part=actor:AddComponentByClass(S.asset('/Script/Engine.'..class),true,
                S.transform(actor,point,scale,angle,pitch),false)
            list[#list+1]=part
            part:SetMobility(2);part:SetComponentTickEnabled(false)
            if actor.IsPreview then part:K2_AttachToComponent(actor.RootComponent,FName('None'),1,1,1,false)
            else part:SetAbsolute(true,true,true) end
            part:SetVisibility(true,false);part:SetHiddenInGame(false,false)
            return part
        end
        local function tint(part)
            part:SetCollisionEnabled(0);part:SetGenerateOverlapEvents(false);part:SetCastShadow(false)
            for slot=0,part:GetNumMaterials()-1 do
                local mid=part:CreateDynamicMaterialInstance(slot,material,FName('None'))
                mid:SetVectorParameterValue(FName('Color'),c)
            end
        end
        local cat=component('StaticMeshComponent',ground,vec(.25,.25,.25),yaw+180)
        cat:SetStaticMesh(S.asset('/Game/ObjectiveModeContent/SM_ReviveCatSoft.SM_ReviveCatSoft'));tint(cat)
        local decal=component('DecalComponent',ground,nil,yaw,-90)
        decal.DecalSize=vec(60,128,128)
        local mid=StaticFindObject('/Script/Engine.Default__KismetMaterialLibrary'):CreateDynamicMaterialInstance(actor,
            S.asset('/Game/ObjectiveModeContent/M_SmallCauldronDecal.M_SmallCauldronDecal'),FName('None'),0)
        mid:SetVectorParameterValue(FName('Color'),c);mid:SetScalarParameterValue(FName('Fill'),1)
        decal:SetDecalMaterial(mid)
        local a=math.rad(yaw)
        local feet=vec(center.X-10*m*math.cos(a),center.Y-10*m*math.sin(a),center.Z-93*m)
        local witch=component('SkeletalMeshComponent',feet,vec(m,m,m))
        witch:SetSkinnedAssetAndUpdate(S.asset('/Game/Characters/Witch/SK_WitchDefault.SK_WitchDefault'),true)
        witch:SetAnimationMode(1,true);witch.bPauseAnims=true;tint(witch)
        local box=component('BoxComponent',vec(ground.X,ground.Y,ground.Z+40))
        box:SetBoxExtent(vec(32,32,40),false);box:SetCollisionObjectType(0)
        box:SetCollisionResponseToAllChannels(0);box:SetCollisionEnabled(1);box:SetVisibility(false,false)
        local dx,dy=center.X-anchor.X,center.Y-anchor.Y
        if dx*dx+dy*dy>.01 then
            local horizontal=math.sqrt(dx*dx+dy*dy)
            local dz=destination.ground.Z-ground.Z
            local length=math.sqrt(horizontal^2+dz^2)
            local line=component('StaticMeshComponent',vec((anchor.X+center.X)/2,(anchor.Y+center.Y)/2,
                (ground.Z+destination.ground.Z)/2+2),vec(length/100,.01,.01),
                math.deg(math.atan(dy,dx)),math.deg(math.atan(dz,horizontal)))
            line:SetStaticMesh(S.asset('/Engine/BasicShapes/Cube.Cube'));tint(line)
        end
    end
    R.post('/Script/Engine.Actor:ReceiveEndPlay',function(actor)
        if R.valid(actor) then ghosts[actor:GetAddress()]=nil end
    end)
    R.on('world_end',function() ghosts={} end)
end
