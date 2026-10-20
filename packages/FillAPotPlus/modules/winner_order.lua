-- WIN1: two-half FaP comparison. Collection is driven by native events only.
local M={default="wins,pots,props,lives,kills,time"}
M.labels={wins="Halves won",pots="Full cauldrons",props="Delivered props",lives="Witch lives remaining",kills="Hunter kills",time="Time"}
M.reasons={wins=1,time=2,lives=4,props=5,kills=6,pots=7}
function M.parse(value)
    if type(value)~="string" then return end
    local order,seen={},{}
    for key in value:gmatch("[^,]+") do
        if not M.labels[key] or seen[key] then return end
        seen[key]=true; order[#order+1]=key
    end
    if #order==6 and table.concat(order,",")==value then return order end
end
-- Higher values win, except time: finish faster; if neither finishes, survive longer.
function M.compare(order,a,b,infinite)
    for _,key in ipairs(assert(M.parse(order))) do
        local x,y=a[key],b[key]
        if key=="time" then
            if a.finished~=b.finished then x,y=a.finished and 1 or 0,b.finished and 1 or 0
            elseif a.finished then x,y=-x,-y end
        end
        if not (key=="lives" and infinite) and x~=y then return x>y and 1 or 2,key end
    end
    return 0,"draw"
end
function M.init(C,H)
    local api,match,title={}
    local uiRevision,screenCache=0,{}
    local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
    local Context=dofile(dir..'match_context.lua')
    local Identity=FAPP_SERVICES.match_identity
    local panel
    local read=FAPP_SERVICES.runtime.read
    local function value(p) return p:get() end
    local O="/Game/Blueprints/Gamemodes/ObjectiveMode/"
    local killPath="/Game/Blueprints/Player/Components/B_DamageHandler.B_DamageHandler_C:RemoveTeamAndSetDead"
    local function path(asset,fn) return O..asset.."."..asset.."_C:"..fn end
    local said={}
    local function why(key,msg) if not said[key] then said[key]=true; H.log('WIN1 skip: '..msg) end end
    local function session(mm)
        local gi=Context.instance(mm)
        return Identity.session(gi)
    end
    local function retain(mm,data)
        local owner=session(mm); if not owner then return end
        owner.winner=data; match=owner.winner
        return match
    end
    local function current(mm)
        local owner=session(mm)
        match=owner and owner.winner
        if not match then return end
        local key=Identity.key(mm)
        if match.id==key then return match end
        if mm.CurrentRound==2 and match.rounds[1] then match.id=key; return match end
    end
    local function teams(gs)
        local counts={0,0}
        for _,ps in ipairs(FAPP_SERVICES.runtime.values(gs and gs.PlayerArray)) do
            if H.valid(ps) and ps.IsPendingDisconnect~=true and not H.waiter(ps) and (ps.ObjectiveTeam==1 or ps.ObjectiveTeam==2) then
                counts[ps.ObjectiveTeam]=counts[ps.ObjectiveTeam]+1
            end
        end
        return counts
    end
    local function early(mm,gs,s)
        if (read(mm,'SurrenderedTeam') or 0)~=0 then return true end
        local a,b=s and s.rounds[1],s and s.rounds[2]
        if not a or not b or not a.done or not b.done then return true end
        local now=teams(gs); local started=b.teams or {0,0}
        -- Reason zero also means an intentionally empty side. Only a side lost
        -- since this half began is evidence of native disconnect termination.
        return (started[1]>0 and now[1]==0) or (started[2]>0 and now[2]==0)
    end
    local function begin(gm)
        local g,mm,gs=H.world(gm); if not g then return end
        local n=mm.CurrentRound; if n~=1 and n~=2 then why('begin-round','HandleStartMatch with manager round '..tostring(n)); return end
        local s=current(mm)
        if n==1 and (not s or not s.rounds[1] or s.rounds[1].done) then
            s={id=Identity.key(mm),order=C.WinnerOrder or M.default,infinite=C.MaxLives=="infinite",rounds={}}
            s=retain(mm,s); title=nil; uiRevision=uiRevision+1
        end
        if not s then why('begin-mid','round '..n..' started without round-1 record (mid-match attach)'); return end -- attaching mid-match must not invent earlier statistics
        local owner=session(mm); if owner then owner.normalResult=false end
        said={}; H.log('WIN1 tracking round '..n)
        s.round=n
        s.rounds[n]=s.rounds[n] or {teams=teams(gs),props=0,kills=0,fullPots=0,pots={},full={},available=H.installed(killPath)}
    end
    H.hook(path("B_ObjectiveGameMode","HandleStartMatchOverride"),function(self) begin(value(self)) end)
    -- Called at the native Stacks dirty mark, BEFORE a target delivery can end the half.
    function api.stacks(pot)
        if not H.class(pot,"B_ObjectiveCauldron_C") then return end
        local gm,mm,gs=H.world(pot); if not gm or gs.State~=2 then return end
        local s=current(mm); local r=s and s.rounds[s.round]
        if not r or r.done then return end
        local n=read(pot,"Stacks"); if type(n)~="number" or n<0 then return end
        local key=pot:GetFullName()..":"..pot:GetAddress(); local prior=r.pots[key] or 0
        -- Native stacks are monotonic within a half. Duplicate marks never add deliveries.
        if n>prior then r.props=r.props+n-prior; r.pots[key]=n end
        -- A cauldron is full at its native MaxStacks (same test as the native fill check).
        local max=read(pot,"MaxStacks")
        if type(max)=="number" and max>0 and n>=max and not r.full[key] then r.full[key]=true; r.fullPots=r.fullPots+1 end
    end
    -- Kill calls this once, after score credit and before SetSpectator/OnKilled
    -- can finish the half. OwnerPlayerState and KillerPlayerState are native fields.
    H.hook(killPath,function(self)
        local ctx=value(self)
        if not H.class(ctx,'B_DamageHandler_C') then return end
        local gm,mm,gs=H.world(ctx); if not gm or gs.State~=2 then return end
        local s=current(mm); local r=s and s.rounds[s.round]; if not r or r.done then return end
        local hunter=read(ctx,'KillerPlayerState'); local witch=read(ctx,'OwnerPlayerState')
        if not H.class(hunter,'B_ObjectivePlayerState_C') or not H.class(witch,'B_ObjectivePlayerState_C')
            or hunter.Team~=1 or witch.IsWitchTeam~=true or H.waiter(hunter) or H.waiter(witch)
            or (hunter.ObjectiveTeam~=1 and hunter.ObjectiveTeam~=2)
            or (witch.ObjectiveTeam~=1 and witch.ObjectiveTeam~=2)
            or hunter.ObjectiveTeam==witch.ObjectiveTeam then return end
        r.kills=r.kills+1
    end)
    H.hook(path("B_ObjectiveMatchManager","AddRoundState"),function(self,state)
        local mm=value(self); local gm=H.managerWorld(mm); if not gm then why("addworld","AddRoundState outside host Objective world"); return end
        local s=current(mm); local r=s and s.rounds[s.round]; local native=value(state)
        if not r or r.done or not H.valid(native) then why("add"..tostring(s and s.round),"AddRoundState without an open round record (match="..tostring(s~=nil)..")"); return end
        if type(native.Playtime)~="number" or type(native.WitchLivesLeft)~="number" then return end
        r.time=native.Playtime; r.lives=native.WitchLivesLeft; r.finished=native.WinnerTeam==0
        r.winner=native.WinnerTeam; r.done=true
    end)
    H.hook(path("B_ObjectiveMatchManager","GetWinnerTeam"),function(self,_,winner,reason)
        -- Native reason zero also covers intentionally empty teams; completed halves
        -- and participant loss distinguish that case from surrender/disconnect.
        -- Preserve that branch, including reconnect's own integrity/grace policy.
        if type(value(reason))~="number" then return end
        local mm=value(self); local gm=H.managerWorld(mm); if not gm then why("world","GetWinnerTeam outside host Objective world"); return end
        local s=current(mm); local first=s and s.rounds[1]; local second=s and s.rounds[2]
        if value(reason)==0 and early(mm,value(_),s) then
            -- A repeated reward query can receive our draw's reason 0. Preserve
            -- its complete presentation; all actual native early outcomes stay native.
            if s and s.result and s.result.key=="draw" and value(winner)==0
                and first and second and first.done and second.done then return end
            s=s or {id=Identity.key(mm),order=C.WinnerOrder or M.default,infinite=C.MaxLives=="infinite",rounds={}}
            s=retain(mm,s); local owner=session(mm); if owner then owner.normalResult=false end
            s.result=nil; uiRevision=uiRevision+1; s.fallback="Match ended early"
            if not s.earlyLogged then H.log("WIN3 Match ended early: native result winner="..tostring(value(winner))); s.earlyLogged=true end
            return
        end
        if not first or not second or not first.done or not second.done then
            why('rounds','winner query without two finished halves (r1='..tostring(first and first.done)..' r2='..tostring(second and second.done)..')'); return
        end
        if not first.available or not second.available or not H.installed(killPath) then
            if not s.warned then H.log("WIN1 native fallback: kill collection hook unavailable"); s.warned=true end
            return
        end
        if (first.winner~=0 and first.winner~=1) or (second.winner~=0 and second.winner~=1) then why('winners','native half winners '..tostring(first.winner)..'/'..tostring(second.winner)); return end
        local a,b={},{}
        local aw=mm.TeamAStartsAsWitch
        if type(aw)~="boolean" then why('aw','TeamAStartsAsWitch unreadable'); return end
        local wa,wb=aw and first or second,aw and second or first
        for _,key in ipairs({"props","lives","time","finished"}) do a[key]=wa[key]; b[key]=wb[key] end
        a.pots=wa.fullPots or 0; b.pots=wb.fullPots or 0
        a.kills=wb.kills; b.kills=wa.kills -- kills belong to the hunters of the opposite half
        a.wins=(wa.winner==0 and 1 or 0)+(wb.winner==1 and 1 or 0); b.wins=2-a.wins
        local team,key=M.compare(s.order,a,b,s.infinite)
        winner:set(team); reason:set(M.reasons[key] or 0)
        if not s.result or s.result.key~=key or s.result.team~=team then
            local function stats(t)
                return "wins="..t.wins.." pots="..t.pots.." props="..t.props.." lives="..t.lives..
                    " kills="..t.kills.." time="..t.time.." finished="..tostring(t.finished)
            end
            H.log("WIN1 winner="..team.." criterion="..key.." order="..s.order..
                " infinite="..tostring(s.infinite).." A "..stats(a).." B "..stats(b))
        end
        local owner=session(mm); if owner then owner.normalResult=true end
        s.result={team=team,key=key,a=a,b=b}; s.fallback=nil; uiRevision=uiRevision+1
    end)
    panel=dofile(dir..'result_screen.lua').init(C,H,function(w)
        local gm,mm,gs=H.world(w); if not gm then return end -- authority only
        local s=current(mm)
        local fallback=s and s.fallback
        local completedDraw=s and s.result and s.result.key=="draw" and gs.WinnerObjectiveTeam==0
            and s.round==2 and mm.CurrentRound==2
        if gs.WinningReasonIndex==0 and not completedDraw and not (s and s.result) then fallback="Match ended early" end
        if not fallback and not (s and s.result) then
            fallback=gs.WinningReasonIndex==0 and gs.WinnerObjectiveTeam~=0
                and "Match ended early" or "Match result"
        end
        return {order=s and s.order or C.WinnerOrder or M.default,
            infinite=s and s.infinite or (not s and C.MaxLives=="infinite"),result=s and s.result,fallback=fallback}
    end)
    function api.resultpreview() return panel.preview() end
    local UI="/Game/UserInterface/MatchResult/ObjectivemodeResult/WB_ObjectiveResultScreen.WB_ObjectiveResultScreen_C:"
    local function update(w)
        if H.Lifetime.transition or w==nil then return end
        -- Native Construct never assigns ObjectiveGameState: UpdateStats on the
        -- first UI Tick does. Resolve the host world at the ready/open event.
        local gs=read(w,"ObjectiveGameState")
        if not H.class(gs,"B_ObjectiveGameState_C") then local _,_,current=H.world(w); gs=current end
        local address=w:GetAddress(); local cache=screenCache[address]
        if cache and cache.epoch==H.Lifetime.epoch and cache.revision==uiRevision and gs
            and cache.reason==gs.WinningReasonIndex and cache.team==gs.WinnerObjectiveTeam then
            title=cache.title; return
        end
        if not H.valid(w) or not H.class(gs,"B_ObjectiveGameState_C") then return end
        cache={epoch=H.Lifetime.epoch,revision=uiRevision,reason=gs.WinningReasonIndex,team=gs.WinnerObjectiveTeam}
        screenCache[address]=cache
        panel.refresh(w,nil,gs)
        -- Guests lack the host's delivery/kill counters and frozen order. WIN3
        -- leaves their entire native screen, including its title, untouched.
        if not H.world(w) then title=nil; return end
        local label
        for key,index in pairs(M.reasons) do if gs.WinningReasonIndex==index then label=M.labels[key] end end
        if gs.WinnerObjectiveTeam==0 then label="Draw"
        elseif gs.WinningReasonIndex==0 then
            local _,mm=H.world(w); local s=mm and current(mm)
            label=s and s.result and M.labels[s.result.key] or "Match ended early"
        end
        -- Early end keeps native rows and outcome; only the WIN1 title adds a note.
        local pc=w:GetOwningPlayer(); local ps=H.valid(pc) and read(pc,"PlayerState")
        if not label or not H.class(ps,"B_ObjectivePlayerState_C") then title=nil; return end
        local base=gs.WinnerObjectiveTeam==0 and "Draw" or (gs.WinnerObjectiveTeam==ps.ObjectiveTeam and "Victory!" or "Lost!")
        title=FText(gs.WinnerObjectiveTeam==0 and "Draw" or base.." - "..label)
        cache.title=title
        -- Retain WIN1 title/tooltip behavior alongside native animated lines.
        if H.valid(w.Victory) then
            w.Victory:SetText(title)
            local text="Deciding criterion: "..label
            local result=match and match.result
            if result then
                text=text.."\nFull cauldrons: A "..result.a.pots.." / B "..result.b.pots..
                    "\nDelivered props: A "..result.a.props.." / B "..result.b.props..
                    "\nHunter kills: A "..result.a.kills.." / B "..result.b.kills..
                    "\nDelivered props counts props accepted by cauldrons: standard full pot = 2, half = 1."
            end
            w.Victory:SetToolTipText(FText(text))
        end
    end
    H.hook(UI.."Construct",function(self)
        local w=value(self); screenCache[w:GetAddress()]=nil; title=nil
        panel.construct(w); update(w)
    end)
    H.hook('/Script/UMG.UserWidget:Destruct',function(self)
        screenCache[value(self):GetAddress()]=nil
    end)
    -- The result asset may load and Construct before its hook retry is consumed.
    -- The already-live UI manager supplies the cached widget after native open.
    H.hook("/Game/Blueprints/UserInterface/B_IngameUIManager.B_IngameUIManager_C:ShowObjectiveResult",function(self)
        update(read(value(self),"ObjectiveResultWidget"))
    end)
    -- Travel clears presentation handles; manager identity/TearDown owns metrics.
    function api.reset() title=nil; screenCache={}; uiRevision=uiRevision+1; panel.reset() end
    H.hook(path("B_ObjectiveMatchManager","TearDown"),function(self)
        local manager=value(self)
        if H.managerWorld(manager) and (manager.CurrentRound~=1 or manager.IsMatchOver==true) then
            local owner=session(manager); if owner then owner.winner=nil end
            match=nil; title=nil; screenCache={}; uiRevision=uiRevision+1
        end
    end)
    return api
end
return M
