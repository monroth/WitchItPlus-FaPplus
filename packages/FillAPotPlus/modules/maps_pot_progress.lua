-- BAR3: clipped native BG/fill/frame pieces; replicated delivery order, event-fed.
-- Keep Blueprint-bound fills detached: native Tick owns them, not our Images.
local M={}
local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
local Layout=dofile(dir..'maps_bar_layout.lua')
local PREVIEW_COLOURS={{220,60,220},{230,220,40},{70,90,240},{60,200,90},{240,120,40},{40,200,220},{200,40,60},{250,250,250},{140,80,200},{120,200,40}}
function M.init(X)
    local H,C=X.H,X.C
    local api,records,owners,dirty,failed,retries,previews,building={},{},{},{},{},{},{},{}
    local owned={} -- scalar metadata for GI-owned widgets retained over travel
    local enabled=C.CreativeMaps
    local function native(v,label)
        assert(v~=nil and type(v)~='table','non-native '..label); return v
    end
    local function aligned(parent,child,h,v)
        local slot=parent:AddChild(child)
        slot:SetHorizontalAlignment(h); slot:SetVerticalAlignment(v); return slot
    end
    local function report(w,why)
        if X.Lifetime.rawValid(w) then
            X.once('bar3:'..X.Lifetime.epoch..':'..w:GetAddress(),'HUD/progress','BAR3 '..why)
        end
    end
    local function restore(r)
        -- Travel may retain valid-looking GC handles or reuse world addresses.
        if r.epoch~=X.Lifetime.epoch or X.Lifetime.transition or not X.live(r.widget) then return end
        if r.root and H.valid(r.root) then r.root:RemoveFromParent() end
        local bound=X.same(r.widget.Cauldron1,r.bound[1]) and X.same(r.widget.Cauldron2,r.bound[2])
            and X.same(r.widget.Cauldron3,r.bound[3])
        if r.captured and bound and H.valid(r.parent) then
            for _,s in ipairs(r.originals) do if H.valid(s.image) then
                s.image:RemoveFromParent()
                local slot=aligned(r.parent,s.image,s.h,s.v)
                local padding=native(slot.Padding,'restore padding')
                for k,v in pairs(s.padding) do padding[k]=v end
                slot:SetPadding(padding); s.image:SetVisibility(s.visibility)
            end end
        end
        if r.hudOffsets and H.valid(r.hudSlot) then
            local offsets=native(r.hudSlot.LayoutData.Offsets,'restore offsets')
            for k,v in pairs(r.hudOffsets) do offsets[k]=v end
            r.hudSlot:SetOffsets(offsets)
        end
        for _,c in ipairs(r.clips) do if H.valid(c.widget) then c.widget:SetClipping(c.value) end end
    end
    local function current(r,w,widget)
        return r.epoch==X.Lifetime.epoch and X.Lifetime.same(r.owner,w) and X.Lifetime.same(r.widget,widget)
            and X.Lifetime.alive(r.parent) and X.Lifetime.alive(r.root) and X.Lifetime.same(r.root:GetParent(),r.parent)
            and X.Lifetime.same(widget.Cauldron1,r.bound[1])
            and X.Lifetime.same(widget.Cauldron2,r.bound[2]) and X.Lifetime.same(widget.Cauldron3,r.bound[3])
    end
    local function gameState(w)
        local gs=X.gameplay():GetGameState(w)
        local world=X.Lifetime.worldKey(w)
        local function valid(o)
            return X.Lifetime.alive(o) and o:GetClass():GetFName():ToString()=='B_ObjectiveGameState_C'
                and X.Lifetime.worldKey(o)==world
        end
        if valid(gs) then return gs end
        if X.Lifetime.alive(gs) and X.Lifetime.worldKey(gs)==world and gs:GetClass():GetFName():ToString()~='B_ObjectiveGameState_C' then
            return nil,'outside Fill a Pot'
        end
        -- A transient HUD's WorldContext can lag its owning player's context.
        -- Native TickFillState caches State; registry fallback is event-fed only.
        gs=X.read(w,'State'); if valid(gs) then return gs end
        local ok,pc=pcall(function() return w:GetOwningPlayer() end)
        if ok and X.live(pc) and X.Lifetime.worldKey(pc)==world then
            gs=X.gameplay():GetGameState(pc); if valid(gs) then return gs end
        end
        for _,o in ipairs(X.findAll('B_ObjectiveGameState_C')) do if valid(o) then return o end end
    end
    -- Native WB_ObjectiveHudExtension paints slots above CauldronTarget with this
    -- constant (second half needing fewer pots than a full win).
    local BLOCKED={R=0.2961379885673523,G=0.2307399958372116,B=0.34670400619506836}
    local function fullTarget(gs,target)
        local gi=X.gi(gs); local scope=X.Identity.session(gi)
        local matchKey=X.Identity.key(X.read(gi,'ObjectiveMatchManager'))
        local round=X.get(X.read(gs,'CurrentRound'))
        -- CurrentRound=0 during loading is not evidence of a new first half.
        -- Guests use only replicated fields; dead/spectator HUDs share this path.
        if scope and round==1 then scope.fullTarget={match=matchKey,value=target} end
        local latched=scope and scope.fullTarget and scope.fullTarget.match==matchKey and scope.fullTarget.value or 0
        local ceiling=X.Targets and X.Targets.ceiling and X.Targets.ceiling(gs)
        return math.min(math.max(target,ceiling or 0,latched),10)
    end
    local function widgetKey(w) return tostring(w:GetAddress())..':'..w:GetFullName() end
    local function remember(r)
        local m={parent=widgetKey(r.parent),root=widgetKey(r.root),originals={},clips={},hudOffsets=r.hudOffsets}
        for _,o in ipairs(r.originals) do
            m.originals[#m.originals+1]={key=widgetKey(o.image),h=o.h,v=o.v,padding=o.padding,visibility=o.visibility}
        end
        for _,c in ipairs(r.clips) do m.clips[#m.clips+1]={key=widgetKey(c.widget),value=c.value} end
        -- Keep metadata only for the current local HUDs. A newly constructed
        -- destination widget makes departed widget identities obsolete.
        local active={}
        for _,record in pairs(records) do active[record.widgetKey]=true end
        for key in pairs(owned) do if not active[key] then owned[key]=nil end end
        owned[widgetKey(r.widget)]=m
    end
    local function recover(w,widget)
        local key=widgetKey(widget); local m=owned[key]; if not m then return end
        -- Resolve through the current native tree, never through retained handles
        -- or a global UObject scan. Detached Blueprint images remain bound fields.
        local found={}
        local function walk(o)
            if not H.valid(o) then return end
            local k=widgetKey(o); if found[k] then return end; found[k]=o
            if X.read(o,'GetAllChildren') then for _,child in ipairs(X.values(o:GetAllChildren())) do walk(child) end end
        end
        walk(widget); walk(widget:GetParent())
        local tree=X.read(widget,'WidgetTree'); if H.valid(tree) then walk(X.read(tree,'RootWidget')) end
        for n=1,3 do walk(widget['Cauldron'..n]) end
        local parent=found[m.parent]; if not H.valid(parent) then return end
        local r={owner=w,widget=widget,parent=parent,root=found[m.root],epoch=X.Lifetime.epoch,
            captured=true,originals={},clips={},bound={widget.Cauldron1,widget.Cauldron2,widget.Cauldron3},
            hudSlot=widget.Slot,hudOffsets=m.hudOffsets}
        for _,o in ipairs(m.originals) do
            local image=found[o.key]; if not H.valid(image) then return end
            r.originals[#r.originals+1]={image=image,h=o.h,v=o.v,padding=o.padding,visibility=o.visibility}
        end
        for _,c in ipairs(m.clips) do if found[c.key] then r.clips[#r.clips+1]={widget=found[c.key],value=c.value} end end
        restore(r); owned[key]=nil
        X.log('HUD/progress','BAR3 recovered retained widget after travel')
    end
    local function snapshot(gs)
        local target=X.get(X.read(gs,'CauldronTarget'))
        if type(target)~='number' or target<1 or target>10 or target%1~=0 then return nil,'target outside 1..10: '..tostring(target) end
        local full=fullTarget(gs,target)
        -- Do not require GS.Cauldrons (local, non-Net) or every actor's Color.
        -- FilledCauldronColors is the authority's append-only, replicated order;
        -- equal colours and black must remain separate successful deliveries.
        local colours,parts={}, {tostring(target)..'/'..tostring(full)}
        for i,c in ipairs(X.values(X.read(gs,'FilledCauldronColors'))) do
            if i>target then break end
            local copy={R=X.get(c.R),G=X.get(c.G),B=X.get(c.B)}
            for _,k in ipairs({'R','G','B'}) do
                local v=copy[k]
                if type(v)~='number' or v~=v or math.abs(v)==math.huge then return nil,'waiting for native filled colours' end
            end
            colours[i]=copy; parts[#parts+1]=string.pack('<fff',copy.R,copy.G,copy.B)
        end
        for i=target+1,full do colours[i]=BLOCKED end
        return {target=full,colours=colours,signature=table.concat(parts,'\0')}
    end
    local function buildJob(w,widget,parent,n,complete)
        local plan,width=Layout.layout(n)
        local r={owner=w,widget=widget,widgetKey=widgetKey(widget),parent=parent,epoch=X.Lifetime.epoch,n=n,plan=plan,width=width,
            prebuilt=X.preparingHUD==true,originals={},pieces={},clips={},bound={widget.Cauldron1,widget.Cauldron2,widget.Cauldron3}}
        local textures={}; r.textures=textures
        local function construct(cls)
            local o=StaticConstructObject(X.asset('/Script/UMG.'..cls),widget.WidgetTree)
            assert(H.valid(o),'progress '..cls..' construction failed'); return o
        end
        local function unclip(o)
            r.clips[#r.clips+1]={widget=o,value=o.Clipping}; o:SetClipping(0)
        end
        local steps={X.Work.each(X.values(parent:GetAllChildren()),function(image)
            local name=image:GetFName():ToString()
            local key=({Back='bg',Galss='frame',Cauldron2='mid',Cauldron3='right'})[name]
            local slot=image.Slot; local padding=native(slot.Padding,'original padding')
            r.originals[#r.originals+1]={image=image,detach=name:match('^Cauldron[123]$')~=nil,h=slot.HorizontalAlignment,v=slot.VerticalAlignment,
                visibility=image:GetVisibility(),padding={Left=padding.Left,Top=padding.Top,Right=padding.Right,Bottom=padding.Bottom}}
            if key then textures[key]=image.Brush.ResourceObject end
        end),function()
            for _,key in ipairs({'bg','frame','mid','right'}) do assert(H.valid(textures[key]),'native texture missing: '..key) end
            widget:ForceLayoutPrepass()
            local size
            for _,image in ipairs(r.originals) do if image.image:GetFName():ToString()=='Galss' then size=image.image:GetDesiredSize() end end
            assert(size and size.Y>0 and size.X>0,'native bar size not ready')
            r.k=size.Y/64
            assert(math.abs(size.X/512-r.k)<.001,'native bar has nonuniform scale')
            local offsets=native(widget.Slot.LayoutData.Offsets,'HUD offsets')
            r.hudSlot=widget.Slot; r.hudOffsets={Left=offsets.Left,Top=offsets.Top,Right=offsets.Right,Bottom=offsets.Bottom}
            return true
        end,function()
            r.root=construct('SizeBox'); r.root:SetWidthOverride(width*r.k); r.root:SetHeightOverride(64*r.k)
            r.root:SetVisibility(2)
            -- Attach collapsed immediately for native GC ownership. Original art
            -- remains visible until the final commit; never show a partial bar.
            aligned(parent,r.root,2,2); remember(r)
            return true
        end,function()
            r.row=construct('HorizontalBox'); r.root:AddChild(r.row); return true
        end}
        for _,p in ipairs(plan) do
            local piece={images={},section=p.section}
            steps[#steps+1]=function()
                piece.box=construct('SizeBox'); piece.box:SetWidthOverride(p.w*r.k); piece.box:SetHeightOverride(64*r.k)
                piece.box:SetClipping(1)
                local hs=aligned(r.row,piece.box,0,0); local auto=native(hs.Size,'piece auto size')
                auto.SizeRule=0; auto.Value=1; hs:SetSize(auto)
                piece.canvas=construct('CanvasPanel'); piece.box:AddChild(piece.canvas)
                r.pieces[#r.pieces+1]=piece; return true
            end
            for z,key in ipairs({'bg','fill','frame'}) do
                steps[#steps+1]=function()
                    local image=construct('Image'); piece.images[z]=image
                    local tex=key=='fill' and (p.fill=='left' and textures.right or textures[p.fill]) or textures[key]
                    image:SetBrushFromTexture(tex,false)
                    local white=native(image.ColorAndOpacity,'image colour')
                    white.R=1; white.G=1; white.B=1; white.A=1; image:SetColorAndOpacity(white)
                    if key=='fill' and p.fill=='left' then
                        local pivot=native(image.RenderTransformPivot,'pivot'); pivot.X=.5; pivot.Y=.5; image:SetRenderTransformPivot(pivot)
                        local scale=native(image.RenderTransform.Scale,'scale'); scale.X=-1; scale.Y=1; image:SetRenderScale(scale)
                    end
                    local slot=piece.canvas:AddChild(image)
                    local offsets=native(slot.LayoutData.Offsets,'canvas offsets')
                    local factor=p.w/(p.src[2]-p.src[1])*r.k
                    offsets.Left=-p.src[1]*factor; offsets.Top=0; offsets.Right=512*factor; offsets.Bottom=64*r.k
                    slot:SetOffsets(offsets); slot:SetZOrder(z-1)
                    image:SetVisibility(key=='fill' and 2 or 4); return true
                end
            end
        end
        steps[#steps+1]=function()
            local offsets=native(r.hudSlot.LayoutData.Offsets,'HUD offsets'); offsets.Right=width*r.k; r.hudSlot:SetOffsets(offsets)
            unclip(parent); unclip(parent:GetParent()); unclip(widget); unclip(widget:GetParent())
            r.captured=true
            for _,image in ipairs(r.originals) do
                image.image:SetVisibility(2); if image.detach then image.image:RemoveFromParent() end
            end
            r.root:SetVisibility(4); remember(r)
            X.log('HUD/progress',string.format('BAR3 built N=%d W=%d k=%.6g',n,width,r.k))
            complete(r); return true
        end
        return X.Work.sequence(steps),r
    end
    local function paint(r,state)
        if r.signature==state.signature then return end
        for _,p in ipairs(r.pieces) do
            local image=p.images[2]; local c=state.colours[p.section+1]
            if c then
                local v=native(image.ColorAndOpacity,'image colour')
                v.R=c.R; v.G=c.G; v.B=c.B; v.A=1; image:SetColorAndOpacity(v)
            end
            image:SetVisibility(c and 4 or 2)
        end
        r.signature=state.signature
    end
    function api.refresh(w,rebuild)
        if not X.live(w) then return end
        local id=w:GetAddress(); local r=records[id]
        local gs,reason=gameState(w)
        if not gs then
            if reason then
                local pending=building[id]
                if pending then X.Work.cancel('BAR3:'..id); restore(pending); owned[pending.widgetKey]=nil; building[id]=nil end
                if r then restore(r); records[id]=nil end
                owners[id]=nil; previews[id]=nil
            end
            return -- a transient WorldContext must not dismantle a working bar
        end
        local widget=X.read(w,'WB_CauldronProgress')
        -- HUD-only rebuilds can arrive before the native progress widget exists.
        -- Such a HUD has no progress to reconcile; a later native refresh retries.
        if not X.live(widget) then owners[id]=nil; return end
        local owner=owners[id]
        if not owner or owner.epoch~=X.Lifetime.epoch or not X.same(owner.gs,gs) then
            owners[id]={widget=w,gs=gs,epoch=X.Lifetime.epoch}
        end
        if rebuild then failed[id]=nil end
        if r and not current(r,w,widget) then restore(r); records[id]=nil; r=nil end
        local state,why
        if C.CreativeMaps then state=previews[id]; if not state then state,why=snapshot(gs) end else why='disabled'; previews[id]=nil end
        if not state then
            local pending=building[id]
            if pending then X.Work.cancel('BAR3:'..id); restore(pending); owned[pending.widgetKey]=nil; building[id]=nil end
            if r then restore(r); records[id]=nil end
            report(w,why); return
        end
        if r and r.n~=state.target then restore(r); records[id]=nil; r=nil end
        local failure=failed[id]
        if failure and failure.epoch==X.Lifetime.epoch and failure.n==state.target and X.same(failure.widget,widget) then return end
        local function sameArt(candidate)
            local mid=widget.Cauldron2; local right=widget.Cauldron3
            return candidate.textures and X.Lifetime.same(candidate.textures.mid,mid.Brush.ResourceObject)
                and X.Lifetime.same(candidate.textures.right,right.Brush.ResourceObject)
        end
        if not r and not previews[id] then
            -- Native ShowHUD recreates its tree at seek start. Move the complete
            -- load-phase art to the new tree rather than construct it again.
            for oldId,candidate in pairs(records) do
                if oldId~=id and candidate.epoch==X.Lifetime.epoch and candidate.n==state.target
                    and X.Lifetime.alive(candidate.root) and sameArt(candidate) and X.Lifetime.worldKey(candidate.widget)==X.Lifetime.worldKey(widget) then
                    local parent=widget.Cauldron1:GetParent()
                    candidate.root:RemoveFromParent()
                    candidate.owner=w; candidate.widget=widget; candidate.widgetKey=widgetKey(widget); candidate.parent=parent
                    candidate.bound={widget.Cauldron1,widget.Cauldron2,widget.Cauldron3}; candidate.originals={}; candidate.clips={}
                    candidate.hudSlot=widget.Slot
                    local offsets=native(widget.Slot.LayoutData.Offsets,'HUD offsets')
                    candidate.hudOffsets={Left=offsets.Left,Top=offsets.Top,Right=offsets.Right,Bottom=offsets.Bottom}
                    for _,image in ipairs(X.values(parent:GetAllChildren())) do
                        local slot=image.Slot; local padding=native(slot.Padding,'original padding')
                        local detach=image:GetFName():ToString():match('^Cauldron[123]$')~=nil
                        candidate.originals[#candidate.originals+1]={image=image,detach=detach,h=slot.HorizontalAlignment,v=slot.VerticalAlignment,
                            visibility=image:GetVisibility(),padding={Left=padding.Left,Top=padding.Top,Right=padding.Right,Bottom=padding.Bottom}}
                        image:SetVisibility(2); if detach then image:RemoveFromParent() end
                    end
                    aligned(parent,candidate.root,2,2)
                    offsets.Right=candidate.width*candidate.k; candidate.hudSlot:SetOffsets(offsets)
                    for _,o in ipairs({parent,parent:GetParent(),widget,widget:GetParent()}) do
                        candidate.clips[#candidate.clips+1]={widget=o,value=o.Clipping}; o:SetClipping(0)
                    end
                    records[oldId]=nil; owners[oldId]=nil; dirty[oldId]=nil
                    records[id]=candidate; r=candidate; candidate.signature=nil; remember(candidate)
                    X.log('HUD/progress','BAR3 reused load-phase art N='..state.target)
                    break
                end
            end
        end
        if not r then
            local pending=building[id]
            if pending and pending.n==state.target and pending.widgetKey==widgetKey(widget) then pending.state=state; return end
            if pending then X.Work.cancel('BAR3:'..id); restore(pending); owned[pending.widgetKey]=nil; building[id]=nil end
            recover(w,widget)
            local parent=widget.Cauldron1:GetParent(); assert(H.valid(parent),'progress parent missing')
            local step,partial
            step,partial=buildJob(w,widget,parent,state.target,function(value)
                records[id]=value; failed[id]=nil; building[id]=nil; paint(value,partial.state)
            end)
            -- Declare before invoking completion; callbacks never hold a native
            -- event-param wrapper, and Core reset discards these world cursors.
            partial.state=state; building[id]=partial
            local pass,live
            local function advance()
                if partial.epoch~=X.Lifetime.epoch or X.Lifetime.transition then building[id]=nil; return true end
                if pass~=X.Work.pass then
                    pass=X.Work.pass
                    live=X.live(w) and X.live(widget) and X.Lifetime.rawValid(w.WB_CauldronProgress)
                        and widgetKey(w.WB_CauldronProgress)==partial.widgetKey
                end
                if not C.CreativeMaps or not live then
                    restore(partial); owned[partial.widgetKey]=nil; building[id]=nil; return true
                end
                local ok,done=pcall(step)
                if not ok then
                    restore(partial); owned[partial.widgetKey]=nil; building[id]=nil
                    failed[id]={widget=widget,n=state.target,epoch=X.Lifetime.epoch}; report(w,'FAILED '..tostring(done)); error(done)
                end
                return done
            end
            if FAPP_TEST_NO_THROTTLE then X.Work.finish(advance) else X.Work.submit('BAR3:'..id,'BAR3 construction',advance) end
            return
        end
        local ok,err=pcall(paint,r,state)
        if not ok then
            restore(r); records[id]=nil; failed[id]={widget=widget,n=state.target,epoch=X.Lifetime.epoch}
            report(w,'FAILED '..tostring(err)); error(err)
        end
    end
    function api.preview(n,filled)
        local off=n=='off'
        n=tonumber(n); filled=tonumber(filled)
        assert(off or (n and n%1==0 and n>=1 and n<=10 and filled and filled%1==0 and filled>=0 and filled<=n),
            'usage: fapmaps barpreview <1..10> <0..N> | fapmaps barpreview off')
        assert(C.CreativeMaps,'CreativeMaps is disabled')
        local w
        for _,gi in ipairs(X.findAll('B_GameInstance_C')) do if X.live(gi) then
            local ui=X.read(gi,'IngameUIManager'); local root=H.valid(ui) and X.read(ui,'HUDUserWidget')
            local hud=H.valid(root) and X.read(root,'ObjectiveHud')
            if X.live(hud) then w=hud; break end
        end end
        assert(w and gameState(w),'current Fill a Pot HUD unavailable')
        local id=w:GetAddress()
        if off then previews[id]=nil else
            local colours={}
            for i=1,filled do local c=PREVIEW_COLOURS[i]; colours[i]={R=c[1]/255,G=c[2]/255,B=c[3]/255} end
            previews[id]={target=n,colours=colours,signature='preview:'..n..':'..filled}
        end
        api.refresh(w,true)
        assert(records[id] or building[id],'bar could not be scheduled')
        X.reply('HUD/progress',off and 'Progress preview off.' or ('Progress preview: cauldrons='..n..' filled='..filled))
        return true
    end
    function api.pending()
        if next(dirty)~=nil then return true end
        local now=os.time()
        for _,r in pairs(retries) do if now>=r.at then return true end end
        return false
    end
    function api.invalidate(gs,settle)
        for id,r in pairs(owners) do
            if not gs or X.same(r.gs,gs) then
                dirty[id]=true
                -- RPC may precede replicated fields. Three bounded existing-poll
                -- reconciliations, never an actor Tick or permanent read loop.
                if settle then retries[id]={left=3,at=os.time()+1} end
            end
        end
    end
    function api.poll()
        if enabled~=C.CreativeMaps then
            enabled=C.CreativeMaps; api.invalidate(); if not enabled then retries={} end
        end
        -- Only retained HUD owners and their three replicated progress fields.
        -- Replication has no OnRep for these fields in the cooked GameState.
        for id,r in pairs(owners) do
            if r.epoch~=X.Lifetime.epoch or not X.Lifetime.rawValid(r.gs) or not X.Lifetime.rawValid(r.widget) then owners[id]=nil; records[id]=nil
            else
                local target=X.read(r.gs,'CauldronTarget'); local filled=X.read(r.gs,'CauldronsFilled')
                local colours=X.values(X.read(r.gs,'FilledCauldronColors'))
                local parts={tostring(target),tostring(filled)}
                for _,c in ipairs(colours) do parts[#parts+1]=string.pack('<fff',c.R,c.G,c.B) end
                local key=table.concat(parts,'|')
                if r.progressKey~=key then r.progressKey=key; dirty[id]=true end
            end
        end
        local now=os.time()
        for id,r in pairs(retries) do if now>=r.at then
            dirty[id]=true; r.left=r.left-1; r.at=now+1
            if r.left==0 then retries[id]=nil end
        end end
        local pending=dirty; dirty={}
        for id in pairs(pending) do
            local r=owners[id]
            if r and r.epoch==X.Lifetime.epoch then X.guard('HUD/progress',api.refresh)(r.widget) end
        end
    end
    function api.reset()
        for id,r in pairs(building) do X.Work.cancel('BAR3:'..id); restore(r) end
        for _,r in pairs(records) do restore(r) end
        if not X.Lifetime.transition then owned={} end
        records={}; owners={}; dirty={}; failed={}; retries={}; previews={}; building={}; enabled=C.CreativeMaps
    end
    H.hook('/Script/UMG.UserWidget:Destruct',X.guard('HUD/progress teardown',function(self)
        if X.Lifetime.transition then return end
        local o=X.get(self); local id=o:GetAddress(); local r=records[id]
        if not r then
            for key,value in pairs(records) do if X.same(value.widget,o) then id=key; r=value; break end end
        end
        local pending=building[id]
        if not pending then for key,value in pairs(building) do if X.same(value.widget,o) then id=key; pending=value; break end end end
        if pending then X.Work.cancel('BAR3:'..id); restore(pending); owned[pending.widgetKey]=nil; building[id]=nil end
        if r and r.prebuilt then
            -- ShowHUD removes the old Slate tree before publishing its replacement.
            -- Keep completed load art in its native owning tree until that POST
            -- moves it; epoch reset still drops all old-world records.
            owners[id]=nil; dirty[id]=nil; retries[id]=nil; previews[id]=nil
        elseif r then restore(r); owned[widgetKey(r.widget)]=nil; records[id]=nil; owners[id]=nil; dirty[id]=nil; retries[id]=nil; previews[id]=nil; failed[id]=nil end
    end))
    H.hook('/Game/Blueprints/UserInterface/B_IngameUIManager.B_IngameUIManager_C:ShowHUD',function(self)
        if not C.CreativeMaps or X.Lifetime.transition then return end
        local root=X.read(X.get(self),'HUDUserWidget'); local w=H.valid(root) and X.read(root,'ObjectiveHud')
        if H.valid(w) then api.refresh(w,true) end
    end)
    for _,fn in ipairs({'OnCauldronFilledMulti','OnGameStartedMulti','OnMatchStartedMulti','LoadPropsAndCauldrons'}) do
        H.hook(X.path(X.OM,'B_ObjectiveGameState',fn),X.guard('HUD/progress event',function(self)
            if not C.CreativeMaps or X.Lifetime.transition then return end
            local gs=X.get(self)
            -- Latch round one even when the local HUD is hidden/not constructed.
            -- This is replicated match data, independent of the player's pawn.
            if X.live(gs) and H.class(gs,'B_ObjectiveGameState_C') then
                local target=X.get(X.read(gs,'CauldronTarget'))
                if type(target)=='number' and target>=1 and target<=10 and target%1==0 then fullTarget(gs,target) end
            end
            if fn=='OnGameStartedMulti' or fn=='OnMatchStartedMulti' then previews={} end
            if next(owners)==nil and X.live(gs) and H.class(gs,'B_ObjectiveGameState_C') then
                -- Recover a refresh missed while travel was latched; only events
                -- consult the native HUD chain, never menu/maintenance drivers.
                local gi=X.gi(gs); local ui=H.valid(gi) and X.read(gi,'IngameUIManager')
                local root=H.valid(ui) and X.read(ui,'HUDUserWidget')
                local w=H.valid(root) and X.read(root,'ObjectiveHud')
                if w then api.refresh(w) end
            end
            api.invalidate(gs,true)
        end))
    end
    for _,fn in ipairs({'Init','UpdateFillVisibility','ResetUIMulti'}) do
        H.hook(X.path(X.OM,'B_ObjectiveCauldron',fn),X.guard('HUD/progress pot event',function()
            if C.CreativeMaps and next(owners)~=nil and not X.Lifetime.transition then api.invalidate(nil,true) end
        end))
    end
    X.PotProgress=api
    return api
end
return M
