-- Native cauldron cards: seven per column, with the original lift and DPI fit.
local dir=debug.getinfo(1,'S').source:match('^@(.+[/\\])')
return function(S)
    local R,C=S.R,S.C
    -- The HUD in use, its cards and our columns. A native rebuild or a new HUD (respawn,
    -- second half) replaces them; nothing of an older HUD is kept (PROBE13).
    local hud,hudAddress,columns,blocks,widest,reach
    local function use(w)
        local address=w and w:GetAddress()
        if address~=hudAddress then columns,blocks,widest,reach=nil,nil,0,{} end
        hud,hudAddress=w,address
    end
    -- The name sits centred under the prop icon, not under both icons (user). Natively it
    -- fills the card's column: the 142-wide icon row is right-aligned, the prop icon's
    -- centre 108 from the row's right edge. A name wider than 216 moves the icons of its
    -- whole column left by the same amount, kept for this HUD so a column never jumps back.
    local function namesUnderProps()
        local rows={}
        for i,block in ipairs(blocks or {}) do
            local column=block.WidgetTree.RootWidget:GetChildAt(0):GetChildAt(1)
            local row={icons=column:GetChildAt(0),name=column:GetChildAt(1),column=(i-1)//7}
            row.width=row.name:GetDesiredSize().X
            reach[row.column]=math.max(reach[row.column] or 0,row.width/2-108)
            rows[i]=row
        end
        for _,row in ipairs(rows) do
            local right=reach[row.column]
            local padding=row.icons.Slot.Padding
            row.icons.Slot:SetPadding({Left=padding.Left,Top=padding.Top,Right=right,Bottom=padding.Bottom})
            local shift=math.max(0,108+right-math.max(142+right,row.width)/2)
            row.name.Slot:SetPadding({Left=-shift,Top=-3,Right=shift,Bottom=-3})
        end
    end
    -- Columns keep the widest card seen in this HUD, so a new wanted prop with a shorter
    -- name never moves the left columns (PROBE17).
    local function steadyColumns()
        if not columns then return end
        hud:ForceLayoutPrepass()
        for _,block in ipairs(blocks) do widest=math.max(widest,block:GetDesiredSize().X+12) end
        columns.grid:SetMinDesiredSlotWidth(widest)
    end
    local function fit()
        if not columns then return end
        local parent=columns.parent
        local layout=StaticFindObject('/Script/UMG.Default__WidgetLayoutLibrary')
        local viewport,dpi=layout:GetViewportSize(hud),layout:GetViewportScale(hud)
        local height=parent:GetDesiredSize().Y
        local scale=height>0 and math.min(1,math.max(200,viewport.Y/dpi-390+60)/height) or 1
        parent:SetRenderTransformPivot({X=1,Y=0})
        parent:SetRenderScale({X=scale,Y=scale})
    end
    local function cards(w)
        local box=w.CauldronBlock
        local parent=box:GetParent()
        blocks=S.values(box:GetAllChildren())
        parent:SetRenderScale({X=1,Y=1})
        parent:SetRenderTranslation({X=0,Y=#blocks>5 and -60 or 0})
        columns=nil
        if #blocks<=7 then return end
        local grid=S.new('/Script/UMG.UniformGridPanel',w.WidgetTree)
        -- The first seven cards keep their native place at the right edge; further columns
        -- grow to the left, and the gap sits on each card's left so nothing shifts.
        local padding=grid.SlotPadding
        padding.Left=12;padding.Top=0;padding.Right=0;padding.Bottom=10
        grid:SetSlotPadding(padding)
        box:ClearChildren();box:AddChild(grid)
        local last=math.floor((#blocks-1)/7)
        for i,block in ipairs(blocks) do
            local slot=grid:AddChildToUniformGrid(block,(i-1)%7,last-math.floor((i-1)/7))
            slot:SetHorizontalAlignment(3);slot:SetVerticalAlignment(0)
        end
        columns={parent=parent,grid=grid}
    end
    -- Entry point for every HUD update, including network values; it owns the HUD's scope.
    function S.refreshHUD()
        if not S.inMatch() then return end
        S.updateHUDPolicy()
        S.refreshLivesStatus()
        if R.valid(hud) then
            local progress=R.valid(hud.WB_CauldronProgress)
            if progress then S.progressBar(progress) end
            hud:ForceLayoutPrepass()
            namesUnderProps()
            steadyColumns()
            fit()
        end
    end
    dofile(dir..'hud_lives_status.lua')(S)
    dofile(dir..'hud_presentation.lua')(S)
    C.net.watch('fap.rules',S.refreshHUD)
    local path='/Game/UserInterface/ObjectiveMode/WB_ObjectiveHudExtension.WB_ObjectiveHudExtension_C:'
    S.onMatch.post(path..'RefreshCauldronBlock',function(w)
        if not R.valid(w) then return end
        use(w);cards(w)
        local life=R.valid(w.WB_LifeBlock)
        if life then S.trackLife(life) end
        S.refreshHUD()
    end)
    S.onMatch.post(path..'Construct',function(w)
        -- RefreshCauldronBlock owns the cards, including every native rebuild.
        use(w);S.refreshHUD()
    end)
    S.onMatch.post('/Game/Blueprints/UserInterface/B_IngameUIManager.B_IngameUIManager_C:ShowHUD',function(ui)
        use(R.valid(ui.HUDUserWidget.ObjectiveHud))
        S.refreshHUD()
    end)
    for _,method in ipairs({'OnRep_MaxLives','OnRep_FilledCauldronColors',
        'OnGameStartedMulti','OnMatchStartedMulti'}) do
        S.onMatch.post(S.path(S.O,'B_ObjectiveGameState',method),S.refreshHUD)
    end
    for _,method in ipairs({'OnRep_Stacks','OnRep_Filled'}) do
        S.onMatch.post(S.path(S.O,'B_ObjectiveCauldron',method),S.refreshHUD)
    end
    S.onMatch.post('/Script/Engine.Controller:Possess',S.refreshHUD)
    S.onMatch.on('round_start',S.refreshHUD)
    -- A guest learns the mode from the host after its HUD exists.
    S.onMatch.session(S.refreshHUD)
    R.on('world_end',function() use(nil) end)
end
