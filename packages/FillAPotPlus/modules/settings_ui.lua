-- Runtime UMG injection. Native row behavior/focus; value polling while open.
local M={}
local PLAY="/Game/UserInterface/Play/"
local EL="/Game/UserInterface/UIElements/"
local function path(folder,asset,fn) return folder..asset.."."..asset.."_C:"..fn end
function M.init(C,S,H)
    local ui=FAPP_SERVICES.uikit or FAPP_API.shared('UIKit').new(FAPP_API)
    local scopes={}
    local function scope(widget)
        local key=FAPP_SERVICES.lifetime.key(widget)
        assert(key,'settings screen identity unavailable')
        if not scopes[key] then scopes[key]=ui.scope(widget) end
        return scopes[key]
    end
    local E=FAPP_SERVICES.events
    H=E.scope(H)
    local Registry=FAPP_SERVICES.registry
    local api,screens,buttons,missing,failed,loadAttempt,scrollRows,rowEntries={}, {}, {}, {}, {}, {}, {}, {}
    local syncing,dirty,injecting=false,false,false
    local function once(key,err)
        if not missing[key] then missing[key]=true; H.log("settings UI fallback "..key..": "..tostring(err)) end
    end
    local function need(o,label) assert(H.valid(o),"missing "..label); return o end
    local read=FAPP_SERVICES.runtime.read
    local function same(a,b) return H.valid(a) and H.valid(b) and FAPP_SERVICES.lifetime.same(a,b) end
    local function objective(w)
        local options=read(w,"NextMatchOptions")
        if FAPP_MODE and not FAPP_MODE.selected(options) then return false end
        local mode=H.valid(options) and read(options,"GameMode")
        return H.valid(mode) and mode:GetFName():ToString()=="B_ObjectiveGameMode_C"
    end
    local function open(w)
        if not w:IsVisible() then return false end
        if w:IsInViewport() then return true end
        -- The game's menu screens can be canvas children, not viewport roots.
        -- Walk up panel parents; at the root of a nested WidgetTree continue via
        -- Outer (WidgetTree -> owning UserWidget). Without this the Custom Match
        -- screen (a nested root, not a viewport root) was never treated as open.
        local node=w
        for _=1,24 do
            local parent=node:GetParent()
            if not H.valid(parent) then
                local ok,owner=pcall(function() return node:GetOuter():GetOuter() end)
                if not ok or not H.valid(owner) or not owner:IsA(StaticFindObject("/Script/UMG.UserWidget")) then
                    return not same(node,w) -- reached a top-level root that we climbed to: visible chain
                end
                parent=owner
            end
            if not parent:IsVisible() then return false end
            if parent:IsInViewport() then return true end
            node=parent
        end
        return true
    end
    local function class(folder,asset)
        local full=folder..asset.."."..asset.."_C"
        local c=StaticFindObject(full)
        return need(c,asset)
    end
    local function make(w,asset,panel)
        return scope(w).widget(asset,panel)
    end
    local function native(w,cls)
        return scope(w).native(cls)
    end
    local unwrap=FAPP_SERVICES.runtime.unwrap
    local function values(array)
        local t={}
        if type(array)=="table" and not array.ForEach then for _,v in ipairs(array) do t[#t+1]=unwrap(v) end
        else array:ForEach(function(_,p) t[#t+1]=p:get() end) end
        return t
    end
    local function header(w,panel,text)
        return ui.header(scope(w),panel,text)
    end
    local function focus(row)
        for _,key in ipairs({"FocusableWidget","CheckBox","ValueSlider","ButtonRef"}) do
            local inner=read(row,key); if H.valid(inner) then return inner end
        end
        return row
    end
    local function nav(a,direction,b)
        if H.valid(a) and H.valid(b) then
            a:SetNavigationRuleExplicit(direction,b)
            local inner=focus(a)
            if H.valid(inner) and not same(inner,a) then inner:SetNavigationRuleExplicit(direction,b) end
        end
    end
    -- Only scalars/UObjects and UE4SS's supported FText wrapper cross native calls.
    -- In particular, never copy Font/SlateBrush or pointer-owning parameter structs.
    local function lifeValue() return C.MaxLives=="infinite" and 100 or C.MaxLives end
    local function paintLife(entry,force)
        local input=need(entry.widget.InputField,"lives InputField")
        if force or not input:HasFocusedDescendants() then
            local text=C.MaxLives=="infinite" and "∞" or string.format("%.0f",C.MaxLives)
            if input:GetText():ToString()~=text then input:SetText(FText(text)) end
        end
    end
    local function updateLife(entry,force)
        local wasSyncing=syncing; syncing=true
        local ok,err=pcall(function()
            local value=lifeValue()
            if entry.widget.RealValue~=value then entry.widget:SetRealValue(value) end
            paintLife(entry,force); entry.last=value
        end)
        syncing=wasSyncing
        if not ok then error(err) end
    end
    local function commitLife(entry,value)
        local before=C.MaxLives
        if S.set("MaxLives",value) and before~=C.MaxLives then dirty=true end
        updateLife(entry,true) -- rejected text restores the last valid preference
    end
    local function row(w,panel,r)
        local control=make(w,r.kind=="choice" and "WB_TabButton" or (r.kind=="bool" and "WB_CheckBoxWithEditableLabel" or "WB_SliderWithEditableLabel"),panel)
        control.bIsFocusable=true
        local timing=FAPP_SERVICES.settings_factory.timing(r)
        if r.kind=="choice" then
            local value=S.get(r.key)
            local entry={widget=control,spec=r,last=value}
            entry.paint=function()
                local index=1; for i,v in ipairs(r.choices) do if v==S.get(r.key) then index=i end end
                local text=FText(r.label..": "..r.captions[index])
                control.LabelText=text; need(control.Label,"choice label"):SetText(text)
            end
            entry.paint(); control:SetToolTipText(FText(r.note))
            return entry
        end
        local label=r.label
        control.DescriptiveLabel=FText(label)
        need(control.DescriptiveLabelText,"row label"):SetText(FText(label))
        local value=r.key=="MaxLives" and lifeValue() or S.get(r.key)
        if r.kind=="bool" then
            control.DefaultBoolValue=value
            control:SetIsCheckedWithoutEvent(value)
        else
            control.MinimumValue=r.min; control.MaximumValue=r.key=="MaxLives" and 100 or r.max; control.StepSize=r.step
            control.bRoundToIntegers=r.step>=1; control.UIMultiplyFactor=1
            control.DefaultFloatValue=r.key=="MaxLives" and 4 or value
            if r.key=="MaxLives" then
                -- Vanilla MaxLives=4; mirror InitializeFloatParam's normalized marker.
                need(control.DefaultValueIndicator,"lives default indicator"):SetValue((4-1)/(100-1))
                need(control.InputField,"lives InputField")
            end
            control:SetRealValue(value)
            control:CheckDefaultToUpdateUI()
        end
        local note=""
        if r.key=="TotemReviveSeconds" then note="Two witches revive twice as fast." end
        if r.key=="MaxLives" then note=note.." Slide to ∞ for unlimited lives, or type 1–255." end
        if r.key=="RespawnSeconds" then note=note.." Affects future deaths." end
        if r.key=="ReviveAtFilledCauldrons" then note=note.." " end
        if r.key=="reconnect.max_wait_seconds" then note=note.." Affects future disconnects." end
        if r.key=="LateJoinSpectators" then note=note.." Affects future arrivals." end
        if r.note then note=note.." "..r.note end
        control:SetToolTipText(FText(note))
        local entry={widget=control,spec=r,last=value}
        if r.key=="MaxLives" then paintLife(entry,true) end
        return entry
    end
    local function rows(w,panel,group)
        local result={}
        for _,r in ipairs(S.rows) do if (r.group=="custom")==group then result[#result+1]=row(w,panel,r) end end
        for i,r in ipairs(result) do
            if i>1 then nav(r.widget,2,result[i-1].widget) end -- Up / Down
            if i<#result then nav(r.widget,3,result[i+1].widget) end
        end
        return result
    end
    local function rollback(list)
        for i=#list,1,-1 do if H.valid(list[i]) then pcall(function() list[i]:RemoveFromParent() end) end end
    end
    local function injectBody(w,tab)
        if not H.valid(w) or w:GetFullName():find("Default__",1,true) then return end
        local key=w:GetAddress()
        if screens[key] or failed[key] then return end
        local loaded,loadError=pcall(function()
            class(EL,"WB_CheckBoxWithEditableLabel"); class(EL,"WB_SliderWithEditableLabel")
            class(EL,"WB_TabButton")
        end)
        if not loaded then once("row classes",loadError); return end
        local cleanup,restoreArrays={},nil
        local ok,record=pcall(function()
            if not tab then
                local original=need(w.Slider_WitchLives,"Slider_WitchLives")
                local panel=need(original:GetParent(),"custom-match rule panel")
                local box=native(w,"VerticalBox"); cleanup[#cleanup+1]=box; panel:AddChild(box)
                box:SetVisibility(objective(w) and 0 or 1)
                local scroll=panel
                for _=1,8 do
                    if not H.valid(scroll) or H.class(scroll,"ScrollBox") then break end
                    scroll=scroll:GetParent()
                end
                if H.valid(scroll) and H.class(scroll,"ScrollBox") then
                    -- The native panel scrolls, but hides its bar: show it so rows below
                    -- the fold (start controls) are reachable and visibly so.
                    pcall(function() scroll:SetAlwaysShowScrollbar(true) end)
                    pcall(function() scroll:SetScrollBarVisibility(0) end)
                else
                    -- One-pixel separator, no header row or copied Brush/Font struct.
                    local line=native(w,"SizeBox"); line:SetHeightOverride(1)
                    line:AddChild(native(w,"Image")); box:AddChild(line)
                end
                local list=rows(w,box,true)
                -- Hide only after the section succeeds; no explicit navigation
                -- link into the replaced vanilla control.
                return {widget=w,root=box,rows=list,original=original,custom=true,scroll=scroll}
            end
            local switcher=need(w.RulesSwitcher,"RulesSwitcher")
            local old=need(w.TabButton_Mods,"TabButton_Mods")
            local bar=need(old:GetParent(),"tab button bar")
            local page=native(w,"ScrollBox"); cleanup[#cleanup+1]=page
            -- A ScrollBox is a valid RulesTab: native Skills/Mods/Powerups use it too.
            switcher:AddChild(page)
            header(w,page,"Fill a Pot+ - host gameplay; local UI fixes",read(w,"Settings"))
            local list=rows(w,page,false)
            local button=make(w,"WB_TabButton",bar); cleanup[#cleanup+1]=button
            button.bIsFocusable=true
            button.LabelText=FText("Fill a Pot+"); need(button.Label,"tab label"):SetText(FText("Fill a Pot+"))
            local bs,ts=values(w.Buttons),values(w.RuleTabs)
            local originalButtons,originalTabs=values(w.Buttons),values(w.RuleTabs)
            restoreArrays=function() w.Buttons=originalButtons; w.RuleTabs=originalTabs end
            bs[#bs+1]=button; ts[#ts+1]=page
            local arraysOK,arrayError=pcall(function()
                w.Buttons=bs; w.RuleTabs=ts
                assert(#w.Buttons==#bs and #w.RuleTabs==#ts,"tab array write did not grow")
            end)
            if not arraysOK then
                pcall(function() w.Buttons=originalButtons; w.RuleTabs=originalTabs end)
                error(arrayError)
            end
            -- Both packages own independent children in these native arrays. Remove
            -- only this tab on disable/travel; snapshots may predate MRPP injection.
            scope(w).own(function()
                if not H.valid(w) then return end
                local bs,ts={},{}
                for _,b in ipairs(values(w.Buttons)) do if not same(b,button) then bs[#bs+1]=b end end
                for _,p in ipairs(values(w.RuleTabs)) do if not same(p,page) then ts[#ts+1]=p end end
                w.Buttons=bs; w.RuleTabs=ts
                if same(switcher:GetActiveWidget(),page) and ts[1] then w:SetActiveTab(ts[1]) end
                w:UpdateTabButtonStyles()
            end)
            w:UpdateTabButtonStyles()
            nav(button,0,old); nav(button,3,list[1].widget); nav(list[1].widget,2,button)
            nav(old,1,button) -- change the native tab only after new subtree checks
            return {widget=w,root=page,rows=list,button=button,custom=false,scroll=page}
        end)
        if not ok then
            if restoreArrays then pcall(restoreArrays) end
            rollback(cleanup); failed[key]=true
            once(tab and "Fill a Pot+ tab" or "custom-match controls",record); return
        end
        screens[key]=record
        if record.button then buttons[record.button:GetAddress()]=record end
        for _,entry in ipairs(record.rows) do
            scrollRows[entry.widget:GetAddress()]=record
            rowEntries[entry.widget:GetAddress()]=entry
        end
        H.retryHooks(true)
        H.log("added "..(tab and "Fill a Pot+ tab" or "FillAPotPlus custom-match controls"))
        if api.pollScreen then local okPoll,errPoll=pcall(api.pollScreen,record); if not okPoll then once("initial poll",errPoll) end end
    end
    local function inject(w,tab)
        if injecting then return end
        injecting=true
        local ok,err=pcall(injectBody,w,tab)
        injecting=false
        if not ok then once("screen injection",err) end
    end
    local function activate(r)
        if not H.valid(r.widget) or not H.valid(r.root) then return end
        r.widget:SetActiveTab(r.root)
        r.rows[1].widget:SetUserFocus(r.widget:GetOwningPlayer())
        r.rows[1].widget:SetKeyboardFocus()
    end
    local function activeRecord(w)
        local r=H.valid(w) and screens[w:GetAddress()]
        if r and not r.custom and same(w.RulesSwitcher:GetActiveWidget(),r.root) then return r end
    end
    H.hook(path(PLAY,"WB_Custommatch","Construct"),function(self) inject(self:get(),false) end)
    -- Menus have no ticking actor: refresh our rows' visibility/values on the
    -- native mode-change path instead of waiting for the (game-only) tick poll.
    for _,fn in ipairs({"UpdateWidgetVisibility","SetGameModeDefaultValues","LoadCustomMatchOptions","FillComboBoxes",
        "BndEvt__ComboBox_GameMode_K2Node_ComponentBoundEvent_0_OnSelectionChanged__DelegateSignature"}) do
        H.hook(path(PLAY,"WB_Custommatch",fn),function(self)
            local w=self:get()
            local r=H.valid(w) and screens[w:GetAddress()]
            -- UpdateWidgetVisibility first paints AllControlsShow, then collapses
            -- ControlsToHide. Its POST state belongs to the game, even when it
            -- equals our Collapsed override. Do not restore over that native paint.
            local shown=fn=="UpdateWidgetVisibility" and read(w,"AllControlsShow")
            if r and r.custom and shown then
                for _,control in ipairs(values(shown)) do
                    if same(control,r.original) then r.nativeHidden=false; break end
                end
            end
            inject(w,false)
            local ok,err=pcall(api.poll); if not ok then once("menu poll",err) end
        end)
    end
    H.hook(path(PLAY.."GameRules/","WB_GameRulesTabs","Construct"),function(self) inject(self:get(),true) end)
    -- Construct binds this existing BP handler to Clicked. Both mouse and native
    -- gamepad OnKeyUp broadcast it; no Lua closure/delegate binding is needed.
    H.hook(path(EL,"WB_BaseControl","ButtonClicked"),
        function(self)
            local b=self:get(); if not H.valid(b) then return end
            -- Menus have no tick: any click (e.g. game-mode dropdown) refreshes
            -- our rows' visibility on the next screen poll.
            pcall(function() for _,r in pairs(screens) do if r.custom and api.pollScreen then api.pollScreen(r) end end end)
            if buttons[b:GetAddress()] then activate(buttons[b:GetAddress()]); return end
            local e=rowEntries[b:GetAddress()]; local screen=scrollRows[b:GetAddress()]
            if syncing or not e or e.spec.kind~="choice" or not screen or not open(screen.widget) then return end
            local rank=tonumber(e.spec.key:match("^WinnerPriority([1-6])$"))
            if rank then
                if S.winnerSink(rank) then dirty=true; api.poll() end -- repaint all six; menu has no tick
                return
            end
            local index=1; for i,v in ipairs(e.spec.choices) do if v==S.get(e.spec.key) then index=i end end
            if S.set(e.spec.key,e.spec.choices[index%#e.spec.choices+1]) then
                e.last=S.get(e.spec.key); e.paint(); dirty=true
                if e.spec.key:match("^WinnerPriority") or e.spec.key=="ReviveTotemsPerDeadWitch" then api.poll() end -- menus have no actor tick
            end
        end)
    -- Native gamepad shoulders already cycle switcher children. Focus our first row.
    H.hook(path(PLAY.."GameRules/","WB_GameRulesTabs","SetActiveTab"),function(self,tab)
        local w=self:get(); local r=H.valid(w) and screens[w:GetAddress()]
        if r and same(tab:get(),r.root) then
            r.rows[1].widget:SetUserFocus(w:GetOwningPlayer()); r.rows[1].widget:SetKeyboardFocus()
        end
    end)
    -- The native ScrollBox page has no IGameRulesTab interface. Supply the parent
    -- screen's ordinary OUT parameter and restore focus after modal dialogs.
    H.hook(path(PLAY.."GameRules/","WB_GameRulesTabs","GetInitialFocusWidget"),function(self,out)
        local r=activeRecord(self:get()); if r then out:set(r.rows[1].widget) end
    end)
    H.hook(path(PLAY.."GameRules/","WB_GameRulesTabs","HandleRefocus"),function(self)
        local w=self:get(); local r=activeRecord(w)
        if r then r.rows[1].widget:SetUserFocus(w:GetOwningPlayer()); r.rows[1].widget:SetKeyboardFocus() end
    end)
    -- PreConstruct rebuilds native arrays. Restore our identity at any length;
    -- MRPP may have already restored its own tab in this dispatch.
    H.hook(path(PLAY.."GameRules/","WB_GameRulesTabs","PreConstruct"),function(self)
        local w=self:get(); local r=H.valid(w) and screens[w:GetAddress()]
        if r and H.valid(r.root) then
            local bs,ts=values(w.Buttons),values(w.RuleTabs)
            local hasButton,hasPage=false,false
            for _,b in ipairs(bs) do if same(b,r.button) then hasButton=true end end
            for _,p in ipairs(ts) do if same(p,r.root) then hasPage=true end end
            if not hasButton then bs[#bs+1]=r.button end
            if not hasPage then ts[#ts+1]=r.root end
            w.Buttons=bs; w.RuleTabs=ts
        end
    end)
    H.hook(path(EL,"WB_BaseControl","OnFocusReceived"),function(self)
        local w=self:get(); local r=H.valid(w) and scrollRows[w:GetAddress()]
        if r and H.valid(r.scroll) and H.class(r.scroll,"ScrollBox") then r.scroll:ScrollWidgetIntoView(w,true,0,0) end
    end)
    -- Capture completed native edits before a fast Apply/Host/close can hide the UI.
    -- No delegate binding: these are ordinary per-class BP POST hooks, instance-filtered.
    local function edited(self)
        if syncing then return end
        local w=self:get(); local entry=H.valid(w) and rowEntries[w:GetAddress()]
        if not entry or entry.spec.key=="MaxLives" then return end
        local screen=scrollRows[w:GetAddress()]
        if not screen or not open(screen.widget) then return end
        local value
        if entry.spec.kind=="bool" then value=w.CheckBox:IsChecked() else value=w.RealValue end
        if value~=entry.last and S.set(entry.spec.key,value) then
            entry.last=S.get(entry.spec.key); dirty=true
            if entry.spec.key=="ReviveAtFilledCauldrons" then api.poll() end
        end
    end
    H.hook(path(EL,"WB_SliderWithEditableLabel","SetRealValue"),edited)
    H.hook(path(EL,"WB_CheckBoxWithEditableLabel","SetIsChecked"),edited)
    H.hook(path(EL,"WB_CheckBoxWithEditableLabel","BndEvt__CheckBox_K2Node_ComponentBoundEvent_0_OnCheckBoxComponentStateChanged__DelegateSignature"),edited)
    local function lifeEntry(self)
        if syncing then return end
        local w=self:get(); local e=H.valid(w) and rowEntries[w:GetAddress()]
        local r=e and scrollRows[w:GetAddress()]
        if e and e.spec.key=="MaxLives" and r and open(r.widget) and (not r.custom or objective(r.widget)) then return e end
    end
    local SLIDER="WB_SliderWithEditableLabel"
    local function slideLife(self,value)
        local e=lifeEntry(self); if not e then return end
        local real=e.widget.RealValue
        if value then
            -- Commit sets IgnoreSliderChange in the native BP; the first drag may
            -- skip SetRealValue. The event's normalized scalar still reflects intent.
            local normalized=value:get()
            real=math.floor(1+99*math.max(0,math.min(1,normalized))+.5)
        end
        commitLife(e,real==100 and "infinite" or real)
    end
    H.hook(path(EL,SLIDER,"BndEvt__ValueSlider_K2Node_ComponentBoundEvent_0_OnFloatValueChangedEvent__DelegateSignature"),slideLife)
    H.hook(path(EL,SLIDER,"ChangeRealValue"),function(self) slideLife(self) end) -- native keyboard/gamepad arrows
    H.hook(path(EL,SLIDER,"BndEvt__WB_SliderWithEditableLabel_ResetButton_K2Node_ComponentBoundEvent_1_OnButtonClickedEvent__DelegateSignature"),function(self)
        local e=lifeEntry(self); if e then commitLife(e,4) end
    end)
    H.hook(path(EL,SLIDER,"BndEvt__WB_SliderWithEditableLabel_InputField_K2Node_ComponentBoundEvent_3_OnEditableTextBoxCommittedEvent__DelegateSignature"),function(self,text)
        local e=lifeEntry(self); if not e then return end
        -- Read the original event text, not InputField overwritten by the native body.
        -- Convert immediately in Lua; never forward the borrowed FText to a UFunction.
        local v=text:get():ToString():match("^%s*(.-)%s*$")
        local lower=v:lower()
        local value=(lower=="inf" or lower=="infinite" or v=="∞") and "infinite" or tonumber(v)
        if value==nil then H.log("rejected UI lives text: "..v) end
        commitLife(e,value)
    end)
    H.hook(path(EL,SLIDER,"CheckDefaultToUpdateUI"),function(self)
        local e=lifeEntry(self); if e then paintLife(e,false) end
    end)
    local pollScreen
    function api.pollScreen(r) return pollScreen(r) end
    pollScreen=function(r)
        if r.custom then
            local replace=objective(r.widget) and H.valid(r.root)
                and same(r.root:GetParent(),r.original:GetParent())
            local hasLife=false
            for _,entry in ipairs(r.rows) do
                if entry.spec.key=="MaxLives" and H.valid(entry.widget)
                    and same(entry.widget:GetParent(),r.root) then hasLife=true end
            end
            replace=replace and hasLife
            local visibility=r.original:GetVisibility()
            if replace then
                if not r.nativeHidden or visibility~=1 then r.nativeVisibility=visibility end
                r.original:SetVisibility(1); r.nativeHidden=true -- Collapsed removes the row's space
            elseif r.nativeHidden then
                -- Native mode-change code may already have painted its own state.
                if visibility==1 then r.original:SetVisibility(r.nativeVisibility or 0) end
                r.nativeHidden=false
            end
        end
        local isOpen=open(r.widget)
        if r.custom then pcall(function()
            local dbg="open="..tostring(isOpen).." original="..tostring(r.original:IsVisible()).." root="..tostring(r.root:GetVisibility())
                .." parent="..tostring(H.valid(r.root:GetParent()) and r.root:GetParent():GetFullName():match("[^%.]+$") or "nil")
            if dbg~=r.lastDbg then r.lastDbg=dbg; H.log("settings UI state: "..dbg) end
        end) end
        if not isOpen then return false end
        if r.custom then
            local visible=objective(r.widget)
            r.root:SetVisibility(visible and 0 or 1)
            if not visible then return false end
        elseif not same(r.widget.RulesSwitcher:GetActiveWidget(),r.root) then return false end
        local changed=false
        for _,entry in ipairs(r.rows) do
            local w,spec=entry.widget,entry.spec
            if not H.valid(w) then error("settings row destroyed") end
            if spec.kind=="choice" then entry.paint(); entry.last=S.get(spec.key)
            else
            local current
            if spec.kind=="bool" then current=w.CheckBox:IsChecked() else current=w.RealValue end
            local wanted=S.get(spec.key)
            if spec.key=="MaxLives" then
                if current~=entry.last then
                    commitLife(entry,current==100 and "infinite" or current)
                    changed=changed or dirty
                else updateLife(entry,false) end
            else
                if current~=entry.last then
                    if S.set(spec.key,current) then changed=true end
                    wanted=S.get(spec.key)
                end
                if current~=wanted then
                    if spec.kind=="bool" then w:SetIsCheckedWithoutEvent(wanted)
                    else w:SetRealValue(wanted); w:CheckDefaultToUpdateUI() end
                end
                entry.last=wanted
            end
            end
        end
        return changed
    end
    local settingsVersion=-1
    function api.poll()
        settingsVersion=S.revision
        local changed=dirty
        syncing=true
        for key,r in pairs(screens) do
            if not H.valid(r.widget) or not H.valid(r.root) then
                if r.custom and r.nativeHidden and H.valid(r.original)
                    and r.original:GetVisibility()==1 then r.original:SetVisibility(r.nativeVisibility or 0) end
                if r.button then buttons[r.button:GetAddress()]=nil end
                for _,entry in ipairs(r.rows) do
                    rowEntries[entry.widget:GetAddress()]=nil; scrollRows[entry.widget:GetAddress()]=nil
                end
                screens[key]=nil
            else
                local ok,result=pcall(pollScreen,r)
                if ok then changed=changed or result else once("screen polling",result) end
            end
        end
        syncing=false
        if changed then dirty=not S.save() end
    end
    -- Construct hooks normally suffice. Retry only failed/missed open screens cheaply.
    function api.discover()
        for _,cls in ipairs({"WB_Custommatch_C","WB_GameRulesTabs_C"}) do
            for _,w in ipairs(Registry.list(cls) or {}) do
                if H.valid(w) and open(w) then inject(w,cls=="WB_GameRulesTabs_C") end
            end
        end
    end
    function api.reset()
        local errors={}
        for key,owned in pairs(scopes) do
            local done,why=owned.close()
            if done~=false then scopes[key]=nil else errors[#errors+1]='FAPP settings '..key..': '..tostring(why) end
        end
        if #errors>0 then return false,table.concat(errors,' | ') end
        scopes={}; screens={}; buttons={}; scrollRows={}; rowEntries={}
        return true
    end
    E.poll(api,H,Registry,function() return dirty or settingsVersion~=S.revision end)
    return api
end
return M
