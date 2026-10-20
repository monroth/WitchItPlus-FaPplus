-- D's proposal helpers wired to scoped epochs, plus compact A/B diagnostics.
local M={}
local O="/Game/Blueprints/Gamemodes/ObjectiveMode/"
local P="/Game/Blueprints/Player/"
local I="/Game/Blueprints/UserInterface/"
local U="/Game/UserInterface/PlayerListAndTeamSelection/"
local function path(folder,asset,fn) return folder..asset.."."..asset.."_C:"..fn end
local WF="OpenedWidget_3_4ACF54C34C03E2DB3A8C3B809C094569"
local FF="HasFocus_6_6498D26743BF4852BC28D8AD83C97448"
function M.init(C,H)
    local Registry=FAPP_SERVICES.registry
    local api, selection, blocks, wardrobeEpoch, traces, modes, advances = {}, {}, {}, {}, {}, {}, {}
    local dir=debug.getinfo(1,'S').source:match('^@(.+[\\/])')
    local Lifetime=FAPP_SERVICES.lifetime
    local Clock=FAPP_SERVICES.event_clock
    local F=C.SoftLocks
    H.helpers.log=H.log
    local read=FAPP_SERVICES.runtime.read
    local call=FAPP_SERVICES.runtime.call
    local function name(o)
        if H.valid(o) then return o:GetFullName() end
        if o==nil then return "?" end
        return tostring(o)
    end
    local function same(a,b) return H.valid(a) and H.valid(b) and FAPP_SERVICES.lifetime.same(a,b) end
    local function array(a,fn)
        if type(a)=='table' and not a.ForEach then for i,p in ipairs(a) do
            fn(i,FAPP_SERVICES.runtime.unwrap(p))
        end elseif a then a:ForEach(function(i,p) fn(i,p:get()) end) end
    end
    local function game(o)
        if Lifetime.transition or not H.valid(o) then return end
        local s=H.object("/Script/Engine.Default__GameplayStatics"):GetGameState(o)
        if H.class(s,"B_ObjectiveGameState_C") and not name(s):find("Default__",1,true) then return s end
    end
    local function localPC(o)
        local pc=H.class(o,"B_ObjectivePlayerController_C") and o or call(o,"GetOwningPlayer")
        if not H.valid(pc) then pc=call(o,"GetController") end
        if H.class(pc,"B_ObjectivePlayerController_C") and call(pc,"IsLocalPlayerController")==true
            and game(pc) then return pc end
    end
    local function ui(pc)
        local gi=H.object("/Script/Engine.Default__GameplayStatics"):GetGameInstance(pc)
        return read(gi,"IngameUIManager"),gi
    end
    local function attached(w) return H.valid(w) and H.valid(call(w,"GetParent")) end
    local function psText(ps)
        local s="name="..name(call(ps,"GetPlayerName")).." PS="..name(ps)
        for _,k in ipairs({"ObjectiveTeam","Team","Lives","IsDead","IsReady","IsTeamInitialized","LocalIsReady"}) do
            s=s.." "..k.."="..name(read(ps,k))
        end
        local pc=read(ps,"PlayerController")
        local pawn=call(pc,"K2_GetPawn") or read(pc,"Pawn") or read(ps,"PawnPrivate")
        local waiting=H.authority(ps) and tostring(H.waiter(ps)~=nil) or "server-owned"
        local reconnect=H.authority(ps) and H.reconnect.player_status(ps) or "server-owned"
        s=s.." Pawn="..name(pawn).." waiter="..waiting.." reconnect="..reconnect
        local saved=read(ps,"ObjectiveMatchPlayerState")
        return s.." savedDead="..name(read(saved,"IsDead")).." pending="..name(read(ps,"IsPendingDisconnect"))
    end
    local function uiText(pc)
        local m,gi=ui(pc)
        local w,hud=read(m,"CustomizationWidget"),read(m,"HUDUserWidget")
        local canvas=read(read(read(gi,"MenuUIManager"),"MasterScreen"),"CurrentScreenCanvas")
        local s="LocalUI PC="..name(pc).." Custom="..name(w).." inViewport="..name(call(w,"IsInViewport"))..
            " parent="..name(call(w,"GetParent"))..
            " canvas="..name(canvas).." HUD="..name(hud).." inViewport="..name(call(hud,"IsInViewport"))..
            " inputMode="..(modes[pc:GetAddress()] or "unknown (no observed input-mode call)")..
            " HUDVisible="..name(read(m,"HUDIsVisible")).." subordinate="..name(read(m,"IsSupordinateMenuOpen"))..
            " chat="..name(read(read(m,"ChatWidget"),"ChatIsOpen"))..
            " ignoredMove="..name(call(pc,"IsMoveInputIgnored")).." ignoredLook="..name(call(pc,"IsLookInputIgnored"))
        array(read(m,"OpenedWidgets"),function(i,entry)
            local widget=read(entry,WF)
            s=s.." ["..i..":"..name(widget)..",parent="..name(call(widget,"GetParent"))..
                ",focus="..name(read(entry,FF))..",visible="..name(call(widget,"GetVisibility")).."]"
        end)
        return s
    end
    function api.dump()
        local context
        for _,gm in ipairs(Registry.list("B_ObjectiveGameMode_C") or {}) do
            local g,m,s=H.world(gm)
            if g then
                context=s
                local rs=H.reconnect.status()
                H.log("DUMP manager="..name(m).." round="..name(m.CurrentRound).." State="..name(s.State)..
                    " TimerIsCounting="..name(g.TimerIsCounting).." TimerRemainingSeconds="..name(read(g,"TimerRemainingSeconds"))..
                    " RemainingSeconds="..name(read(s,"RemainingSeconds")).." "..H.timer.status()..
                    " reconnectReady="..tostring(rs.ready).." hooks="..rs.hooks.."/"..rs.required_hooks)
                break
            end
        end
        for _,pc in ipairs(Registry.list("B_ObjectivePlayerController_C") or {}) do
            if localPC(pc) then
                context=context or game(pc)
                H.log(uiText(pc))
            end
        end
        if not context then return end -- do not dump menu/other mode stale objects
        if not H.authority(context) then
            H.log("DUMP client State="..name(context.State).." round="..name(context.CurrentRound)..
                " RemainingSeconds="..name(read(context,"RemainingSeconds")).." manager/timer ownership=server")
        end
        array(context.PlayerArray,function(_,ps) H.log(psText(ps)) end)
    end
    local function bind(id,key,description,fn)
        assert(type(Key)=="table" and Key[key]~=nil,"unknown UE4SS hotkey "..tostring(key))
        -- Runtime dispatch already enters on the game thread.
        FAPP_API.hotkey({id=id,default_chord=key,description=description,
            context={'lobby','match','creative'}},fn)
    end
    bind('pause',C.ManualPauseKey,'Pause/resume Fill a Pot+',H.timer.toggle)
    FAPP_API.command('fappdump',function() if C.Diagnostics then api.dump() end; return true end)
    local function add(folder,asset,fn,cb) H.hook(path(folder,asset,fn),cb) end
    -- Boundary is POST override / PRE wrapper travel. Never reset death on reconnect.
    add(O,"B_ObjectiveGameMode","StartNewGameOverride",function(self,join,out)
        local gm,m,s=H.world(self:get())
        local accepted=out:get()==true and join:get()==false
        if not gm or not accepted or s.State~=3 then return end
        local boundary=tostring(Lifetime.epoch)..":"..s:GetAddress()..":"..s.CurrentRound
        if advances[boundary] then return end
        advances[boundary]=true
        selection={}; blocks={}; wardrobeEpoch={}; H.helpers.reset()
        if C.Diagnostics then H.log("HALF accepted-restart epoch="..Lifetime.epoch.." gsRound="..s.CurrentRound..
            " managerRound="..m.CurrentRound.." matchOver="..tostring(m.IsMatchOver)) end
        if F.hostRoundAdvance and m.CurrentRound==2 and s.CurrentRound==1 and not m.IsMatchOver then
            local cleared,count=H.helpers.hostRoundAdvance(gm,false,true)
            if cleared then H.log("HALF cleared persisted deaths for round 2 count="..tostring(count)) end
            -- Retained disconnected records are absent from PlayerArray.
            H.reconnect.clear_round_deaths()
        end
        if F.hostCancelOldKillSpectators then
            -- Retire at a proven ended-round boundary, also ends frame-retry lifecycle.
            H.helpers.hostCancelOldKillSpectators(gm,true,true)
            H.log("SoftLock: retired old kill spectators at accepted restart")
        end
    end)
    add(O,"B_ObjectiveMatchManager","TearDown",function(self)
        if game(self:get()) then api.reset() end -- same-world next match must allow a fresh boundary
    end)
    local function scheduleSelection(o)
        if Lifetime.transition or not F.clientRetrySelection then return end
        local pc=localPC(o)
        if not pc then return end
        local pawn=call(pc,"K2_GetPawn")
        local s=game(pc)
        if not s or s.State~=0 or H.valid(pawn) and not H.class(pawn,"B_ObjectiveSpectator_C") then return end
        local key=Lifetime.key(pc)
        if not key then return end
        local existing=selection[key]
        if existing and existing.epoch==Lifetime.epoch and Clock.now()<=existing.deadline
            and same(existing.gs,s) and (not existing.round or existing.round==s.CurrentRound)
            and (not existing.pawn or same(existing.pawn,pawn)) then return end
        -- Replicated round/pawn fields can arrive after this one-shot event.
        -- Retain intent now, then pin each identity when it first becomes known.
        local token={pc=pc,pawn=H.valid(pawn) and pawn or nil,gs=s,
            round=s.CurrentRound>0 and s.CurrentRound or nil,epoch=Lifetime.epoch,deadline=Clock.now()+6}
        selection[key]=token
        local queued=H.helpers.clientRetrySelection(pc,function()
            if Lifetime.transition or token.epoch~=Lifetime.epoch or not F.clientRetrySelection
                or selection[key]~=token or not H.valid(pc) or not same(game(pc),s) then return false end
            local currentPawn=call(pc,"K2_GetPawn")
            if token.pawn then
                if not same(token.pawn,currentPawn) then return false end
            elseif H.valid(currentPawn) then
                if not H.class(currentPawn,"B_ObjectiveSpectator_C") then return false end
                token.pawn=currentPawn
            end
            if token.round then
                if s.CurrentRound~=token.round then return false end
            elseif s.CurrentRound>0 then token.round=s.CurrentRound end
            return true
        end,function()
            if selection[key]==token then selection[key]=nil end
        end)
        if not queued then selection[key]=nil; return end
        H.log("SoftLock: bounded selection retry for "..name(pc))
    end
    for _,fn in ipairs({"ClientPossessed","HandleClientProcessed"}) do
        add(P.."Pawns/","B_Spectator",fn,function(self,pc) scheduleSelection(pc:get()) end)
    end
    add(O,"B_ObjectiveSpectator","ShowSuitableSelectionScreen",function(self) scheduleSelection(self:get()) end)
    local function queueBlock(b)
        if Lifetime.transition or not F.clientRebindSkillBlock or not H.valid(b) then return end
        local pc=localPC(b)
        local owner=call(b,"GetOwningPlayer")
        if H.valid(owner) and not pc then return end
        local s=game(b)
        local key=Lifetime.key(b)
        if not s or not key then return end
        local parent=call(b,"GetParent")
        blocks[key]={b=b,gs=s,pc=pc,epoch=Lifetime.epoch,world=Lifetime.worldKey(b),
            parent=H.valid(parent) and parent or nil,
            round=s.CurrentRound>0 and s.CurrentRound or nil,deadline=Clock.now()+5}
    end
    for _,fn in ipairs({"Construct","SetTeam"}) do add(U,"WB_SkillSelectionBlock",fn,function(self) queueBlock(self:get()) end) end
    add(I,"B_IngameUIManager","ShowCustomization",function(self,team,wardrobe)
        local m=self:get()
        local w=read(m,"CustomizationWidget")
        local pc=localPC(w)
        if not pc then return end
        wardrobeEpoch[pc:GetAddress()]=nil -- a newer UI open cancels pending input restoration
        if not F.clientRepairCustomization then return end
        -- Never clear subordinate/chat state; only proven duplicate class / wrong canvas.
        local duplicate=false
        array(read(m,"OpenedWidgets"),function(_,entry)
            local old=read(entry,WF)
            if H.valid(old) and H.valid(w) and name(old:GetClass())==name(w:GetClass()) and not same(old,w) then duplicate=true end
        end)
        local _,gi=ui(pc)
        local canvas=read(read(read(gi,"MenuUIManager"),"MasterScreen"),"CurrentScreenCanvas")
        if duplicate or (H.valid(canvas) and not same(call(w,"GetParent"),canvas)) then
            if H.helpers.clientRepairCustomization(m,team:get(),wardrobe:get(),false) then
                H.log("SoftLock: repaired customization stack on "..name(pc))
            end
        end
        if C.Diagnostics then H.log("UI customization wardrobe="..tostring(wardrobe:get())..
            " duplicate="..tostring(duplicate).." attached="..tostring(attached(w))..
            " PS="..name(read(pc,"PlayerState")).." round="..game(pc).CurrentRound) end
    end)
    add(P,"B_PlayerController","RefreshPawnServer",function(self,fromWardrobe)
        local pc=self:get()
        if not F.hostWardrobeReenable or not fromWardrobe:get() or not H.authority(pc) or not H.world(pc) then return end
        local pawn=call(pc,"K2_GetPawn")
        local wc=StaticFindObject("/Game/Blueprints/StaticProps/Placeable/Utility/BP_Wardrobe.BP_Wardrobe_C")
        if not H.valid(pawn) or not H.valid(wc) then return end
        local actual,count=nil,0
        array(Registry.list('BP_Wardrobe_C'),function(_,w)
            if H.valid(w) and H.authority(w) and same(w:GetWorld(),pawn:GetWorld())
                and pawn:IsOverlappingActor(w) then actual=w; count=count+1 end
        end)
        if count~=1 then H.log("SoftLock: wardrobe retry skipped; overlap count="..count); return end
        local _,mm,s=H.world(pc)
        local key=pc:GetAddress(); local token={round=mm.CurrentRound,gs=s}; wardrobeEpoch[key]=token
        H.helpers.hostWardrobeReenable(pc,actual,function()
            local g,m,current=H.world(pc)
            return F.hostWardrobeReenable and wardrobeEpoch[key]==token and g~=nil and same(current,token.gs) and m.CurrentRound==token.round
        end)
        H.log("SoftLock: bounded wardrobe input retry for "..name(pc))
    end)
    local nextRetry=0
    function api.pending() return H.helpers.pending() or next(selection)~=nil or next(blocks)~=nil end
    function api.poll(time)
        if Lifetime.transition then api.reset(); return end
        H.helpers.poll(time)
        if not next(selection) and not next(blocks) then return end
        if Clock.now()<nextRetry then return end
        nextRetry=Clock.now()+.1
        for key,r in pairs(selection) do
            if r.epoch~=Lifetime.epoch or Clock.now()>r.deadline or not F.clientRetrySelection
                or not H.valid(r.pc) or not same(game(r.pc),r.gs)
                or r.pawn and not same(call(r.pc,"K2_GetPawn"),r.pawn)
                or r.round and r.gs.CurrentRound~=r.round or r.gs.State~=0 then selection[key]=nil end
        end
        for key,r in pairs(blocks) do
            local b,s=r.b,r.gs
            if r.epoch~=Lifetime.epoch or Clock.now()>r.deadline or not F.clientRebindSkillBlock
                or not H.valid(b) or Lifetime.worldKey(b)~=r.world or not same(game(b),s)
                or r.round and s.CurrentRound~=r.round then
                blocks[key]=nil
            else
                local pc=localPC(b); local owner=call(b,"GetOwningPlayer"); local parent=call(b,"GetParent")
                if r.pc and not same(r.pc,pc) or H.valid(owner) and not pc
                    or r.parent and not same(r.parent,parent) then blocks[key]=nil
                else
                if pc and not r.pc then r.pc=pc end
                if H.valid(parent) and not r.parent then r.parent=parent end
                if not r.round and s.CurrentRound>0 then r.round=s.CurrentRound end
                local ps=read(pc,"PlayerState"); local team=read(b,"Team")
                -- Repair an already mounted native block even in the lobby.
                -- Only automatic screen opening requires a positive round.
                if attached(b) and H.valid(ps) and (team==0 or team==1) then
                    local rules=read(s,team==0 and "AllowedWitchSkills" or "AllowedHunterSkills")
                    local count=0; array(rules,function(_,v) if H.valid(v) then count=count+1 end end)
                    local children=call(read(b,"SkillListWrap"),"GetChildrenCount")
                    local missing=not H.valid(read(b,"CurrentMovementSkill")) or not H.valid(read(b,"CurrentUtilitySkill"))
                    if count>0 and (not same(read(b,"OwningPlayer"),ps) or children==0 or missing) then
                        if H.helpers.clientRebindSkillBlock(b,team,function() return count>0 end) then
                            blocks[key]=nil; H.log("UI rebound local skill block "..name(b).." team="..team..
                                " owner="..name(read(b,"OwningPlayer")).." movement="..name(read(b,"CurrentMovementSkill"))..
                                " utility="..name(read(b,"CurrentUtilitySkill")))
                        end
                    elseif count>0 then blocks[key]=nil end
                end
                end
            end
        end
    end
    -- Compact subset of hangs/hooks.txt: persistence/readiness + UI ownership/focus.
    do -- register once; runtime Diagnostics gates output
        local selected={
            {O,"B_ObjectiveGameMode",{"HandleEndMatchOverride","StartNewGameOverride","HandleStartMatchOverride","HandleStartSeek","RespawnWitch"}},
            {O,"B_ObjectivePlayerState",{"SaveDataToMatchPlayerState","InitializeFromMatchPlayerState","SetTeamByRoundAndObjectiveTeam"}},
            {O,"B_ObjectiveSpectator",{"ShowSuitableSelectionScreen"}},
            {O,"B_ObjectiveKillSpectator",{"ReceivePossessed","TimerFinished"}},
            {"/Game/Blueprints/Core/","B_GameMode",{"CheckIfAllPlayersAreReady"}},
            {P.."Pawns/","B_Spectator",{"ClientPossessed","HandleClientProcessed","RefreshScreen"}},
            {I,"B_IngameUIManager",{"ShowCustomization","OpenScreen","CloseScreen","RefreshFocus","Set Focused Widget Input Mode"}},
            {P,"B_PlayerController",{"RefreshPawnServer","ToggleRefreshPawnInputClient"}},
            {U,"WB_SkillSelectionBlock",{"Construct","SetTeam"}},
            {U,"WB_PlayerCustomization",{"OnApply","OnBack"}},
        }
        for _,spec in ipairs(selected) do for _,fn in ipairs(spec[3]) do
            add(spec[1],spec[2],fn,function(self,...)
                if not C.Diagnostics or not C.TraceTransitionDetails then return end
                local o=self:get(); local s=game(o)
                if not s then return end
                -- Gate BEFORE roster/widget/focus inspection. Repeated readiness
                -- checks in a stable phase must not repeatedly walk engine arrays.
                local key=fn..":"..o:GetAddress()..":"..Lifetime.epoch..":"..tostring(s.CurrentRound)..":"..tostring(s.State)
                local args={...}
                for _,p in ipairs(args) do
                    local v=p:get()
                    key=key..":"..tostring(H.valid(v) and v:GetAddress() or v)
                end
                if traces[key] then return end
                traces[key]=true
                local text="TRACE "..fn.." "..name(o).." auth="..name(call(o,"HasAuthority"))..
                    " round="..name(s.CurrentRound).." State="..name(s.State)
                for _,p in ipairs({...}) do local v=p:get(); text=text.." arg="..name(v)
                    if H.valid(v) and call(v,"GetParent") then text=text.." parent="..name(call(v,"GetParent")) end
                end
                if H.class(o,"B_ObjectivePlayerState_C") then text=text.." "..psText(o) end
                if spec[2]=="WB_SkillSelectionBlock" then
                    text=text.." owner="..name(read(o,"OwningPlayer")).." team="..name(read(o,"Team"))..
                        " movement="..name(read(o,"CurrentMovementSkill")).." utility="..name(read(o,"CurrentUtilitySkill"))..
                        " slots="..name(call(read(o,"SkillListWrap"),"GetChildrenCount"))
                end
                if fn=="CheckIfAllPlayersAreReady" then array(s.PlayerArray,function(_,ps) text=text.." ["..psText(ps).."]" end) end
                if spec[2]=="B_IngameUIManager" then
                    local w=read(o,"CustomizationWidget"); local pc=localPC(w)
                    if pc then text=text.." "..uiText(pc) end
                end
                H.log(text)
            end)
        end end
        for _,mode in ipairs({"UIOnlyEx","GameOnly","GameAndUIEx"}) do
            H.hook("/Script/UMG.WidgetBlueprintLibrary:SetInputMode_"..mode,function(_,pcParam)
                local pc=pcParam:get()
                -- Input-mode observation needs no roster, world or UI traversal.
                -- The native signature already supplies a PlayerController.
                if C.Diagnostics and not Lifetime.transition then
                    local id=call(pc,'GetAddress'); if id and id~=0 then modes[id]=mode end
                end
            end)
        end
    end
    function api.reset() selection={}; blocks={}; wardrobeEpoch={}; traces={}; modes={}; advances={}; nextRetry=0; H.helpers.reset() end
    return api
end
return M
