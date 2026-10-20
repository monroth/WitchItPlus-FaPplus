-- Vanilla Creative playtest: Objective cauldrons are visual actors only.
-- Lua owns preview gates; native per-frame visuals and multicasts, no Objective GameState writes.
local M={}
local PROP='/Game/Blueprints/Props/Bases/B_StaticMeshProp.B_StaticMeshProp_C'
local WITCH='/Game/Blueprints/Player/Pawns/B_Witch.B_Witch_C'
local PAWN='/Game/Blueprints/Player/Pawns/B_PropPawnPhysics.B_PropPawnPhysics_C'
-- Cooked Blueprint component templates, verified by lossless UAssetAPI decoding.
M.DUMP_RULES={maxStacks=2,dwell=4,minDistance=2500,
    witchRadius=200,witchZ=120,propRadius=90,propZ=138.49224853515625,orbMaxDistanceSq=4000000,respawnDelay=3}
-- WB_ObjectiveHudExtension.GetPropClosePercent: clamp squared distance before sqrt.
function M.closePercent(distanceSq,maxDistanceSq)
    return 1-math.sqrt(math.min(distanceSq or maxDistanceSq,maxDistanceSq))/math.sqrt(maxDistanceSq)
end
function M.pool(groups,pot,distance)
    local pool,near,single={}, {},0
    for _,g in pairs(groups) do
        if #g.props<2 then single=single+1
        else
            local tooClose=false
            for _,prop in ipairs(g.props) do
                local p=prop.position; local q=pot.position
                if (p.X-q.X)^2+(p.Y-q.Y)^2+(p.Z-q.Z)^2<=distance^2 then tooClose=true; break end
            end
            if tooClose then near[#near+1]=g.label elseif not g.avoided and not ((pot.info or {}).excluded or {})[g.path] and not (pot.nativeAvoid or {})[g.nativeName] then pool[#pool+1]=g end
        end
    end
    table.sort(pool,function(a,b) return a.label==b.label and a.id<b.id or a.label<b.label end)
    table.sort(near); return pool,near,single
end
function M.init(X)
    local H,C=X.H,X.C; local api,states={},{}; local pending={}; local previewClock; local scope
    local decisions={};local observed={}
    local function native()
        scope=scope or assert(FAPP_API.Native.scope(FAPP_API.id),'preview Native scope unavailable')
        return scope
    end
    local function obsolete(s) return X.Lifetime.transition or s.epoch~=X.Lifetime.epoch end
    local function stopFrames(s)
        local cancel=s and s.frameCancel;if s then s.frameCancel=nil;s.frameReady=false end
        if cancel then cancel() end
    end
    local function armFrames(s,id)
        local function held() return states[id]==s and not s.stopping and not obsolete(s) end
        s.frameCancel=native().on_tick(function(delta,ctx)
            if not held() then return false end
            if s.frameReady then
                local ok,why=pcall(api.frame,s,ctx and X.same(ctx.controller,s.pc) and ctx.time or X.gameplay():GetTimeSeconds(s.pc))
                if not ok then
                    s.stopping=true;s.cleanup_pending=true;stopFrames(s)
                    X.log('PreviewFrame','FAILED: '..tostring(why));return false
                end
            end
            return held()
        end)
        return type(s.frameCancel)=='function' and held()
    end
    local function destroyActor(s,a)
        if obsolete(s) then return true end -- native travel owns the old actor
        if X.live(a) then
            local name=a:GetFullName()
            local removed,why=native().destroy(a)
            assert(removed,'native preview actor destruction refused: '..name..' / '..tostring(why))
            if not obsolete(s) then assert(not X.live(a),'native preview actor still active: '..name) end
        end
        return true
    end
    local function context(pc)
        if not C.CreativeMaps then return nil,nil,'CreativeMaps disabled' end
        if not X.live(pc) then return nil,nil,'controller not live; transition='..tostring(X.Lifetime.transition) end
        if not H.class(pc,'B_CreativePlayerController_C') then return nil,nil,'not a Creative controller' end
        if not H.authority(pc) then return nil,nil,'controller has no authority' end
        if not pc:IsLocalController() then return nil,nil,'controller is not local' end
        if pc.CurrentPlayMode~=3 then return nil,nil,'CurrentPlayMode='..tostring(pc.CurrentPlayMode) end
        local gm=X.gameplay():GetGameMode(pc); local gs=X.gameplay():GetGameState(pc)
        if not H.class(gm,'B_CreativeGameMode_C') then return nil,nil,'Creative GameMode unavailable' end
        if not H.authority(gm) then return nil,nil,'GameMode has no authority' end
        if not H.class(gs,'B_CreativeGameState_C') then return nil,nil,'Creative GameState unavailable' end
        if not gs.IsPlayTestMode then return nil,nil,'IsPlayTestMode='..tostring(gs.IsPlayTestMode) end
        return gm,gs
    end
    local function skipped(reason,pc)
        local key=pc and X.live(pc) and pc:GetAddress() or 'world'
        if decisions[key]~=reason then
            decisions[key]=reason;X.log('Preview','start skipped: '..reason)
        end
    end

    local function now(pc) return X.gameplay():GetTimeSeconds(pc) end
    local function rules()
        local r={}; for k,v in pairs(M.DUMP_RULES) do r[k]=v end
        local ok,cdo=pcall(X.cauldronDefaults)
        if ok then
            local stacks=X.read(cdo,'MaxStacks'); local dwell=X.read(cdo,'WitchInCircleTimeNeeded')
            if type(stacks)=='number' and stacks>=1 and stacks<=255 then r.maxStacks=stacks end
            if type(dwell)=='number' and dwell>0 and dwell<3600 then r.dwell=dwell end
            r.avoid={}; for _,v in ipairs(X.values(X.read(cdo,'PropClassesToAvoid'))) do r.avoid[X.text(v)]=true end
        else X.once('preview-defaults','PreviewDefaults','CDO unavailable; using verified dumped 2 stacks / 4 witch-seconds') end
        r.minDistance=X.minDistance(); r.avoid=r.avoid or {}; return r
    end
    local function markerKey(pots,points)
        local ids={}; for _,list in ipairs({pots,points}) do
            for _,p in ipairs(list) do ids[#ids+1]=p.id..'@'..X.positionKey(p.position) end
        end
        return table.concat(ids,';')
    end
    local function classLabel(cls)
        return X.text(X.object('/Script/Engine.Default__KismetSystemLibrary'):GetClassDisplayName(cls))
    end
    function api.updatePools(s)
        s.orbCandidates={} -- registry/edit reconciliation invalidates class membership
        local groups={}; local ignored=0
        for _,a in ipairs(X.actors(s.pc,PROP)) do
            if X.read(a,'IsControlledByWitch')~=true then
                local cls=a:GetClass(); local category=cls:GetCDO().PropCategory
                if category==0 then
                    -- Native Proplist keeps its original actor refs even after transformation.
                    -- Retain discovered originals, then measure their LIVE locations for the orb.
                    s.originalProps[a:GetAddress()]=a
                    local originals=s.originalsByClass[cls:GetAddress()] or {}
                    s.originalsByClass[cls:GetAddress()]=originals; originals[a:GetAddress()]=a
                    local id=cls:GetAddress(); local g=groups[id]
                    if not g then
                        local nativeName=classLabel(cls); local label=X.text(X.read(cls:GetCDO(),'Name') or '')
                        if label=='' or label=='nil' then label='Unnamed prop' end
                        g={id=id,path=X.classPath(cls),nativeName=nativeName,class=cls,label=label,props={},avoided=s.rules.avoid[nativeName]}; groups[id]=g
                    end
                    g.props[#g.props+1]={actor=a,position=X.location(a)}
                else ignored=ignored+1 end
            end
        end
        s.rules.minDistance=X.minDistance(); local global,union=nil,{}
        for _,p in ipairs(s.pots) do
            p.nativeAvoid=X.excludedNames(p.info)
            p.localPool,p.near,p.single=M.pool(groups,p,s.rules.minDistance)
            local found={}; for _,g in ipairs(p.localPool) do found[g.id]=g end
            p.localById=found; for id,g in pairs(found) do union[id]=g end
            if not global then global=found else for id in pairs(global) do if not found[id] then global[id]=nil end end end
        end
        s.pool={}; s.poolById=union; s.sharedCount=0
        for _ in pairs(global or {}) do s.sharedCount=s.sharedCount+1 end
        for _,g in pairs(union) do s.pool[#s.pool+1]=g end
        table.sort(s.pool,function(a,b) return a.label==b.label and a.id<b.id or a.label<b.label end)
        s.ignored=ignored; s.lastPool=now(s.pc)
        -- Requests use each pot's distance pool, like native GenerateWantedProp.
        -- Also report the actual-match adapter's conservative all-pot intersection.
        for _,p in ipairs(s.pots) do
            if p.wanted and not p.localById[p.wanted.id] then p.wanted=nil; p.active=false; p.dwell=0 end
        end
        return true
    end
    function api.assign(s)
        local used={}; for _,p in ipairs(s.pots) do if p.wanted then used[p.wanted.id]=true end end
        for _,p in ipairs(s.pots) do
            if not p.filled and not p.wanted then
                local choices={}
                for _,g in ipairs(p.localPool) do if not used[g.id] and not p.lastProps[g.id] then choices[#choices+1]=g end end
                if #choices>0 then p.wanted=choices[math.random(#choices)]; used[p.wanted.id]=true end
            end
        end
    end
    local function textActor(s,p,height,colour)
        local actor=assert(native().spawn('/Script/Engine.TextRenderActor',s.pc,
            {X=p.position.X,Y=p.position.Y,Z=p.position.Z+height},function(a)
                a:SetReplicates(false);a:SetActorEnableCollision(false)
            end),'TextRenderActor spawn unavailable')
        s.actors[#s.actors+1]=actor
        local slot=#s.actors
        local ok,err=pcall(function()
        local text=actor:GetComponentByClass(X.asset('/Script/Engine.TextRenderComponent'))
        assert(H.valid(text),'TextRenderActor component missing')
        text:SetHorizontalAlignment(1); text:SetWorldSize(18)
        local function channel(v) return math.floor(math.max(.15,v)^(1/2.2)*255+.5) end
        local c=text.TextRenderColor; c.R=channel(colour.R); c.G=channel(colour.G); c.B=channel(colour.B); c.A=255
        text:SetTextRenderColor(c)
        p.labelActor=actor; p.label=text
        end)
        if not ok then
            -- Failed component setup must not accumulate empty actors on every retry.
            local removed=pcall(destroyActor,s,actor)
            if removed then table.remove(s.actors,slot) end
            if not removed then s.stopping=true; s.cleanup_pending=true end
            error(err,0)
        end
    end
    local function nativePot(s,p)
        local rotation=p.actor:K2_GetActorRotation()
        local a=assert(native().spawn(X.OM..'B_ObjectiveCauldron.B_ObjectiveCauldron_C',s.pc,
            {X=p.position.X,Y=p.position.Y,Z=p.position.Z,Yaw=rotation.Yaw,Pitch=rotation.Pitch,Roll=rotation.Roll},function(a)
                a.Color=p.colour;a.MaxStacks=s.rules.maxStacks
                a:SetReplicates(false);a:SetActorTickEnabled(false);a:SetActorEnableCollision(false)
            end),'native cauldron spawn unavailable')
        s.actors[#s.actors+1]=a;p.nativeActor=a;p.nativeSlot=#s.actors
        assert(not obsolete(s),'preview owner retired')
        a:SetActorTickEnabled(false); a:SetActorEnableCollision(false)
        -- BeginPlay calls Init. Repeat explicitly after widget construction, with our Color.
        local component=a.Widget; assert(H.valid(component),'native WidgetComponent unavailable')
        local ui=component:GetUserWidgetObject()
        if not H.valid(ui) then
            ui=X.object('/Script/UMG.Default__WidgetBlueprintLibrary'):Create(s.pc,
                X.asset('/Game/UserInterface/ObjectiveMode/WB_CauldronUI.WB_CauldronUI_C'),s.pc)
            assert(H.valid(ui),'native cauldron widget creation unavailable'); component:SetWidget(ui)
        end
        local player=X.read(s.pc,'Player'); if H.valid(player) then component:SetOwnerPlayer(player) end
        a:Init();assert(not obsolete(s),'preview owner retired');p.nativeVisual=true
        if X.applyCauldronLook then X.guard('PreviewAppearance',X.applyCauldronLook)(a,p.info) end
        assert(not obsolete(s),'preview owner retired')
        p.wasHidden=X.read(p.actor,'bHidden')==true; p.hidden=true; p.actor:SetActorHiddenInGame(true)
        X.log('PreviewVisuals','pot '..p.index..': native actor/materials initialized, carrier hidden; gameplay disabled')
    end
    local function nativeUI(s,p)
        local a=p.nativeActor; assert(p.nativeVisual and X.live(a),'native cauldron visuals unavailable')
        -- Vanilla keeps WantedProp invalid and the request widget collapsed until activation.
        local revealed=p.active and not p.filled and p.wanted
        local wanted=revealed and p.wanted.class or (type(CreateInvalidObject)=='function' and CreateInvalidObject() or nil)
        a.WantedProp=wanted; a.Active=not not revealed; a.Filled=p.filled
        a.VisualCirclelFill=p.filled and 0 or (p.active and 1 or math.min(1,p.dwell/s.rules.dwell))
        if p.nativeStacks~=p.stacks then
            a.Stacks=p.stacks; a:OnRep_Stacks(); p.nativeStacks=p.stacks
        end
        if revealed and p.nativeRequest~=p.wanted.id then
            a:UpdateWantedPropMulti(); p.nativeRequest=p.wanted.id
        elseif not revealed then p.nativeRequest=nil end
        if p.filled and not p.nativeFilled then a:ActivateLightMulti(); p.nativeFilled=true end
        local ui=a.Widget:GetUserWidgetObject(); assert(H.valid(ui),'native cauldron user widget not constructed yet')
        local icon=ui.WB_RequiredPropIcon; local fill=ui.WB_CauldronFillstate
        assert(H.valid(icon) and H.valid(fill),'native required-prop/fill widgets missing')
        local colour={SpecifiedColor=p.colour,ColorUseRule=0}
        ui.Cauldron=a; ui.Color=colour; ui.Team=X.read(X.read(s.pc,'PlayerState'),'Team') or 2; ui:SetOwningPlayer(s.pc)
        icon.Cauldron=a; icon.Color=colour; fill.Stacks=p.stacks
        local gi=X.gi(s.pc); local stats=X.read(X.read(gi,'ServerStatManager'),'PropDatas')
        -- The native brush binding uses PropID -> PropDatas.Icon. Verify the icon exists;
        -- an empty native brush is not a successful fallback.
        if revealed then
            local propId=X.read(p.wanted.class:GetCDO(),'PropID'); local found
            if type(stats)=='table' and not stats.ForEach then found=X.get(stats[propId])
            elseif stats then stats:ForEach(function(k,v)
                if X.get(k)==propId then found=X.get(v) end
            end) end
            assert(found and H.valid(X.read(found,'Icon_8_FEE692074B47D3A0A046338C9F3EFA1E')),'native PropDatas icon unavailable')
        end
        p.nativeUI=true
        if H.valid(p.labelActor) then p.labelActor:SetActorHiddenInGame(true) end
    end
    local function sphere(s,p,key,radius,z)
        local transform={Translation={X=0,Y=0,Z=z},Rotation={X=0,Y=0,Z=0,W=1},Scale3D={X=1,Y=1,Z=1}}
        local component=p.actor:AddComponentByClass(X.asset('/Script/Engine.SphereComponent'),false,transform,false)
        if obsolete(s) then return end
        local slot=#s.components+1
        if component then s.components[slot]={component=component,owner=p.actor} end
        local ok,err=pcall(function()
            assert(H.valid(component),'preview '..key..' sphere could not be added')
            component:SetCollisionProfileName(FName('OverlapAllDynamic'),true)
            assert(not obsolete(s),'preview owner retired');component:SetCollisionEnabled(1)
            assert(not obsolete(s),'preview owner retired');component:SetGenerateOverlapEvents(true)
            assert(not obsolete(s),'preview owner retired');component:SetSphereRadius(radius,true)
            assert(not obsolete(s),'preview owner retired');component:SetHiddenInGame(true,false)
            assert(not obsolete(s),'preview owner retired');p[key]=component
        end)
        if not ok then
            local removed=pcall(function()
                if not obsolete(s) and H.valid(component) then
                    component:K2_DestroyComponent(p.actor)
                    if not obsolete(s) then assert(not H.valid(component),'preview sphere destruction refused') end
                end
            end)
            if removed then s.components[slot]=nil else s.stopping=true;s.cleanup_pending=true end
            error(err,0)
        end
    end
    local function overlay(s)
        local folder='/Game/UserInterface/UIElements/'; local cls='WB_TooltipTextContent'
        local ui=X.object('/Script/UMG.Default__WidgetBlueprintLibrary'):Create(s.pc,X.asset(folder..cls..'.'..cls..'_C'),s.pc)
        assert(not obsolete(s),'preview owner retired')
        assert(H.valid(ui),'preview overlay unavailable'); s.overlay=ui
        local root=ui.WidgetTree.RootWidget
        for _,child in ipairs(X.values(root:GetAllChildren())) do if H.class(child,'TextBlock') then s.overlayText=child; break end end
        assert(H.valid(s.overlayText),'native tooltip text missing')
        ui:AddToViewport(200); ui:SetPositionInViewport({X=12,Y=70},false)
        ui:SetDesiredSizeInViewport({X=540,Y=0}); ui:SetRenderTransformPivot({X=0,Y=0})
        ui:SetRenderScale({X=.55,Y=.55}); s.overlayText:SetAutoWrapText(true)
    end
    local function orb(s)
        local folder='/Game/UserInterface/ObjectiveMode/'
        local lib=X.object('/Script/UMG.Default__WidgetBlueprintLibrary')
        -- Copy the native hierarchy: full-screen CanvasPanel -> 96x96 Divine Orb.
        -- A sized standalone viewport widget did not render reliably in this game.
        local host=lib:Create(s.pc,X.asset('/Game/UserInterface/UIElements/WB_TooltipTextContent.WB_TooltipTextContent_C'),s.pc)
        assert(not obsolete(s),'preview owner retired')
        assert(H.valid(host),'orb canvas host creation unavailable'); s.orbHost=host
        local canvas=StaticConstructObject(X.asset('/Script/UMG.CanvasPanel'),host.WidgetTree)
        assert(H.valid(canvas),'orb full-screen CanvasPanel unavailable'); host.WidgetTree.RootWidget=canvas
        local ui=lib:Create(s.pc,X.asset(folder..'WB_DivineOrb.WB_DivineOrb_C'),s.pc)
        assert(not obsolete(s),'preview owner retired')
        assert(H.valid(ui),'native Divine Orb creation unavailable'); s.orb=ui
        ui.Percentage=0; ui:SetOwningPlayer(s.pc); host:SetOwningPlayer(s.pc)
        local slot=canvas:AddChildToCanvas(ui); assert(H.valid(slot),'orb CanvasPanelSlot unavailable')
        slot:SetAnchors({Minimum={X=1,Y=1},Maximum={X=1,Y=1}})
        slot:SetAlignment({X=.5,Y=1}); X.placeOrb(slot); slot:SetAutoSize(false)
        ui:SetVisibility(4); ui:SetRenderOpacity(1); ui:SetIsEnabled(true)
        for _,name in ipairs({'Container','Bar','Frame'}) do
            local child=X.read(ui,name)
            -- The native Bar Image exists in Container but is not exposed as
            -- a widget field. Resolve it once; geometry uses the same child.
            if name=='Bar' and not H.valid(child) then
                for _,image in ipairs(X.values(ui.Container:GetAllChildren())) do
                    if H.valid(image) and X.text(image:GetFName())==name then child=image; break end
                end
            end
            assert(H.valid(child),'orb child missing: '..name)
            child:SetVisibility(4); child:SetRenderOpacity(1)
            if name=='Bar' then s.orbBar=child end
        end
        host:AddToViewport(1000)
        host:SetAlignmentInViewport({X=0,Y=0}); host:SetPositionInViewport({X=0,Y=0},false)
        host:SetDesiredSizeInViewport({X=0,Y=0})
        -- Native viewport position/size setters reset anchors to the top-left.
        -- Stretch last so the child uses the full screen's bottom-right corner.
        host:SetAnchorsInViewport({Minimum={X=0,Y=0},Maximum={X=1,Y=1}})
        host:SetVisibility(4); host:SetRenderOpacity(1)
        host:ForceLayoutPrepass()
        local ok,cdo=pcall(function() return X.asset(folder..'WB_ObjectiveHudExtension.WB_ObjectiveHudExtension_C'):GetCDO() end)
        local range=ok and X.read(cdo,'MaxDistanceSq')
        s.orbMaxDistanceSq=type(range)=='number' and range>0 and range or M.DUMP_RULES.orbMaxDistanceSq
        s.orbReady=true
        X.log('PreviewOrb','native orb inside full-screen Canvas; z=1000; vanilla bottom-right (-140,-175), 96x96; range='..math.sqrt(s.orbMaxDistanceSq)..' UU')
    end
    local function orbGeometry(s)
        if not s.orbReady or s.orbGeometryLogged then return end
        local layout=X.object('/Script/UMG.Default__WidgetLayoutLibrary')
        local viewport=layout:GetViewportSize(s.orbHost); local dpi=layout:GetViewportScale(s.orbHost)
        assert(viewport.X>0 and viewport.Y>0 and dpi>0,'orb viewport/DPI not ready')
        local desired=s.orb:GetDesiredSize(); local bar=s.orbBar:GetDesiredSize()
        X.once('preview-orb-geometry:'..s.pc:GetAddress(),'PreviewOrbGeometry',string.format(
            'host in viewport=%s; orb parent=%s; viewport=%.0fx%.0f DPI=%.3f; slot=96x96; orb desired=%.1fx%.1f; Bar desired=%.1fx%.1f; opacity host=%s/orb=%s; Percentage=%.3f (native Frame alpha=Percentage, Bar always visible)',
            tostring(s.orbHost:IsInViewport()),tostring(H.valid(s.orb:GetParent())),viewport.X,viewport.Y,dpi,
            desired.X,desired.Y,bar.X,bar.Y,tostring(X.read(s.orbHost,'RenderOpacity')),tostring(X.read(s.orb,'RenderOpacity')),s.orb.Percentage))
        s.orbGeometryLogged=true
    end
    function api.nearest(s,p,origin,sample)
        if not p.wanted then return end
        local class=p.wanted.id
        if sample and sample[class] then return table.unpack(sample[class],1,3) end
        local revision=X.Registry.revision
        local retirement=X.Lifetime.retirement_revision
        if s.orbRegistryRevision~=revision or s.orbRetirementRevision~=retirement or s.orbEditRevision~=X.revision then
            s.orbCandidates={};s.orbRegistryRevision=revision;s.orbRetirementRevision=retirement;s.orbEditRevision=X.revision
        end
        s.orbCandidates=s.orbCandidates or {}
        local candidates=s.orbCandidates[class]
        if not candidates then
            candidates={}
            for id,a in pairs(s.originalsByClass[class] or {})do candidates[#candidates+1]={id=id,actor=a} end
            s.orbCandidates[class]=candidates
        end
        local best,position,distance
        for i=#candidates,1,-1 do
            local c=candidates[i];local a=c.actor
            if not X.live(a) then
                s.originalProps[c.id]=nil;s.originalsByClass[class][c.id]=nil;table.remove(candidates,i)
            else
                local location=X.location(a);local d=X.distance2(origin,location)
                if not distance or d<distance then best,position,distance=a,location,d end
            end
        end
        if sample then sample[class]={best,position,distance} end
        return best,position,distance
    end
    function api.updateOrb(s)
        if not s.orbReady or not H.valid(s.orb) then return end
        local time=now(s.pc)
        if s.orbSampleAt and time>=s.orbSampleAt and time-s.orbSampleAt<.1 then return end
        s.orbSampleAt=time -- target search is <=10Hz, owned by maintenance/render
        if H.valid(s.orbHost) then
            if not s.orbHost:IsInViewport() then
                s.orbHost:AddToViewport(1000); s.orbGeometryLogged=false
                X.log('PreviewOrb','viewport host removed by native HUD rebuild; re-added at z=1000')
            end
            local manager=X.read(X.gi(s.pc),'IngameUIManager')
            s.orbHost:SetVisibility(X.read(manager,'UserInterfaceIsHidden')==true and 1 or 4)
        end
        local closest;local pawn=s.pc:K2_GetPawn();local sample={}
        if X.live(pawn) then
            local origin=X.location(pawn)
            for _,p in ipairs(s.pots) do if p.active and not p.filled and p.wanted then
                local _,_,d=api.nearest(s,p,origin,sample)
                if d and (not closest or d<closest) then closest=d end
            end end
        end
        s.orb.Percentage=M.closePercent(closest,s.orbMaxDistanceSq)
    end
    local function problems(s,p)
        local list={}
        if not p.nativeUI and not H.valid(p.label) then list[#list+1]='Wanted prop display unavailable; restart Playtest.' end
        if #p.localPool==0 then list[#list+1]='Add at least two copies of each wanted prop.' end
        if #s.pool<#s.pots then list[#list+1]='Not enough prop types for '..#s.pots..' pots ('..#s.pool..')' end
        if #p.localPool<#s.pots+1 and s.rules.maxStacks>1 then list[#list+1]='Add more prop types for changing requests.' end
        if #p.near>0 then list[#list+1]='props too close: '..table.concat(p.near,', ',1,math.min(3,#p.near))..(#p.near>3 and ' …' or '') end
        if not p.filled and not p.wanted then list[#list+1]='No unused prop types remain; add more types.' end
        if not H.valid(p.witchSphere) or not H.valid(p.propSphere) then list[#list+1]='Deliveries unavailable; restart Playtest.' end
        return table.concat(list,'; ')
    end
    function api.render(s)
        local lines={'Fill a Pot preview — map problems'}
        local issues={}; local camera=X.read(s.pc,'PlayerCameraManager')
        local eye=H.valid(camera) and camera:GetCameraLocation() or nil
        for i,p in ipairs(s.pots) do
            local status=p.filled and 'FILLED' or (p.active and 'READY' or string.format('witch %.1f/%.1fs',p.dwell,s.rules.dwell))
            local wanted=p.wanted and p.wanted.label or 'no request'
            local label='Pot '..i..' ['..status..'] '..p.stacks..'/'..s.rules.maxStacks..'\n'..wanted
            local ok,err=pcall(nativeUI,s,p)
            if not ok then
                p.nativeUI=false
                X.once('preview-ui:'..p.id,'PreviewIcon','pot '..i..': text fallback: '..tostring(err))
                if not H.valid(p.label) and not p.textAttempted then
                    p.textAttempted=true -- one attempt per marker/playtest; no timed failure loop
                    local made,why=pcall(textActor,s,p,280,p.colour)
                    if not made then X.once('preview-text:'..tostring(why),'PreviewTextFallback',tostring(why)) end
                end
                if H.valid(p.label) then p.labelActor:SetActorHiddenInGame(false); p.label:K2_SetText(FText((p.filled and 'Filled' or (p.active and wanted or 'Stand in the rune circle'))..'  '..p.stacks..'/'..s.rules.maxStacks)) end
            end
            local issue=problems(s,p)
            if issue~='' and #lines<5 then lines[#lines+1]='Pot '..i..': '..issue:sub(1,180) end
            if issue~='' then issues[#issues+1]='pot '..i..': '..issue end
        end
        for _,p in ipairs(s.points) do if H.valid(p.label) then p.label:K2_SetText(FText('Witch respawn point')) end end
        if eye then
            for _,p in ipairs(s.display) do if X.live(p.labelActor) then
                local loc=X.location(p.labelActor); local yaw=math.deg(math.atan(eye.Y-loc.Y,eye.X-loc.X))
                p.labelActor:K2_SetActorRotation({Pitch=0,Yaw=yaw,Roll=0},true)
            end end
        end
        if X.Teleporters then for _,problem in ipairs(X.Teleporters.problems())do
            issues[#issues+1]=problem;if #lines<7 then lines[#lines+1]=problem end
        end end
        if H.valid(s.overlayText) then s.overlayText:SetText(FText(table.concat(lines,'\n'))); s.overlay:SetVisibility(#issues>0 and 0 or 1) end
        api.updateOrb(s)
        local summary=#issues==0 and 'PASS' or table.concat(issues,' | ')
        X.once('preview-validation:'..s.pc:GetAddress(),'PreviewValidation',#s.pots..' pots / '..#s.points..' respawns / '..#s.pool..
            ' candidate classes / '..(s.sharedCount or 0)..' actual-match shared classes / MinPropDistance='..s.rules.minDistance..': '..summary)
    end
    local function respawnTransform(s)
        local function unit(t)
            local q=t.Rotation
            return {Translation={X=t.Translation.X,Y=t.Translation.Y,Z=t.Translation.Z},
                Rotation={X=q.X,Y=q.Y,Z=q.Z,W=q.W},Scale3D={X=1,Y=1,Z=1}}
        end
        local points=s.points
        if #points>0 then
            local p=points[math.random(#points)]
            return unit((X.live(p.nativeActor) and p.nativeActor or p.actor):GetTransform())
        end
        for _,path in ipairs({'/Game/Blueprints/StaticProps/Placeable/Utility/BP_WitchPlayerStart.BP_WitchPlayerStart_C',
            '/Game/Blueprints/Player/PlayerStarts/B_WitchPlayerStart.B_WitchPlayerStart_C'}) do
            local starts=X.actors(s.pc,path); if #starts>0 then return unit(starts[math.random(#starts)]:GetTransform()) end
        end
        return unit(s.startTransform) -- solo fallback: possessed pawn's original playtest position
    end
    local function consume(s,p)
        if s.consuming then return end
        local pawn=s.pc:K2_GetPawn(); local prop=X.read(pawn,'ControllingProp')
        assert(X.live(pawn) and X.live(prop),'controlled Creative prop pawn unavailable')
        local r={pawn=pawn,prop=prop,oldRespawn=X.read(pawn,'IsRespawn'),pawnHidden=X.read(pawn,'bHidden')==true,
            propHidden=X.read(prop,'bHidden')==true,pawnCollision=X.read(pawn,'bActorEnableCollision')~=false,
            destination=respawnTransform(s),untilTime=now(s.pc)+s.rules.respawnDelay}
        s.consuming=r -- own all changed state before mutation; stop can unwind partial failure
        local position=p.nativeActor:K2_GetActorLocation();local rotation=p.nativeActor:K2_GetActorRotation()
        local camera=assert(native().spawn(X.OM..'B_CauldronPawn.B_CauldronPawn_C',s.pc,
            {X=position.X,Y=position.Y,Z=position.Z,Yaw=rotation.Yaw,Pitch=rotation.Pitch,Roll=rotation.Roll},function(a)
                a.Instigator=pawn;a:SetReplicates(false);a:SetActorEnableCollision(false)
            end),'native cauldron camera pawn unavailable')
        r.camera=camera;s.actors[#s.actors+1]=camera
        pawn.IsRespawn=false -- Creative's unpossess override otherwise destroys our return path
        pawn:OnKilledMulti() -- native skill/highlight shutdown, same call as real delivery
        pawn:SetActorHiddenInGame(true); pawn:SetActorEnableCollision(false); prop:SetActorHiddenInGame(true)
        s.pc:Possess(camera)
        assert(X.same(s.pc:K2_GetPawn(),camera),'native cauldron pawn possession failed')
        X.log('PreviewConsume','native B_CauldronPawn possessed; controlled prop hidden; native Creative SetWitch return in 3 seconds')
    end
    local function finishConsume(s,cancel)
        local r=s.consuming; if not r then return true end
        local pc=s.pc; local pawn=r.pawn; local current=X.live(pc) and pc:K2_GetPawn()
        local gm=X.live(pc) and X.gameplay():GetGameMode(pc)
        local creative=H.class(gm,'B_CreativeGameMode_C') and X.same(gm,s.gm)
        local play=creative and pc.CurrentPlayMode==3
        if X.live(r.prop) then r.prop:SetActorHiddenInGame(r.propHidden) end
        if X.live(pawn) then
            pawn.IsRespawn=r.oldRespawn; pawn:SetActorHiddenInGame(r.pawnHidden); pawn:SetActorEnableCollision(r.pawnCollision)
            if play and (X.same(current,r.camera) or X.same(current,pawn)) then
                -- Repossess the retained prop pawn so SetWitch's native GetController succeeds.
                pc:Possess(pawn); pawn:SetWitch(X.native(r.destination))
                local witch=pc:K2_GetPawn()
                assert(X.live(witch) and not X.same(witch,pawn) and witch:GetClass():IsChildOf(X.asset(WITCH)),
                    'native Creative SetWitch did not return a witch; will retry')
                destroyActor(s,pawn)
                local ok,err=pcall(function()
                    local fx=X.object('/Script/Niagara.Default__NiagaraFunctionLibrary'):SpawnSystemAtLocation(pc,
                        X.asset('/Game/Effects/Witch/NS_WitchTransform.NS_WitchTransform'),X.location(witch),
                        {Pitch=0,Yaw=0,Roll=0},{X=1,Y=1,Z=1},true,true,0,true)
                    if H.valid(fx) then s.effects[#s.effects+1]=fx end
                end)
                if not ok then X.once('preview-respawn-fx','PreviewRespawnEffect','native transform VFX unavailable: '..tostring(err)) end
                X.log('PreviewRespawn','native Creative SetWitch + transform effect; return complete'..(cancel and ' (preview stopped)' or ''))
            else
                -- Mode/world already changed: never repossess an old playtest pawn.
                if creative and X.same(current,r.camera) then
                    pc:RespawnPlayerPawnServer(2)
                    assert(not X.same(pc:K2_GetPawn(),r.camera),'Creative edit return did not replace camera; will retry')
                end
                pawn:MultiSwitchBack(); destroyActor(s,pawn)
            end
        elseif play and X.same(current,r.camera) then
            pc:RespawnPlayerPawnServer(0) -- native Creative witch fallback if old pawn was destroyed externally
            assert(not X.same(pc:K2_GetPawn(),r.camera),'Creative fallback respawn did not replace camera')
        end
        destroyActor(s,r.camera)
        s.consuming=nil; return true
    end
    function api.deliver(s,p,simulated)
        if p.filled or not p.wanted then return false end
        if not simulated then X.guard('PreviewConsume',consume)(s,p) end
        if p.nativeVisual then X.guard('PreviewSplash',function() p.nativeActor:ResetUIMulti() end)() end
        local old=p.wanted; p.lastProps[old.id]=true; p.wanted=nil; p.stacks=p.stacks+1
        p.filled=p.stacks>=s.rules.maxStacks; p.active=false; p.dwell=0
        X.guard('PreviewPool',api.updatePools)(s); api.assign(s)
        X.log('PreviewDelivery','pot '..p.index..' '..p.stacks..'/'..s.rules.maxStacks..' '..old.label..(simulated and ' (simulated)' or ' (exact controlled prop overlap)'))
        X.guard('PreviewFeedback',X.message)(s.pc,'PREVIEW: pot '..p.index..' '..(p.filled and 'filled' or 'stack '..p.stacks..'/'..s.rules.maxStacks))
        api.render(s); return true
    end
    function api.step(s,time)
        local dt=math.max(0,math.min(1,time-s.lastTime)); s.lastTime=time
        if s.consuming then
            if time>=s.consuming.untilTime then finishConsume(s,false) end
            return
        end
        local pawn=s.pc:K2_GetPawn(); local cls=H.valid(pawn) and pawn:GetClass()
        local witch=cls and cls:IsChildOf(X.asset(WITCH))
        local propPawn=cls and cls:IsChildOf(X.asset(PAWN))
        local prop=propPawn and X.read(pawn,'ControllingProp')
        for _,p in ipairs(s.pots) do if not p.filled and p.wanted then
            if not p.active then
                local inside=witch and H.valid(p.witchSphere) and p.witchSphere:IsOverlappingActor(pawn)
                p.dwell=inside and p.dwell+dt or math.max(0,p.dwell-dt)
                if p.dwell>=s.rules.dwell then
                    p.active=true;nativeUI(s,p)
                    X.log('PreviewRequest','pot '..p.index..' revealed after native dwell: '..p.wanted.label)
                end
            end
            if p.active and X.live(prop) and X.read(prop,'IsControlledByWitch')==true
                and X.same(prop:GetClass(),p.wanted.class) and H.valid(p.propSphere) and p.propSphere:IsOverlappingActor(prop) then
                api.deliver(s,p,false)
            end
        end end
    end
    -- Decoded entry 3638 -> fluid FInterpTo, decal Fill, rune rays Fill -> return.
    -- ReceiveTick's other branch casts the WORLD GameState to SeekGameState and
    -- invokes latent/init/gameplay logic; Creative is a different subclass. Do not invoke it.
    function api.frame(s,time)
        if obsolete(s) or s.stopping or s.lastFrame==time then return end
        s.lastFrame=time; api.step(s,time)
        for _,p in ipairs(s.pots) do if p.nativeVisual and X.live(p.nativeActor) then
            local a=p.nativeActor
            a.WitchInCircleTime=p.dwell
            a.VisualCirclelFill=p.filled and 0 or (p.active and 1 or math.min(1,p.dwell/s.rules.dwell))
            if not p.nativeMotionFailed then
                local ok,err=pcall(function() a:ExecuteUbergraph_B_ObjectiveCauldron(3638) end)
                if not ok then p.nativeMotionFailed=true;error('native per-frame visual branch: '..tostring(err),0) end
            end
        end end
        -- Orb targets are sampled by maintenance; frame work stays O(pots).
    end
    function api.stop(pc)
        if not next(states) then return true end
        if X.Lifetime.transition then api.reset(); return true end
        for id,s in pairs(states) do if obsolete(s) then stopFrames(s);states[id]=nil end end
        if not next(states) then return true end
        if not X.live(pc) then return false,'preview controller unavailable' end
        local id=pc:GetAddress(); local s=states[id]; if not s then return true end
        if pc:GetFullName()~=s.pcName then return false,'preview controller identity changed: '..s.pcName end
        s.stopping=true;stopFrames(s); s.cleanup_pending=true; local done=true;local errors={}
        local function remove(stage,fn)
            if obsolete(s) then return true end -- abandon without reading old UObject fields
            local ok,err=pcall(fn); if not ok then done=false;errors[#errors+1]=stage..': '..tostring(err); X.once('preview-cleanup:'..tostring(err),stage,'FAILED '..tostring(err)) end
            return ok
        end
        if s.consuming and not remove('PreviewCleanup/possession',function() finishConsume(s,true) end) then return false,table.concat(errors,' | ') end
        for i,fx in pairs(s.effects) do if remove('PreviewCleanup/effect',function()
            if H.valid(fx) then
                fx:Deactivate()
                if not obsolete(s) then
                    X.destroy(fx)
                end
            end
        end) then s.effects[i]=nil end end
        if s.overlay and remove('PreviewCleanup',function() if H.valid(s.overlay) then s.overlay:RemoveFromParent() end end) then s.overlay=nil end
        if s.orb and remove('PreviewCleanup',function() if H.valid(s.orb) then s.orb:RemoveFromParent() end end) then s.orb=nil end
        if s.orbHost and remove('PreviewCleanup',function() if H.valid(s.orbHost) then s.orbHost:RemoveFromParent() end end) then s.orbHost=nil end
        for i,a in pairs(s.actors) do if remove('PreviewCleanup',function() destroyActor(s,a) end) then s.actors[i]=nil end end
        for i,r in pairs(s.components) do if remove('PreviewCleanup',function()
            if H.valid(r.component) then
                X.destroy(r.component)
            end
        end) then s.components[i]=nil end end
        for _,p in ipairs(s.pots) do
            if p.hidden and remove('PreviewCleanup',function() if X.live(p.actor) then
                p.actor:SetActorHiddenInGame(p.wasHidden)
                if not obsolete(s) then assert(X.read(p.actor,'bHidden')==p.wasHidden,'preview carrier visibility restore refused') end
            end end) then p.hidden=false end
            if p.tinted and remove('PreviewCleanup',function() if X.releaseMarkerTint then X.releaseMarkerTint(p.actor) end end) then p.tinted=false end
        end
        if done then states[id]=nil; X.log('PreviewCleanup','removed owned cauldrons/labels/overlay/orb/spheres; restored carriers; Lua progress discarded') end
        return done,table.concat(errors,' | ')
    end
    function api.cleanup()
        if X.Lifetime.transition then api.reset(); return true end
        local errors={}
        for id,s in pairs(states) do
            if obsolete(s) then stopFrames(s);states[id]=nil
            else local done,why=api.stop(s.pc);if not done then errors[#errors+1]='preview '..tostring(s.pcName or id)..': '..tostring(why) end end
        end
        return #errors==0,table.concat(errors,' | ')
    end
    function api.cleanupPending()
        for _,s in pairs(states) do if s.cleanup_pending then return true end end
        return false
    end
    function api.begin(pc)
        if X.live(pc) and not pc:IsLocalController() then return end
        local gm,gs,why=context(pc); if not gm then skipped(why,pc);return end
        if states[pc:GetAddress()] then skipped('controller already owns a preview',pc);return states[pc:GetAddress()] end
        local pots,points=X.markers(pc); if #pots==0 then skipped('no cauldron markers in current world',pc);return end
        pots=X.colours(pc,pots)
        local time=now(pc)
        local initialPawn=pc:K2_GetPawn()
        local s={pc=pc,pcName=pc:GetFullName(),epoch=X.Lifetime.epoch,gm=gm,gs=gs,pots=pots,points=points,display={},actors={},components={},effects={},pool={},poolById={},originalProps={},originalsByClass={},
            startTransform=X.live(initialPawn) and initialPawn:GetTransform() or pots[1].actor:GetTransform(),
            rules=rules(),lastTime=time,lastPool=time,key=markerKey(pots,points)}
        states[pc:GetAddress()]=s -- partial initialization is still owned/cleanable
        decisions[pc:GetAddress()]='running'
        if not armFrames(s,pc:GetAddress()) then
            stopFrames(s);states[pc:GetAddress()]=nil
            skipped('native frame subscription unavailable',pc)
            return nil
        end
        for i,p in ipairs(pots) do
            p.index=i; p.stacks=0; p.dwell=0; p.active=false; p.filled=false; p.lastProps={}; p.localPool={}; p.near={}
            s.display[#s.display+1]=p
            if X.tintMarker then p.tinted=true; X.guard('PreviewTint',X.tintMarker)(p.actor,p.colour) end
            local ok,err=pcall(nativePot,s,p)
            if not ok then
                p.nativeVisual=false
                X.log('PreviewVisuals','FAILED pot '..i..': '..tostring(err)..'; retaining tinted marker and text fallback')
                local removed,cleanupError=pcall(function()
                    destroyActor(s,p.nativeActor)
                    if not obsolete(s) and p.hidden and X.live(p.actor) then
                        p.actor:SetActorHiddenInGame(p.wasHidden); p.hidden=false
                    end
                end)
                if removed then
                    if p.nativeSlot then s.actors[p.nativeSlot]=nil end
                    p.nativeActor=nil; p.nativeSlot=nil
                else
                    s.stopping=true; s.cleanup_pending=true
                    X.log('PreviewCleanup','partial pot cleanup pending: '..tostring(cleanupError))
                    skipped('partial pot cleanup pending');return s
                end
            end
            if obsolete(s) then skipped('world changed during pot construction');return end
            X.guard('PreviewVolumes',sphere)(s,p,'witchSphere',s.rules.witchRadius,s.rules.witchZ)
            if obsolete(s) or s.stopping then skipped('world changed or cleanup pending after witch volume');return s end
            X.guard('PreviewVolumes',sphere)(s,p,'propSphere',s.rules.propRadius,s.rules.propZ)
            if obsolete(s) or s.stopping then skipped('world changed or cleanup pending after prop volume');return s end
        end
        for _,p in ipairs(points) do
            s.display[#s.display+1]=p
            X.guard('PreviewRespawns',function()
                local position=p.actor:K2_GetActorLocation();local rotation=p.actor:K2_GetActorRotation();local scale=p.actor:GetTransform().Scale3D
                local a=assert(native().spawn(X.OM..'B_ObjectiveWitchRespawnPoint.B_ObjectiveWitchRespawnPoint_C',s.pc,
                    {X=position.X,Y=position.Y,Z=position.Z,Yaw=rotation.Yaw,Pitch=rotation.Pitch,Roll=rotation.Roll,
                     ScaleX=scale.X,ScaleY=scale.Y,ScaleZ=scale.Z},function(a)
                        a:SetReplicates(false);a:SetActorTickEnabled(false);a:SetActorEnableCollision(false)
                    end),'native preview respawn point unavailable')
                s.actors[#s.actors+1]=a;p.nativeActor=a
            end)()
            if obsolete(s) or s.stopping then skipped('world changed or cleanup pending after respawn actor');return s end
            X.guard('PreviewRespawns',textActor)(s,p,180,X.RESPAWN_GREEN)
            if s.stopping then skipped('cleanup pending after respawn label');return s end
        end
        local function createUI(stage,fn,fields)
            local ok,err=pcall(fn,s)
            if ok then return end
            local complete=true
            for _,key in ipairs(fields) do
                local ui=s[key]
                local removed=pcall(function()
                    if not obsolete(s) and H.valid(ui) then ui:RemoveFromParent() end
                end)
                if removed then s[key]=nil else complete=false end
            end
            if not complete then s.stopping=true;s.cleanup_pending=true end
            X.log(stage,'FAILED '..tostring(err)) -- preserve the original setup failure
        end
        createUI('PreviewOverlay',overlay,{'overlay'})
        if obsolete(s) or s.stopping then skipped('world changed or cleanup pending after overlay');return s end
        createUI('PreviewOrb/create',orb,{'orb','orbHost'})
        if obsolete(s) or s.stopping then skipped('world changed or cleanup pending after orb');return s end
        if not s.orbReady then X.guard('PreviewOrb/hide',function()
            if H.valid(s.orbHost) then s.orbHost:SetVisibility(1) end
            if H.valid(s.orb) then s.orb:SetVisibility(1) end
        end)() end
        X.guard('PreviewPool',api.updatePools)(s); api.assign(s); api.render(s)
        s.poolRevision=X.Registry.revision; s.editRevision=X.revision
        s.frameReady=true
        X.reports['preview-start-decision']=nil
        X.log('Preview','started inside vanilla playtest; transformation supported (Creative witch / prop pawn); '..#pots..' pots; '..#points..' respawns')
        X.log('PreviewVolumes','witch activation radius=200 @ Z120, dwell='..s.rules.dwell..' witch-seconds; delivery radius=90 @ Z138.492; stacks='..s.rules.maxStacks)
        return s
    end
    function api.state(pc) if next(states)==nil or X.Lifetime.transition then return end;return states[pc:GetAddress()] end
    function api.simulate(index)
        for _,s in pairs(states) do if not s.stopping and context(s.pc) then
            local p=s.pots[index]; if p then return api.deliver(s,p,true) end
        end end
        X.log('PreviewDelivery','simulate refused: enter vanilla Creative playtest with markers, then use a valid pot number')
        return false
    end
    function api.where()
        local found=false
        for _,s in pairs(states) do if not s.stopping and context(s.pc) then
            local pawn=s.pc:K2_GetPawn()
            if X.live(pawn) then
                found=true; local origin=X.location(pawn); local yaw
                pcall(function() yaw=s.pc:GetControlRotation().Yaw end)
                for _,p in ipairs(s.pots) do
                    local _,position,d=api.nearest(s,p,origin)
                    local label=p.wanted and p.wanted.label or 'no request'
                    if d then
                        local dx,dy,dz=position.X-origin.X,position.Y-origin.Y,position.Z-origin.Z
                        local bearing=math.deg(math.atan(dy,dx)); local direction
                        if type(yaw)=='number' then
                            local relative=(bearing-yaw+180)%360-180
                            direction=math.abs(relative)<=45 and 'ahead' or (math.abs(relative)>=135 and 'behind' or (relative>0 and 'right' or 'left'))
                            direction=direction..string.format(' (view bearing %+.0f deg)',relative)
                        else direction=string.format('world bearing %.0f deg (+X=0, +Y=90)',bearing) end
                        X.log('PreviewWhere',string.format('pot %d: %s; nearest %.0f UU (%.1f m), %s, height %+.0f UU; position [%.0f, %.0f, %.0f]',
                            p.index,label,math.sqrt(d),math.sqrt(d)/100,direction,dz,position.X,position.Y,position.Z))
                    else X.log('PreviewWhere','pot '..p.index..': '..label..'; no live original copy found') end
                end
            end
        end end
        if not found then X.log('PreviewWhere','where refused: enter vanilla Creative playtest with cauldron markers and a possessed pawn') end
        return found
    end
    function api.invalidate() observed={} end
    -- Retry a start decision only for a changed local mode/playtest flag,
    -- current world, or relevant actor/marker set. Unrelated callbacks may bump
    -- X.revision every poll; they do not make an empty marker set worth decoding.
    local function observe(pc)
        local id=pc:GetAddress();local v=X.Registry.versions
        local old=observed[id]
        local gmVersion,gsVersion=v.B_CreativeGameMode_C or 0,v.B_CreativeGameState_C or 0
        if not old or old.epoch~=X.Lifetime.epoch or old.gmVersion~=gmVersion or old.gsVersion~=gsVersion then
            old={epoch=X.Lifetime.epoch,gmVersion=gmVersion,gsVersion=gsVersion,gs=X.gameplay():GetGameState(pc)}
            observed[id]=old
        end
        local mode=pc.CurrentPlayMode
        local playing=X.live(old.gs) and old.gs.IsPlayTestMode==true or false
        local pots,starts=v.BP_WitchCauldron_C or 0,v.BP_WitchRuneStone01_C or 0
        if old.mode==mode and old.playing==playing and old.pots==pots and old.starts==starts and old.enabled==C.CreativeMaps then return end
        old.mode=mode;old.playing=playing;old.pots=pots;old.starts=starts;old.enabled=C.CreativeMaps
        if not states[id] then X.guard('Preview/start',api.begin)(pc) end
    end
    function api.poll()
        local work=pending; pending={}
        for _,command in ipairs(work) do
            local function execute()
                if command=='help' then X.log('Preview','usage: fappreview deliver <pot number> | fappreview where')
                elseif command=='where' then api.where()
                else assert(api.simulate(command),'preview delivery refused') end
            end
            if X.command then X.command(execute) else X.guard('PreviewCommand',execute)() end
        end
        for _,s in pairs(states) do
            if not obsolete(s) and not s.stopping then
            local gm,gs=context(s.pc)
            if not gm or not X.same(gs,s.gs) or not X.same(gm,s.gm) then api.stop(s.pc)
            else
                local time=now(s.pc)
                if s.poolRevision~=X.Registry.revision or s.editRevision~=X.revision then
                    local pots,points=X.markers(s.pc)
                    if markerKey(pots,points)~=s.key then api.stop(s.pc);observed[s.pc:GetAddress()]=nil
                    else
                        X.guard('PreviewPool',api.updatePools)(s); api.assign(s); X.guard('PreviewOrbGeometry',orbGeometry)(s)
                        s.poolRevision=X.Registry.revision; s.editRevision=X.revision
                    end
                end
                if states[s.pc:GetAddress()]==s and not s.stopping then api.render(s) end -- maintenance; frame producer alone advances dwell/visuals
            end
            end
        end
        local controllers=X.findAll('B_CreativePlayerController_C')
        if #controllers==0 then skipped('no Creative controller in current registry') else decisions.world=nil end
        for _,pc in ipairs(controllers) do
            if X.live(pc) and pc:IsLocalController() then
                observe(pc)
            end
        end
    end
    -- Only the elected main watchdog drives active preview. Editor idle has no engine work.
    function api.tick(time)
        if not C.CreativeMaps or not api.active() then return end
        -- Heartbeat owns reconciliation only. Continuous native viewport
        -- delivery is the sole animation/dwell/Orb producer.
        for _,s in pairs(states) do if not s.stopping then time=time or now(s.pc) end end
        if previewClock and time and time-previewClock<.25 then return end
        previewClock=time
        api.poll()
    end
    function api.active()
        for _,s in pairs(states) do if not s.stopping then return true end end
        return false
    end
    X.Preview=api
    X.hook('Preview',X.CREATIVE,'B_CreativePlayerController','ChangePlayerMode',function(self)
        local pc=self:get();if not X.live(pc) or not pc:IsLocalController() then return end
        api.invalidate()
        local stop=pc.CurrentPlayMode~=3
        X.log('Preview','ChangePlayerMode entered; mode='..tostring(pc.CurrentPlayMode)..'; decision='..(stop and 'stop' or 'observe next maintenance'))
        if stop then api.stop(pc) end
    end)
    -- Events describe transitions; the existing maintenance pass reads the live
    -- controller/GameState flags even when no actor is born or bucket changes.
    for _,entry in ipairs({{'B_CreativeGameMode','BeginPlayTest'},{'B_CreativeGameState','OnRep_IsPlayTestMode'}}) do
        local method=entry[2]
        X.hook('Preview',X.CREATIVE,entry[1],method,function()
            api.invalidate()
            X.log('Preview',method..' entered; decision=observe next maintenance')
        end)
    end
    X.hook('Preview',X.CREATIVE,'B_CreativeGameMode','EndPlayTest',function(self)
        api.invalidate()
        local count=0
        for _,s in pairs(states) do if X.same(s.gm,self:get()) then count=count+1;api.stop(s.pc) end end
        X.log('Preview','EndPlayTest entered; decision=stop matching previews; count='..count)
    end)
    -- A distinct diagnostics command never opens/travels a match or changes play mode.
    if type(FAPP_SERVICES.runtime.command)=='function' then
        function api.command(args)
            local index=tonumber(args[2])
            if args[1]=='cleanup' then
                return api.cleanup() -- explicit healthy command: one retry, no scheduled job
            elseif args[1]=='deliver' and index and index%1==0 and index>=1 then
                pending[#pending+1]=index -- consumed by the existing tick-driven maps poll
            elseif args[1]=='where' then pending[#pending+1]='where'
            else pending[#pending+1]='help' end
            return true
        end
        FAPP_SERVICES.runtime.command('fappreview',function(_,parameters) return api.command(X.values(parameters)) end)
    end
    function api.reset() for _,s in pairs(states)do stopFrames(s)end;states={}; decisions={}; observed={}; pending={}; previewClock=nil end
    if X.Lifetime.onReset then X.Lifetime.onReset(api.reset) end
    if FAPP_API and FAPP_API.own then FAPP_API.own(api.cleanup,api.reset) end
    X.log('Preview','module ready; native per-frame fluid/runes + reveal/splash/camera/respawn + Divine Orb; 4 Hz maintenance; vanilla CurrentPlayMode=3 only; fappreview deliver <pot number> | where')
    -- Do not cache an edit-mode decision by object/event revision. The same
    -- resident actors change these properties without a constructor notification.
    -- No new timer: maps maintenance already polls this module every 500 ms.
    return api
end
return M
