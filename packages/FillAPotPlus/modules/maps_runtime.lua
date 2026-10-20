-- Independent module initialization/poll guards keep one failure from hiding later stages.
local M={}
function M.init(C,H,load,deferred)
    local X=load('maps_shared').init(C,H)
    local api,modules={},{{name="maps_chat",api=X.Chat}}
    -- Native admission and HUD publication are event producers, not discovery.
    -- Declare them now; their UFunctions subscribe at destination/class birth.
    local function add(name)
        local module=X.guard('Init/'..name,function() return load(name).init(X) end)()
        if module then modules[#modules+1]={name=name,api=module} end
    end
    for _,name in ipairs({'maps_targets','maps_objective','maps_hud'}) do add(name) end
    local initialize=X.Work.each({'maps_modsync','maps_check','maps_visuals','maps_radius','maps_endpoint_looks','maps_palette','maps_colour','maps_ui_polish','maps_featured','maps_preflight','maps_selection','maps_voting','maps_teleporters','maps_preview','maps_suppression'},add)
    function api.reset()
        X.reports={}; X.loadAttempts={}
        for _,m in ipairs(modules) do if m.api.reset then m.api.reset() end end
    end
    function api.poll()
        X.hookStatus()
        local step=X.Work.each(modules,function(module) X.guard(module.name..'/poll',module.api.poll)() end)
        if FAPP_TEST_NO_THROTTLE then X.Work.finish(step)
        else X.Work.submit('maps:maintenance','maps/maintenance',step) end
    end
    function api.framePending() return X.Work.pending() or (X.Preview and X.Preview.active()) or (X.Suppression and X.Suppression.active()) or X.Chat.pending() end
    function api.deadlinePending() return (X.Preview and X.Preview.active()) or (X.Suppression and X.Suppression.active()) or X.Chat.pending() end
    function api.menuPending() return (X.Selection and X.Selection.pending()) or X.Chat.pending() end
    function api.tick(time)
        if X.Preview and X.Preview.tick then X.Preview.tick(time) end
        if X.Suppression then X.guard("Hide/aim",X.Suppression.tick)(time) end
        if X.Chat.pending() then X.Chat.poll() end
    end
    function api.menuPoll()
        -- Only the explicit console launch queue; no actor/HUD/editor maintenance.
        if X.Selection then X.guard('Selection/menu',X.Selection.poll)() end
        if X.Chat.pending() then X.Chat.poll() end
    end
    function api.begin(actor)
        if X.ModSync then X.ModSync.begin(actor) end
        if X.Featured then X.Featured.begin(actor) end
    end
    function api.everyoneModded() return X.ModSync and X.ModSync.everyoneModded() or false end
    function api.unmodded() return X.ModSync and X.ModSync.unmodded() or {} end
    api.mapRequiresMod=X.mapRequiresMod
    api.initialize=X.Work.sequence({initialize,function()
        X.log('Init','CreativeMaps='..tostring(C.CreativeMaps)..'; '..#modules..'/19 modules initialized; voting='..tostring(C.CreativeMapVoting~=false))
        return true
    end})
    if not deferred then X.Work.finish(api.initialize) end
    local preparing=false
    function api.prepare(manager)
        if preparing or X.Lifetime.transition or not C.CreativeMaps then return end
        preparing=true
        local ok,err=pcall(function()
            if X.Objective then
                local gm=X.gameplay():GetGameMode(manager)
                if X.H.valid(gm) then
                    local status=X.Objective.status(gm)
                    if status and (not status.ready or status.recheck) then X.Objective.loadComplete(gm) end
                end
            end
            api.poll()
            -- Presentation work resumes in Core slices; UI callbacks never
            -- drain an unrelated discovery/catalog/maintenance backlog.
            if FAPP_TEST_NO_THROTTLE then X.Work.flush('world presentation') end
        end)
        preparing=false; if not ok then error(err) end
    end
    X.prepare=api.prepare
    local UI='/Game/Blueprints/UserInterface/B_IngameUIManager.B_IngameUIManager_C:'
    H.hook(UI..'Initialize',X.guard('Load/HUD prewarm',function(self)
        local manager=X.get(self)
        if X.Lifetime.transition or not FAPP_MODE or not FAPP_MODE.state.plus then return end
        if H.loadHooks then H.loadHooks() end
        if not X.H.valid(X.read(manager,'HUDUserWidget')) then
            X.preparingHUD=true
            local ok,err=pcall(function() manager:ShowHUD() end)
            X.preparingHUD=false; if not ok then error(err) end
            -- Keep the native tree owned by HUDUserWidget until ShowHUD replaces
            -- it. Removing it here would destruct the prebuilt progress widget.
            local root=X.read(manager,'HUDUserWidget'); if X.H.valid(root) then root:SetVisibility(2) end
        end
        api.prepare(manager)
    end))
    for _,event in ipairs({'ShowTeamSelectionObjective','ShowTeamSelectionObjectiveCoop','ShowHUD'}) do
        H.hook(UI..event,X.guard('Load/prepare',function(self) api.prepare(X.get(self)) end))
    end
    return api
end
return M
