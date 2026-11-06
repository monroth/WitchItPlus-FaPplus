return function(S)
    local R,C=S.R,S.C
    local aliases,looks,radii={},{},{}
    local selectedKind
    local CR=S.CR
    local edit=CR..'PlacementAndEditUI/'
    local function component(actor,class,point,scale,yaw,pitch)
        local c=actor:AddComponentByClass(S.asset('/Script/'..(class=='NiagaraComponent' and 'Niagara.' or 'Engine.')..class),
            true,S.transform(actor,point,scale,yaw,pitch),false)
        c:SetMobility(2);c:SetComponentTickEnabled(false)
        -- The aiming preview moves with the cursor; its parts move with it.
        if actor.IsPreview then c:K2_AttachToComponent(actor.RootComponent,FName('None'),1,1,1,false) end
        if class=='StaticMeshComponent' then c:SetCollisionEnabled(0);c:SetGenerateOverlapEvents(false);c:SetCastShadow(false) end
        return c
    end
    function S.markerLook(actor,info)
        local key=actor:GetAddress()
        local old=looks[key]
        if old then
            for _,cancel in ipairs(old.loads) do cancel() end
            for _,part in ipairs(old) do part:K2_DestroyComponent(actor) end
            if old.actor then old.actor:K2_DestroyActor() end
        end
        local list={original=old and old.original or {},loads={}};looks[key]=list
        local function asset(path,ready)
            list.loads[#list.loads+1]=R.native.on_asset(path,ready)
        end
        if not old then
            for _,part in ipairs(S.values(actor:K2_GetComponentsByClass(S.asset('/Script/Engine.PrimitiveComponent')))) do
                if not radii[key] or part:GetAddress()~=radii[key]:GetAddress() then
                    list.original[#list.original+1]={part=part,visible=part.bVisible,collision=part:GetCollisionEnabled()}
                    part:SetVisibility(false,false)
                end
            end
        end
        if info.kind>=3 then
            for _,row in ipairs(list.original) do row.part:SetCollisionEnabled(0) end
        end
        if info.kind==2 then S.ghost(actor);return end
        local p=actor:K2_GetActorLocation()
        local function part(class,position,scale,yaw,pitch)
            local c=component(actor,class,position or p,scale,yaw,pitch);list[#list+1]=c;return c
        end
        local function mesh(path,scale,mat)
            local c=part('StaticMeshComponent',p,scale)
            local function tint() c:SetVectorParameterValueOnMaterials(FName('Color'),{X=info.colour.R,Y=info.colour.G,Z=info.colour.B}) end
            asset(path,function(value) c:SetStaticMesh(value);tint() end)
            if mat then asset(mat,function(value) c:SetMaterial(0,value);tint() end) end
            return c
        end
        if info.kind==1 then
            if radii[key] then radii[key]:SetSphereRadius(info.radius,false) end
            mesh('/Game/ObjectiveModeContent/SM_Cauldron01.SM_Cauldron01',{X=1.2,Y=1.2,Z=1.2})
            mesh('/Game/ObjectiveModeContent/SM_CauldronFluid.SM_CauldronFluid')
            mesh('/Game/ObjectiveModeContent/SM_PotRuneRays.SM_PotRuneRays',{X=1.28,Y=1.28,Z=2.2})
            local decal=part('DecalComponent',p,nil,nil,-90)
            decal.DecalSize={X=(info.down+info.up)/2,Y=256,Z=256}
            asset('/Game/ObjectiveModeContent/M_CauldronDecal.M_CauldronDecal',function(value)
                local material=StaticFindObject('/Script/Engine.Default__KismetMaterialLibrary'):CreateDynamicMaterialInstance(actor,value,FName('None'),0)
                material:SetVectorParameterValue(FName('Color'),info.colour);material:SetScalarParameterValue(FName('Fill'),1)
                decal:SetDecalMaterial(material)
            end)
        elseif info.look==1 then
            asset('/Game/Blueprints/Unused/ObjectiveMode/B_WitchPortalVisualOnly.B_WitchPortalVisualOnly_C',function(class)
                local a=R.native.spawn(class,actor,p,function(a)
                    a:SetActorEnableCollision(false);a:SetActorTickEnabled(false)
                end)
                a:K2_AttachToActor(actor,FName('None'),1,1,1,false)
                list.actor=a
            end)
        elseif info.look==2 then
            local name=info.kind==3 and 'NS_TowerPortalEntrance' or 'NS_TowerPortalExit'
            local c=part('NiagaraComponent')
            asset('/Game/Effects/Tower/'..name..'.'..name,function(value) c:SetAsset(value,true);c:Activate(true) end)
        elseif info.look==3 then
            local root='/Game/Environment/WitchHouse/WitchPortal/'
            local mat=info.kind==3 and 'MI_WitchPortalTwistEntry' or 'MI_WitchPortalTwistExit'
            mesh(root..'SM_WitchPortal.SM_WitchPortal',nil,root..mat..'.'..mat)
        elseif info.look==4 then
            mesh('/Game/Environment/WitchForest/SM_RuneRayCircle.SM_RuneRayCircle',nil,
                '/Game/Environment/WitchForest/MI_RuneRaysGreen.MI_RuneRaysGreen')
        end
        if info.kind>=3 and S.editing() and not actor.IsPreview then
            local selector=part('BoxComponent',{X=p.X,Y=p.Y,Z=p.Z+75})
            selector:SetBoxExtent({X=50,Y=50,Z=75},false);selector:SetCollisionObjectType(0)
            selector:SetCollisionResponseToAllChannels(0);selector:SetCollisionEnabled(1)
            local text=part('TextRenderComponent',{X=p.X,Y=p.Y,Z=p.Z+115})
            text:K2_SetText(FText('Teleporter '..tostring(info.pairId)..(info.twoWay and ' ↔' or info.kind==3 and ' →' or ' ←')))
            text:SetWorldSize(18);text:SetHorizontalAlignment(1)
        end
    end
    function S.nextPair(kind)
        local used={}
        for _,row in ipairs(S.markers()) do
            if row.info.kind>=3 and row.info.pairId then
                local pair=used[row.info.pairId] or {};used[row.info.pairId]=pair;pair[row.info.kind]=true
            end
        end
        local id=1
        while used[id] and used[id][kind] do id=id+1 end
        return id
    end
    S.onEditor.post(S.path(CR,'WB_PropCollectionWidgetCreative','GetStructureTileViewDatas'),function(w,out,focus)
        if w.SelectedPropCategory~=6 then return end
        aliases={}
        local items,flags=S.values(out:get()),S.values(focus:get())
        for kind=1,4 do
            local result={}
            w.TileViewManager:GetPropButtonData(0,true,false,S.asset(S.carriers[kind]),w,{},result)
            local data=result.Data
            aliases[data:GetFullName()]=kind;items[#items+1]=data;flags[#flags+1]=false
        end
        w.CurrentCategoryPropsCount=w.CurrentCategoryPropsCount+4;out:set(items);focus:set(flags)
    end)
    S.onEditor.post('/Game/UserInterface/UIElements/WB_SearchBar.WB_SearchBar_C:GetItemName',function(_,item,out)
        if not R.valid(item) then return end
        local kind=aliases[item:GetFullName()];if kind then out:set(FText(S.names[kind])) end
    end)
    S.onEditor.post('/Game/UserInterface/PropCollection/B_PropButtonData.B_PropButtonData_C:Compare',function(item,other,out)
        if not R.valid(other) then return end
        local a,b=aliases[item:GetFullName()],aliases[other:GetFullName()]
        if a or b then out:set(a~=nil and a==b) end
    end)
    S.onEditor.post('/Game/UserInterface/PropCollection/WB_PropButton.WB_PropButton_C:GetTooltip',function(w,out)
        local kind=aliases[w.ItemData:GetFullName()]
        local tooltip=out:get()
        if kind and R.valid(tooltip) then
            tooltip.Name:SetText(FText(S.names[kind]))
            local descriptions={
                'Place at least three cauldrons. Select one to choose its colour and wanted props. Use Playtest to check the map.',
                'Place on the ground: the capsule shows witch spawn; revive totems sit on the surface. Keep ordinary player starts for match start.',
                'Teleports players to the exit with the same number. Select to change the number and look.',
                'Players arrive in front of this marker, facing its direction. Pair with an entrance with the same number.'}
            tooltip.Description:SetText(FText(descriptions[kind]))
        end
    end)
    local function paletteIcon(tile)
        local kind=aliases[tile.ItemData:GetFullName()]
        if not kind then return end
        local path=kind==1 and '/Game/UserInterface/PropCollection/PlacableActorIcons/BP_WitchCauldron_C.BP_WitchCauldron_C'
            or '/Game/UserInterface/CreativeMode/CollectionUtilityIconWitchStart.CollectionUtilityIconWitchStart'
        tile.GridButton.Icon:SetBrushFromTexture(S.asset(path),false)
        tile.GridButton.Icon:SetColorAndOpacity(kind==3 and {R=0,G=.65,B=1,A=1}
            or kind==4 and {R=1,G=.65,B=0,A=1} or {R=1,G=1,B=1,A=1})
    end
    S.onEditor.post('/Game/UserInterface/UIElements/MenuTileView/WB_TileViewButton.WB_TileViewButton_C:SetButtonParameters',function(tile)
        if R.valid(tile.ItemData) then paletteIcon(tile) end
    end)
    S.onEditor.post('/Game/UserInterface/UIElements/WB_GridButton.WB_GridButton_C:SetIconImage',function(grid)
        local tree=grid:GetOuter()
        if not tree:IsA('/Script/UMG.WidgetTree') then return end
        local tile=tree:GetOuter()
        if tile:IsA('/Game/UserInterface/UIElements/MenuTileView/WB_TileViewButton.WB_TileViewButton_C') and R.valid(tile.ItemData) then paletteIcon(tile) end
    end)
    S.onEditorHost.post('/Game/UserInterface/PropCollection/WB_PropButton.WB_PropButton_C:Clicked',function(w)
        selectedKind=aliases[w.ItemData:GetFullName()]
        if not selectedKind then
            for _,actor in ipairs(S.values(w:GetOwningPlayer().ActorsToPlace)) do
                local info=S.marker(actor)
                if info then
                    local bytes=S.bytes(actor)
                    local prefix={};for i=1,info.prefix do prefix[i]=bytes:byte(i) end
                    S.write(actor,'SavedMaterialIndices',prefix,10)
                    local old=looks[actor:GetAddress()]
                    if old then
                        for _,cancel in ipairs(old.loads) do cancel() end
                        for _,part in ipairs(old) do part:K2_DestroyComponent(actor) end
                        if old.actor then old.actor:K2_DestroyActor() end
                        for _,row in ipairs(old.original) do row.part:SetVisibility(row.visible,false);row.part:SetCollisionEnabled(row.collision) end
                        looks[actor:GetAddress()]=nil
                    end
                    S.clearGhost(actor)
                end
            end
            return
        end
        for _,actor in ipairs(S.values(w:GetOwningPlayer().ActorsToPlace)) do
            local info=S.codec.defaults({kind=selectedKind,authored=true})
            if selectedKind>=3 then info.pairId=S.nextPair(selectedKind) end
            S.stamp(actor,info);S.markerLook(actor,info)
        end
    end)
    S.onEditor.post(S.path(CR,'B_CreativePlayerController','GetPrefabInfo'),function(_,actor,_,_,_,_,_,colour)
        if not R.valid(actor) then return end
        local info=S.marker(actor)
        if info then colour:set({X=70,Y=65,Z=256+info.kind}) end
    end)
    S.onEditorHost.post(S.path(CR,'B_CreativePlayerController','PlaceActor'),function(pc,class,_,_,_,_,_,_,colour,indices,out)
        local actor=out:get()
        if not R.valid(actor) then return end
        local info=S.marker(actor)
        local kind=info and info.kind
        if not kind and colour.X==70 and colour.Y==65 then kind=colour.Z-256 end
        if not kind or not S.carriers[kind] or not actor:IsA(S.carriers[kind]) then return end
        info=S.codec.defaults(info or {kind=kind,authored=true})
        if kind>=3 and not info.pairId then info.pairId=S.nextPair(kind) end
        S.stamp(actor,info);S.markerLook(actor,info)
    end)
    local build,clearPanel=dofile(S.dir..'editor_panel.lua')(S)
    local function selection(pc)
        if not R.valid(pc) then return end
        local selected={}
        if S.editing() and pc:IsLocalController() and pc.CurrentPlayMode<=2 then
            for _,actor in ipairs(S.values(pc.SelectedActors)) do
                if R.valid(actor) and not actor.IsPreview then
                    local info=S.marker(actor)
                    if info and info.kind==1 then selected[actor:GetAddress()]={actor=actor,info=info} end
                end
            end
        end
        for key,sphere in pairs(radii) do
            if not selected[key] then sphere:K2_DestroyComponent(sphere:GetOwner());radii[key]=nil end
        end
        for key,row in pairs(selected) do
            if not radii[key] then
                -- Native SphereComponent draws the original three wire circles, with its default colour.
                local sphere=row.actor:AddComponentByClass(S.asset('/Script/Engine.SphereComponent'),false,
                    {Translation={X=0,Y=0,Z=0},Rotation={X=0,Y=0,Z=0,W=1},Scale3D={X=1,Y=1,Z=1}},false)
                radii[key]=sphere
                sphere:SetCollisionEnabled(0);sphere:SetGenerateOverlapEvents(false)
                sphere:SetMobility(2);sphere:SetAbsolute(false,true,true)
                sphere:SetVisibility(true,false);sphere:SetHiddenInGame(false,false)
            end
            radii[key]:SetSphereRadius(row.info.radius,false)
        end
    end
    for _,method in ipairs({'SelectActor','SelectMultiple','DeselectSingleActor','DeselectMultipleActors','ChangePlayerMode'}) do
        R.post(S.path(CR,'B_CreativePlayerController',method),selection)
    end
    for _,method in ipairs({'BeginPlayTest','EndPlayTest'}) do
        R.post(S.path(CR,'B_CreativeGameMode',method),function()
            selection(C.session().pc);if not S.editing() then clearPanel() end
        end)
    end
    R.post(S.path(CR,'B_CreativeGameState','OnRep_IsPlayTestMode'),function()
        selection(C.session().pc);if not S.editing() then clearPanel() end
    end)
    for _,method in ipairs({'UpdateWorldsettingsTabContent','UpdateContentTabsVisibility'}) do
        S.onEditor.post(S.path(edit..'Tabs/','WB_WorldSettingsTab',method),build)
    end
    for _,method in ipairs({'UpdateNonCollapsedUI','Maximize'}) do
        S.onEditor.post(S.path(edit,'WB_PlaceAndEditUI',method),function(w) build(w.WorldSettingsTab) end)
    end
    S.onEditor.post(S.path(CR,'B_CreativePlayerController','UpdateActorTransformServer'),function(pc,actor)
        if not R.valid(actor) then return end
        local info=S.marker(actor);if info then S.markerLook(actor,info) end
    end)
    S.onEditor.on('layout_loaded',function(info)
        for _,row in ipairs(S.markers()) do S.markerLook(row.actor,row.info) end
    end)
    R.post('/Script/Engine.Actor:ReceiveEndPlay',function(actor)
        local key=actor:GetAddress();local look=looks[key]
        if look then for _,cancel in ipairs(look.loads) do cancel() end end
        if look and look.actor then look.actor:K2_DestroyActor() end
        looks[key]=nil
        radii[key]=nil
    end)
    R.on('world_end',function()
        for _,look in pairs(looks) do for _,cancel in ipairs(look.loads) do cancel() end end
        aliases={};looks={};radii={};selectedKind=nil
    end)
end
