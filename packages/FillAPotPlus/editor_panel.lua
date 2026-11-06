-- Creative presentation from maps_colour/maps_swatch_renderer, on the current marker codec.
return function(S)
    local R,C,U=S.R,S.C,S.U
    local edit=S.CR..'PlacementAndEditUI/'
    local tabs,tiles,el=edit..'Tabs/',edit..'TileAndListviews/','/Game/UserInterface/UIElements/'
    local panel,actions,swatches,grids=nil,{},{},{}
    local names={'Purple','Yellow','Blue','Green','Red','Pink','White'}
    local looks={'None','Island portal','Tower pad','Doorway','Colored rune'}
    local function clear()
        actions,swatches,grids={},{},{}
        if panel then
            if R.valid(panel.root) then panel.root:RemoveFromParent() end
            panel=nil
        end
    end
    local function paintSwatch(tile)
        local row=swatches[tile:GetAddress()]
        if not row then return end
        local grid=tile.GridButton
        grids[grid:GetAddress()]=tile
        local icon=grid.Icon
        local size={X=icon.Brush.ImageSize.X,Y=icon.Brush.ImageSize.Y}
        icon:SetBrush(S.asset('/Script/UMG.Default__Image').Brush)
        icon.Brush.ImageSize.X=size.X;icon.Brush.ImageSize.Y=size.Y
        icon:SetDesiredSizeOverride(size)
        for _,widget in ipairs({tile,grid,grid.Button}) do widget:SetColorAndOpacity({R=1,G=1,B=1,A=1}) end
        icon:SetColorAndOpacity(row.colour)
    end
    local function build(w)
        clear()
        local selected={}
        for _,actor in ipairs(S.values(w:GetOwningPlayer().SelectedActors)) do
            if R.valid(actor) then
                local info=S.marker(actor)
                if not info then return end
                selected[#selected+1]={actor=actor,info=info}
            end
        end
        if #selected==0 then return end
        local first=selected[1].info
        for _,row in ipairs(selected) do if row.info.kind~=first.kind then return end end
        local host=S.host()
        local function native(kind,parent)
            local widget=StaticConstructObject(S.asset('/Script/UMG.'..kind),w.WidgetTree)
            if parent then parent:AddChild(widget) end
            return widget
        end
        local function cooked(folder,name,parent)
            local widget=StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary'):Create(w,
                S.asset(S.path(folder,name)),w:GetOwningPlayer())
            parent:AddChild(widget);return widget
        end
        local function box(parent,width,height)
            local widget=native('SizeBox',parent)
            widget:SetWidthOverride(width);widget:SetHeightOverride(height)
            return widget
        end
        local function auto(parent,child)
            local slot=parent:AddChild(child)
            slot:SetSize({Value=1,SizeRule=0});slot:SetVerticalAlignment(1)
        end
        local function space(parent,width) auto(parent,box(nil,width,1)) end
        local function text(parent,value,size)
            local widget=native('TextBlock',parent)
            local font=widget.Font;font.Size=size or 14;widget:SetFont(font)
            widget:SetText(FText(value));return widget
        end
        local root=native('VerticalBox',w.TransformBox:GetParent())
        panel={widget=w,root=root}
        local sliders,choices={},{}
        local hsv=S.calc.colourHSV(first.colour)
        local showcase,wanted,paintTypes
        local function swatch(tile,colour,index)
            local data=S.new(S.path(tiles,'B_LightColorButtonData'),w)
            data.Color={X=colour.R,Y=colour.G,Z=colour.B};data.Parent=w
            data.IsInitial=false;data.IsSelected=false
            tile.ItemData=data;tile.ParentWidget=w;tile.Color=data.Color
            tile.bIsFocusable=index~=nil;tile:SetIsEnabled(host or index==nil)
            swatches[tile:GetAddress()]={colour=colour}
            tile:SetButtonParameters();paintSwatch(tile)
            if index then choices[#choices+1]={widget=tile,index=index} end
        end
        local function sync()
            for _,row in ipairs(sliders) do row.set(row.read()) end
            if showcase then
                local tile=showcase
                local colour=first.colour
                tile.Color={X=colour.R,Y=colour.G,Z=colour.B};tile.ItemData.Color=tile.Color
                swatches[tile:GetAddress()].colour=colour
                tile:SetButtonParameters();paintSwatch(tile)
                for _,choice in ipairs(choices) do
                    local on=true
                    for _,row in ipairs(selected) do
                        local c=choice.index>0 and S.codec.palette[choice.index]
                        if c then
                            on=on and row.info.source~=0 and math.abs(row.info.colour.R-c.R)<1e-6
                                and math.abs(row.info.colour.G-c.G)<1e-6 and math.abs(row.info.colour.B-c.B)<1e-6
                        else on=on and row.info.source==0 end
                    end
                    if choice.index>0 then
                        choice.widget.ItemData.IsSelected=on;choice.widget.GridButton.bSelected=on
                    else choice.widget:SetActiveState(on) end
                end
            end
            if paintTypes then paintTypes() end
        end
        local function change(key,value)
            for _,row in ipairs(selected) do
                if key=='colour' and row.info.kind==1 then row.info.source=1 end
                row.info[key]=value;S.stamp(row.actor,row.info);S.markerLook(row.actor,row.info)
            end
        end
        local function button(parent,label,width,click)
            local frame=box(parent,width,36)
            local scale=native('ScaleBox',frame);scale:SetStretch(2);scale:SetStretchDirection(1)
            local widget=cooked(el,'WB_TabButton',scale)
            widget.LabelText=FText(label);widget.Label:SetText(widget.LabelText)
            widget:SetActiveState(false);widget:SetIsEnabled(host);widget.bIsFocusable=true
            actions[widget:GetAddress()]={click=click}
            return widget
        end
        local function numericLayout(control,withTrack,withReset)
            local label=control.DescriptiveLabelText
            local labelScale=label:GetParent();local grid=labelScale:GetParent()
            local extras={}
            for _,child in ipairs(S.values(grid:GetAllChildren())) do extras[S.text(child:GetFName())]=child end
            grid:ClearChildren()
            for col=0,3 do grid:SetColumnFill(col,0) end
            local frame=box(nil,446,40);local slot=grid:AddChildToGrid(frame,0,0)
            slot:SetHorizontalAlignment(1);slot:SetVerticalAlignment(1)
            local row=native('HorizontalBox',frame)
            local labelBox=box(nil,withTrack and (withReset and 148 or 180) or 298,32);auto(row,labelBox);labelBox:AddChild(labelScale)
            label:SetJustification(2);labelScale:SetStretch(2);labelScale:SetStretchDirection(1)
            space(row,8)
            for _,child in ipairs({extras.ValueFill,control.DefaultValueIndicator}) do
                child:SetVisibility(1);grid:AddChildToGrid(child,0,2)
            end
            if withTrack then
                local track=box(nil,110,32);auto(row,track);track:AddChild(control.ValueSlider);space(row,8)
            else
                control.ValueSlider:SetVisibility(1);control.ValueSlider:SetIsEnabled(false)
                grid:AddChildToGrid(control.ValueSlider,0,2)
            end
            local input=box(nil,140,32);input:SetMinDesiredWidth(140);auto(row,input)
            local overlay=native('Overlay',input)
            extras.ValueText:SetVisibility(1)
            for _,child in ipairs({control.InputField,extras.ValueText,extras.ValueFocusButton}) do
                local childSlot=overlay:AddChild(child);childSlot:SetHorizontalAlignment(0);childSlot:SetVerticalAlignment(1)
            end
            local reset=control.ResetButton:GetParent()
            if withReset then
                space(row,4);auto(row,reset)
            else
                reset:SetVisibility(1);grid:AddChildToGrid(reset,0,1)
            end
        end
        -- default: the value the native reset arrow restores; without one the arrow is hidden.
        local function slider(parent,label,lo,hi,step,suffix,read,write,layout,default)
            local frame=box(parent,446,40)
            frame.Slot:SetHorizontalAlignment(2);frame.Slot:SetVerticalAlignment(1)
            frame.Slot:SetPadding({Left=10,Right=10,Top=0,Bottom=0})
            local widget=cooked(el,'WB_SliderWithEditableLabel',frame)
            widget.DescriptiveLabel=FText(label);widget.DescriptiveLabelText:SetText(widget.DescriptiveLabel)
            widget.MinimumValue=lo;widget.MaximumValue=hi;widget.StepSize=step
            widget.bRoundToIntegers=step>=1;widget.bTimeValueInSeconds=false;widget.UIMultiplyFactor=1
            widget.ValueSuffix=FText(suffix);widget.DefaultFloatValue=default or read()
            widget.bIsFocusable=true;widget:SetIsEnabled(host)
            if layout then
                local font=widget.DescriptiveLabelText.Font;font.Size=14;widget.DescriptiveLabelText:SetFont(font)
                widget.TextFocusColor=widget.TextColor;widget:ChangeTextColor(widget.TextColor)
                numericLayout(widget,layout=='radius',default~=nil)
            end
            local record={}
            local function set(value)
                record.value=value;record.painting=true;widget:SetRealValue(value)
                if default then widget:CheckDefaultToUpdateUI()
                else widget.ResetButton:SetVisibility(1);widget.DefaultValueIndicator:SetVisibility(1) end
                record.painting=false
            end
            record.edit=function(value)
                value=tonumber((S.text(value):gsub('%s*[%a°%%]+%s*$','')))
                if not value or value~=value or math.abs(value)==math.huge then set(record.value);return end
                value=math.max(lo,math.min(hi,value))
                if step>=1 then value=math.floor(value/step+.5)*step end
                if value~=record.value then write(value);sync() end
            end
            record.slide=function(value) record.edit(tostring(lo+(hi-lo)*value)) end
            record.drag=function() record.edit(tostring(widget.RealValue)) end
            record.reset=function() record.edit(tostring(default)) end
            actions[widget:GetAddress()]=record;sliders[#sliders+1]={set=set,read=read};set(read())
            return widget
        end
        local function number(parent,key,label,lo,hi,step,suffix,layout,default)
            return slider(parent,label,lo,hi,step,suffix or '',function() return first[key] end,
                function(value) change(key,value) end,layout or 'number',default)
        end
        local content=root
        if first.kind==1 or first.kind>=3 then
            local tab=cooked(tabs,'WB_LightColorTab',root)
            for _,child in ipairs(S.values(tab.WidgetTree.RootWidget:GetAllChildren())) do
                if S.text(child:GetFName())=='TextBlock_38' then child:SetText(FText(first.kind==1 and 'Cauldron colour' or 'Teleporter colour')) end
            end
            for _,field in ipairs({'BrightnessBox','SpotLightAngleBox','WB_CastShadowsCheckboxAreaButton',
                'WB_DirectionalLightCheckboxAreaButton','LightGroupPreviewInfo'}) do tab[field]:SetVisibility(1) end
            showcase=tab.ShowcaseColorButton;swatch(showcase,first.colour)
            content=tab.ColorShowcaseBox:GetParent()
            if first.kind==1 then wanted=text(content,'Wanted props: —/—');wanted.Slot:SetHorizontalAlignment(2) end
            local row=native('HorizontalBox',content)
            row.Slot:SetHorizontalAlignment(2);row.Slot:SetPadding({Left=10,Right=10,Top=0,Bottom=0})
            for index=1,7 do
                local frame=box(nil,40,36);auto(row,frame)
                local scale=native('ScaleBox',frame);scale:SetStretch(2);scale:SetStretchDirection(1)
                local tile=cooked(tiles,'WB_LightColorButton',scale)
                swatch(tile,S.codec.palette[index],index);tile:SetToolTipText(FText(names[index]))
                actions[tile:GetAddress()]={click=function()
                    change('colour',S.codec.palette[index]);hsv=S.calc.colourHSV(first.colour);sync()
                end}
            end
            space(row,102)
            local autoButton=button(row,'Auto',64,function()
                change('source',0);hsv=S.calc.colourHSV(first.colour);sync()
            end)
            choices[#choices+1]={widget=autoButton,index=0}
            for i,choice in ipairs(choices) do
                if i>1 then choice.widget:SetNavigationRuleExplicit(0,choices[i-1].widget) end
                if i<#choices then choice.widget:SetNavigationRuleExplicit(1,choices[i+1].widget) end
            end
            if first.kind>=3 then
            local pair=text(content,'Teleporter number: '..first.pairId);pair.Slot:SetHorizontalAlignment(2)
            for _,spec in ipairs({{'−',-1},{'+',1}}) do
                button(content,spec[1],446,function()
                    change('pairId',math.max(1,math.min(4294967295,first.pairId+spec[2])))
                    pair:SetText(FText('Teleporter number: '..first.pairId))
                end)
            end
            local check=cooked(el,'WB_CheckBoxWithEditableLabel',box(content,446,36))
            check.DescriptiveLabel=FText('Two-way');check.DescriptiveLabelText:SetText(check.DescriptiveLabel)
            check:SetIsCheckedWithoutEvent(first.twoWay);check:SetIsEnabled(host)
            actions[check:GetAddress()]={check=function()
                local value=check.CheckBox:IsChecked()
                if value==first.twoWay then return end
                change('twoWay',value)
                -- Both ends of a pair share the setting.
                for _,row in ipairs(S.markers()) do
                    if row.info.kind>=3 and row.info.pairId==first.pairId and row.info.twoWay~=value then
                        row.info.twoWay=value;S.stamp(row.actor,row.info);S.markerLook(row.actor,row.info)
                    end
                end
            end}
            local look=cooked(el,'WB_ComboBoxWithLabel',box(content,446,40))
            look.DescriptiveLabel=FText('Look');look.DescriptiveLabelText:SetText(look.DescriptiveLabel)
            look.Options:Empty()
            for index,label in ipairs(looks) do look.Options[index]=FText(label) end
            look:SetOptionIndex(first.look);look:SetIsEnabled(host)
            -- The native row keeps a third of its width empty and pads the combo; the dropdown follows the combo.
            local combo=look.ComboboxSizeSwitcher;local grid=combo:GetParent()
            grid:SetColumnFill(0,.35);grid:SetColumnFill(1,.65);grid:SetColumnFill(2,0)
            combo.Slot:SetPadding({Left=8,Right=0,Top=0,Bottom=0})
            actions[look:GetAddress()]={select=function()
                if look.SelectedOptionIndex~=first.look then change('look',look.SelectedOptionIndex) end
            end}
            end
            for _,spec in ipairs({{'H','Hue',360,1,'°'},{'S','Saturation',100,100,'%'},{'V','Value',100,100,'%'}}) do
                local key,label,max,factor,suffix=table.unpack(spec)
                slider(content,label,0,max,.1,suffix,function() return hsv[key]*factor end,function(value)
                    hsv[key]=value/factor;change('colour',S.calc.hsvColour(hsv.H,hsv.S,hsv.V))
                end,'radius')
            end
        end
        if first.kind==1 then
            number(content,'down','Rune depth below',0,2000,1,' UU');number(content,'up','Rune height above',0,2000,1,' UU')
            local pots=0;for _,row in ipairs(S.markers()) do if row.info.kind==1 then pots=pots+1 end end
            slider(content,'Cauldrons to win',1,math.max(1,pots),1,'',function() return first.target end,function(value)
                local rows=S.markers();local revision=os.time()*1000
                for _,row in ipairs(rows) do revision=math.max(revision,row.info.revision+1) end
                for _,row in ipairs(rows) do if row.info.kind==1 then
                    row.info.target=value;row.info.revision=revision;S.stamp(row.actor,row.info)
                end end
                for _,row in ipairs(selected) do row.info.target=value;row.info.revision=revision end
            end,'number')
            local groups=S.propGroups();local sorted={}
            for _,group in pairs(groups) do sorted[#sorted+1]=group end
            table.sort(sorted,function(a,b) return a.name==b.name and a.path<b.path or a.name<b.name end)
            -- Wanted props, apart from the colour: a line, the exclusion radius, then the kinds.
            local list=native('VerticalBox',root)
            local line=box(list,446,2)
            native('Image',line):SetColorAndOpacity({R=1,G=1,B=1,A=.25})
            text(list,'Wanted props')
            number(list,'radius','Prop exclusion radius',0,10000,100,' UU','radius',2500)
            local page,typeRows=1,{}
            for i=1,4 do
                local row=native('HorizontalBox',list)
                local scale=native('ScaleBox',box(row,358,40));scale:SetStretch(2);scale:SetStretchDirection(1)
                local label=text(scale,'',12)
                local toggle=button(row,'Exclude',88,function()
                    local group=sorted[(page-1)*4+i]
                    if not first.excluded[group.path] then
                        local count=0;for _ in pairs(first.excluded) do count=count+1 end
                        if count==64 then U.message('Excluded props','Choose up to 64 prop kinds.');return end
                    end
                    first.excluded[group.path]=not first.excluded[group.path] or nil
                    S.stamp(selected[1].actor,first);sync()
                end)
                typeRows[i]={row=row,label=label,button=toggle}
            end
            local nav=native('HorizontalBox',list)
            local previous=button(nav,'Previous',100,function() page=page-1;paintTypes() end)
            local status=text(box(nav,246,36),'',12)
            local nextButton=button(nav,'Next',100,function() page=page+1;paintTypes() end)
            paintTypes=function()
                local pool=S.eligible({info=first,position=selected[1].actor:K2_GetActorLocation()},groups)
                local eligible={};for _,group in ipairs(pool) do eligible[group.path]=true end
                wanted:SetText(FText('Wanted props: '..#pool..'/'..(pots+1)..' '..(#pool>=pots+1 and '✓' or '✗')))
                for i,row in ipairs(typeRows) do
                    local group=sorted[(page-1)*4+i];row.row:SetVisibility(group and 0 or 1)
                    if group then
                        local distance=math.huge
                        for _,prop in ipairs(group.props) do distance=math.min(distance,S.distance(selected[1].actor:K2_GetActorLocation(),prop.position)^.5) end
                        local excluded=first.excluded[group.path]==true
                        row.label:SetText(FText((group.path:match('%.(.+)$') or group.name)..'\n'..#group.props..' copies; nearest '..string.format('%.0f UU',distance)..'; '
                            ..(excluded and 'excluded' or eligible[group.path] and 'eligible' or 'ineligible')))
                        row.label:SetToolTipText(FText(group.path..'\n'..group.name))
                        row.button.LabelText=FText(excluded and 'Include' or 'Exclude');row.button.Label:SetText(row.button.LabelText)
                        row.button:SetIsEnabled(host and (excluded or eligible[group.path]==true))
                    end
                end
                local pages=math.max(1,math.ceil(#sorted/4))
                status:SetText(FText('Page '..page..'/'..pages..' · '..#sorted..' types'))
                previous:SetIsEnabled(host and page>1);nextButton:SetIsEnabled(host and page<pages)
            end
        end
        button(root,'Check map problems',200,function()
            U.message('Map check',S.mapExplanation())
        end)
        sync()
    end
    local function hook(folder,name,event,action,resolve)
        S.onEditorHost.post(S.path(folder,name,event),function(widget,...)
            if resolve then widget=resolve(widget) end
            local record=actions[widget:GetAddress()]
            if record and not record.painting then record[action](...) end
        end)
    end
    hook(tiles,'WB_LightColorButton','Clicked','click')
    hook(el,'WB_TabButton','BndEvt__MyButton_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature','click')
    hook(el,'WB_SliderWithEditableLabel','ChangeRealValue','drag')
    hook(el,'WB_SliderWithEditableLabel','BndEvt__WB_SliderWithEditableLabel_ResetButton_K2Node_ComponentBoundEvent_1_OnButtonClickedEvent__DelegateSignature','reset')
    hook(el,'WB_SliderWithEditableLabel','BndEvt__ValueSlider_K2Node_ComponentBoundEvent_0_OnFloatValueChangedEvent__DelegateSignature','slide')
    hook(el,'WB_SliderWithEditableLabel','BndEvt__WB_SliderWithEditableLabel_InputField_K2Node_ComponentBoundEvent_3_OnEditableTextBoxCommittedEvent__DelegateSignature','edit')
    hook(el,'WB_CheckBoxWithLabel','SetIsChecked','check')
    hook(el,'WB_CheckBoxWithLabel','BndEvt__CheckBox_K2Node_ComponentBoundEvent_0_OnCheckBoxComponentStateChanged__DelegateSignature','check')
    hook(el,'WB_CheckBoxWithEditableLabel','SetIsChecked','check')
    hook(el,'WB_CheckBoxWithEditableLabel','BndEvt__CheckBox_K2Node_ComponentBoundEvent_0_OnCheckBoxComponentStateChanged__DelegateSignature','check')
    hook(el,'WB_ComboBoxOverlay','SetOption','select',function(overlay) return overlay.BaseWidget end)
    R.post(S.path(el..'MenuTileView/','WB_TileViewButton','SetButtonParameters'),paintSwatch)
    R.post(S.path(el,'WB_GridButton','SetIconImage'),function(grid)
        local tile=grids[grid:GetAddress()];if tile then paintSwatch(tile) end
    end)
    S.onEditor.post(S.path(tabs,'WB_TargetActorDisplay','UpdateName'),function(widget)
        if not R.valid(widget.TargetActor) then return end
        local info=S.marker(widget.TargetActor)
        if not info or widget.TargetActor.IsPreview then return end
        local count=0
        for _,actor in ipairs(S.values(widget.OwningCreativePlayerController.SelectedActors)) do
            if not R.valid(actor) then return end
            local other=S.marker(actor);if not other or other.kind~=info.kind then return end
            count=count+1
        end
        widget.TargetName:SetText(FText(S.names[info.kind]..(widget.IsHeader and count>1 and ' ('..count..')' or '')))
    end)
    R.post('/Script/UMG.UserWidget:Destruct',function(widget)
        if panel and widget:GetAddress()==panel.widget:GetAddress() then clear() end
    end)
    -- The edit screen outlives worlds with our panel on it: the next build takes it off.
    R.on('world_end',function() actions={};swatches={};grids={} end)
    return build,clear
end
