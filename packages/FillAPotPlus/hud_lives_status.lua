-- Original HP-styled number, centred six pixels left of the top native heart.
return function(S)
    local R,C=S.R,S.C
    local lives,status={},{}
    -- The heart's number, by heart. A heart can outlive a world, so this table does too.
    local numbers={}
    -- With a choice of sides the two team logos show the native witch and hunter logos
    -- (WB_TeamLogo, TeamId 0 and 1). The native logo image is bound, so ours lies over it.
    -- The screen outlives worlds, so its own children say whether ours is there.
    local function sideLogos(w)
        local choice=S.rules().roleChoice==true
        for team,logo in pairs({[0]=w.TeamALogo,[1]=w.TeamBLogo}) do
            local box=logo.Logo:GetParent()
            local present=box:GetChildrenCount()>2
            if choice and not present then
                local icon=StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary'):Create(w,w.SpectatorLogo:GetClass(),w:GetOwningPlayer())
                icon.TeamId=team
                box:AddChild(icon)
            elseif present and not choice then box:GetChildAt(2):RemoveFromParent() end
            local visibility=choice and 1 or 4
            logo.Logo:SetVisibility(visibility);logo.Name:SetVisibility(visibility)
        end
    end
    local function refreshLife(w,record)
        local ps=w:GetOwningPlayer().PlayerState
        local policy=S.hudPolicy()
        if not policy then return end
        w:SetVisibility((policy.infinite or ps.Team~=0) and 1 or 0)
        local visible=not policy.infinite and ps.Team==0 and not ps.IsPendingDisconnect and ps.Lives>5
        if not visible then
            if record.text then record.text:SetVisibility(2) end
            return
        end
        local top=w.VerticalBox_0:GetChildAt(0)
        local image=top.WidgetTree.RootWidget:GetChildAt(0)
        local ui=StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetGameInstance(w).IngameUIManager
        local hud=R.valid(ui.HUDUserWidget)
        if not hud then return end -- ShowHUD publishes this after LifeBlock Construct.
        local source=hud.HealthBar.Health
        if not record.text or record.topAddress~=top:GetAddress() then
            record.topAddress=top:GetAddress()
            record.text=R.valid(numbers[record.topAddress])
            if not record.text then
                record.text=S.new('/Script/UMG.TextBlock',top.WidgetTree)
                numbers[record.topAddress]=record.text
                image:GetParent():AddChild(record.text)
                record.text:SetJustification(1)
            end
        end
        local text=record.text
        text:SetFont(source.Font);text:SetColorAndOpacity(source.ColorAndOpacity)
        text:SetShadowColorAndOpacity(source.ShadowColorAndOpacity);text:SetShadowOffset(source.ShadowOffset)
        local sourceSlot,slot=image.Slot,text.Slot
        local src,dst=sourceSlot.LayoutData,slot.LayoutData
        local stretchX=src.Anchors.Minimum.X~=src.Anchors.Maximum.X
        local stretchY=src.Anchors.Minimum.Y~=src.Anchors.Maximum.Y
        local size=image:GetDesiredSize()
        local width,height=src.Offsets.Right,src.Offsets.Bottom
        if width<=0 or sourceSlot.bAutoSize and size.X>0 then width=size.X end
        if height<=0 or sourceSlot.bAutoSize and size.Y>0 then height=size.Y end
        dst.Anchors.Minimum.X=src.Anchors.Minimum.X
        dst.Anchors.Minimum.Y=(src.Anchors.Minimum.Y+src.Anchors.Maximum.Y)/2
        dst.Anchors.Maximum.X=dst.Anchors.Minimum.X;dst.Anchors.Maximum.Y=dst.Anchors.Minimum.Y
        dst.Alignment.X=.5;dst.Alignment.Y=.5
        dst.Offsets.Left=src.Offsets.Left-(stretchX and 0 or width*src.Alignment.X)-6-52/2
        dst.Offsets.Top=stretchY and (src.Offsets.Top-src.Offsets.Bottom)/2 or src.Offsets.Top+height*(.5-src.Alignment.Y)
        dst.Offsets.Right=0;dst.Offsets.Bottom=0
        slot:SetLayout(dst);slot:SetAutoSize(true)
        text:SetText(FText(tostring(ps.Lives)));text:SetVisibility(4)
    end
    function S.refreshLivesStatus()
        for id,record in pairs(lives) do
            if R.valid(record.widget) then refreshLife(record.widget,record) else lives[id]=nil end
        end
        local policy=S.hudPolicy()
        for id,w in pairs(status) do
            if R.valid(w) then
                w.BalanceTeamSelection:SetText(policy and policy.reason~=nil and FText(policy.reason) or w:Get_BalanceTeamSelection_Text_0())
                sideLogos(w)
            else status[id]=nil end
        end
    end
    local function track(w)
        if not R.valid(w) then return end
        local id=w:GetAddress()
        lives[id]=lives[id] or {widget=w}
        S.refreshHUD()
    end
    for _,method in ipairs({'Construct','CreateLiveIcons','MaxLivesChanged'}) do
        S.onMatch.post('/Game/UserInterface/ObjectiveMode/WB_LifeBlock.WB_LifeBlock_C:'..method,track)
    end
    -- hud.lua tracks the life block after it rebuilds the cauldron cards.
    S.trackLife=track
    -- A guest's lobby can open before the host's mode arrives: always remember the
    -- widget; refreshHUD paints it only in Plus.
    R.post('/Game/Blueprints/UserInterface/B_IngameUIManager.B_IngameUIManager_C:ShowTeamSelectionObjective',function(ui)
        local w=R.valid(ui.TeamSelectionObjectiveWidget)
        if w then status[w:GetAddress()]=w;S.refreshHUD() end
    end)
    R.on('world_end',function() lives={};status={} end)
end
