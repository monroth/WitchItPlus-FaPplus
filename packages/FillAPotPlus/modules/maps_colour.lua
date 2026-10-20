-- Host Creative editing. Reuse cooked native swatches; do not send light RPCs for markers.
local M={}
M.LOOKS=dofile(assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))..'maps_endpoint_looks.lua').NAMES
M.PANEL={label=100,track=190,field=140,gap=8,trackHeight=32,rowHeight=40,pageSize=4}
-- Exact float32 B_ObjectiveCauldron.Color values from SpringTownObjective (Castle agrees).
M.SWATCHES={
    {name='Purple',R=0.33834901452064514,G=0,B=0.921999990940094,A=1},
    {name='Yellow',R=1,G=0.8192780017852783,B=0.09399999678134918,A=1},
    {name='Blue',R=0,G=0.5219209790229797,B=0.8999999761581421,A=1},
    {name='Green',R=0.2274789959192276,G=0.9734449982643127,B=0.05315500125288963,A=1},
    {name='Red',R=0.6927080154418945,G=0.08415199816226959,B=0,A=1},
}
-- HSV operates on linear RGB; do not gamma-transform the saved FLinearColor.
function M.hsvColour(h,s,v)
    assert(type(h)=='number' and type(s)=='number' and type(v)=='number')
    local sector=(h%360)/60; local c=v*s; local x=c*(1-math.abs(sector%2-1)); local m=v-c
    local rgb=({{c,x,0},{x,c,0},{0,c,x},{0,x,c},{x,0,c},{c,0,x}})[math.floor(sector)+1]
    return {R=rgb[1]+m,G=rgb[2]+m,B=rgb[3]+m,A=1}
end
-- Extra presets use the same linear HSV contract as the editable controls.
do
    local pink=M.hsvColour(342,.896,1); pink.name='Pink'; M.SWATCHES[#M.SWATCHES+1]=pink
    local white=M.hsvColour(0,0,1); white.name='White'; M.SWATCHES[#M.SWATCHES+1]=white
end
function M.colourHSV(c,previous)
    local hi,lo=math.max(c.R,c.G,c.B),math.min(c.R,c.G,c.B); local delta=hi-lo
    local h=previous and previous.H or 0
    if delta>1e-8 then
        if hi==c.R then h=60*((c.G-c.B)/delta%6)
        elseif hi==c.G then h=60*((c.B-c.R)/delta+2)
        else h=60*((c.R-c.G)/delta+4) end
    end
    return {H=h,S=hi>1e-8 and delta/hi or (previous and previous.S or 0),V=hi}
end
function M.init(X)
    local H,C=X.H,X.C; local api,panels,buttons,tints,sliders,headers={},{},{},{},{},{}
    local Restore=dofile(assert(debug.getinfo(1,"S").source:match("^@(.+[\\/])")).."maps_material_restore.lua").init(X)
    local Swatches=dofile(assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))..'maps_swatch_renderer.lua').init(X)
    local typeButtons={}
    local closed={}
    local wantedObserver,watchWanted
    local wantedJobs=0
    local EDIT=X.CREATIVE..'PlacementAndEditUI/'
    local TABS=EDIT..'Tabs/'; local TILES=EDIT..'TileAndListviews/'
    local function identity(w)
        if not X.live(w) then return end
        return {address=w:GetAddress(),name=w:GetFullName(),epoch=X.Lifetime.epoch}
    end
    local function matches(w,id)
        return id and id.epoch==X.Lifetime.epoch and X.live(w)
            and w:GetAddress()==id.address and w:GetFullName()==id.name
    end
    local function isClosed(w)
        return X.live(w) and matches(w,closed[w:GetAddress()])
    end
    local function current(r)
        return r and r.active and matches(r.widget,r.identity)
            and panels[r.identity.address]==r and not isClosed(r.widget)
            and matches(r.root,r.rootIdentity) and matches(r.root:GetParent(),r.parentIdentity)
    end
    local function panel(w)
        if not X.live(w) then return end
        local r=panels[w:GetAddress()]
        if current(r) and matches(w,r.identity) then return r end
    end
    local function binding(r,w)
        return {widget=w,identity=assert(identity(w)),parentIdentity=assert(identity(w:GetParent())),panel=r}
    end
    local function bound(e,w)
        return e and current(e.panel) and matches(w,e.identity)
            and matches(w:GetParent(),e.parentIdentity)
    end
    local function release(r,removeRoot)
        if not r then return end
        -- Revoke before any native cleanup can dispatch another input event.
        r.active=false
        if r.wantedJob then X.Work.cancel(r.wantedJob);r.wantedJob=nil end
        if panels[r.identity.address]==r then panels[r.identity.address]=nil end
        if next(panels)==nil and wantedObserver then wantedObserver();wantedObserver=nil end
        for _,entries in ipairs({buttons,typeButtons,sliders}) do
            for id,e in pairs(entries) do if e.panel==r then entries[id]=nil end end
        end
        if matches(r.widget,r.identity) then Swatches.release(r.widget) end
        if removeRoot and matches(r.root,r.rootIdentity) and matches(r.root:GetParent(),r.parentIdentity) then
            r.root:RemoveFromParent()
        end
    end
    local function creative(o,host)
        local gm=X.gameplay():GetGameMode(o)
        return H.class(gm,'B_CreativeGameMode_C') and (not host or H.authority(gm))
    end
    -- Creative GameMode is server-only. Guest fluid presentation uses the
    -- replicated GameState in this actor's world; editing still needs authority.
    local function presentation(o)
        if not X.live(o) then return false end
        local g=X.gameplay(); local gm=g:GetGameMode(o)
        if H.valid(gm) then return H.class(gm,'B_CreativeGameMode_C') end
        local gs=g:GetGameState(o)
        return X.live(gs) and H.class(gs,'B_CreativeGameState_C')
            and X.Lifetime.sameWorld(o,gs)
    end
    local function targets(w)
        if not X.live(w) or isClosed(w) then return {} end
        local pc=w.OwningCreativePlayerController; local result={}
        if not C.CreativeMaps or not X.live(pc) or not H.authority(pc) or not creative(pc,true)
            or (pc.CurrentPlayMode~=0 and pc.CurrentPlayMode~=1) or w.MenuState~=0 then return result end
        local ui=X.read(pc,'EditUI'); if H.valid(ui) and ui.IsMinimized then return result end
        for _,a in ipairs(X.values(pc.SelectedActors)) do
            local info=X.kind(a)
            if info and (info.kind==1 or info.kind==3 or info.kind==4) and X.read(a,'IsPreview')~=true and H.authority(a) then result[#result+1]=a end
        end
        return result
    end
    local function need(o,label) assert(H.valid(o),'missing '..label); return o end
    local function native(w,cls) return need(StaticConstructObject(X.asset('/Script/UMG.'..cls),w.WidgetTree),cls) end
    local function widget(w,folder,cls)
        return need(X.object('/Script/UMG.Default__WidgetBlueprintLibrary'):Create(w,X.asset(folder..cls..'.'..cls..'_C'),w:GetOwningPlayer()),cls)
    end
    local function tintCurrent(id,r)
        assert(not X.Lifetime.transition and r.epoch==X.Lifetime.epoch and tints[id]==r,
            'tint owner retired during cleanup')
    end
    local function tintObsolete(id,r)
        return X.Lifetime.transition or r.epoch~=X.Lifetime.epoch or tints[id]~=r
    end
    -- The decorative cauldron's fluid material has no Color parameter. Replace
    -- only that slot with the already cooked Objective fluid MID, on this actor.
    function api.tint(a,colour)
        local epoch=X.Lifetime.epoch
        if X.Lifetime.transition then return false end
        if not C.CreativeMaps or not presentation(a) then return end
        if X.Lifetime.transition or epoch~=X.Lifetime.epoch then return false end
        local info=X.kind(a); if not info or info.kind~=1 then return end
        local c=colour or info.colour; if not c then return end
        -- The exact existing visual owner keeps rollback authority until explicit cleanup.
        if X.visualCleanupPending and X.visualCleanupPending(X.Lifetime.key(a)) then return false end
        -- Preserve intent: background reconciliation must not masquerade as a colour edit.
        local editor=X.editorCauldronLook and X.guard('EditorAppearance',X.editorCauldronLook)(a,colour)
        if X.Lifetime.transition or epoch~=X.Lifetime.epoch then return false end
        if editor then return end
        local id=a:GetAddress();local record=tints[id]
        if record and record.cleanup_pending then return false end
        if not record or not X.same(record.actor,a) then
            record={actor=a,slots={},epoch=X.Lifetime.epoch};tints[id]=record
        end
        tintCurrent(id,record)
        local count=0
        for _,mesh in ipairs(X.values(a.MeshComponents)) do if not Restore.isHolder(mesh) then
            for index,mat in ipairs(X.values(mesh:GetMaterials())) do
                local slot=index-1; local key=mesh:GetAddress()..':'..slot; local cached=record.slots[key]
                if cached then
                    local matching=Restore.matches(cached.retained,cached.midAddress);tintCurrent(id,record)
                    if not matching then Restore.drop(cached.retained);tintCurrent(id,record);record.slots[key]=nil;cached=nil end
                end
                if not cached and H.valid(mat) and mat:GetFullName():find('M_StaticCauldronFluid',1,true) then
                    local source=X.asset('/Game/ObjectiveModeContent/M_CauldronFillFluid.M_CauldronFillFluid')
                    local retained=Restore.capture(a,mesh,slot);tintCurrent(id,record)
                    cached={mesh=mesh,slot=slot,retained=retained}; record.slots[key]=cached
                    local ok,mid=pcall(function() return mesh:CreateDynamicMaterialInstance(slot,source,FName('None')) end)
                    if not ok and tintObsolete(id,record) then error(mid,0) end
                    tintCurrent(id,record)
                    if ok then ok,mid=pcall(need,mid,'marker fluid MID');tintCurrent(id,record) end
                    if not ok then
                        record.cleanup_pending=true
                        local cleaned=pcall(function()
                            Restore.restore(retained);tintCurrent(id,record)
                            Restore.drop(retained);tintCurrent(id,record)
                        end)
                        if not tintObsolete(id,record) and cleaned then record.slots[key]=nil;record.cleanup_pending=nil end
                        error(mid,0)
                    end
                    cached.midAddress=mid:GetAddress();tintCurrent(id,record)
                end
                if cached then
                    local signature=string.pack('<ffff',c.R,c.G,c.B,1)
                    if cached.signature~=signature then
                        local mid=mesh:GetMaterial(slot);tintCurrent(id,record)
                        mid:SetVectorParameterValue(FName('Color'),X.native(c));tintCurrent(id,record);cached.signature=signature
                    end
                    count=count+1
                end
            end
        end
        end
        tintCurrent(id,record)
        X.once('tint:'..id,'ColourPreview',count>0 and 'editor marker fluid tinted; slots='..count or
            'no compatible fluid slot; colour swatches remain the preview')
    end
    local function releaseTintRecord(id,record)
        record.cleanup_pending=true
        local ok,err=pcall(function()
            for key,s in pairs(record.slots) do
                local matching=Restore.matches(s.retained,s.midAddress);tintCurrent(id,record)
                if matching then Restore.restore(s.retained);tintCurrent(id,record) end
                Restore.drop(s.retained);tintCurrent(id,record)
                record.slots[key]=nil -- completed slots do not retry a destroyed holder
            end
        end)
        if tintObsolete(id,record) then return true end
        if not ok then error(err,0) end
        tints[id]=nil
        return true
    end
    function api.releaseTint(a)
        local epoch=X.Lifetime.epoch
        if X.Lifetime.transition then return true end
        -- Resolve an owned record by Lua identity first; cleanup must not ask a
        -- retired actor for its address after a synchronous visual release.
        local id,record
        for key,r in pairs(tints) do if r.actor==a then id,record=key,r;break end end
        if not H.valid(a) then return end
        if X.releaseEditorLook then
            local done=X.releaseEditorLook(a)
            if X.Lifetime.transition or epoch~=X.Lifetime.epoch then return true end
            assert(done~=false,'editor cleanup pending; tint ownership retained')
        end
        if not record then return end
        if tintObsolete(id,record) then return true end
        return releaseTintRecord(id,record)
    end
    X.tintMarker=api.tint; X.releaseMarkerTint=api.releaseTint -- transient Creative playtest visuals
    local function fitButton(w,parent,b)
        local scale=native(w,'ScaleBox'); scale:SetStretch(2); scale:SetStretchDirection(1) -- fit, down only
        parent:AddChild(scale); scale:AddChild(b)
    end
    local function swatchData(w,c)
        local d=need(StaticConstructObject(X.asset(TILES..'B_LightColorButtonData.B_LightColorButtonData_C'),w),'swatch data')
        d.Color={X=c.R,Y=c.G,Z=c.B}; d.Parent=w; d.IsInitial=false; d.IsSelected=false
        return d
    end
    local function selectionKey(selected)
        local ids={}; for _,a in ipairs(selected) do ids[#ids+1]=X.Lifetime.key(a) end
        table.sort(ids); return X.Lifetime.epoch..':'..X.Lifetime.key(selected[1])..':'..table.concat(ids,',')
    end
    local EL='/Game/UserInterface/UIElements/'
    local SLIDER='WB_SliderWithEditableLabel'
    local VALUE_EVENT='BndEvt__ValueSlider_K2Node_ComponentBoundEvent_0_OnFloatValueChangedEvent__DelegateSignature'
    local COMMIT_EVENT='BndEvt__WB_SliderWithEditableLabel_InputField_K2Node_ComponentBoundEvent_3_OnEditableTextBoxCommittedEvent__DelegateSignature'
    local specs={
        {key='H',label='Hue',max=360,factor=1,suffix='°'},
        {key='S',label='Saturation',max=100,factor=100,suffix='%'},
        {key='V',label='Value',max=100,factor=100,suffix='%'},
    }
    -- Fixed outer rows and prop list; HSV keeps the cooked internal layout.
    local P=M.PANEL
    local LABEL_W,TRACK_W,FIELD_W,GAP,TRACK_H,ROW_H=P.label,P.track,P.field,P.gap,P.trackHeight,P.rowHeight
    local ROW_W=LABEL_W+GAP+TRACK_W+GAP+FIELD_W
    local function autoChild(row,child)
        local slot=row:AddChild(child)
        local size=slot.Size; size.Value=1; size.SizeRule=0
        slot:SetSize(size); slot:SetVerticalAlignment(1)
        return slot
    end
    local function space(w,row,width)
        local box=native(w,'SizeBox'); box:SetWidthOverride(width); box:SetHeightOverride(1)
        autoChild(row,box); return box
    end
    local function layoutNumeric(w,control)
        local label=need(control.DescriptiveLabelText,'HSV label')
        local labelScale=need(label:GetParent(),'native label ScaleBox')
        local grid=need(labelScale:GetParent(),'native slider GridPanel')
        local input=need(control.InputField,'HSV numeric input')
        local track=need(control.ValueSlider,'HSV track')
        local extras={}
        for _,child in ipairs(X.values(grid:GetAllChildren())) do
            local okName,name=pcall(function() return child:GetFName():ToString() end)
            if okName then extras[name]=child end
        end
        -- Keep the original UserWidget root and event-bound native controls.
        -- Every width, including the root frame, is explicit; no Fill slot or
        -- zero desired width is involved in the row's allocation.
        grid:ClearChildren()
        for col=0,3 do grid:SetColumnFill(col,0) end
        local frame=native(w,'SizeBox'); frame:SetWidthOverride(ROW_W); frame:SetHeightOverride(ROW_H)
        local rootSlot=grid:AddChildToGrid(frame,0,0)
        rootSlot:SetHorizontalAlignment(1); rootSlot:SetVerticalAlignment(1)
        local row=native(w,'HorizontalBox'); frame:AddChild(row)
        local labelBox=native(w,'SizeBox'); labelBox:SetWidthOverride(ROW_W-GAP-FIELD_W); labelBox:SetHeightOverride(TRACK_H)
        autoChild(row,labelBox); labelBox:AddChild(labelScale)
        label:SetJustification(2)
        labelScale:SetStretch(2); labelScale:SetStretchDirection(1)
        space(w,row,GAP)
        local function stretch(slot) slot:SetHorizontalAlignment(0); slot:SetVerticalAlignment(1); return slot end
        -- Map target/decal fields remain numeric-only; do not expose a track.
        for _,child in ipairs({track,extras.ValueFill,control.DefaultValueIndicator}) do
            need(child,'native numeric control'):SetVisibility(1)
            grid:AddChildToGrid(child,0,2)
        end
        track:SetIsEnabled(false)
        local inputBox=native(w,'SizeBox'); inputBox:SetWidthOverride(FIELD_W); inputBox:SetMinDesiredWidth(FIELD_W)
        inputBox:SetHeightOverride(TRACK_H); autoChild(row,inputBox)
        local inputOverlay=native(w,'Overlay'); inputBox:AddChild(inputOverlay)
        stretch(inputOverlay:AddChild(input))
        local valueText=need(extras.ValueText,'native value text'); valueText:SetVisibility(1)
        stretch(inputOverlay:AddChild(valueText))
        stretch(inputOverlay:AddChild(need(extras.ValueFocusButton,'native numeric focus button')))
        -- Keep unused reset/controller objects attached outside the numeric row.
        local resetGroup=need(control.ResetButton,'HSV reset'):GetParent(); resetGroup:SetVisibility(1)
        grid:AddChildToGrid(resetGroup,0,1)
        return {row=row,frame=frame,track=track}
    end
    local function logGeometry(r)
        if r.geometryLogged then return end
        r.geometryLogged=true -- one attempt per build, never per drag/poll
        X.guard('ColourGeometry',function()
            r.root:ForceLayoutPrepass()
            local function size(widget)
                local v=widget:GetDesiredSize(); return string.format('%.1fx%.1f',v.X,v.Y)
            end
            for _,e in ipairs(r.sliders) do
                X.log('ColourGeometry',e.spec.label..' cooked grid/slots/fonts intact; outer='..ROW_W..'x'..ROW_H..
                    '; desired grid='..size(e.layout.row)..' frame='..size(e.layout.frame)..' slider='..size(e.layout.track))
            end
            X.log('ColourGeometry','swatches desired='..size(r.row)..'; fixed width='..ROW_W..'; Auto right edge')
        end)()
    end
    local function syncSliders(r)
        local was=r.syncing; r.syncing=true
        local ok,err=pcall(function()
            for _,e in ipairs(r.sliders) do
                local value=math.floor(r.hsv[e.spec.key]*e.spec.factor*10+.5)/10
                local real=e.widget.RealValue
                if type(real)~='number' or real~=real or math.abs(real)==math.huge or math.abs(real-value)>1e-6 then e.widget:SetRealValue(value) end
            end
        end)
        r.syncing=was; if not ok then error(err) end
    end
    function api.editHSV(w,key,value)
        local selected=targets(w); if #selected==0 then return false end
        local r=panel(w); if not r or r.syncing then return false end
        -- An event from the previous selection must never edit the new selection.
        if r.selection~=selectionKey(selected) then api.refresh(w); return false end
        local spec; for _,s in ipairs(specs) do if s.key==key then spec=s end end
        assert(spec,'unknown HSV axis')
        if type(value)~='number' or value~=value or math.abs(value)==math.huge then
            syncSliders(r); X.once('picker-invalid:'..w:GetAddress(),'ColourPicker','rejected non-finite/nonnumeric HSV input'); return false
        end
        value=math.max(0,math.min(spec.max,value))
        r.hsv[key]=value/spec.factor
        local c=M.hsvColour(r.hsv.H,r.hsv.S,r.hsv.V)
        -- refresh must retain hue/saturation at black/grey and hue=360 at the endpoint.
        r.writing=true
        local ok,result=pcall(api.chooseColour,w,c,'HSV',true)
        r.writing=false; if not ok then error(result) end
        local now=os.time()
        if result and r.lastLog~=now then
            r.lastLog=now; X.log('ColourPicker',string.format('live HSV %.1f° / %.1f%% / %.1f%%; host saved RGBA for %d markers',
                r.hsv.H,r.hsv.S*100,r.hsv.V*100,#selected))
        end
        return result
    end
    function api.editTarget(w,value)
        local selected=targets(w); if #selected==0 then return false end
        local r=panel(w); if not r or r.syncing then return false end
        if r.selection~=selectionKey(selected) then api.refresh(w); return false end
        if type(value)~='number' or value~=value or math.abs(value)==math.huge then api.refresh(w); return false end
        local pots=X.markers(w); if #pots==0 then return false end
        value=math.max(1,math.min(#pots,math.floor(value+.5)))
        local current,revision=X.mapTarget(w,pots)
        if value==current and revision>0 then api.refresh(w); return true end
        revision=math.max(revision+1,os.time()*1000)
        X.colours(w,pots) -- resolve legacy/auto colour before upgrading a v1 marker
        for _,p in ipairs(pots) do
            assert(H.authority(p.actor),'map target requires authority on every marker')
            X.stamp(p.actor,1,p.colour,p.authored,true,p.source,value,revision)
        end
        X.log('MapTarget','host saved Cauldrons to win='..value..' in all '..#pots..' markers; revision='..revision)
        api.refresh(w); return true
    end
    function api.editSeek(w,value)
        local r=panel(w);if not r or r.syncing or #targets(w)==0 then return false end
        if type(value)~='number'or value~=value or math.abs(value)>600 then return false end
        value=math.floor(value*100+.5)/100
        local pots=X.markers(w);local _,revision=X.seekCoefficient(w,pots)
        revision=math.max(revision+1,os.time()*1000)
        for _,p in ipairs(X.colours(w,pots))do
            assert(H.authority(p.actor),'seek coefficient requires host authority')
            X.stamp(p.actor,1,p.colour,p.authored,true,p.source,nil,nil,nil,nil,nil,value,revision)
        end
        X.log('SeekTime','saved map coefficient S='..value..' in '..#pots..' cauldron markers')
        api.refresh(w);return true
    end
    function api.editDepth(w,key,value)
        assert(key=='decalDown' or key=='decalUp','unknown decal extent')
        local selected=targets(w); if #selected==0 then return false end
        local r=panel(w); if not r or r.syncing then return false end
        if r.selection~=selectionKey(selected) then api.refresh(w); return false end
        if type(value)~='number' or value~=value or math.abs(value)==math.huge then api.refresh(w); return false end
        value=math.max(0,math.min(X.DECAL_MAX,math.floor(value+.5)))
        -- Resolve colour once; projection edits preserve colour source and map target.
        local picked={}; for _,a in ipairs(selected) do picked[a:GetAddress()]=true end
        for _,p in ipairs(X.colours(w,X.markers(w))) do if picked[p.id] then
            local down=key=='decalDown' and value or p.info.decalDown
            local up=key=='decalUp' and value or p.info.decalUp
            X.stamp(p.actor,1,p.colour,p.authored,true,p.source,nil,nil,down,up)
        end end
        api.refresh(w); return true
    end
    local function build(w)
        local parent=need(w.TransformBox,'TransformBox'):GetParent(); need(parent,'world settings content panel')
        local root=native(w,'VerticalBox'); parent:AddChild(root)
        local r={widget=w,identity=assert(identity(w)),root=root,rootIdentity=assert(identity(root)),parentIdentity=assert(identity(parent)),
            choices={},sliders={},depth={},hsv={H=0,S=1,V=1}}
        local ok,result=pcall(function()
            -- Keep the cooked Light designer subtree and its slots intact. The
            -- title/divider/font/Color label/large swatch now match native Light.
            r.tab=widget(w,TABS,'WB_LightColorTab'); root:AddChild(r.tab)
            local lightRoot=need(r.tab.WidgetTree.RootWidget,'native Light root')
            for _,child in ipairs(X.values(lightRoot:GetAllChildren())) do
                local okName,n=pcall(function() return child:GetFName():ToString() end)
                if okName and n=='TextBlock_38' then r.label=child end
            end
            need(r.label,'native Light section title'):SetText(FText('Cauldron colour'))
            for _,field in ipairs({'BrightnessBox','SpotLightAngleBox','WB_CastShadowsCheckboxAreaButton',
                'WB_DirectionalLightCheckboxAreaButton','LightGroupPreviewInfo'}) do
                need(r.tab[field],'native Light '..field):SetVisibility(1)
            end
            r.showcase=need(r.tab.ShowcaseColorButton,'native current colour swatch')
            r.showcase.ParentWidget=w; r.showcase.ItemData=swatchData(w,M.SWATCHES[1]); r.showcase.Color=r.showcase.ItemData.Color
            assert(Swatches.own(w,r.showcase,r.showcase.ItemData,M.SWATCHES[1]))
            r.showcase:SetButtonParameters();assert(Swatches.paint(r.showcase))
            r.showcase:SetToolTipText(FText('Changes the colour of all selected markers.'))
            r.showcase.bIsFocusable=false -- enabled colours stay bright; neutral parent makes clicks inert
            r.content=need(r.tab.ColorShowcaseBox,'native Color row'):GetParent(); need(r.content,'native Light content')
            r.wanted=native(w,'TextBlock')
            local font=r.wanted.Font; font.Size=14; r.wanted:SetFont(font)
            r.wanted:SetText(FText('Wanted props: —/—'))
            r.wanted:SetToolTipText(FText('Reopen this panel after moving props to update the count.'))
            local wantedSlot=r.content:AddChild(r.wanted); wantedSlot:SetHorizontalAlignment(2)
            local row=native(w,'HorizontalBox'); local rowSlot=r.content:AddChild(row)
            rowSlot:SetHorizontalAlignment(2); rowSlot:SetPadding({Left=10,Top=0,Right=10,Bottom=0}); r.row=row
            for index,c in ipairs(M.SWATCHES) do
                local box=native(w,'SizeBox'); box:SetWidthOverride(40); box:SetHeightOverride(36)
                autoChild(row,box)
                local b=widget(w,TILES,'WB_LightColorButton'); fitButton(w,box,b)
                -- A WorldSettingsTab is deliberately not one of Clicked's native
                -- popup/light-tab/world-properties parents: all native edit routes skip.
                local data=swatchData(w,c)
                b.ItemData=data; b.ParentWidget=w; b.Color=data.Color; b.bIsFocusable=true
                assert(Swatches.own(w,b,data,c))
                b:SetButtonParameters();assert(Swatches.paint(b)); b:SetToolTipText(FText(c.name))
                r.choices[#r.choices+1]={widget=b,index=index,data=data}
            end
            space(w,row,ROW_W-#M.SWATCHES*40-64)
            local box=native(w,'SizeBox'); box:SetWidthOverride(64); box:SetHeightOverride(36); autoChild(row,box)
            local auto=widget(w,'/Game/UserInterface/UIElements/','WB_TabButton'); fitButton(w,box,auto)
            auto.LabelText=FText('Auto'); need(auto.Label,'Auto label'):SetText(FText('Auto')); auto.bIsFocusable=true
            auto:SetToolTipText(FText('Choose a colour automatically.'))
            r.choices[#r.choices+1]={widget=auto,index=0}
            for i,choice in ipairs(r.choices) do
                if i>1 then choice.widget:SetNavigationRuleExplicit(0,r.choices[i-1].widget) end
                if i<#r.choices then choice.widget:SetNavigationRuleExplicit(1,r.choices[i+1].widget) end
            end
            r.lookGroup=native(w,'VerticalBox');r.content:AddChild(r.lookGroup);r.lookButtons={}
            local title=native(w,'TextBlock');title:SetText(FText('Look'));r.lookGroup:AddChild(title)
            for i,name in ipairs(M.LOOKS)do
                local box=native(w,'SizeBox');box:SetWidthOverride(ROW_W);box:SetHeightOverride(36);r.lookGroup:AddChild(box)
                local b=widget(w,'/Game/UserInterface/UIElements/','WB_TabButton');fitButton(w,box,b)
                b.LabelText=FText(name);b.Label:SetText(FText(name));b.bIsFocusable=true
                r.lookButtons[#r.lookButtons+1]=b
                local e=binding(r,b);e.action='look';e.look=i-1;typeButtons[b:GetAddress()]=e
                X.passiveUI(X.path('/Game/UserInterface/UIElements/','WB_TabButton','BndEvt__MyButton_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature'),b)
            end
            for _,spec in ipairs(specs) do
                -- Size the outer control only; keep every cooked child and slot.
                local box=native(w,'SizeBox'); box:SetWidthOverride(ROW_W); box:SetHeightOverride(ROW_H)
                local slot=r.content:AddChild(box); slot:SetHorizontalAlignment(2)
                slot:SetPadding({Left=10,Top=0,Right=10,Bottom=0}); slot:SetVerticalAlignment(1)
                local control=widget(w,EL,SLIDER); box:AddChild(control)
                control.bIsFocusable=true; control.DescriptiveLabel=FText(spec.label)
                need(control.DescriptiveLabelText,'HSV label'):SetText(FText(spec.label))
                control.MinimumValue=0; control.MaximumValue=spec.max; control.StepSize=.1
                control.bRoundToIntegers=false; control.bTimeValueInSeconds=false; control.UIMultiplyFactor=1
                control.ValueSuffix=FText(spec.suffix); control.DefaultFloatValue=0
                control:SetRealValue(0)
                -- Native Tick, focus animation and value events keep using these
                -- children. Preserve the cooked GridPanel, slots and fonts.
                local layout={row=control.WidgetTree.RootWidget,frame=box,track=control.ValueSlider}
                need(control.ResetButton,'HSV reset'):SetVisibility(1)
                need(control.DefaultValueIndicator,'HSV default indicator'):SetVisibility(1)
                need(control.InputField,'HSV numeric input')
                control:SetToolTipText(FText(''))
                r.sliders[#r.sliders+1]={widget=control,spec=spec,panel=r,layout=layout}
            end
            for _,spec in ipairs({{key='decalDown',label='Rune depth below',default=X.DECAL_DOWN},
                {key='decalUp',label='Rune height above',default=X.DECAL_UP}}) do
                local group=native(w,'VerticalBox'); r.content:AddChild(group)
                local box=native(w,'SizeBox'); box:SetWidthOverride(ROW_W); box:SetHeightOverride(ROW_H)
                local slot=group:AddChild(box); slot:SetHorizontalAlignment(2)
                local padding=slot.Padding; padding.Left=10; padding.Right=10; padding.Top=0; padding.Bottom=0; slot:SetPadding(padding)
                local control=widget(w,EL,SLIDER); box:AddChild(control)
                control.DescriptiveLabel=FText(spec.label); control.DescriptiveLabelText:SetText(control.DescriptiveLabel)
                local font=control.DescriptiveLabelText.Font; font.Size=14; control.DescriptiveLabelText:SetFont(font)
                control.MinimumValue=0; control.MaximumValue=X.DECAL_MAX; control.StepSize=1
                control.bRoundToIntegers=true; control.bTimeValueInSeconds=false; control.UIMultiplyFactor=1
                control.ValueSuffix=FText(' UU'); control.DefaultFloatValue=spec.default
                control:SetToolTipText(FText('How far the rune circle projects above or below the cauldron.'))
                r.depth[#r.depth+1]={widget=control,group=group,spec=spec,panel=r,layout=layoutNumeric(w,control)}
            end
            -- Separate from HSV: this row edits the whole map, not just selection.
            local group=native(w,'VerticalBox'); r.content:AddChild(group)
            local box=native(w,'SizeBox'); box:SetWidthOverride(ROW_W); box:SetHeightOverride(ROW_H)
            local slot=group:AddChild(box); slot:SetHorizontalAlignment(2)
            local padding=slot.Padding; padding.Left=10; padding.Right=10; padding.Top=0; padding.Bottom=0; slot:SetPadding(padding)
            local control=widget(w,EL,SLIDER); box:AddChild(control)
            control.DescriptiveLabel=FText('Cauldrons to win'); control.DescriptiveLabelText:SetText(control.DescriptiveLabel)
            local font=control.DescriptiveLabelText.Font; font.Size=14; control.DescriptiveLabelText:SetFont(font)
            control.MinimumValue=1; control.MaximumValue=math.max(1,#X.markers(w)); control.StepSize=1
            control.bRoundToIntegers=true; control.bTimeValueInSeconds=false; control.UIMultiplyFactor=1
            control.ValueSuffix=FText(''); control.DefaultFloatValue=math.min(3,control.MaximumValue)
            control:SetToolTipText(FText('Number of full cauldrons needed to win. Match Rules + can adjust this.'))
            r.target={widget=control,group=group,spec={key='WIN',max=control.MaximumValue},panel=r,layout=layoutNumeric(w,control)}
            local group=native(w,'VerticalBox');r.content:AddChild(group)
            local box=native(w,'SizeBox');box:SetWidthOverride(ROW_W);box:SetHeightOverride(ROW_H);group:AddChild(box)
            local control=widget(w,EL,SLIDER);box:AddChild(control)
            control.DescriptiveLabel=FText('Map size steps');control.DescriptiveLabelText:SetText(control.DescriptiveLabel)
            control.MinimumValue=-600;control.MaximumValue=600;control.StepSize=.1
            control.bRoundToIntegers=false;control.bTimeValueInSeconds=false;control.UIMultiplyFactor=1
            control.ValueSuffix=FText('');control.DefaultFloatValue=0
            control:SetToolTipText(FText('Each step adds the extra search time chosen in Match Rules +. Negative steps shorten the time.'))
            r.seek={widget=control,group=group,spec={key='SEEK'},panel=r,layout=layoutNumeric(w,control)}
            r.typePage=1; r.typeRows={}
            local list=native(w,'VerticalBox'); root:AddChild(list); r.typeList=list
            local title=native(w,'TextBlock'); title:SetText(FText('Wanted props'))
            local font=title.Font; font.Size=14; title:SetFont(font); list:AddChild(title)
            title:SetToolTipText(FText('Each wanted prop needs at least two copies, all beyond the minimum distance. Edits affect the first selected cauldron.'))
            local function button(parent,label,width,action)
                local box=native(w,'SizeBox'); box:SetWidthOverride(width); box:SetHeightOverride(36); parent:AddChild(box)
                local b=widget(w,EL,'WB_TabButton'); box:AddChild(b)
                b.LabelText=FText(label); b.Label:SetText(b.LabelText); b:SetActiveState(false)
                local e=binding(r,b);e.action=action;typeButtons[b:GetAddress()]=e
                X.passiveUI(X.path(EL,'WB_TabButton','BndEvt__MyButton_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature'),b)
                return b
            end
            for i=1,P.pageSize do
                local row=native(w,'HorizontalBox'); list:AddChild(row)
                local box=native(w,'SizeBox'); box:SetWidthOverride(ROW_W-88); box:SetHeightOverride(40); autoChild(row,box)
                local fit=native(w,'ScaleBox'); fit:SetStretch(2); fit:SetStretchDirection(1); box:AddChild(fit)
                local text=native(w,'TextBlock'); fit:AddChild(text)
                local font=text.Font; font.Size=12; text:SetFont(font)
                local b=button(row,'Exclude',88,'toggle')
                r.typeRows[i]={row=row,text=text,button=b}
            end
            local nav=native(w,'HorizontalBox'); list:AddChild(nav)
            r.typePrev=button(nav,'Previous',100,-1)
            local box=native(w,'SizeBox'); box:SetWidthOverride(ROW_W-200); nav:AddChild(box)
            r.typeStatus=native(w,'TextBlock'); box:AddChild(r.typeStatus)
            local font=r.typeStatus.Font; font.Size=12; r.typeStatus:SetFont(font)
            r.typeNext=button(nav,'Next',100,1)
            return r
        end)
        if not ok then release(r,true);error(result) end
        if not matches(w,result.identity) or isClosed(w) then release(result,true);return end
        for _,e in ipairs(result.sliders) do
            e.identity=assert(identity(e.widget));e.parentIdentity=assert(identity(e.widget:GetParent()));sliders[e.widget:GetAddress()]=e
        end
        for _,e in ipairs(result.depth) do
            e.identity=assert(identity(e.widget));e.parentIdentity=assert(identity(e.widget:GetParent()));sliders[e.widget:GetAddress()]=e
        end
        result.target.identity=assert(identity(result.target.widget))
        result.target.parentIdentity=assert(identity(result.target.widget:GetParent()))
        sliders[result.target.widget:GetAddress()]=result.target
        result.seek.identity=assert(identity(result.seek.widget));result.seek.parentIdentity=assert(identity(result.seek.widget:GetParent()))
        sliders[result.seek.widget:GetAddress()]=result.seek
        for _,b in ipairs(result.choices) do
            local e=binding(result,b.widget);e.index=b.index;e.data=b.data
            e.dataIdentity=b.data and identity(b.data);buttons[b.widget:GetAddress()]=e
        end
        result.active=true
        panels[w:GetAddress()]=result
        watchWanted()
        if type(H.retryHooks)=='function' then H.retryHooks() end -- the swatch class just loaded
        X.log('ColourUI','added Cauldron colour block: native Light divider/title/Color preview, 5 SpringTown swatches + Pink + White + Auto, map-wide Cauldrons to win')
        X.log('ColourPicker','ready: native HSV grid/slots/fonts; outer rows 446x40 UU; live preview + saved RGBA')
        return result
    end
    local function paintTypes(r)
        if not current(r) then return end
        local list=r.types or {}; local pages=math.max(1,math.ceil(#list/P.pageSize))
        r.typePage=math.max(1,math.min(pages,r.typePage or 1))
        local ready=H.installed(X.path(EL,'WB_TabButton','BndEvt__MyButton_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature'))
        for i,ui in ipairs(r.typeRows) do
            local entry=list[(r.typePage-1)*P.pageSize+i]
            ui.row:SetVisibility(entry and 0 or 1)
            local e=typeButtons[ui.button:GetAddress()]
            if not bound(e,ui.button) then return end
            e.path=entry and entry.path
            if entry then
                local distance=entry.distance<math.huge and string.format('%.0f UU',entry.distance) or 'unavailable'
                local state=entry.excluded and 'excluded' or (entry.eligible and 'eligible' or 'ineligible')
                local cls=entry.name
                if cls:match('^[BPSM]+_')or cls:find('/',1,true)then cls='Unavailable prop' end
                ui.text:SetText(FText(cls..'\n'..entry.copies..' copies; nearest '..distance..'; '..state))
                ui.text:SetToolTipText(FText(''))
                local label=entry.excluded and 'Include' or 'Exclude'
                ui.button.LabelText=FText(label); ui.button.Label:SetText(ui.button.LabelText)
                ui.button:SetIsEnabled(ready and (entry.eligible or entry.excluded))
            end
        end
        r.typeStatus:SetText(FText('Page '..r.typePage..'/'..pages..' · '..#list..' types'))
        r.typePrev:SetIsEnabled(ready and r.typePage>1); r.typeNext:SetIsEnabled(ready and r.typePage<pages)
    end
    function api.toggleType(w,path)
        local selected=targets(w); local r=panel(w)
        if #selected==0 or not r or r.typeSelection~=selectionKey(selected) then api.refresh(w,true); return false end
        local entry; for _,e in ipairs(r.types or {}) do if e.path==path then entry=e; break end end
        if not entry or (not entry.eligible and not entry.excluded) then return false end
        local a=selected[1]; local info=X.kind(a); local excluded={}
        for key in pairs(info.excluded or {}) do excluded[key]=true end
        if entry.excluded then
            excluded[path]=nil
            for _,key in ipairs(entry.exclusionPaths or {}) do excluded[key]=nil end
        else excluded[path]=true end
        local ok,err=pcall(X.exclusionPaths,excluded)
        if not ok then X.log('PropTypes',tostring(err));X.reply('PropTypes',FAPP_SERVICES.runtime.player_error(err)); return false end
        X.stamp(a,1,info.colour,info.authored,true,info.source,nil,nil,nil,nil,excluded)
        api.refresh(w,true); return true
    end
    local function wanted(r,report,actor)
        if not current(r) then return false end
        local selected=targets(r.widget)
        if #selected==0 or not X.same(selected[1],actor) then return false end
        local key=selectionKey(selected)
        for _,row in ipairs(report.pots) do
            if row.id==actor:GetAddress() and row.fullname==actor:GetFullName() then
                r.wanted:SetText(FText('Wanted props: '..row.count..'/'..report.minimum..' '..(row.ok and '✓' or '✗')))
                r.wantedCount=row.count
                if r.typeSelection~=key then r.typePage=1 end
                r.typeSelection=key; r.types=row.types; paintTypes(r)
                r.wantedSelection=key;r.wantedPending=nil;r.wantedActorKey=nil;r.wantedWorld=nil;r.wantedStatus='complete'
                return true
            end
        end
        r.wanted:SetText(FText('Wanted props: —/—'));r.wantedCount=nil;r.types={};r.typeSelection=nil
        paintTypes(r)
        r.wantedSelection=nil;r.wantedPending=key;r.wantedActorKey=X.Lifetime.key(actor)
        r.wantedWorld=X.Lifetime.worldKey(r.widget);r.wantedStatus='missing-row'
        return false
    end
    -- Console refreshes only the already visible panels in the checked world.
    function api.checked(report)
        for _,r in pairs(panels) do
            local selected=current(r) and targets(r.widget) or {}
            if #selected>0 then wanted(r,report,selected[1]) end
        end
    end
    function api.refresh(w,opened)
        if not X.live(w) or isClosed(w) then return end
        local old=panels[w:GetAddress()];local r=panel(w)
        if old and not r then release(old,false) end
        local selected=targets(w)
        local mounted=false
        if #selected>0 and not r then r=build(w);mounted=r~=nil end
        if r then
            r.root:SetVisibility(#selected>0 and 0 or 1) -- Collapsed, not Hidden

            if #selected==0 then r.wantedSelection=nil;r.wantedPending=nil;r.wantedActorKey=nil;r.wantedWorld=nil;r.wantedStatus='unselected' end
            if #selected>0 then
                local wantedKey=selectionKey(selected)
                local selectedInfo=X.kind(selected[1]);local cauldron=selectedInfo.kind==1
                r.wanted:SetVisibility(cauldron and 0 or 1);r.typeList:SetVisibility(cauldron and 0 or 1)
                r.label:SetText(FText(cauldron and 'Cauldron colour' or 'Teleporter colour'))
                r.lookGroup:SetVisibility(cauldron and 1 or 0)
                for i,b in ipairs(r.lookButtons)do
                    local on=not cauldron
                    for _,a in ipairs(selected)do on=on and X.kind(a).look==i-1 end
                    b:SetActiveState(on)
                end
                r.target.group:SetVisibility(cauldron and 0 or 1);r.seek.group:SetVisibility(cauldron and 0 or 1)
                for _,e in ipairs(r.depth)do e.group:SetVisibility(cauldron and 0 or 1)end
                if not cauldron then r.wantedPending=nil;r.wantedSelection=nil end
                if cauldron and X.Check and (mounted or opened~=false and (opened or r.wantedSelection~=wantedKey)) then
                    -- Mount consumes its current selection once, even when its
                    -- selection event preceded the panel. Later paints do not
                    -- retry a missing row or failed check.
                    r.wantedPending=wantedKey;r.wantedActorKey=X.Lifetime.key(selected[1])
                    r.wantedWorld=X.Lifetime.worldKey(w);r.wantedStatus='evaluating'
                    -- A new check supersedes the completed report even for
                    -- the same selection. An exception must leave it pending.
                    r.wantedSelection=nil
                    r.wanted:SetText(FText('Wanted props: —/—'));r.wantedCount=nil
                    r.types={};r.typeSelection=nil;paintTypes(r)
                    X.Check.invalidate(false)
                    local ok,report=pcall(X.Check.evaluate,w)
                    if not ok then r.wantedStatus='error';error(report) end
                    wanted(r,report,selected[1])
                end
                r.label:SetToolTipText(FText('Changes all selected markers. Match entrance and exit colours to pair teleporters.'))
                local info=X.kind(selected[1]); local c=info.colour
                if not c then
                    for _,p in ipairs(X.colours(w,X.markers(w))) do if X.same(p.actor,selected[1]) then c=p.colour; break end end
                end
                if c then
                    local signature=string.pack('<ffff',c.R,c.G,c.B,1)
                    local key=selectionKey(selected)
                    if not r.writing and (r.showcaseSignature~=signature or r.selection~=key) then
                        r.hsv=M.colourHSV(c,r.selection==key and r.hsv or nil)
                    end
                    r.selection=key
                    if r.showcaseSignature~=signature then
                        r.showcase.Color={X=c.R,Y=c.G,Z=c.B}; r.showcase.ItemData.Color=r.showcase.Color
                        assert(Swatches.colour(r.showcase,c))
                        r.showcase:SetButtonParameters();assert(Swatches.paint(r.showcase));r.showcaseSignature=signature
                    end
                end
                syncSliders(r)
                local inputReady=H.installed(X.path(EL,SLIDER,COMMIT_EVENT))
                local ready=H.installed(X.path(EL,SLIDER,VALUE_EVENT)) and H.installed(X.path(EL,SLIDER,'ChangeRealValue'))
                    and H.installed(X.path(EL,SLIDER,COMMIT_EVENT))
                for _,e in ipairs(r.sliders) do
                    e.widget:SetIsEnabled(ready)
                    -- Native SetRealValue shows reset again. Auto is the only reset here.
                    e.widget.ResetButton:SetVisibility(1); e.widget.DefaultValueIndicator:SetVisibility(1)
                end
                if cauldron then
                local pots=X.markers(w); local target=X.mapTarget(w,pots); local control=r.target.widget
                local coefficient=X.seekCoefficient(w,pots);local was=r.syncing;r.syncing=true
                if r.seek.widget.RealValue~=coefficient then r.seek.widget:SetRealValue(coefficient)end
                r.seek.widget:SetIsEnabled(inputReady);r.seek.widget.ResetButton:SetVisibility(1);r.seek.widget.DefaultValueIndicator:SetVisibility(1);r.syncing=was
                local max=math.max(1,#pots); local changed=control.MaximumValue~=max
                control.MaximumValue=max; r.target.spec.max=max
                local was=r.syncing; r.syncing=true
                if changed or control.RealValue~=target then control:SetRealValue(target) end
                r.syncing=was
                control:SetIsEnabled(inputReady); control.ResetButton:SetVisibility(1); control.DefaultValueIndicator:SetVisibility(1)
                local was=r.syncing; r.syncing=true
                for _,e in ipairs(r.depth) do
                    local value=info[e.spec.key]
                    if e.widget.RealValue~=value then e.widget:SetRealValue(value) end
                    e.widget:SetIsEnabled(inputReady)
                    e.widget.ResetButton:SetVisibility(1); e.widget.DefaultValueIndicator:SetVisibility(1)
                end
                r.syncing=was
                end
                for _,choice in ipairs(r.choices) do
                    local path=choice.index==0 and X.path('/Game/UserInterface/UIElements/','WB_TabButton',
                        'BndEvt__MyButton_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature') or
                        X.path(TILES,'WB_LightColorButton','Clicked')
                    choice.widget:SetIsEnabled(H.installed(path))
                    local on=true
                    for _,a in ipairs(selected) do
                        local info=X.kind(a); local c=M.SWATCHES[choice.index]
                        if choice.index==0 then on=on and info.source~='marker'
                        else on=on and info.source=='marker' and math.abs(info.colour.R-c.R)<1e-6
                            and math.abs(info.colour.G-c.G)<1e-6 and math.abs(info.colour.B-c.B)<1e-6 end
                    end
                    if choice.data then
                        choice.data.IsSelected=on
                        local grid=X.read(choice.widget,'GridButton'); if H.valid(grid) then grid.bSelected=on end
                    else choice.widget:SetActiveState(on) end
                end
                logGeometry(r)
            end
        end
    end
    function api.chooseColour(w,c,label,quiet)
        if not X.live(w) or isClosed(w) then return false end
        local r=panel(w)
        if panels[w:GetAddress()] and not r then return false end
        local selected=targets(w); if #selected==0 then return false end
        if c then c=assert(X.colour(c),'invalid cauldron colour') end
        for _,a in ipairs(selected) do
            if r and not current(r) then return false end
            local kind=X.kind(a).kind
            local colour=c or (kind>=3 and X.nextTeleporterColour(w,kind,a)or nil)
            local look=kind>=3 and X.inheritedTeleporterLook(w,colour,a,X.kind(a).look)or nil
            X.stamp(a,kind,colour,c~=nil,true,c and 'marker' or 'auto',nil,nil,nil,nil,nil,nil,nil,look)
        end
        local pots=X.colours(w,X.markers(w)); local picked={}
        for _,a in ipairs(selected) do picked[a:GetAddress()]=true end
        for _,p in ipairs(pots) do if picked[p.id] then
            X.stamp(p.actor,1,p.colour,p.authored,true,p.source)
            X.guard('ColourPreview',api.tint)(p.actor,p.colour)
        end end
        if not quiet then X.log('ColourEdit','host applied '..(label or (c and 'custom colour' or 'Auto'))..' to '..#selected..' selected markers; saved RGBA, map target preserved') end
        api.refresh(w); return true
    end
    function api.chooseLook(w,look)
        assert(type(look)=='number' and look%1==0 and M.LOOKS[look+1],'invalid teleporter look')
        local selected=targets(w);local keys={}
        for _,a in ipairs(selected)do local info=X.kind(a);if info and info.kind>=3 then keys[X.TeleporterPairs.key(info.colour)]=true end end
        if not next(keys)then return false end
        local _,_,entrances,exits=X.markers(w);local count=0
        for _,list in ipairs({entrances,exits})do for _,p in ipairs(list)do
            if keys[X.TeleporterPairs.key(p.info.colour)]then
                local info=p.info;X.stamp(p.actor,info.kind,info.colour,info.authored,true,info.source,nil,nil,nil,nil,nil,nil,nil,look);count=count+1
            end
        end end
        X.log('TeleporterLook','host chose '..M.LOOKS[look+1]..' for '..count..' endpoint(s)')
        api.refresh(w);return true
    end
    function api.choose(w,index)
        assert(index==0 or M.SWATCHES[index],'unknown cauldron swatch')
        return api.chooseColour(w,index~=0 and M.SWATCHES[index] or nil,index~=0 and M.SWATCHES[index].name or 'Auto')
    end
    local function clicked(self)
        local w=self:get();if not X.live(w) then return end
        local t=typeButtons[w:GetAddress()]
        if bound(t,w) then
            local selected=targets(t.panel.widget)
            if #selected==0 or (t.action~='look' and t.panel.typeSelection~=selectionKey(selected)) then api.refresh(t.panel.widget,true); return end
            if t.action=='look' then api.chooseLook(t.panel.widget,t.look)
            elseif t.action=='toggle' then api.toggleType(t.panel.widget,t.path)
            else t.panel.typePage=t.panel.typePage+t.action; paintTypes(t.panel) end
            return
        end
        local r=buttons[w:GetAddress()]
        if bound(r,w) and (not r.dataIdentity or matches(X.read(w,'ItemData'),r.dataIdentity)
            and matches(X.read(w,'ParentWidget'),r.panel.identity)
            and matches(X.read(X.read(w,'ItemData'),'Parent'),r.panel.identity)) then
            local selected=targets(r.panel.widget)
            if #selected==0 or r.panel.selection~=selectionKey(selected) then api.refresh(r.panel.widget);return end
            api.choose(r.panel.widget,r.index)
        end
    end
    local function sliderEntry(self)
        local w=self:get();if not X.live(w) then return end
        local e=sliders[w:GetAddress()]
        if bound(e,w) and not e.panel.syncing then return e end
    end
    local function editSlider(e,value)
        if e.spec.key=='SEEK'then return api.editSeek(e.panel.widget,value)end
        if e.spec.key=='WIN' then return api.editTarget(e.panel.widget,value) end
        if e.spec.key=='decalDown' or e.spec.key=='decalUp' then return api.editDepth(e.panel.widget,e.spec.key,value) end
        return api.editHSV(e.panel.widget,e.spec.key,value)
    end
    -- Separate intent hooks avoid saving native text-commit intermediates. The
    -- normalized event also handles the native IgnoreSliderChange first-drag skip.
    X.hook('ColourPicker',EL,SLIDER,VALUE_EVENT,function(self,value)
        local e=sliderEntry(self); if not e then return end
        local v=value:get()
        if e.spec.factor and type(v)=='number' then editSlider(e,v*e.spec.max) end
    end)
    X.hook('ColourPicker',EL,SLIDER,'ChangeRealValue',function(self)
        local e=sliderEntry(self); if e and e.spec.factor then editSlider(e,e.widget.RealValue) end
    end)
    X.hook('ColourPicker',EL,SLIDER,COMMIT_EVENT,function(self,text)
        local e=sliderEntry(self); if not e then return end
        local raw=X.text(text:get()):match('^%s*(.-)%s*$')
        -- The native numeric fields are not a hex picker: allow an optional unit.
        raw=raw:gsub('%%$',''):gsub('°$',''):gsub('%s*[Uu][Uu]$','')
        local v=tonumber(raw)
        if not editSlider(e,v) then
            api.refresh(e.panel.widget)
        end
    end)
    function api.header(w)
        if not X.live(w) or not C.CreativeMaps then return end
        local function reset()
            local old=headers[w:GetAddress()]
            if old and matches(w,old.identity) and X.text(w.TargetName:GetText())==old.ours then w.TargetName:SetText(FText(old.original)) end
            headers[w:GetAddress()]=nil
        end
        local pc=X.read(w,'OwningCreativePlayerController'); local actor=X.read(w,'TargetActor'); local info=X.kind(actor)
        if not info or X.read(actor,'IsPreview')==true or not X.live(pc) or not H.authority(pc) or not creative(pc,true) then reset(); return end
        local count=1
        if w.IsHeader and pc.MultipleSelected then
            count=0
            for _,a in ipairs(X.values(pc.SelectedActors)) do local i=X.kind(a); if not i or i.kind~=info.kind then reset(); return end; count=count+1 end
            if count==0 then reset(); return end
        end
        local label=need(w.TargetName,'target header name'); local text=X.NAMES[info.kind]..(count>1 and ' ('..count..')' or '')
        local current=X.text(label:GetText()); local old=headers[w:GetAddress()]
        if old and not matches(w,old.identity) then old=nil end
        local original=old and current==old.ours and old.original or current
        headers[w:GetAddress()]={widget=w,identity=assert(identity(w)),original=original,ours=text}
        if current~=text then label:SetText(FText(text)) end; X.once('header:'..w:GetAddress(),'ColourUI','marker header uses '..X.NAMES[info.kind])
    end
    X.hook('ColourUI',TABS,'WB_TargetActorDisplay','UpdateName',function(self) api.header(self:get()) end)
    X.hook('ColourUI',TABS,'WB_WorldSettingsTab','UpdateWorldsettingsTabContent',function(self) api.refresh(self:get()) end)
    X.hook('ColourUI',TABS,'WB_WorldSettingsTab','UpdateContentTabsVisibility',function(self) api.refresh(self:get(),true) end)
    X.hook('ColourUI',EDIT,'WB_PlaceAndEditUI','UpdateNonCollapsedUI',function(self)
        local w=self:get(); if H.valid(w.WorldSettingsTab) then api.refresh(w.WorldSettingsTab) end
    end)
    for _,fn in ipairs({'OpenEditUi','ChangePlayerMode','OpenTabScreen'}) do
        X.hook('ColourUI',X.CREATIVE,'B_CreativePlayerController',fn,function(self)
            local pc=self:get(); local ui=X.read(pc,'EditUI')
            if H.valid(ui) and H.valid(ui.WorldSettingsTab) then api.refresh(ui.WorldSettingsTab,true) end
        end)
    end
    -- A completed registration is an explicit producer, even for static
    -- marker carriers outside the filtered B_StaticMeshProp onChange lane.
    -- The observer retains scalar identity; queued work belongs to the panel.
    watchWanted=function()
        if wantedObserver then return end
        wantedObserver=X.Registry.onCommitted(function(actorKey,world,epoch,revision)
            if X.Lifetime.transition or epoch~=X.Lifetime.epoch then return end
            for _,r in pairs(panels) do
                if r.active and r.identity.epoch==epoch and r.wantedPending
                    and r.wantedActorKey==actorKey and r.wantedWorld==world then
                    r.wantedArrivalKey=actorKey;r.wantedArrivalRevision=revision
                    if not r.wantedJob then
                        -- A real arrival during this action may own a successor.
                        -- Never reuse the still-active Core key or overwrite its
                        -- successor latch when the preceding action completes.
                        wantedJobs=wantedJobs+1
                        local job='ColourUI/wanted-ready:'..epoch..':'..r.identity.address..':'..wantedJobs
                        local accepted=X.Work.submit(job,'ColourUI/wanted-ready',function()
                            if r.wantedJob==job then r.wantedJob=nil end
                            local arrived=r.wantedArrivalKey;r.wantedArrivalKey=nil
                            if current(r) then
                                local selected=targets(r.widget)
                                local key=#selected>0 and selectionKey(selected) or nil
                                if key==r.wantedPending and r.wantedActorKey==arrived then
                                    X.guard('ColourUI/wanted-ready',api.refresh)(r.widget,true)
                                end
                            end
                            return true
                        end)
                        if accepted then r.wantedJob=job end
                    end
                end
            end
        end)
    end
    -- Selection changes are real producers; repeated paints never re-evaluate.
    for _,fn in ipairs({'SelectActor','SelectMultiple','DeselectSingleActor','DeselectMultipleActors'}) do
        X.hook('ColourUI/selection',X.CREATIVE,'B_CreativePlayerController',fn,function(self)
            local pc=self:get();local ui=X.read(pc,'EditUI');local w=H.valid(ui) and X.read(ui,'WorldSettingsTab')
            if not H.valid(w) then return end
            local r=panel(w);if not r then return end
            local selected=targets(w);local key=#selected>0 and selectionKey(selected) or nil
            if r.wantedSelection~=key then api.refresh(w,true) end
        end)
    end
    H.hook('/Script/UMG.UserWidget:Destruct',X.guard('ColourUI/teardown',function(self)
        local w=self:get();if not X.live(w) then return end
        local r=panels[w:GetAddress()]
        if r and not matches(w,r.identity) then return end
        if H.class(w,'WB_WorldSettingsTab_C') then closed[w:GetAddress()]=identity(w) end
        if r then release(r,true) end
        local h=headers[w:GetAddress()]
        if h and matches(w,h.identity) then headers[w:GetAddress()]=nil end
    end))
    -- This is the actual inherited Blueprint Construct, declared by the base
    -- tab. A detached but still valid UObject cannot reopen itself via polling.
    H.hook(X.path(TABS,'WB_PlaceAndEditUITab','Construct'),X.guard('ColourUI/reopen',function(self)
        local w=self:get();if not X.live(w) or not H.class(w,'WB_WorldSettingsTab_C') or not isClosed(w) then return end
        closed[w:GetAddress()]=nil;api.refresh(w,true)
    end))
    X.hook('ColourEdit',TILES,'WB_LightColorButton','Clicked',clicked)
    X.hook('ColourEdit','/Game/UserInterface/UIElements/','WB_TabButton',
        'BndEvt__MyButton_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature',clicked)
    function api.poll()
        for id,r in pairs(panels) do
            if not current(r) then release(r,false) else X.guard('ColourUI/selection',api.refresh)(r.widget,false) end
        end
        for id,r in pairs(typeButtons) do if not X.live(r.widget) or not X.live(r.panel.widget) then typeButtons[id]=nil end end
        for id,r in pairs(buttons) do if not X.live(r.widget) or not X.live(r.panel.widget) then buttons[id]=nil end end
        for id,e in pairs(sliders) do if not X.live(e.widget) or not X.live(e.panel.widget) then sliders[id]=nil end end
        for _,w in ipairs(X.findAll('WB_WorldSettingsTab_C')) do X.guard('ColourUI/discovery',api.refresh)(w,false) end
        for _,w in ipairs(X.findAll('WB_TargetActorDisplay_C')) do X.guard('ColourUI/header',api.header)(w) end
        for id,r in pairs(headers) do
            if not X.live(r.widget) then headers[id]=nil
            elseif not C.CreativeMaps or not creative(r.widget,false) then
                if X.text(r.widget.TargetName:GetText())==r.ours then r.widget.TargetName:SetText(FText(r.original)) end
                headers[id]=nil
            end
        end
        for _,a in ipairs(X.findAll('BP_WitchCauldron_C')) do X.guard('ColourPreview',api.tint)(a) end
        for id,r in pairs(tints) do
            if tintObsolete(id,r) then
                if tints[id]==r then tints[id]=nil end
            elseif not r.cleanup_pending then
                if not X.live(r.actor) then tints[id]=nil
                elseif not C.CreativeMaps or not presentation(r.actor) then releaseTintRecord(id,r) end
            end
        end
    end
    X.Colour=api
    X.log('ColourUI','module ready; direct marker colour > nearest legacy light within 300 UU > auto')
    function api.reset()
        if wantedObserver then wantedObserver();wantedObserver=nil end
        for _,r in pairs(panels) do
            r.active=false
            if r.wantedJob then X.Work.cancel(r.wantedJob);r.wantedJob=nil end
        end
        Swatches.reset();panels={};closed={};buttons={};typeButtons={};tints={};sliders={};headers={}
    end
    X.cachedPoll(api,nil)
    X.Lifetime.onReset(function() api.reset() end)
    return api
end
return M
