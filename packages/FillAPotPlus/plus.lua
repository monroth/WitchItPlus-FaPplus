local M={}
local CUSTOM='/Game/UserInterface/Play/WB_Custommatch.WB_Custommatch_C:'
local OPTIONS='/Game/Blueprints/Match/B_MatchOptions.B_MatchOptions_C:'
local GM='/Game/Blueprints/Core/B_GameMode.B_GameMode_C:'
local UI='/Game/Blueprints/UserInterface/B_IngameUIManager.B_IngameUIManager_C:'
local OBJECTIVE='/Game/Blueprints/Gamemodes/ObjectiveMode/B_ObjectiveGameMode.B_ObjectiveGameMode_C'
local SESSION='/Script/OnlineSubsystemBlueprints.'
function M.install(api,mode,config)
    local Context=FAPP_SERVICES.match_context
    local read,call,text,valid,key=mode.read,mode.call,mode.text,mode.valid,mode.key
    local invoke=api.shared('Core').ufunction.call
    local parameters={SetGameModeDefaultValues=1,UpdateWidgetVisibility=0,UpdateLayoutComboBox=0}
    local label,vanilla='Fill a Pot+','Fill a Pot (Experimental)'
    local translating={}
    local advertisedPlus=false
    local nativeLabel=vanilla
    api.notify('/Game/UserInterface/Play/WB_Custommatch.WB_Custommatch_C',function()
        WIR_RUNTIME.retry_hooks()
    end,{ungated=true})
    api.notify('/Game/Blueprints/UserInterface/B_IngameUIManager.B_IngameUIManager_C',function()
        WIR_RUNTIME.retry_hooks()
    end,{ungated=true})
    local object=FAPP_SERVICES.runtime.unwrap
    local function gi(context)
        if mode.class(context)=='B_IngameUIManager_C' then return Context.instance(context,'IngameUIManager') end
        return StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetGameInstance(context)
    end
    local function adapted(widget,method,...)
        local id=key(widget); if not id or translating[id] then return end
        local combo=read(widget,'ComboBox_GameMode')
        if text(read(combo,'SelectedOption'))~=label then return end
        translating[id]=true; combo.SelectedOption=FText(vanilla)
        local args=table.pack(...)
        for index=1,args.n do
            args[index]=object(args[index])
        end
        local ok,err=pcall(invoke,widget,method,parameters[method],table.unpack(args,1,args.n))
        combo.SelectedOption=FText(label); translating[id]=nil
        if not ok then error(err) end
    end
    local function fill(self)
        local widget=object(self); if not valid(widget) then return end
        local instance=gi(widget); mode.remember(instance)
        local combo=read(widget,'ComboBox_GameMode'); if not valid(combo) then return end
        local native=StaticFindObject(OBJECTIVE); assert(valid(native),'Objective mode class unavailable')
        widget.GameModesByName:Add(FName(label),native)
        local exists=false
        combo.Options:ForEach(function(_,value) if text(value:get())==label then exists=true end end)
        if not exists then
            combo.Options[#combo.Options+1]=FText(label)
            api.log('added Custom Match mode option '..label)
        end
        if mode.selected(widget.NextMatchOptions) then combo.SelectedOption=FText(label) end
    end
    for _,method in ipairs({'FillComboBoxes','LoadCustomMatchOptions'}) do
        api.hook(CUSTOM..method,fill,{ungated=true})
    end
    for _,method in ipairs({'SetGameModeDefaultValues','UpdateWidgetVisibility','UpdateLayoutComboBox'}) do
        api.hook(CUSTOM..method,function(self,...) adapted(object(self),method,...) end,{ungated=true})
    end
    api.hook(CUSTOM..'BndEvt__ComboBox_GameMode_K2Node_ComponentBoundEvent_0_OnSelectionChanged__DelegateSignature',function(self,item)
        local widget=object(self); if translating[key(widget)] then return end
        local plus=text(item:get())==label
        mode.select(gi(widget),widget.NextMatchOptions,plus)
        if plus then
            widget.NextMatchOptions:SetGameMode(StaticFindObject(OBJECTIVE))
            mode.select(gi(widget),widget.NextMatchOptions,true)
            for _,method in ipairs({'SetGameModeDefaultValues','UpdateWidgetVisibility','UpdateLayoutComboBox'}) do
                if method=='SetGameModeDefaultValues' then adapted(widget,method,false)
                else adapted(widget,method) end
            end
        end
    end,{ungated=true})
    api.hook(OPTIONS..'SetGameMode',function(self)
        local options=object(self); local id=key(options)
        -- Native repaint/default code reapplies the same Objective class while
        -- translating the Plus label. Only an actual mode change clears it;
        -- explicit vanilla selection is cleared by the dropdown event below.
        if id and (not mode.selected(options) or key(read(options,'GameMode'))~=key(StaticFindObject(OBJECTIVE))) then
            mode.state.options[id]=false
        end
    end,{ungated=true})
    api.hook(OPTIONS..'CopyMatchOptions',function(self,source) mode.copy(object(self),object(source)) end,{ungated=true})
    local function updateSession(G,gm,gameplay)
        if not G or not G.current() then return end
        local instance=G.call(gameplay,'GetGameInstance',gm)
        if not G.current() then return end
        local manager=G.read(instance,'SessionManager')
        if not G.current() or not G.valid(manager) or not G.current() then return end
        manager.SessionIsDirty=true
        if not G.current() then return end
        G.call(manager,'UpdateSessionProperties')
        if not G.current() then return end
    end
    local function nameGame(self)
        local gm=object(self)
        if mode.observe(gm)~=true then return end
        local advertised=advertisedPlus
        local function localDecision() return advertisedPlus==advertised end
        if not mode.state.authority or not mode.state.plus and not advertised then return end
        local operation,decision=mode.authority_operation(gm,localDecision)
        if not operation or not operation.current() or not decision.plus and not advertised then return end
        -- All Native preparation after this decision belongs to the same
        -- operation. A failed writer is terminal; it cannot select a fallback.
        local gmClass=operation.call(gm,'GetClass')
        if not operation.current() then return end
        local default=operation.call(gmClass,'GetCDO')
        if not operation.current() then return end
        local original=operation.text(operation.read(default,'DisplayName') or operation.read(gm,'DisplayName')) or ''
        if not operation.current() then return end
        if original~='' and original~=label then nativeLabel=original end
        local className=operation.text(operation.call(gmClass,'GetFName'))
        if not operation.current() or not className or className=='' then return end
        local gameplay=StaticFindObject('/Script/Engine.Default__GameplayStatics')
        if not operation.current() then return end
        if decision.plus and className=='B_ObjectiveGameMode_C' then
            local gs=operation.call(gameplay,'GetGameState',gm)
            if not operation.current() then return end
            local G,accepted,expected=mode.label_write(gs,gm,localDecision)
            if not operation.current() or not G or not G.current() then return end
            if not G.valid(gs) or not G.current() or not G.valid(gm) or not G.current() then return end
            local name=FName(label)
            if not G.current() then return end
            gm.DisplayName=name
            if not G.current() then return end
            gs.GamemodeDisplayName=name
            if not G.current() then return end
            G.call(gs,'FlushNetDormancy')
            if not G.current() then return end
            local push=StaticFindObject('/Script/Engine.Default__NetPushModelHelpers')
            if not G.current() then return end
            local field=FName('GamemodeDisplayName')
            if not G.current() then return end
            G.call(push,'MarkPropertyDirtyFromRepIndex',gs,19,field)
            if not G.current() then return end
            G.call(gs,'ForceNetUpdate')
            if not G.current() then return end
            -- Exact local final write only. Publication consumes its old lease;
            -- remaining session work needs exactly its own successor scope.
            local committed,session=mode.label_committed(gs,G,accepted,label,expected)
            if not committed then return end
            updateSession(session,gm,gameplay)
            return
        end
        -- Valid no-label-action decision, held from entry through the last
        -- Native step. Guard rejection never reaches this separate branch.
        if not operation.current() then return end
        updateSession(operation,gm,gameplay)
    end
    api.hook(GM..'Initialize',nameGame,{ungated=true,priority=-50})
    local function rename(settings,name)
        local entries=read(settings,'Settings'); if not entries then return false end
        local replacement
        entries:ForEach(function(name,value)
            if text(name:get())=='GameMode' then replacement=value:get() end
        end)
        if not replacement then return false end
        replacement.Data.AsString=name
        entries:Add(FName('GameMode'),replacement)
        return true
    end
    api.hook(SESSION..'OnlineSessionSubsystemCreateSession:CreateSession',function(_,_,_,_,settings)
        if mode.hosting() then
            assert(rename(settings:get(),label),'initial session GameMode setting missing')
            settings:set(settings:get())
            advertisedPlus=true
            api.log('initial advertised GameMode='..label)
        end
    end,{phase='pre',out_params={5},ungated=true})
    api.hook(SESSION..'OnlineSessionSubsystemUpdateSession:UpdateSession',function(_,_,_,settings)
        if mode.state.plus or advertisedPlus then
            local name=mode.state.plus and label or nativeLabel
            assert(rename(settings:get(),name),'updated session GameMode setting missing')
            settings:set(settings:get())
            advertisedPlus=mode.state.plus
            api.log('updated advertised GameMode='..name)
        end
    end,{phase='pre',out_params={4},ungated=true})
    local function refresh(self) mode.observe(object(self)) end
    for _,method in ipairs({'Initialize','ShowHUD','ShowTeamSelectionObjective','ShowObjectiveResult'}) do
        api.hook(UI..method,refresh,{ungated=true,priority=-100})
    end
    -- Only a classified normal completion may repair the native result route.
    -- Surrender/disconnect presentation remains native.
    api.hook(UI..'ShowResult',function(self)
        local manager=object(self); mode.observe(manager)
        if not mode.state.plus or mode.state.mode~='objective' then return end
        local instance=gi(manager); local match=read(instance,'ObjectiveMatchManager')
        local widget=read(manager,'ResultWidget')
        local scope=valid(instance) and FAPP_SERVICES.match_identity.session(instance)
        if scope and scope.normalResult==true and valid(match) and match.IsMatchOver==true and valid(widget)
            and mode.class(widget)=='WB_ResultScreen_C' and widget.ResultType~=3 then
            widget:Initialize(3)
            api.log('final result route: Objective winner screen (completed halves)')
        end
    end,{phase='post',ungated=true,priority=-100})
    api.hook(UI..'ShowRewards',function(self)
        mode.observe(object(self))
        if not mode.state.plus or mode.state.mode~='objective' then return end
        if not config.CreativeMaps or config.CreativeMapVoting==false then return end
        local manager=object(self)
        local instance=gi(manager)
        local gs=valid(instance) and StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetGameState(instance)
        if not valid(instance) or not valid(gs) or mode.class(gs)~='B_ObjectiveGameState_C'
            or gs.State~=3 or gs.IsDedicatedServerGame==true then return end
        if gs.CurrentRound~=2 then return end
        local used=read(instance,'UsedMatchOptions')
        if not valid(used) or used.IsTournamentMode==true or used.IsRecordingMode==true then return end
        local offers=read(gs,'MapsToVote'); if not offers or #offers==0 then return end
        local widget=read(manager,'RewardsWidget')
        if not valid(widget) or mode.class(widget)~='WB_RewardsScreen_C' then return end
        if type(widget.NextScreenTime)~='number' or widget.NextScreenTime==0 then return end
        local previous=widget.NextScreenTime; widget.NextScreenTime=0
        api.log('rewards skip round='..tostring(gs.CurrentRound)..' previous='..tostring(previous)..' offers='..tostring(#offers)
            ..' authority='..tostring(mode.state.authority))
    end,{phase='post',ungated=true,priority=-100})
end
return M
