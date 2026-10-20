-- Objective-only local presentation. No frame ticks, scans or asset loads.
local M={}
local UI='/Game/UserInterface/'
local OM='/Game/Blueprints/Gamemodes/ObjectiveMode/'
local CORE='/Game/Blueprints/Core/'
local LIFE=UI..'ObjectiveMode/WB_LifeBlock.WB_LifeBlock_C:'
function M.init(H)
    local api,owners,numbers={}, {},{}
    local L=H.Lifetime
    local statusOwners={}
    local presentation
    local samples={}
    local read=FAPP_SERVICES.runtime.read
    -- Once the live owner/world is admitted for this generation, bound tree
    -- children need allocation/retirement checks, not repeated owner walks.
    local function boundClass(o,name)
        return L.alive(o) and o:GetClass():GetFName():ToString()==name
    end
    local function same(a,b) return H.valid(a) and H.valid(b) and FAPP_SERVICES.lifetime.same(a,b) end
    local function hide(r)
        if r and H.valid(r.text) then r.text:SetVisibility(2) end
    end
    local function heart(w)
        local column=read(w,'VerticalBox_0')
        if not L.alive(column) then return end
        local top=column:GetChildAt(0)
        local image=L.alive(top) and read(top,'LifeImage')
        if L.alive(top) and not L.alive(image) then
            -- LifeImage may be a named template child without a reflected member.
            -- The dumped WB_Life tree has a root CanvasPanel with this one Image.
            local tree=read(top,'WidgetTree')
            local root=L.alive(tree) and read(tree,'RootWidget')
            if boundClass(root,'CanvasPanel') then image=root:GetChildAt(0) end
        end
        if boundClass(image,'Image') then return top,image,image:GetParent() end
    end
    local function hp(w)
        -- Same path as WB_ObjectiveHudExtension:GetVisibility_0; no UObject scan.
        local gi=H.object('/Script/Engine.Default__GameplayStatics'):GetGameInstance(w)
        local ui=L.alive(gi) and read(gi,'IngameUIManager')
        local hud=L.alive(ui) and read(ui,'HUDUserWidget')
        local bar=L.alive(hud) and read(hud,'HealthBar')
        local text=L.alive(bar) and read(bar,'Health')
        if boundClass(text,'TextBlock') and L.worldKey(w)==L.worldKey(text) then return text end
    end
    local function style(text,source)
        -- Borrow native property structs directly, including the HP font's outline.
        -- Never reconstruct a pointer-owning Font or forward a math-getter table.
        text:SetFont(source.Font)
        text:SetColorAndOpacity(source.ColorAndOpacity)
        text:SetShadowColorAndOpacity(source.ShadowColorAndOpacity)
        text:SetShadowOffset(source.ShadowOffset)
    end
    local function place(image,text)
        local source=read(image,'Slot'); local slot=read(text,'Slot')
        assert(boundClass(source,'CanvasPanelSlot') and boundClass(slot,'CanvasPanelSlot'),'life counter needs a canvas slot')
        local src=source.LayoutData; local dst=slot.LayoutData
        local stretchX=src.Anchors.Minimum.X~=src.Anchors.Maximum.X
        local stretchY=src.Anchors.Minimum.Y~=src.Anchors.Maximum.Y
        -- Read getter scalars only; never forward a Lua math-getter table.
        local size=image:GetDesiredSize()
        local width,height=src.Offsets.Right,src.Offsets.Bottom
        if width<=0 or (source.bAutoSize and size.X>0) then width=size.X end
        if height<=0 or (source.bAutoSize and size.Y>0) then height=size.Y end
        assert((stretchX or width>0) and (stretchY or height>0),'life image size is not ready')
        dst.Anchors.Minimum.X=src.Anchors.Minimum.X
        -- Stretch offsets are margins: the icon's vertical centre is at the
        -- midpoint anchor plus (top-bottom)/2, without reading viewport geometry.
        dst.Anchors.Minimum.Y=(src.Anchors.Minimum.Y+src.Anchors.Maximum.Y)/2
        dst.Anchors.Maximum.X=dst.Anchors.Minimum.X; dst.Anchors.Maximum.Y=dst.Anchors.Minimum.Y
        -- Centre text in the 52px column, 6px left of the heart. AutoSize and
        -- half alignment keep any HP font height centred on the actual top icon.
        dst.Alignment.X=.5; dst.Alignment.Y=.5
        dst.Offsets.Left=src.Offsets.Left-(stretchX and 0 or width*src.Alignment.X)-6-52/2
        dst.Offsets.Top=stretchY and (src.Offsets.Top-src.Offsets.Bottom)/2
            or src.Offsets.Top+height*(.5-src.Alignment.Y)
        dst.Offsets.Right=0; dst.Offsets.Bottom=0
        slot:SetLayout(dst) -- genuine native FAnchorData property
        slot:SetAutoSize(true)
    end
    local function refreshJob(w)
        local id,r,pc,ps,remaining,gm,mm,top,image,parent,source,text
        local epoch=L.epoch
        local presentationRevision=presentation and presentation.revision
        local finished=false
        local function stop() hide(r); finished=true; return true end
        local step=FAPP_WORK.sequence({function()
            if not H.valid(w) or not L.alive(read(w,'WidgetTree')) then finished=true; return true end
            id=w:GetAddress(); r=numbers[id]; return true
        end,function()
            -- Host rules stay authoritative. A guest needs explicit matching
            -- presentation metadata; neither MaxLives=5 nor its config describes
            -- whether replicated Lives=99 is a finite counter or infinite reserve.
            local g=H.object('/Script/Engine.Default__GameplayStatics')
            gm=g:GetGameMode(w)
            if not boundClass(g:GetGameState(w),'B_ObjectiveGameState_C') then return stop() end
            if boundClass(gm,'B_ObjectiveGameMode_C') and gm:HasAuthority()==true then
                local gi=g:GetGameInstance(w); mm=L.alive(gi) and read(gi,'ObjectiveMatchManager')
                if not L.alive(mm) then return stop() end
            else
                gm=nil
                pc=w:GetOwningPlayer()
                if not L.valid(pc) or pc:IsLocalPlayerController()~=true or not L.sameWorld(w,pc) then return stop() end
                local policy=presentation and presentation.policy(pc)
                if not policy or policy.infinite then return stop() end
            end
            return true
        end,function()
            pc=w:GetOwningPlayer(); ps=L.alive(pc) and read(pc,'PlayerState')
            remaining=L.alive(ps) and read(ps,'Lives')
            local visible=boundClass(ps,'B_ObjectivePlayerState_C') and L.worldKey(w)==L.worldKey(ps)
                and ps.Team==0 and not ps.IsPendingDisconnect
                and (not gm or H.settings(mm).MaxLives~='infinite')
                and type(remaining)=='number' and remaining==math.floor(remaining) and remaining>5 and remaining<=255
            if not visible then return stop() end
            return true
        end,function()
            top,image,parent=heart(w)
            if not L.alive(parent) then return stop() end
            return true
        end,function()
            source=hp(w)
            if not source then return stop() end
            if r and (not same(r.owner,w) or not same(r.parent,parent) or not L.alive(r.text)) then
                hide(r); numbers[id]=nil; r=nil
            end
            return true
        end,function()
            if not r then
                assert(boundClass(parent,'CanvasPanel'),'life counter parent is not CanvasPanel')
                text=StaticConstructObject(H.object('/Script/UMG.TextBlock'),top.WidgetTree)
                assert(L.alive(text),'life counter TextBlock construction failed')
                parent:AddChild(text); text:SetVisibility(2); text:SetJustification(1)
                r={owner=w,parent=parent,text=text}; numbers[id]=r
            end
            return true
        end,function() style(r.text,source); return true end,
        function() place(image,r.text); return true end,function()
            r.text:SetText(FText(tostring(remaining))); r.text:SetVisibility(4); return true
        end})
        return function()
            if finished or L.transition or epoch~=L.epoch
                or presentationRevision~=(presentation and presentation.revision) or not L.rawValid(w) then return true end
            return step()
        end
    end
    function api.refresh(w)
        if L.transition or not L.rawValid(w) then return end
        local work=assert(FAPP_WORK)
        local step=refreshJob(w); local key='HUD:lives:'..w:GetAddress()
        work.cancel(key)
        if FAPP_TEST_NO_THROTTLE then work.finish(step)
        else work.submit(key,'HUD1/lives presentation',step) end
    end
    local function refreshAll()
        for id,w in pairs(owners) do
            if not H.valid(w) then owners[id]=nil; numbers[id]=nil
            else
                H.visibility(w)
                H.guard('HUD1/lives',api.refresh)(w)
            end
        end
    end
    -- ShowHUD publishes HUDUserWidget after creating the native tree. A LifeBlock
    -- Construct callback can run before that assignment; retry on this event.
    H.hook('/Game/Blueprints/UserInterface/B_IngameUIManager.B_IngameUIManager_C:ShowHUD',refreshAll)
    local paintStatus,paintOneStatus
    local revision=0
    local function changed()
        local work=FAPP_WORK
        if not work or FAPP_TEST_NO_THROTTLE then
            refreshAll(); if paintStatus then paintStatus() end
            return
        end
        revision=revision+1
        local seen,step
        work.submit('HUD:changes','HUD1/changes',function()
            if not step then seen=revision; step=api.discoverJob() end
            local done=step()
            if done and seen~=revision then step=nil; return false end
            return done
        end)
    end
    function api.discoverJob()
        local work=assert(FAPP_WORK)
        local widgets=H.Registry.list('WB_LifeBlock_C') or {}
        local refresh
        return work.sequence({work.each(widgets,function(widget)
            if H.valid(widget) then owners[widget:GetAddress()]=widget end
        end),work.defer(function()
            refresh={}; for _,widget in pairs(owners) do refresh[#refresh+1]=widget end
            return work.each(refresh,function(widget)
                if H.valid(widget) then H.visibility(widget); H.guard('HUD1/lives',api.refresh)(widget) end
            end)
        end),work.defer(function()
            local entries={}; for id,widget in pairs(statusOwners) do entries[#entries+1]={id=id,widget=widget} end
            return work.each(entries,function(entry) if paintOneStatus then paintOneStatus(entry.id,entry.widget) end end)
        end)})
    end
    function api.discover()
        -- Registry is populated by object/event notifications, never FindAllOf.
        for _,w in ipairs(H.Registry.list('WB_LifeBlock_C') or {}) do
            if H.valid(w) then owners[w:GetAddress()]=w end
        end
        changed()
    end
    local function track(self)
        local w=self:get(); owners[w:GetAddress()]=w; api.refresh(w)
    end
    for _,fn in ipairs({'Construct','CreateLiveIcons','MaxLivesChanged'}) do H.hook(LIFE..fn,track) end
    H.hook(UI..'ObjectiveMode/WB_ObjectiveHudExtension.WB_ObjectiveHudExtension_C:RefreshCauldronBlock',function(self)
        local w=read(self:get(),'WB_LifeBlock')
        if H.valid(w) then owners[w:GetAddress()]=w; api.refresh(w) end
    end)
    local function hostReason(w)
        local gm,mm,gs=H.world(w); if not gm then return end
        local rules=H.settings(mm)
        if not rules.StartWhenEveryoneReady and not rules.UnequalTeams then return end
        if mm.CurrentRound>0 and gs.State~=0 then return '' end
        local count,a,b,unselected,unready=0,0,0,false,false
        for _,ps in ipairs(H.players(gs)) do
            if not ps.IsPendingDisconnect and not H.waiter(ps)
                and not (rules.StartWhenEveryoneReady and H.chosenSpectator(ps,mm)) then
                count=count+1
                if ps.ObjectiveTeam==1 then a=a+1 elseif ps.ObjectiveTeam==2 then b=b+1 else unselected=true end
                local ready=mm.CurrentRound==0 and ps.IsReadyObjectiveTeamSelection or mm.CurrentRound>0 and ps.IsReady
                if not ready then unready=true end
            end
        end
        if count==0 then return 'Waiting for players' end
        if unselected and mm.CurrentRound==0 then return 'Waiting for players to choose a team' end
        if not rules.StartWhenEveryoneReady and not rules.AllowEmptyTeams and (a==0 or b==0) then
            return 'Waiting for a player on each team'
        end
        if unready then return 'Waiting for ready players' end
        return 'Starting match'
    end
    local reasonKey,reasonValue
    presentation=dofile(assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))..'hud_presentation.lua').init({
        Lifetime=L,Registry=H.Registry,object=H.object,class=H.class,world=H.world,settings=H.settings,hook=H.hook,
        changed=changed,now=H.now,reason=function(gs)
            -- Readiness roster work runs only after its existing state-change
            -- producers or a policy/round change, never on each HUD refresh.
            local key=tostring(FAPP_SERVICES.events.revision)..':'..tostring(H.revision())..':'
                ..tostring(read(gs,'State'))..':'..tostring(read(gs,'CurrentRound'))
            if key~=reasonKey then reasonKey=key; reasonValue=hostReason(gs) end
            return reasonValue
        end,
    })
    local function reason(w)
        local gm=H.world(w)
        if gm then return hostReason(w) end
        local pc=w:GetOwningPlayer()
        if not L.valid(pc) or pc:IsLocalPlayerController()~=true or not L.sameWorld(pc,w) then return end
        local policy=presentation.policy(pc)
        return policy and policy.reason
    end
    paintOneStatus=function(id,w)
            if not H.valid(w) then statusOwners[id]=nil
            else
                local block=read(w,'BalanceTeamSelection'); local value=reason(w)
                if H.class(block,'TextBlock') then
                    -- SetText replaces its binding. Read the original pure getter
                    -- on this rare notification when no rule override applies.
                    block:SetText(value~=nil and FText(value) or w:Get_BalanceTeamSelection_Text_0())
                end
            end
    end
    paintStatus=function() for id,widget in pairs(statusOwners) do paintOneStatus(id,widget) end end
    H.hook('/Game/Blueprints/UserInterface/B_IngameUIManager.B_IngameUIManager_C:ShowTeamSelectionObjective',function(self)
        local w=read(self:get(),'TeamSelectionObjectiveWidget')
        if H.class(w,'WB_TeamSelectionObjective_C') then statusOwners[w:GetAddress()]=w; paintStatus() end
    end)
    -- These are state-change notifications, not the native per-frame getters.
    for _,fn in ipairs({'OnRep_MaxLives','OnGameStartedMulti','OnMatchStartedMulti'}) do
        H.hook(OM..'B_ObjectiveGameState.B_ObjectiveGameState_C:'..fn,changed)
    end
    for _,fn in ipairs({'InitializeFromMatchPlayerState','SetTeamByRoundAndObjectiveTeam','OnRep_IsReadyObjectiveTeamSelection'}) do
        H.hook(OM..'B_ObjectivePlayerState.B_ObjectivePlayerState_C:'..fn,changed)
    end
    for _,fn in ipairs({'OnPlayerJoinedMulti','OnPlayerLeftMulti','OnPlayerChangedTeamMulti'}) do
        H.hook(CORE..'B_GameState.B_GameState_C:'..fn,changed)
    end
    H.hook(OM..'B_ObjectiveMatchManager.B_ObjectiveMatchManager_C:TearDown',changed)
    H.hook(OM..'B_ObjectiveGameMode.B_ObjectiveGameMode_C:StartNewGameOverride',changed)
    api.changed=changed
    function api.poll()
        if L.transition then return end
        presentation.poll()
        -- Lives has no dedicated RepNotify. Observe one owning local PS scalar
        -- at the existing 500ms game-thread heartbeat while a life widget exists.
        -- Ordinary idle frames do no HUD work and never enumerate UObjects.
        local dirty=false
        for id,w in pairs(owners) do
            if not H.valid(w) then owners[id]=nil; numbers[id]=nil; samples[id]=nil
            else
                local pc=w:GetOwningPlayer()
                local ps=L.valid(pc) and read(pc,'PlayerState')
                if L.valid(ps) and L.sameWorld(w,ps) then
                    local stamp=tostring(L.key(pc))..':'..tostring(L.key(ps))..':'..tostring(read(ps,'Lives'))
                        ..':'..tostring(read(ps,'Team'))..':'..tostring(read(ps,'IsPendingDisconnect'))
                    if samples[id]~=stamp then samples[id]=stamp; dirty=true end
                elseif samples[id] then samples[id]=nil; dirty=true end
            end
        end
        if dirty then changed() end
    end
    L.onReset(function() owners={}; numbers={}; statusOwners={}; samples={}; reasonKey=nil; reasonValue=nil end) -- no retired engine calls
    return api
end
return M
