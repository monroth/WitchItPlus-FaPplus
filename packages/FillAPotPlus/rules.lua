return function(S)
    local R,C,U = S.R,S.C,S.U
    local defaults = {unequal=true, startReady=false, roleChoice=true, lives=4,
        respawn=5, totems=1, revive=3, filledRevive=false, targetOffset=0,
        grace=120, order='wins,pots,time,kills,props,lives',
        plusMode=false, lateSpectate=true, rejoin=true}
    -- Slider minimum, maximum and step, then what the number field also accepts.
    local bounds = {targetOffset={-5,5,1,10,-10},lives={1,10,1},respawn={0,60,.5,3600},totems={0,5,1},revive={.5,30,.5,3600,.01},grace={0,600,10,86400}}
    local labels = {targetOffset='Extra cauldrons to win',unequal='Unequal teams',startReady='Start when everyone is ready',
        lives='Witch lives',respawn='Witch respawn delay (s)',totems='Revive totems per dead witch',
        revive='Revival time (s)',filledRevive='Revive at filled cauldrons',
        grace='Reconnect time limit (s)',
        lateSpectate='Late joiners spectate',rejoin='Allow disconnected players to rejoin'}
    local help={unequal='Allow different numbers of players on the two teams. Applies to the next match.',
        startReady='Skip the selection countdown once everyone is ready. Applies to the next match.',
        lives='Slide to ∞ for unlimited lives, or type 1–255.',
        respawn='Affects future deaths.',
        totems='One revival uses all totems for that witch. Living witches revive a random dead teammate. Applies to the next match.',
        filledRevive='Stand at a full cauldron to revive a random dead teammate. Applies to the next match.',
        revive='Two witches revive twice as fast.',
        lateSpectate='Affects future arrivals.',
        rejoin='Allow disconnected participants to return with their team and remaining lives.',
        grace='Affects future disconnects.'}
    local pref = R.settings('FillAPotPlus',defaults)
    local criteria = {wins='Halves won',pots='Full cauldrons',lives='Witch lives remaining',
        kills='Hunter kills',time='Time',props='Delivered props'}
    local function order(value)
        local rows, seen = {},{}
        for k in value:gmatch('[^,]+') do
            if not criteria[k] or seen[k] then return end
            seen[k]=true; rows[#rows+1]=k
        end
        if #rows==6 then return rows end
    end
    pref.order = order(pref.order) and pref.order or defaults.order
    S.preferences, S.criteria, S.order = pref, criteria, order
    local remote
    -- A guest's own rules to play with. They reach other players only as a code.
    local draft
    local translating = false
    local custom = '/Game/UserInterface/Play/WB_Custommatch.WB_Custommatch_C:'
    local label, vanilla = 'Fill a Pot+','Fill a Pot (Experimental)'
    function S.selected(options) return C.is_plus(options) end
    function S.rules()
        if not S.host() then return remote or pref end
        return S.match and S.match.rules or pref
    end
    function S.publishRules()
        if S.host() then C.net.publish('fap.rules',S.rules()) end
    end
    C.net.watch('fap.rules',function(value) if not S.host() then remote=value end end)
    local function applyLabel()
        local session = C.session()
        session.gm.DisplayName=FName(label)
        S.write(session.gs,'GamemodeDisplayName',FName(label),19)
        session.gi.SessionManager.SessionIsDirty=true
        session.gi.SessionManager:UpdateSessionProperties()
    end
    -- Custom Match menu: these hooks choose the mode, so they run outside it.
    R.post(custom..'FillComboBoxes',function(w)
        w.GameModesByName:Add(FName(label),S.asset(S.path(S.O,'B_ObjectiveGameMode')))
        local found=false
        for _,v in ipairs(S.values(w.ComboBox_GameMode.Options)) do if S.text(v)==label then found=true end end
        if not found then w.ComboBox_GameMode.Options[#S.values(w.ComboBox_GameMode.Options)+1]=FText(label) end
    end)
    local function translate(w)
        translating=true
        w.ComboBox_GameMode.SelectedOption=FText(vanilla)
        w:SetGameModeDefaultValues(false)
        w:UpdateWidgetVisibility()
        w:UpdateLayoutComboBox()
        w.ComboBox_GameMode.SelectedOption=FText(label)
        translating=false
    end
    R.post(custom..'BndEvt__ComboBox_GameMode_K2Node_ComponentBoundEvent_0_OnSelectionChanged__DelegateSignature',function(w,item)
        if translating or w.InGame then return end
        local plus = S.text(item)==label
        C.set_plus(w.NextMatchOptions,plus)
        pref.plusMode=plus;R.save_settings('FillAPotPlus')
        if plus then
            w.NextMatchOptions:SetGameMode(S.asset(S.path(S.O,'B_ObjectiveGameMode')))
            translate(w)
        end
        S.modeChanged(plus,w.NextMatchOptions)
        S.trace('mode %s widget %s',plus and 'plus' or 'other',S.options(w.NextMatchOptions))
    end)
    R.pre(custom..'ForceObjectiveMap',function(w)
        local options=w.NextMatchOptions
        if S.selected(options) and (options.CustomMapSelected or S.text(options.MapData[S.F.file])=='RandomMapCycle') then return true end
    end)
    R.pre(custom..'UpdateWidgetVisibility',function(w)
        if not S.selected(w.NextMatchOptions) then return end
        -- Native objective visibility also clears the active custom layout.
        for _,control in ipairs(S.values(w.AllControlsShow)) do
            control:SetVisibility(0);control.bIsFocusable=true
        end
        for _,control in ipairs(S.values(w.ObjectiveControlsHide)) do
            control:SetVisibility(1);control.bIsFocusable=false
        end
        -- Team Choice is the native control: Free lets players pick witches or hunters.
        w.ComboBox_TeamChoice:SetVisibility(0);w.ComboBox_TeamChoice.bIsFocusable=true
        w.Slider_MaxPlayers.MaximumValue=16
        return true
    end)
    R.post(custom..'LoadCustomMatchOptions',function(w)
        local objective=w.NextMatchOptions.GameMode==S.asset(S.path(S.O,'B_ObjectiveGameMode'))
        -- In a match the menu shows the running mode; in the main menu, the last choice.
        if w.InGame and S.inMatch() or not w.InGame and pref.plusMode and objective then C.set_plus(w.NextMatchOptions,true) end
        if S.selected(w.NextMatchOptions) then w.ComboBox_GameMode.SelectedOption=FText(label) end
    end)
    for _,name in ipairs({'SetGameModeDefaultValues','UpdateLayoutComboBox'}) do
        R.post(custom..name,function(w)
            if not translating and S.text(w.ComboBox_GameMode.SelectedOption)==label then
                translating=true;w.ComboBox_GameMode.SelectedOption=FText(vanilla)
                if name=='SetGameModeDefaultValues' then w[name](w,false) else w[name](w) end
                w.ComboBox_GameMode.SelectedOption=FText(label);translating=false
            end
        end)
    end
    local views={}
    local live={respawn=true,revive=true,grace=true,lateSpectate=true,rejoin=true,targetOffset=true}
    local function apply(key)
        if live[key] and S.match then S.match.rules[key]=pref[key] end
        if key=='targetOffset' and S.inMatch() then S.target() end
    end
    local function change(key,value)
        if not S.host() then
            draft=draft or {}
            draft[key]=value
            return
        end
        pref[key]=value
        apply(key)
        R.save_settings('FillAPotPlus');S.publishRules()
    end
    local function shown(key)
        if S.host() then return pref[key] end
        if draft and draft[key]~=nil then return draft[key] end
        return S.rules()[key]
    end
    local function row(parent,key)
        local opts={editable=false,label=labels[key],tooltip=help[key],value=shown(key),default=defaults[key],
            on_change=function(v) change(key,v) end}
        if bounds[key] then
            opts.min,opts.max,opts.step,opts.input_max,opts.input_min=table.unpack(bounds[key])
            opts.kind=opts.step>=1 and 'int' or nil
            if key=='lives' then opts.infinite=true;opts.input_max=255 end
            return U.slider(parent,opts)
        else return U.checkbox(parent,opts) end
    end
    local function paint(setters) for key,set in pairs(setters) do set(shown(key)) end end
    local function build(parent,scroll)
        U.text(parent,{text='Fill a Pot+'})
        local controls,setters={},{}
        for _,key in ipairs({'targetOffset','respawn','totems','filledRevive','revive','lateSpectate','rejoin','grace'}) do
            controls[#controls+1],setters[key]=row(parent,key)
        end
        local buttons={}
        local function caption(i,k) return 'Winner priority '..i..': '..S.criteria[k] end
        for rank,key in ipairs(order(shown('order'))) do
            local widget,set=U.button(parent,{label=caption(rank,key),
                tooltip='Click each criterion from most to least important. Ties use the next criterion; infinite lives are ignored.',on_click=function()
                    local rows=order(shown('order'));local moved=table.remove(rows,rank);rows[#rows+1]=moved
                    change('order',table.concat(rows,','))
                    for i,k in ipairs(rows) do buttons[i](caption(i,k)) end
                end})
            buttons[rank]=set;controls[#controls+1]=widget
        end
        U.navigate(controls,scroll)
        return function()
            paint(setters)
            for i,k in ipairs(order(shown('order'))) do buttons[i](caption(i,k)) end
        end
    end
    -- A native rules file carries these rules beside it. plusMode and roleChoice follow
    -- the Custom Match screen's own choices. Rules from a code come from another player.
    local unsaved={plusMode=true,roleChoice=true}
    local function valid(key,value)
        if key=='order' then return type(value)=='string' and order(value)~=nil end
        if key=='lives' and value=='infinite' then return true end
        if type(value)~=type(defaults[key]) then return false end
        local limits=bounds[key]
        if not limits then return true end
        local lo,hi=limits[5] or limits[1],key=='lives' and 255 or limits[4] or limits[2]
        return value>=lo and value<=hi and (limits[3]<1 or value%1==0)
    end
    C.saved_rules.register('FillAPotPlus',{
        save=function()
            local rules={}
            for key in pairs(defaults) do if not unsaved[key] then rules[key]=shown(key) end end
            return rules
        end,
        load=function(rules)
            if not S.host() then
                draft=rules and {} or nil
                for key in pairs(rules or {}) do
                    if defaults[key]~=nil and not unsaved[key] and valid(key,rules[key]) then draft[key]=rules[key] end
                end
                return
            end
            for key,value in pairs(defaults) do
                if not unsaved[key] then
                    pref[key]=value
                    if rules and valid(key,rules[key]) then pref[key]=rules[key] end
                    apply(key)
                end
            end
            R.save_settings('FillAPotPlus');S.publishRules()
        end})
    U.rules_tab('match_rules','Fill a Pot+',build)
    S.onMatchHost.on('round_start',function(gs)
        local mm=S.manager()
        local manager=mm:GetAddress()
        if not S.match or S.match.manager~=manager or mm.CurrentRound<=1 then
            local rules={};for k in pairs(defaults) do rules[k]=pref[k] end
            S.match={manager=manager,rules=rules,rounds={}}
        end
        S.publishRules();applyLabel()
    end)
    S.onMatchHost.session(function(session)
        if R.valid(session.gs) then S.publishRules();applyLabel() end
    end)
    C.on_session(function(session) if session.is_creative then S.match=nil end end)
    R.on('world_end',function()
        remote,draft=nil,nil
        -- The Custom Match screen is cached across worlds; keep the rows it still shows.
        for id,view in pairs(views) do if not R.valid(view.box) then views[id]=nil end end
    end)
    function S.endMatch() S.match=nil;S.publishRules() end
    -- The menu's visible game mode is the Plus choice of the options it edits, so the
    -- Plus rows, the Plus choice and the Vanilla server checkbox follow one fact.
    local function customRules(w)
        local id=w:GetAddress()
        local view=views[id]
        local selected=S.text(w.ComboBox_GameMode.SelectedOption)==label
        if not w.InGame and not translating then C.set_plus(w.NextMatchOptions,selected) end
        if not view then
            local parent=w.Slider_WitchLives:GetParent()
            local box=U.section(parent,{})
            local controls,setters={},{}
            for _,key in ipairs({'unequal','startReady','lives'}) do controls[#controls+1],setters[key]=row(box,key) end
            view={box=box,setters=setters};views[id]=view
            U.navigate(controls)
        end
        paint(view.setters)
        view.box:SetVisibility(selected and 0 or 1)
        if selected then w.Slider_WitchLives:SetVisibility(1) end
    end
    for _,method in ipairs({'Construct','LoadCustomMatchOptions','UpdateWidgetVisibility','UpdateLayoutComboBox'}) do
        R.post(custom..method,function(w) customRules(w) end)
    end
    R.post(custom..'BndEvt__ComboBox_GameMode_K2Node_ComponentBoundEvent_0_OnSelectionChanged__DelegateSignature',function(w)
        if not translating then customRules(w) end
    end)
    R.post('/Script/UMG.UserWidget:Destruct',function(w) views[w:GetAddress()]=nil end)
    for _,method in ipairs({'Initialize','HandleEndMatchOverride'}) do
        S.onMatchHost.post(S.path(S.O,'B_ObjectiveGameMode',method),applyLabel)
    end
    local function sessionName(settings,name)
        local data
        settings.Settings:ForEach(function(k,v) if S.text(k:get())=='GameMode' then data=v:get() end end)
        if data then data.Data.AsString=name;settings.Settings:Add(FName('GameMode'),data) end
    end
    R.pre('/Game/Blueprints/Core/B_GameInstance.B_GameInstance_C:HostGame',function(gi)
        if S.selected(gi.UsedMatchOptions) then pref.roleChoice=gi.UsedMatchOptions.TeamSwitchingOption==1 end
    end)
    -- Hosting decides the mode: the options being hosted carry the Fill a Pot+ choice.
    R.pre('/Script/OnlineSubsystemBlueprints.OnlineSessionSubsystemCreateSession:CreateSession',function(_,subsystem,_,_,settings)
        local gi=StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetGameInstance(subsystem)
        if S.selected(gi.UsedMatchOptions) then sessionName(settings,label) end
    end)
    S.onMatchHost.pre('/Script/OnlineSubsystemBlueprints.OnlineSessionSubsystemUpdateSession:UpdateSession',function(_,_,_,settings)
        sessionName(settings,label)
    end)
end
