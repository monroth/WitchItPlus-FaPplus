return function(S)
    local R,C,U=S.R,S.C,S.U
    local damage='/Game/Blueprints/Player/Components/B_DamageHandler.B_DamageHandler_C:'
    local kills={}
    local fact,screen,view
    local timers={}
    local function cancel() for _,stop in ipairs(timers) do stop() end;timers={} end
    local reasons={wins=1,time=2,lives=4,props=5,kills=6,pots=7}
    local function round()
        local m=S.match
        return m and m.rounds[S.manager().CurrentRound]
    end
    local function teamCounts()
        local n={0,0}
        for _,ps in ipairs(S.players()) do
            if not ps.IsPendingDisconnect and not S.waiter(ps) and ps.ObjectiveTeam>0 then n[ps.ObjectiveTeam]=n[ps.ObjectiveTeam]+1 end
        end
        return n
    end
    S.onMatchHost.on('round_start',function(gs)
        local n=S.manager().CurrentRound
        S.match.rounds[n]={props=0,kills=0,pots=0,stacks={},full={},teams=teamCounts()}
    end)
    function S.countStacks(pot)
        local row=round()
        if not row or row.done then return end
        local key=pot:GetAddress()
        local prior=row.stacks[key] or 0
        if pot.Stacks>prior then row.props=row.props+pot.Stacks-prior;row.stacks[key]=pot.Stacks end
        if pot.Stacks>=pot.MaxStacks and not row.full[key] then row.full[key]=true;row.pots=row.pots+1 end
    end
    S.onMatchHost.pre(damage..'Kill',function(handler)
        kills[#kills+1]={handler=handler}
    end)
    S.onMatchHost.pre('/Game/Blueprints/Player/B_PlayerController.B_PlayerController_C:ServerHandleLastHit',function(pc)
        local frame=kills[#kills]
        if not frame or frame.counted then return end
        frame.counted=true
        local owner=frame.handler:GetOwner()
        local victim=R.valid(owner) and owner:GetController()
        local hunter=pc.PlayerState
        local witch=R.valid(victim) and victim.PlayerState
        local row=round()
        if row and not row.done and R.valid(hunter) and R.valid(witch) and hunter.Team==1 and witch.Team==0 and
            hunter.ObjectiveTeam>0 and witch.ObjectiveTeam>0 and hunter.ObjectiveTeam~=witch.ObjectiveTeam then
            row.kills=row.kills+1
        end
    end)
    S.onMatchHost.pre(damage..'RemoveTeamAndSetDead',function(handler)
        for i=#kills,1,-1 do if kills[i].handler==handler then table.remove(kills,i);break end end
    end)
    S.onMatchHost.post(damage..'Kill',function(handler)
        for i=#kills,1,-1 do if kills[i].handler==handler then table.remove(kills,i);break end end
    end)
    S.onMatchHost.post(S.path(S.O,'B_ObjectiveMatchManager','AddRoundState'),function(mm,state)
        if not R.valid(state) then return end
        local row=round()
        if row then
            row.time=state.Playtime;row.lives=state.WitchLivesLeft;row.finished=state.WinnerTeam==0
            row.winner=state.WinnerTeam;row.done=true
        end
    end)
    local function clearView()
        cancel()
        if not view then return end
        for _,row in ipairs(view.rows) do row:RemoveFromParent() end
        for _,original in ipairs(view.originals) do original.widget:SetVisibility(original.visibility) end
        view.parent.Slot:SetOffsets(view.offsets);view.parent.Slot:SetAutoSize(view.auto)
        view=nil
    end
    local function render(w)
        if view and view.screen:GetAddress()==w:GetAddress() and view.fact==fact then return end
        clearView()
        if not fact or not fact.normal then return end
        local source=w.WB_ObjectiveResultLine1
        local parent=source:GetParent()
        local offsets=parent.Slot:GetOffsets()
        view={screen=w,fact=fact,rows={},originals={},parent=parent,offsets={Left=offsets.Left,Top=offsets.Top,Right=offsets.Right,Bottom=offsets.Bottom},auto=parent.Slot.bAutoSize}
        for _,line in ipairs(S.values(parent:GetAllChildren())) do
            view.originals[#view.originals+1]={widget=line,visibility=line:GetVisibility()}
            line:SetVisibility(1)
        end
        local deciding
        local function tint(block,team)
            local colour=block.ColorAndOpacity
            colour.ColorUseRule=0
            colour.SpecifiedColor={R=team==1 and .05724899843335152 or 1,G=team==2 and 0 or 1,
                B=team==1 and 0 or team==2 and .11694200336933136 or 1,A=1}
            block:SetColorAndOpacity(colour)
        end
        for _,key in ipairs(S.order(fact.order)) do
            if not (key=='lives' and fact.infinite) then
                local row=StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary'):Create(w,source:GetClass(),w:GetOwningPlayer())
                parent:AddChild(row);view.rows[#view.rows+1]=row
                w:InitializeResultLine(row)
                row.Stat=FText(key=='wins' and 'Rounds won' or S.criteria[key])
                local function score(value)
                    if key~='time' then return tostring(value) end
                    value=math.max(0,math.floor(value));return string.format('%d:%02d',value//60,value%60)
                end
                row.TeamAScore=FText(score(fact.a[key]));row.TeamBScore=FText(score(fact.b[key]))
                local a,b=fact.a[key],fact.b[key]
                if key=='time' then
                    if fact.a.finished~=fact.b.finished then a,b=fact.a.finished and 1 or 0,fact.b.finished and 1 or 0
                    elseif fact.a.finished then a,b=-a,-b end
                end
                local winner=a==b and 0 or a>b and 1 or 2
                local role=key=='kills' and 1 or 0
                row.TeamATeam=winner==0 and 2 or winner==1 and role or 1-role
                row.TeamBTeam=winner==0 and 2 or winner==2 and role or 1-role
                if key==fact.reason then
                    deciding=#view.rows
                    tint(row.TeamAText,fact.team==1 and 1 or 2);tint(row.TeamBText,fact.team==2 and 1 or 2)
                end
                row:SetVisibility(2)
            end
        end
        local offsets=parent.Slot:GetOffsets()
        local height=math.max(offsets.Bottom,60*#view.rows)
        parent.Slot:SetAutoSize(false)
        parent.Slot:SetOffsets({Left=offsets.Left,Top=offsets.Top+(height-offsets.Bottom)*parent.Slot.LayoutData.Alignment.Y,Right=math.max(800,offsets.Right),Bottom=height})
        w.PlayVictoryLogo=false;w.CurrentResultLineIndex=C.session().gs.WinningReasonIndex
        local rows=view.rows
        local count=deciding or #rows
        for index=1,count do
            timers[#timers+1]=R.after(index*750,function()
                for i=index,index==deciding and #rows or index do
                    rows[i]:SetRenderOpacity(deciding and i>deciding and .4 or 1)
                    rows[i]:SetVisibility(0);rows[i]:PlayAnimation(rows[i].FadeIn,0,1,0,1,false)
                end
            end)
        end
        timers[#timers+1]=R.after((count+1)*750,function() w.PlayVictoryLogo=true end)
        w.Victory:SetToolTipText(FText(fact.reason=='draw' and 'Draw: all criteria equal' or 'Deciding criterion: '..S.criteria[fact.reason]))
    end
    S.onMatchHost.post(S.path(S.O,'B_ObjectiveMatchManager','GetWinnerTeam'),function(mm,gs,out,reason)
        local match=S.match
        local aRound=match and match.rounds[1]
        local bRound=match and match.rounds[2]
        local lost=false
        if bRound and reason:get()==0 then
            local now=teamCounts()
            for i=1,2 do if bRound.teams[i]>0 and now[i]==0 then lost=true end end
        end
        if lost or mm.SurrenderedTeam~=0 or not aRound or not bRound or not aRound.done or not bRound.done then
            fact={normal=false};C.net.publish('fap.result',fact);return
        end
        local wa,wb=mm.TeamAStartsAsWitch and aRound or bRound,mm.TeamAStartsAsWitch and bRound or aRound
        local a,b={},{}
        for _,key in ipairs({'props','lives','time','finished','pots'}) do a[key]=wa[key];b[key]=wb[key] end
        a.kills=wb.kills;b.kills=wa.kills
        a.wins=(wa.winner==0 and 1 or 0)+(wb.winner==1 and 1 or 0);b.wins=2-a.wins
        local winner,why=0,'draw'
        for _,key in ipairs(S.order(match.rules.order)) do
            local x,y=a[key],b[key]
            if key=='time' then
                if a.finished~=b.finished then x,y=a.finished and 1 or 0,b.finished and 1 or 0
                elseif a.finished then x,y=-x,-y end
            end
            if not (key=='lives' and match.rules.lives=='infinite') and x~=y then
                winner=x>y and 1 or 2;why=key;break
            end
        end
        out:set(winner);reason:set(reasons[why] or 0)
        fact={normal=true,team=winner,reason=why,a=a,b=b,order=match.rules.order,infinite=match.rules.lives=='infinite'}
        C.net.publish('fap.result',fact)
    end)
    C.net.watch('fap.result',function(value)
        if S.host() then return end
        fact=value
        if R.valid(screen) and S.inMatch() then render(screen) end
    end)
    local result='/Game/UserInterface/MatchResult/ObjectivemodeResult/WB_ObjectiveResultScreen.WB_ObjectiveResultScreen_C:'
    S.onMatch.post(result..'Construct',function(w)
        screen=w;render(w)
    end)
    S.onMatch.post('/Game/Blueprints/UserInterface/B_IngameUIManager.B_IngameUIManager_C:ShowObjectiveResult',function(ui)
        local w=R.valid(ui.ObjectiveResultWidget)
        if not w then return end
        -- Cached screens have no new Construct. Native display initializes its
        -- rows after an early fact can arrive; apply our rows after that body.
        clearView();screen=w;render(w)
    end)
    R.pre('/Script/UMG.UserWidget:Destruct',function(w)
        if screen and w:GetAddress()==screen:GetAddress() then clearView();screen=nil end
    end)
    R.on('world_end',function() cancel(); kills={};screen=nil;view=nil;fact=nil end)
end
