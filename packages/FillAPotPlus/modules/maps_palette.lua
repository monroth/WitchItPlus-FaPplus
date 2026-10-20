-- Virtual palette entries are instances, never mutations of carrier class defaults.
local M={}
function M.init(X)
    local H,C=X.H,X.C
    local api,data,known,entries={}, {}, {}, {}
    local CR=X.CREATIVE; local UI='/Game/UserInterface/PropCollection/'
    -- Only committed palette inputs wake its actor reconciliation. Other map UI
    -- and unrelated object births must not rescan every marker/light transform.
    local inputRevision=0
    local seenInputs,seenBuckets,seenEnabled
    local function dirty()
        inputRevision=inputRevision+1
        if X.Teleporters then X.Teleporters.invalidate() end
    end
    local function actorWorkNeeded()
        local versions=X.Registry.versions
        local stamp=table.concat({versions.BP_WitchCauldron_C or 0,
            versions.BP_WitchRuneStone01_C or 0,versions.BP_PlaceableLight_C or 0,
            versions.B_CreativeGameMode_C or 0},':')
        if not FAPP_TEST_NO_THROTTLE and seenInputs==inputRevision
            and seenBuckets==stamp and seenEnabled==C.CreativeMaps then return false end
        -- Capture this generation, but consume only after successful reconciliation.
        -- A mutation raised during work remains newer than the captured generation.
        return {revision=inputRevision,buckets=stamp,enabled=C.CreativeMaps}
    end
    local function reconciled(ticket)
        seenInputs,seenBuckets,seenEnabled=ticket.revision,ticket.buckets,ticket.enabled
    end
    local selection={SelectActor=true,SelectMultiple=true,DeselectSingleActor=true,DeselectMultipleActors=true}
    local function hook(stage,folder,asset,fn,callback,...)
        local mutation=stage=='Placement' or stage=='Load' or stage=='Colour'
            or stage=='EditorChange' and not selection[fn]
        X.hook(stage,folder,asset,fn,function(...)
            if mutation then dirty() end
            return callback(...)
        end,...)
    end
    local descriptions={
        'Place at least three cauldrons. Select one to choose its colour and wanted props. Use Playtest to check the map.',
        'Witches respawn here. Keep ordinary player starts for the start of the match.',
        'Teleports players to the exit of the same colour. Select to change the pair colour.',
        'Players arrive in front of this marker, facing its direction. Pair with an entrance of the same colour.',
    }
    local function kind(item)
        local r=H.valid(item) and data[item:GetAddress()]
        return r and X.same(item,r.item) and r.kind or nil
    end
    local function remember(a,k)
        dirty()
        if k==1 and X.editorCauldronLook then X.guard('EditorAppearance',X.editorCauldronLook)(a) end
        if k==2 and X.respawnLook then X.guard('RespawnAppearance',X.respawnLook)(a) end
        if k>=3 and X.EndpointLooks then X.EndpointLooks.update(a) end
        known[a:GetAddress()]={actor=a,kind=k,info=X.kind(a)}
    end
    X.onMarkerStamp=remember -- direct colour edits also refresh material-edit recovery
    local function preview(pc,k)
        local actors=X.values(pc.ActorsToPlace) -- PlaceableActorToPlace is a BP function local, not a PC field.
        local pots=X.markers(pc)
        local target,revision=X.mapTarget(pc,pots)
        for _,a in ipairs(actors) do
            if H.valid(a) and H.class(a,X.CARRIERS[k]:match('%.(.+)$')) then
                local colour=k>=3 and X.nextTeleporterColour(pc,k,a)or nil
                local look=k>=3 and X.inheritedTeleporterLook(pc,colour,a)or nil
                X.stamp(a,k,colour,false,false,'auto',k==1 and target or nil,k==1 and revision or nil,nil,nil,nil,nil,nil,look); remember(a,k)
            end
        end
    end
    hook('Palette',CR,'WB_PropCollectionWidgetCreative','GetStructureTileViewDatas',function(self,out,focus)
        local w=self:get(); local pc=w.OwningCreativePlayerController
        if w.SelectedPropCategory~=6 or not H.valid(pc) or pc.PlayerWantsMenuFilter then return end
        local items,flags=X.values(out:get()),X.values(focus:get())
        local nativeCount,added=#items,0
        local key=w:GetAddress(); local cached=entries[key]
        if not cached or not X.same(cached.widget,w) then cached={widget=w}; entries[key]=cached end
        -- Copy values while the native child frame is live. Keep only genuine
        -- item/class objects and Lua scalars, never an OUT proxy or TArray frame.
        -- A nested build replaces this ticket; world reset clears entries/data.
        local snapshot={items={},focus=false,aliases={},nativeCount=0}
        cached.native=snapshot
        for k=1,#X.CARRIERS do
            local item=cached[k]
            if not H.valid(item) then
                local result={}
                w.TileViewManager:GetPropButtonData(0,true,false,X.asset(X.CARRIERS[k]),w,{},result)
                item=result.Data; assert(H.valid(item),'GetPropButtonData returned no Data')
                cached[k]=item; data[item:GetAddress()]={item=item,kind=k}
            end
            local result={}; w:FulfillsFilterConditions(item,result)
            if result.CanBeShown~=false and (k<3 or H.authority(pc))then
                local at=#items+1
                if k==2 then
                    for i,native in ipairs(items) do
                        if H.valid(native) and X.same(X.read(native,'StructureClass'),X.asset('/Game/Blueprints/StaticProps/Placeable/Utility/BP_WitchPlayerStart.BP_WitchPlayerStart_C')) then at=i+1; break end
                    end
                end
                table.insert(items,at,item); table.insert(flags,at,false)
                added=added+1
            end
        end
        if entries[key]==cached and cached.native==snapshot then
            for i,item in ipairs(items) do
                if H.class(item,'B_PropButtonData_C') then
                    local k=kind(item)
                    snapshot.items[#snapshot.items+1]={item=item,class=X.read(item,'StructureClass'),focus=flags[i]==true,kind=k}
                    snapshot.focus=snapshot.focus or flags[i]==true
                    if k then snapshot.aliases[k]=true else snapshot.nativeCount=snapshot.nativeCount+1 end
                end
            end
        end
        out:set(items); focus:set(flags)
        w.CurrentCategoryPropsCount=w.CurrentCategoryPropsCount+added
        X.once('palette:'..key,'Palette','Utility OUT staged: native='..nativeCount
            ..' aliases='..added..' total='..#items..' pending_commit=true')
    end)
    -- The staged OUT table does not prove delivery to the ListView. Recover only
    -- an empty local Utility list, after native UpdateCategoryContent has finished
    -- clearing/adding/saving it. Reuse the native child items and utility aliases; no OUT setter,
    -- native class-list replacement, timer or second category update is needed.
    hook('Palette','/Game/UserInterface/UIElements/MenuTileView/',
        'WB_CategoryMenuScreen','UpdateCategoryContent',function(self)
            local w=self:get()
            if not H.class(w,'WB_PropCollectionWidgetCreative_C') or w.SelectedPropCategory~=6 then return end
            local pc=w.OwningCreativePlayerController
            if not H.class(pc,'B_CreativePlayerController_C') or not pc:IsLocalController()
                or pc.PlayerWantsMenuFilter then return end
            local tile=w.PropListTileView
            if not H.valid(tile) then return end
            local cached=entries[w:GetAddress()]
            if not cached or not X.same(cached.widget,w) then return end
            local snapshot=cached.native
            if not snapshot or snapshot.consumed then return end
            snapshot.consumed=true
            if tile:GetNumItems()~=0 then return end
            local function current()
                return C.CreativeMaps and not X.Lifetime.transition
                    and H.class(w,'WB_PropCollectionWidgetCreative_C') and w.SelectedPropCategory==6
                    and entries[w:GetAddress()]==cached and X.same(cached.widget,w)
                    and cached.native==snapshot
                    and H.class(pc,'B_CreativePlayerController_C') and pc:IsLocalController()
                    and not pc.PlayerWantsMenuFilter
                    and X.same(X.read(w,'OwningCreativePlayerController'),pc)
                    and X.same(X.read(w,'PropListTileView'),tile)
            end
            local added,nativeAdded,aliasAdded,seen=0,0,0,{}
            local function add(item,expectedKind,cls,focus)
                if not current() then return end
                local function validItem()
                    return H.class(item,'B_PropButtonData_C') and kind(item)==expectedKind
                        and X.same(X.read(item,'Parent'),w)
                        and X.same(X.read(item,'StructureClass'),cls)
                        and X.read(item,'UnlockedByDefault')==true
                end
                if not validItem() then return true end
                local result={}; w:FulfillsFilterConditions(item,result)
                if not current() then return end
                if result.CanBeShown~=true or not validItem() then return true end
                if tile:GetNumItems()~=added then return end -- nested native rebuild owns its new list
                local key=item:GetAddress(); local duplicate=seen[key] and X.same(seen[key],item)
                w.TileViewManager:AddItemToTileView(tile,item,focus==true or not snapshot.focus and added==0)
                if not current() then return end
                if not duplicate then
                    added=added+1;seen[key]=item
                    if expectedKind then aliasAdded=aliasAdded+1 else nativeAdded=nativeAdded+1 end
                end
                assert(tile:GetNumItems()==added,'Utility recovery AddItem did not retain items')
                return true
            end
            for _,entry in ipairs(snapshot.items) do
                if not add(entry.item,entry.kind,entry.class,entry.focus) then return end
            end
            for k=1,#X.CARRIERS do
                if (k<3 or H.authority(pc))and not snapshot.aliases[k] and not add(cached[k],k,X.asset(X.CARRIERS[k]),false) then return end
            end
            if added>0 and current() then
                local count=tile:GetNumItems()
                assert(count==added,'Utility recovery AddItem did not retain items')
                X.once('utility-recovery:'..w:GetAddress(),'Palette',
                    'empty Utilities recovered via AddItem; native='..nativeAdded
                    ..' FAPP='..aliasAdded..' retained='..count..' native_snapshot='..snapshot.nativeCount)
            end
        end)
    hook('Palette','/Game/UserInterface/UIElements/','WB_SearchBar','GetItemName',function(_,item,out)
        local k=kind(item:get()); if k then out:set(X.NAMES[k]:gsub('[^%w ]','')) end
    end,function() return next(data)~=nil end)
    hook('Palette',UI,'B_PropButtonData','Compare',function(self,other,out)
        local a,b=kind(self:get()),kind(other:get())
        if a or b then out:set(a~=nil and a==b) end
    end)
    hook('Palette',UI,'WB_PropButton','GetTooltip',function(self,out)
        local w=self:get(); local k=kind(w.ItemData); local tooltip=out:get()
        if k and H.valid(tooltip) then
            tooltip.Name:SetText(FText(X.NAMES[k]))
            tooltip.Description:SetText(FText(descriptions[k]))
        end
    end)
    -- Keep soft-icon loading in Blueprint. Only loaded Texture UObjects cross
    -- Lua; repair our virtual tiles after setup and any async native icon load.
    local icons,iconTiles={},{}
    local function dropIcon(r)
        if not r then return end
        if icons[r.gridKey]==r then icons[r.gridKey]=nil end
        if iconTiles[r.tileKey]==r then iconTiles[r.tileKey]=nil end
    end
    local function currentIcon(r,grid)
        if not r or r.epoch~=X.Lifetime.epoch or X.Lifetime.transition
            or not C.CreativeMaps or not X.live(grid) or not X.live(r.icon) or not X.same(grid,r.grid)
            or icons[grid:GetAddress()]~=r or not X.live(r.tile)
            or iconTiles[r.tileKey]~=r then return end
        local item=X.read(r.tile,'ItemData');local parent=X.read(r.tile,'ParentWidget')
        if not X.same(item,r.item) or kind(item)~=r.kind
            or not H.class(parent,'WB_PropCollectionWidgetCreative_C') or parent.SelectedPropCategory~=6
            or not X.same(parent,r.parent) or not X.same(X.read(item,'Parent'),parent)
            or not X.same(X.read(item,'StructureClass'),X.asset(X.CARRIERS[r.kind]))
            or not X.same(X.read(r.tile,'GridButton'),grid)
            or not X.same(X.read(grid,'Icon'),r.icon) then return end
        return r.icon
    end
    local function icon(r,grid)
        if not currentIcon(r,grid) then dropIcon(r);return end
        local path=r.kind==1 and '/Game/UserInterface/PropCollection/PlacableActorIcons/BP_WitchCauldron_C.BP_WitchCauldron_C'
            or '/Game/UserInterface/CreativeMode/CollectionUtilityIconWitchStart.CollectionUtilityIconWitchStart'
        local texture=X.asset(path);local image=currentIcon(r,grid)
        if image then
            image:SetBrushFromTexture(texture,false)
            image:SetColorAndOpacity(r.kind==3 and {R=0,G=.65,B=1,A=1} or r.kind==4 and {R=1,G=.65,B=0,A=1} or {R=1,G=1,B=1,A=1})
        else dropIcon(r) end
    end
    hook('Palette','/Game/UserInterface/UIElements/MenuTileView/','WB_TileViewButton','SetButtonParameters',function(self)
        local w=self:get();local grid=X.read(w,'GridButton')
        -- ListView entries and their GridButtons are pooled across items/tabs.
        -- Revoke the old binding on EVERY setup, including ordinary native rows.
        dropIcon(iconTiles[w:GetAddress()])
        if H.valid(grid) then dropIcon(icons[grid:GetAddress()]) end
        local item=X.read(w,'ItemData');local k=kind(item)
        if not k or not H.valid(grid) then return end
        local r={tile=w,tileKey=w:GetAddress(),item=item,parent=X.read(w,'ParentWidget'),grid=grid,gridKey=grid:GetAddress(),
            icon=X.read(grid,'Icon'),kind=k,epoch=X.Lifetime.epoch}
        icons[grid:GetAddress()]=r;iconTiles[w:GetAddress()]=r;icon(r,grid)
    end)
    hook('Palette','/Game/UserInterface/UIElements/','WB_GridButton','SetIconImage',function(self)
        local grid=self:get(); local r=icons[grid:GetAddress()]
        if r then icon(r,grid) end
    end)
    hook('Palette','/Game/UserInterface/UIElements/MenuTileView/','WB_TileViewButton','BP_OnEntryReleased',function(self)
        dropIcon(iconTiles[self:get():GetAddress()])
    end)
    X.Lifetime.onReset(function() icons={};iconTiles={} end)
    hook('Placement',UI,'WB_PropButton','Clicked',function(self)
        local w=self:get(); local pc=w:GetOwningPlayer()
        if not H.class(pc,'B_CreativePlayerController_C') or not w.Owned then return end
        local k=kind(w.ItemData)
        if k then preview(pc,k); X.log('Placement','selected '..X.NAMES[k])
        else
            local actors=X.values(pc.ActorsToPlace)
            for _,a in ipairs(actors) do
                local info=X.kind(a)
                if info then
                    local prefix={}; local old=X.values(a.SavedMaterialIndices)
                    for i=1,info.prefix do prefix[i]=old[i] end
                    a.SavedMaterialIndices=prefix; known[a:GetAddress()]=nil
                    if info.kind==1 and X.releaseEditorLook then X.releaseEditorLook(a) end
                    if info.kind==2 and X.releaseRespawnLook then X.releaseRespawnLook(a) end
                    if info.kind>=3 and X.EndpointLooks then X.EndpointLooks.update(a) end
                end
            end
        end
    end)
    hook('Placement',CR,'B_CreativePlayerController','GetPrefabInfo',function(_,actor,_,_,_,_,_,colour)
        local a=actor:get(); local info=X.kind(a)
        local r=H.valid(a) and known[a:GetAddress()]
        local k=info and info.kind or (r and X.same(r.actor,a) and r.kind)
        if k then colour:set({X=70,Y=65,Z=256+k}) end -- unused by native static-carrier branch
    end)
    hook('Placement',CR,'B_CreativePlayerController','PlaceActor',function(self,cls,_,_,_,_,_,_,colour,indices,out)
        local pc=self:get(); local a=out:get()
        if not H.authority(pc) or not X.live(a) then return end
        local c=colour:get(); local info=X.decode(indices:get())
        local k=info and info.kind
        if not k and c and c.X==70 and c.Y==65 then k=c.Z-256 end
        if not k or not X.CARRIERS[k] or not X.same(cls:get(),X.asset(X.CARRIERS[k]))then return end
        if k>=3 and (not info or not info.authored) then
            -- Fresh native placement may carry only GetPrefabInfo's kind sentinel,
            -- without the ghost's SavedMaterialIndices. Allocate in either case.
            info=info or {kind=k,authored=false,source='auto'}
            info.colour=X.nextTeleporterColour(pc,k,a)
            info.look=X.inheritedTeleporterLook(pc,info.colour,a)
        end
        if c and c.X==70 and c.Y==65 and c.Z==256+k then
            X.stamp(a,k,info and info.colour,info and info.authored,true,info and info.source,info and info.target,info and info.revision,info and info.decalDown,info and info.decalUp,info and info.excluded,nil,nil,info and info.look)
        elseif info and info.kind==k then X.stamp(a,k,info.colour,info.authored,true,info.source,info.target,info.revision,info.decalDown,info.decalUp,info.excluded,nil,nil,info.look)
        else return end
        remember(a,k); X.log('Placement','stamped '..X.NAMES[k]..' actor='..a:GetFullName())
        if k==1 then api.snapshot(pc) end -- new markers inherit the map's current target and S
    end)
    local snapshots={}
    local LIGHT='/Game/Blueprints/StaticProps/Placeable/Utility/BP_PlaceableLight.BP_PlaceableLight_C'
    local function inputs(ctx)
        local state={}
        for _,cls in ipairs({X.CARRIERS[1],X.CARRIERS[2],LIGHT}) do
            for _,a in ipairs(X.actors(ctx,cls)) do
                local p=X.location(a)
                -- Only native lights have Color (FVector). Missing properties can
                -- yield userdata; snapshots compare scalar values, never handles.
                local c=cls==LIGHT and X.read(a,'Color') or nil
                local function component(k)
                    local v=c and X.get(X.read(c,k))
                    return type(v)=='number' and v==v and math.abs(v)~=math.huge and v or ''
                end
                state[a:GetAddress()]=table.concat({p.X,p.Y,p.Z,table.concat(X.values(a.SavedMaterialIndices),','),
                    #X.values(a.MaterialOverwrites),component('X'),component('Y'),component('Z')},':')
            end
        end
        return state
    end
    local function changed(ctx)
        local id=ctx:GetAddress(); local state=inputs(ctx); local old=snapshots[id]
        if not old then return true end
        for k,v in pairs(state) do if old[k]~=v then return true end end
        for k in pairs(old) do if state[k]==nil then return true end end
        return false
    end
    function api.snapshot(ctx)
        local pots,respawns=X.markers(ctx); X.colours(ctx,pots)
        local target,revision=X.mapTarget(ctx,pots)
        for _,p in ipairs(pots) do X.stamp(p.actor,1,p.colour,p.authored,H.authority(p.actor),p.source,target,revision) end
        for _,p in ipairs(respawns) do remember(p.actor,2) end
        snapshots[ctx:GetAddress()]=inputs(ctx)
        return pots,respawns
    end
    hook('Colour',CR,'B_CreativePlayerController','ChangeLightColorServer',function(self)
        if H.authority(self:get()) then api.snapshot(self:get()); X.log('Colour','author light colour snapshot refreshed') end
    end)
    local BFL='/Game/Blueprints/Match/'
    hook('Load',BFL,'BFL_MapLayoutLoading','LoadStatics',function(_,_,_,saved,ctx,out)
        local rows=X.values(saved:get()); local loaded=X.values(out:get())
        assert(#rows==#loaded,'LoadStatics native actor/row count differs')
        -- Native LoadStatics appends its spawned actor for each source row.
        -- Positional matching is ambiguous when authored markers overlap.
        local plan,count,seen={}, {0,0,0,0},{}
        for i,s in ipairs(rows) do
            local info=X.decode(s.MaterialIndices)
            if info then
                local a=loaded[i]
                assert(X.live(a) and H.class(a,X.CARRIERS[info.kind]:match('%.(.+)$'))
                    and X.distance2(s.Location,X.location(a))<.01,'LoadStatics marker actor/row order differs')
                local key=a:GetAddress()
                assert(not seen[key],'LoadStatics reused an actor for multiple marker rows')
                seen[key]=true;plan[#plan+1]={actor=a,info=info}
                count[info.kind]=count[info.kind]+1
            end
        end
        for _,a in ipairs(loaded) do X.Registry.touch(a) end
        for _,entry in ipairs(plan) do
            local a,info=entry.actor,entry.info
            X.stamp(a,info.kind,info.colour,info.authored,H.authority(a),info.source,info.target,info.revision,info.decalDown,info.decalUp,info.excluded,nil,nil,info.look)
            remember(a,info.kind)
        end
        X.log('Load','LoadStatics markers='..count[1]..' cauldrons/'..count[2]..' respawns/'..count[3]..' entrances/'..count[4]..' exits')
    end)
    -- Cold read-only evidence at the actual native writer boundary. PRE has
    -- self + inputs; POST adds the bool return as argument2. Retain no proxies.
    local function writerFrame(phase,file,props,statics,success)
        if not C.CreativeMaps or X.Lifetime.transition then return end
        local array=statics:get()
        local count=FAPP_SERVICES.runtime.call(array,'GetArrayNum')
        local descriptor=FAPP_SERVICES.runtime.call(array,'GetArrayAddress')
        local address=FAPP_SERVICES.runtime.call(array,'GetArrayDataAddress')
        if type(count)~='number' then return end -- wrong/unavailable frame is not evidence
        X.log('SaveWriter',phase..' file='..string.format('%q',X.text(file:get()))
            ..' props='..tostring(FAPP_SERVICES.runtime.call(props:get(),'GetArrayNum'))
            ..' statics='..count..' descriptor='..tostring(descriptor)..' data='..tostring(address)
            ..(success and ' native_success='..tostring(success:get()) or '')
            ..' metadata=physical-native-carrier-copy'
            ..'; disk/reload validation pending')
    end
    for _,fn in ipairs({'SavePropLayoutToFile','SavePropLayoutToFileCompressed'}) do
        H.hook('/Script/PropWitchHuntModule.ProjectVersionBlueprint:'..fn,
            X.guard('SaveWriter/entry',function(_,file,props,_,statics)
                writerFrame('entry',file,props,statics)
            end),X.guard('SaveWriter/exit',function(_,success,file,props,_,statics)
                writerFrame('exit',file,props,statics,success)
            end))
    end
    -- These overrides need their own completion events; calls to the parent
    -- Blueprint loader/material path need not reach its ProcessEvent hook.
    hook('Load',CR,'B_CreativeGameMode','LoadPropLayoutFromSaveGame',function() end)
    hook('Load',CR,'B_CreativeGameState','LoadLayoutMulticast',function() end)
    hook('Load','/Game/Blueprints/StaticProps/Placeable/','BP_PlaceableStaticProp','InitMaterialsBySavedIndices',function(self)
        X.Registry.touch(self:get())
    end)
    hook('Save',CR,'B_CreativeGameMode','SaveLayout',function(self)
        local pots,respawns=X.markers(self:get()); X.log('Save','SaveLayout complete; live markers='..#pots..'/'..#respawns)
    end)
    hook('Placement',CR,'B_CreativePlayerController','SpawnDuplicatedActors',function(self)
        local pots,respawns=api.snapshot(self:get()); X.log('Placement','duplicate complete; markers='..#pots..'/'..#respawns)
    end)
    -- Verified FunctionExports in the cooked Creative controller: these are
    -- committed editor mutations, not its per-frame selection/highlight queries.
    for _,fn in ipairs({'SelectActor','SelectMultiple','DeselectSingleActor','DeselectMultipleActors',
        'UpdateActorTransformServer','UpdateSelectedActorsTransforms','UpdateMaterialServer',
        'SetActorDefaultRotation','SetActorDefaultScale','HandleResetScale','ChangeLightColorServer'}) do
        hook('EditorChange',CR,'B_CreativePlayerController',fn,function() end)
    end
    for _,fn in ipairs({'ChangeColor','SetColor'}) do
        hook('EditorChange','/Game/Blueprints/StaticProps/Placeable/Utility/','BP_PlaceableLight',fn,function() end)
    end
    function api.poll()
        local actorsDirty=actorWorkNeeded()
        if actorsDirty then for id,r in pairs(known) do
            if not X.live(r.actor) then known[id]=nil
            elseif C.CreativeMaps and H.authority(r.actor) then
                local gm=X.gameplay():GetGameMode(r.actor)
                if H.class(gm,'B_CreativeGameMode_C') and not X.kind(r.actor) then
                    local info=r.info
                    X.stamp(r.actor,r.kind,info and info.colour,info and info.authored,true,info and info.source,info and info.target,info and info.revision,info and info.decalDown,info and info.decalUp,info and info.excluded,nil,nil,info and info.look); X.log('Placement','restored signature after native material edit')
                end
            end
        end
        end
        for _,registry in ipairs({data,entries}) do
            for id,r in pairs(registry) do if not X.live(r.item or r.widget) then registry[id]=nil end end
        end
        if not actorsDirty then return end
        if not C.CreativeMaps then reconciled(actorsDirty); return end
        -- Failed reads leave this generation pending for a later event wake.
        -- The guard swallows snapshot exceptions, so require its successful result.
        local complete=true
        for _,gm in ipairs(X.findAll('B_CreativeGameMode_C')) do
            if X.live(gm) and H.authority(gm) and changed(gm) then
                if not X.guard('Colour/poll',api.snapshot)(gm) then complete=false end
            end
        end
        if complete then reconciled(actorsDirty) end
    end
    X.log('Palette','module ready; Utilities aliases use existing cooked classes')
    function api.reset() data={}; known={}; entries={}; snapshots={}; seenInputs=nil; seenBuckets=nil; seenEnabled=nil end
    X.Lifetime.onReset(api.reset) -- addresses/aliases never cross into a menu world
    X.cachedPoll(api,nil)
    local invalidate=api.invalidate
    function api.invalidate() dirty(); invalidate() end
    return api
end
return M
