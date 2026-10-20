local Registry=FAPP_SERVICES.registry
-- Adapted from read-only ../hangs/fix-proposals.lua; still NOT game-tested.
-- integration.lua wires the six requested helpers with mode/local/epoch guards.
-- Unused host skill fallback, live death fallback and generic HUD repair omitted.
-- RegisterHook('/Game/...') is POST only; do not treat it as a cancellable BP pre-hook.
local M={}
local function action(s)
    if M.log then M.log("SoftLock: "..s) else print('[FillAPotPlus] SoftLock: '..s..'\n') end
end
local function try(f) local ok,v=pcall(f); if not ok then print('[FillAPotPlus] SoftLock helper: '..tostring(v)..'\n') end; if ok then return v end; return nil end
local dir=debug.getinfo(1,'S').source:match('^@(.+[\\/])')
local Lifetime=FAPP_SERVICES.lifetime
local Clock=FAPP_SERVICES.event_clock
local valid=Lifetime.valid
local function same(a,b) return valid(a) and valid(b) and Lifetime.same(a,b) end
local pending={}
function M.pending() return #pending>0 end
local function later(ms,fn) pending[#pending+1]={deadline=Clock.now()+ms/1000,fn=fn,epoch=Lifetime.epoch} end
function M.reset() pending={}; M.time=nil end
function M.poll(time)
    if type(time)=="number" then M.time=time end
    if Lifetime.transition then pending={}; return end
    local work=pending; pending={}
    for _,r in ipairs(work) do
        if r.epoch==Lifetime.epoch then
            if Clock.now()>=r.deadline then try(r.fn) else pending[#pending+1]=r end
        end
    end
end
local function array(a,fn)
    if type(a)=='table' and not a.ForEach then for i,v in ipairs(a) do
        fn(i,FAPP_SERVICES.runtime.unwrap(v))
    end elseif a then a:ForEach(function(i,v) fn(i,v:get()) end) end
end
local function cdo(path)
    local o=StaticFindObject(path); assert(valid(o),'CDO not loaded: '..path); return o
end
local function gi(o) return cdo('/Script/Engine.Default__GameplayStatics'):GetGameInstance(o) end
local function gs(o) return cdo('/Script/Engine.Default__GameplayStatics'):GetGameState(o) end
local function manager(pc) local g=gi(pc); return valid(g) and g.IngameUIManager end
local function attached(w) return valid(w) and valid(w:GetParent()) end
local WF='OpenedWidget_3_4ACF54C34C03E2DB3A8C3B809C094569'

-- H1: wire to POST ObjectiveGameMode:StartNewGameOverride(gm,join,acceptedOut).
-- Runs synchronously before Objective wrapper invokes parent StartNewGame/travel.
function M.hostRoundAdvance(gm,join,accepted)
    if Lifetime.transition then return end
    if not valid(gm) or not gm:HasAuthority() or join or not accepted then return false end
    local s=gs(gm); local mm=gi(gm).ObjectiveMatchManager
    if not valid(s) or not valid(mm) or mm.IsMatchOver or mm.CurrentRound~=2 or
       s.CurrentRound~=1 or s.State~=3 then return false end
    -- UE4SS TMap:ForEach includes retained disconnected participants too.
    local count=0
    local function clear(record)
        if valid(record) and (record.ObjectiveTeam==1 or record.ObjectiveTeam==2) and record.IsDead then
            record.IsDead=false; count=count+1
        end
    end
    local cleared=pcall(function()
        mm.Players:ForEach(function(_,value)
            clear(value:get())
        end)
    end)
    if not cleared then
    action("roster TMap unavailable; using connected-player death cleanup fallback")
    array(s.PlayerArray,function(_,ps)
        if valid(ps) and not ps.IsPendingDisconnect then
            if not ps:HasAuthority() then return end
            clear(ps.ObjectiveMatchPlayerState)
        end
    end) end
    return true,count
end
-- H2: wire to POST spectator ClientPossessed / HandleClientProcessed on owning client.
-- The caller supplies a cancellation token to invalidate this on travel or a newer request.
function M.clientRetrySelection(pc,epochIsCurrent,finished)
    if Lifetime.transition or not valid(pc) or not pc:IsLocalPlayerController() then return end
    local pawn=pc:K2_GetPawn(); local initialGS=gs(pc)
    local initialWorld=Lifetime.worldKey(pc)
    local initialEpoch=Lifetime.epoch
    if not initialWorld or not valid(initialGS) then return end
    local round=initialGS.CurrentRound>0 and initialGS.CurrentRound or nil
    if not valid(pawn) then pawn=nil end
    local function done() if finished then finished() end end
    local function attempt(n)
        -- Check the scalar epoch before touching retained engine objects.
        if Lifetime.transition or Lifetime.epoch~=initialEpoch then return done() end
        if not valid(pc) or Lifetime.worldKey(pc)~=initialWorld
            or not pc:IsLocalPlayerController() or not epochIsCurrent() then return done() end
        local ps=pc.PlayerState; local s=gs(pc)
        if not same(initialGS,s) or s.State~=0 then return done() end
        if round then
            if s.CurrentRound~=round then return done() end
        elseif s.CurrentRound>0 then round=s.CurrentRound end
        local current=pc:K2_GetPawn()
        if pawn then
            if not same(pawn,current) or Lifetime.worldKey(pawn)~=initialWorld then return done() end
        elseif valid(current) then pawn=current end
        if pawn and (Lifetime.worldKey(pawn)~=initialWorld
            or not pawn:GetClass():GetFullName():find('B_ObjectiveSpectator_C',1,true)) then return done() end
        if pawn and round and valid(ps) and ps.IsTeamInitialized and not ps.IsDead and
           (ps.Team==0 or ps.Team==1) and not ps.LocalIsReady then
            local m=manager(pc)
            if not valid(m) then
                if n<50 then later(100,function() try(function() attempt(n+1) end) end) end
                if n>=50 then done() end
                return
            end
            if attached(m.CustomizationWidget) then return done() end
            -- Native ShowCustomization replaces its pointer BEFORE OpenScreen's
            -- class-deduplication check. An existing mounted screen means no
            -- new request is needed (including one hidden by chat/subordinate UI).
            local mounted=false
            array(m.OpenedWidgets,function(_,entry)
                local w=entry[WF]
                if attached(w) and w:GetClass():GetFullName():find('WB_PlayerCustomization_C',1,true) then mounted=true end
            end)
            if mounted then return done() end
            pawn:ShowSuitableSelectionScreen()
            if attached(m.CustomizationWidget) then return done() end
        end
        if n<50 then later(100,function() try(function() attempt(n+1) end) end) else done() end
    end
    later(100,function() try(function() attempt(1) end) end)
    return true
end

-- H3: wire to POST UIManager:ShowCustomization(m,team,wardrobe), on owning client.
-- Requires confirmed duplicate/stale customization records. Do not clear unrelated screens.
function M.clientRepairCustomization(m,team,wardrobe,staleSubordinateProven)
    if Lifetime.transition then return end
    if not valid(m) then return end
    local w=m.CustomizationWidget; if not valid(w) then return end
    local old={}; local recorded=false
    array(m.OpenedWidgets,function(_,s)
        local existing=s[WF]
        if same(existing,w) then recorded=true end
        if valid(existing) and existing:GetClass():GetFullName()==w:GetClass():GetFullName()
           and not same(existing,w) then table.insert(old,existing) end
    end)
    local instance=gi(w); if not valid(instance) then return end
    local menu=instance.MenuUIManager; if not valid(menu) or not valid(menu.MasterScreen) then return end
    local canvas=menu.MasterScreen.CurrentScreenCanvas; if not valid(canvas) then return end
    -- Resolve the destination before removing any existing usable screen.
    for _,existing in ipairs(old) do m:CloseScreen(existing) end
    -- An existing record for w attached to an OLD canvas must also be removed before reopening.
    if not same(w:GetParent(),canvas) then
        if recorded then m:CloseScreen(w) end
        if staleSubordinateProven and m.IsSupordinateMenuOpen then m:CloseSubordinateMenu() end
        m:OpenScreen(w,true,0)
    end
    -- ShowCustomization already called SetTeamAndWardrobe on this NEW widget.
    -- Repeating it can auto-pick/save spells. OpenScreen uses the native
    -- chat/subordinate-aware focus path; do not force input mode here.
    return same(w:GetParent(),canvas)
end
-- H4: retry after owner/rule arrival. Supplies a rules-ready predicate because an empty
-- permitted list may be intentional. No random selections or saved loadout changes here.
function M.clientRebindSkillBlock(block,team,rulesReady)
    if Lifetime.transition then return end
    if not valid(block) or not rulesReady() then return false end
    local pc=block:GetOwningPlayer()
    if not valid(pc) or not pc:IsLocalPlayerController() or not valid(pc.PlayerState) then return false end
    block.OwningPlayer=pc.PlayerState
    -- Adaptation: SetTeam calls TryPickRandomSkills/SaveSkill. Rebind only local
    -- widget state, then rebuild with existing distinct, permitted selections.
    local selected=pc.PlayerState.SelectedObjectiveSkills
    if not selected then return false end
    local a,b={},{}
    if team==0 then
        a.Skill=selected.WitchMovement_7_277148B94174BD1D295A6E8350CF3B8F
        b.Skill=selected.WitchUtility_8_0A4175D745028494279E1788F5FC94B3
    elseif team==1 then
        a.Skill=selected.HunterMovement_5_972050544946E965CA999CB953A6C20C
        b.Skill=selected.HunterUtility_6_A50F517B4189925A416735804AF141C9
    else return false end
    if not valid(a.Skill) or not valid(b.Skill) or same(a.Skill,b.Skill) then return false end
    local state=gs(block); if not valid(state) then return false end
    local allowed=team==0 and state.AllowedWitchSkills or team==1 and state.AllowedHunterSkills
    local excluded={}
    array(state.UnlistedSkills,function(_,skill) if valid(skill) then excluded[skill:GetFullName()]=true end end)
    local hasA,hasB=false,false
    array(allowed,function(_,skill)
        if valid(skill) and not excluded[skill:GetFullName()] then
            if same(skill,a.Skill) then hasA=true end
            if same(skill,b.Skill) then hasB=true end
        end
    end)
    if not hasA or not hasB then return false end
    block.Team=team
    block:RefreshSkillList()
    return true
end
-- H5: host-only prototype from POST RefreshPawnServer(true). Capture the actual overlapping
-- wardrobe, plus token tied to controller/world/refresh request. No infinite input override.
-- Existing reliable client RPC can repair input on clients without installing Lua there.
function M.hostWardrobeReenable(pc,wardrobe,epochIsCurrent)
    if Lifetime.transition then return end
    if not valid(pc) or not pc:HasAuthority() or not valid(wardrobe) then return end
    local initialGS=gs(pc)
    local initialWorld=Lifetime.worldKey(pc)
    local function retry(n)
        if Lifetime.transition or Lifetime.worldKey(pc)~=initialWorld or Lifetime.worldKey(wardrobe)~=initialWorld or not epochIsCurrent() or not valid(pc) or not pc:HasAuthority() or not valid(wardrobe) or
           not same(initialGS,gs(pc)) then return end
        local s=gs(pc); if s.State~=1 and s.State~=2 then return end
        local pawn=pc:K2_GetPawn()
        if valid(pawn) and pawn:HasAuthority() and same(pawn,pc.CurrentControlledPawn) then
            local cls=pawn:GetClass():GetFullName()
            if cls:find('B_Hunter_C',1,true) or cls:find('B_ObjectiveWitch_C',1,true) then
                pc:ToggleRefreshPawnInputClient(true,wardrobe)
                action("wardrobe input re-enable RPC: "..pc:GetFullName())
                return -- success ends the request; never re-enable a newly reopened wardrobe
            end
        end
        if n<5 then later(250,function() try(function() retry(n+1) end) end) end
    end
    later(1100,function() try(function() retry(1) end) end)
end

-- H6: host boundary cleanup; acceptedNormalAdvance must be supplied by the H1 boundary check.
-- Clears the timer. Optional confirmed-boundary retirement uses UnPossess and actor destruction
-- to end the old spectator lifecycle; generic actor latent removal is not a reflected Lua API.
-- It does not respawn/force a Witch, change role or revive anyone during active play.
function M.hostCancelOldKillSpectators(gm,acceptedNormalAdvance,retireOldActors)
    if Lifetime.transition then return end
    if not acceptedNormalAdvance or not valid(gm) or not gm:HasAuthority() then return end
    local state=gs(gm); if not valid(state) or state.State~=3 then return end
    local sys=cdo('/Script/Engine.Default__KismetSystemLibrary')
    for _,pawn in ipairs(Registry.list('B_ObjectiveKillSpectator_C') or {}) do
        if valid(pawn) and pawn:HasAuthority() and
           not pawn:GetFullName():find('Default__',1,true) then
            if not same(gs(pawn),gs(gm)) then goto continue end
            sys:K2_ClearTimer(pawn,'TimerFinished')
            action("cancel old kill-spectator timer: "..pawn:GetFullName())
            if retireOldActors then
                local pc=pawn:GetController()
                if valid(pc) and pc:HasAuthority() and same(pc:K2_GetPawn(),pawn) then pc:UnPossess() end
                if valid(pawn) then pawn:K2_DestroyActor() end
                action("retire old kill spectator")
            end
            ::continue::
        end
    end
end
return M
