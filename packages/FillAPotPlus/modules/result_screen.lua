-- Custom native-class rows are isolated from the per-frame native statistics repaint.
local M={}
local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
local Rows=dofile(dir..'result_rows.lua')
local semantics={wins=1,time=2,pots=3,lives=4}
function M.init(C,H,presentation)
    local api,records,owned,last={},{},{},nil
    local sequence=0
    local L=H.Lifetime
    local read=FAPP_SERVICES.runtime.read
    local work=assert(FAPP_WORK)
    local function native(v) assert(v~=nil and type(v)~='table','native property struct required'); return v end
    local function id(o) return tostring(o:GetAddress())..':'..o:GetFullName() end
    local function text(v)
        if type(v)=='string' then return v end
        local ok,s=pcall(function() return v:ToString() end); return ok and s or ''
    end
    local function live(w,gs)
        if L.transition or not H.valid(w) or not H.class(w,'WB_ObjectiveResultScreen_C') then return false end
        gs=gs or read(w,'ObjectiveGameState')
        if not H.class(gs,'B_ObjectiveGameState_C') then local _,_,current=H.world(w); gs=current end
        if H.class(gs,'B_ObjectiveGameState_C') and gs.State==3 then return gs end
    end
    local function slotData(slot)
        local p=slot.Padding
        return {left=p.Left,right=p.Right,top=p.Top,bottom=p.Bottom,
            h=slot.HorizontalAlignment,v=slot.VerticalAlignment,rule=slot.Size.SizeRule,size=slot.Size.Value}
    end
    local function setSlot(slot,s)
        local p=native(slot.Padding); p.Left=s.left; p.Right=s.right; p.Top=s.top; p.Bottom=s.bottom
        slot:SetPadding(p); slot:SetHorizontalAlignment(s.h); slot:SetVerticalAlignment(s.v)
        local z=native(slot.Size); z.SizeRule=s.rule; z.Value=s.size; slot:SetSize(z)
    end
    local function canvasData(slot)
        local l=slot.LayoutData
        return {left=l.Offsets.Left,top=l.Offsets.Top,width=l.Offsets.Right,height=l.Offsets.Bottom,
            minx=l.Anchors.Minimum.X,miny=l.Anchors.Minimum.Y,maxx=l.Anchors.Maximum.X,maxy=l.Anchors.Maximum.Y,
            ax=l.Alignment.X,ay=l.Alignment.Y,auto=slot.bAutoSize,z=slot.ZOrder}
    end
    local function setCanvas(slot,s)
        local l=native(slot.LayoutData)
        l.Offsets.Left=s.left; l.Offsets.Top=s.top; l.Offsets.Right=s.width; l.Offsets.Bottom=s.height
        l.Anchors.Minimum.X=s.minx; l.Anchors.Minimum.Y=s.miny; l.Anchors.Maximum.X=s.maxx; l.Anchors.Maximum.Y=s.maxy
        l.Alignment.X=s.ax; l.Alignment.Y=s.ay
        slot:SetLayout(l); slot:SetAutoSize(s.auto); slot:SetZOrder(s.z)
    end
    -- TextBlock_1.Text binds to the row's Stat FText, not a Text property.
    -- Write the binding source after attachment/native initialization; the label
    -- itself is not an exposed widget variable in this cooked class.
    local function label(line,s)
        line.Stat=FText(s)
    end
    local function build(w)
        local parent=w.WB_ObjectiveResultLine1:GetParent()
        assert(H.class(parent,'VerticalBox') and parent:GetChildrenCount()==4,'native result VerticalBox unavailable')
        local r={widget=w,parent=parent,epoch=L.epoch,originals={},byKey={},extras={},slots={},active={}}
        local meta={originals={},extras={}}
        for i=0,3 do
            local line=parent:GetChildAt(i)
            assert(H.class(line,'WB_ObjectiveResultLine_C'),'unexpected native result child')
            local s={name=id(line),label=text(line.Stat),a=text(line.TeamAScore),b=text(line.TeamBScore),
                ar=line.TeamATeam,br=line.TeamBTeam,visibility=line:GetVisibility(),
                opacity=read(line,'RenderOpacity') or 1,slot=slotData(line.Slot)}
            for key,n in pairs(semantics) do
                if id(line)==id(w['WB_ObjectiveResultLine'..n]) then s.key=key; r.slots[key]=s.slot; break end
            end
            r.originals[#r.originals+1]={line=line,s=s}; meta.originals[#meta.originals+1]=s
        end

        r.slot=r.originals[1].s.slot
        r.meta=meta; owned[id(w)]=meta
        return r
    end
    -- Lifetime resets drop handles. Rebind only through a live screen's owned
    -- tree, never via a registry scan or an old world/address latch.
    local function adopt(w,meta)
        local parent=w.WB_ObjectiveResultLine1:GetParent()
        assert(H.class(parent,'VerticalBox'),'cached result parent changed')
        local r={widget=w,parent=parent,epoch=L.epoch,meta=meta,originals={},byKey={},extras={},slots={},active={}}
        for _,s in ipairs(meta.originals) do
            local found
            for n=1,4 do local line=w['WB_ObjectiveResultLine'..n]; if id(line)==s.name then found=line; break end end
            assert(found,'cached original changed'); r.originals[#r.originals+1]={line=found,s=s}; r.slots[s.key]=s.slot
        end

        for i=0,parent:GetChildrenCount()-1 do
            local child=parent:GetChildAt(i)
            for key,name in pairs(meta.extras) do if id(child)==name then r.extras[key]=child; r.byKey[key]=child end end
        end
        r.slot=r.originals[1].s.slot
        if meta.canvas then
            assert(H.class(parent:GetParent(),'CanvasPanel') and H.class(parent.Slot,'CanvasPanelSlot'),
                'cached result canvas changed')
        end
        return r
    end
    local function cancel(r)
        if r.workKey then work.cancel(r.workKey) end
        r.preparing=nil
        for _,stop in ipairs(r.timers or {}) do stop() end
        r.timers={}
    end
    local function restore(r)
        cancel(r)
        -- Keep the original designer order, texts, visibility, and every slot.
        for _,line in ipairs(r.active) do line:RemoveFromParent() end
        for i=r.parent:GetChildrenCount()-1,0,-1 do r.parent:GetChildAt(i):RemoveFromParent() end
        for _,o in ipairs(r.originals) do
            local line,s=o.line,o.s
            line:RemoveFromParent(); setSlot(r.parent:AddChild(line),s.slot)
            label(line,s.label); line.TeamAScore=FText(s.a); line.TeamBScore=FText(s.b)
            line.TeamATeam=s.ar; line.TeamBTeam=s.br; line:SetVisibility(s.visibility)
            r.widget:InitializeResultLine(line); line:SetRenderOpacity(s.opacity)
        end
        if r.meta.canvas then setCanvas(r.parent.Slot,r.meta.canvas) end
        r.widget.CurrentResultLineIndex=0; r.widget.PlayVictoryLogo=true
    end
    local function arrange(r,model)
        local w=r.widget
        local source=w.WB_ObjectiveResultLine1
        local library
        local steps={}
        for _,row in ipairs(model.rows) do
            if not r.byKey[row.key] then
                steps[#steps+1]=work.native(function()
                    library=library or H.object('/Script/UMG.Default__WidgetBlueprintLibrary')
                    local line=library:Create(w,source:GetClass(),w:GetOwningPlayer())
                    assert(H.class(line,'WB_ObjectiveResultLine_C'),'native result line creation failed')
                    line:SetVisibility(2)
                    r.extras[row.key]=line; r.byKey[row.key]=line; r.meta.extras[row.key]=id(line)
                end)
            end
        end
        steps[#steps+1]=function()
            local count=r.parent:GetChildrenCount()
            if count==0 then return true end
            r.parent:GetChildAt(count-1):RemoveFromParent()
            return count==1
        end
        -- Keep originals in the live tree, collapsed. The Blueprint retains its
        -- semantic references and can repaint/animate them safely; custom rows
        -- have separate fields and occupy all visible layout space. This also
        -- makes a same-screen epoch rebind possible through the native tree.
        for _,original in ipairs(r.originals) do
            steps[#steps+1]=function()
                setSlot(r.parent:AddChild(original.line),original.s.slot)
                original.line:SetVisibility(1)
                return true
            end
        end
        r.active={}
        for _,row in ipairs(model.rows) do
            steps[#steps+1]=function()
                local line=r.byKey[row.key]
                setSlot(r.parent:AddChild(line),r.slots[row.key] or r.slot)
                line:SetVisibility(2); r.active[#r.active+1]=line
                return true
            end
        end
        -- Cooked rows contain a centred, fixed 800x60 canvas. A ScrollBox narrows
        -- their viewport and clips the left score. Grow the native allocation
        -- instead, keeping its top edge, native row widths/fonts and animations.
        local height=0
        for _,row in ipairs(model.rows) do
            steps[#steps+1]=function()
                local line=r.byKey[row.key]
                local size=line:GetDesiredSize(); local y=tonumber(size.Y) or 0
                local padding=line.Slot.Padding
                height=height+math.max(60,y)+(padding.Top or 0)+(padding.Bottom or 0)
                return true
            end
        end
        steps[#steps+1]=function()
            local slot=r.parent.Slot
            assert(H.class(r.parent:GetParent(),'CanvasPanel') and H.class(slot,'CanvasPanelSlot'),
                'native result canvas allocation unavailable')
            r.meta.canvas=r.meta.canvas or canvasData(slot)
            local s=canvasData(slot); local original=r.meta.canvas
            s.width=math.max(800,original.width); s.height=math.max(original.height,height)
            s.top=original.top+(s.height-original.height)*original.ay
            s.auto=false
            setCanvas(slot,s)
            return true
        end
        return steps
    end
    local function tint(block,team)
        local slate=native(block.ColorAndOpacity); local c=slate.SpecifiedColor
        c.R=team==1 and .05724899843335152 or 1
        c.G=team==2 and 0 or 1; c.B=team==1 and 0 or (team==2 and .11694200336933136 or 1); c.A=1
        slate.ColorUseRule=0; block:SetColorAndOpacity(slate)
    end
    -- At most seven game-thread wakeups replace the native semantic reveal loop.
    -- Captures are scalar identities only; travel/destruction cancels and drops
    -- records before any departing UObject can be dereferenced.
    local function schedule(r,ms,fn)
        local address=r.widget:GetAddress(); local epoch=r.epoch; local token=r.token
        r.timers[#r.timers+1]=FAPP_SERVICES.runtime.delay(ms,function()
            local current=records[address]
            if L.transition or L.epoch~=epoch or not current or current.token~=token then return end
            if not live(current.widget) then return end
            fn(current)
        end)
    end
    local function reveal(r,i)
        local line=r.active[i]
        if r.model.rows[i].deciding then
            tint(line.TeamAText,r.model.team==1 and 1 or 2)
            tint(line.TeamBText,r.model.team==2 and 1 or 2)
        end
        line:SetVisibility(0)
        line:PlayAnimation(r.animations[i],0,1,0,1,false)
    end
    local function nextReveal(r)
        schedule(r,750,function(current)
            local step=current.revealSteps[current.nextReveal]
            for index=step.first,step.last do reveal(current,index) end
            current.nextReveal=current.nextReveal+1
            if current.revealSteps[current.nextReveal] then nextReveal(current)
            else schedule(current,750,function(after) after.widget.PlayVictoryLogo=true end) end
        end)
    end
    local function start(r)
        local w=r.widget; local model=r.model
        -- Leave replicated reason/outcome untouched. Hold only this screen's
        -- native reveal cursor/logo until our deciding row has been revealed.
        w.CurrentResultLineIndex=r.reason; w.PlayVictoryLogo=false
        r.started=true
        if r.preview then
            for i=1,#r.active do reveal(r,i) end
            w.PlayVictoryLogo=true
            return
        end
        r.revealSteps=Rows.schedule(model); r.nextReveal=1
        nextReveal(r)
    end
    local function prepare(r)
        cancel(r); sequence=sequence+1; r.token=sequence
        local w=r.widget; local model=r.model
        w.CurrentResultLineIndex=r.reason; w.PlayVictoryLogo=false
        for _,original in ipairs(r.originals) do original.line:SetVisibility(1) end
        local steps=arrange(r,model)
        r.animations={}
        for i,row in ipairs(model.rows) do
            steps[#steps+1]=function()
                local line=r.active[i]
                local animation=read(line,'FadeIn')
                assert(H.class(animation,'WidgetAnimation') and read(line,'PlayAnimation')~=nil,
                    'live result FadeIn/PlayAnimation unavailable')
                r.animations[i]=animation
                w:InitializeResultLine(line)
                label(line,(r.preview and i==1 and 'PREVIEW: ' or '')..row.label)
                line.TeamAScore=FText(row.a); line.TeamBScore=FText(row.b)
                line.TeamATeam=row.ar; line.TeamBTeam=row.br
                line:SetRenderOpacity(model.deciding and i>model.reveal and .4 or 1)
                return true
            end
        end
        steps[#steps+1]=function() r.preparing=nil; start(r); return true end
        local step=work.sequence(steps)
        local address=w:GetAddress(); local epoch=r.epoch; local token=r.token
        r.workKey='WIN7:result:'..id(w); r.preparing=true
        local function failed(err)
            H.log('WIN7 native result setup unavailable: '..tostring(err))
            pcall(restore,r)
            records[address]=nil; owned[id(w)]=nil
        end
        work.submit(r.workKey,'WIN7/result setup',function()
            local current=records[address]
            if L.transition or L.epoch~=epoch or not current or current.token~=token then return true end
            if not live(current.widget) then return true end
            local ok,result=pcall(step)
            if not ok then failed(result); return true end
            if type(result)=='table' and type(result.native)=='function' then
                return {native=function()
                    local success,err=pcall(result.native)
                    if not success then failed(err) end
                end}
            end
            return result
        end)
    end
    function api.refresh(w,preview,gs)
        gs=live(w,gs); if not gs then return end
        last={widget=w,epoch=L.epoch}
        local key=id(w); local address=w:GetAddress(); local r=records[address]
        local data=preview or presentation(w)
        -- A preview persists until Construct/Destruct or explicit replay.
        if r and r.preview and not preview then return r end
        local model=data and Rows.model(data.order,data.result,data.infinite,data.fallback)
        if not model then
            if not r and owned[key] then local ok,v=pcall(adopt,w,owned[key]); if ok then r=v end end
            if r then
                records[address]=nil; owned[key]=nil; restore(r)
                -- Refill the restored native fields once. There is no hot hook
                -- or recursive result callback on UpdateStats.
                w:UpdateStats()
            end
            return
        end
        local ok,err=pcall(function()
            if not r then
                local adopted=owned[key] and select(2,pcall(adopt,w,owned[key]))
                r=type(adopted)=='table' and adopted or build(w); records[address]=r
            end
            if not (r.started or r.preparing) or r.modelSignature~=model.signature or r.reason~=gs.WinningReasonIndex or preview then
                r.model=model; r.modelSignature=model.signature; r.preview=data.preview; r.reason=gs.WinningReasonIndex
                prepare(r)
                H.log('WIN3 native lines='..#model.rows..' reveal='..model.reveal..' isolated=true reason='..r.reason)
            end
        end)
        if not ok then
            H.log('WIN3 native lines unavailable: '..tostring(err))
            if r then pcall(restore,r) end
            records[address]=nil; owned[key]=nil; return
        end
        return r
    end
    function api.construct(w)
        local r=records[w:GetAddress()]
        if r and r.epoch==L.epoch then cancel(r); r.preview=nil; r.started=nil end
    end
    H.hook('/Script/UMG.UserWidget:Destruct',function(self)
        if next(records)==nil and next(owned)==nil and not last then return end
        local w=self:get(); local address=w:GetAddress(); local r=records[address]
        if not r and not H.class(w,'WB_ObjectiveResultScreen_C') then return end
        local key=id(w)
        if not L.transition then
            if not r and owned[key] then local ok,v=pcall(adopt,w,owned[key]); if ok then r=v end end
            if r and r.epoch==L.epoch then restore(r) end
            owned[key]=nil
        end
        if r then cancel(r) end
        records[address]=nil
        if last and id(last.widget)==id(w) then last=nil end
    end)
    function api.preview()
        assert(last and last.epoch==L.epoch and live(last.widget),'WIN3: no current Objective result screen')
        local w=last.widget; local node=w
        assert(H.valid(w:GetParent()) or w:IsInViewport(),'WIN3: Objective result screen is closed')
        for _=1,16 do
            if not H.valid(node) then break end
            local v=node:GetVisibility(); assert(v~=1 and v~=2,'WIN3: Objective result screen is hidden')
            node=node:GetParent()
        end
        local current=presentation(w)
        local order=current and current.order or C.WinnerOrder or 'wins,pots,props,lives,kills,time'
        local infinite=C.MaxLives=='infinite'
        if current then infinite=current.infinite end
        assert(api.refresh(w,{order=order,result=Rows.preview(order),infinite=infinite,preview=true}), 'WIN3: native result preview unavailable; see log')
        -- Replay through the existing latent loop and native victory-logo branch.
        w.PlayVictoryLogo=true; w.VictoryLogo:ClearChildren(); w.NextScreenTime=10
        H.log('WIN3 resultpreview: FAKE values; custom rows shown together / outcome unchanged')
        return 'WIN3b resultpreview: fake data; all custom rows together, dimmed tail'
    end
    function api.reset()
        for _,r in pairs(records) do cancel(r) end
        records={}; last=nil
        -- owned[] holds scalar names only. The native result screen survives
        -- travel with our rows inside; dropping it made the next match's build
        -- fail and show every stale row at once.
    end -- no stale-world dereferences
    return api
end
return M
