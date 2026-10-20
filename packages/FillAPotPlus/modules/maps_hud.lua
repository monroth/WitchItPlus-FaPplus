-- Retain the bound VerticalBox property; put a grid inside it after native rebuild.
local M={}
function M.init(X)
    local H,C=X.H,X.C; local api,records,building={},{},{}
    local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
    local progress=dofile(dir..'maps_pot_progress.lua').init(X)
    api.progress=progress.refresh
    local function current(r)
        return X.live(r.widget) and H.valid(r.parent) and H.valid(r.box)
            and X.same(r.widget.CauldronBlock,r.box) and X.same(r.box:GetParent(),r.parent)
            and X.Lifetime.worldKey(r.widget)==r.world
    end
    local function scale(w,x,y)
        local v=w.RenderTransform.Scale; v.X=x; v.Y=y; w:SetRenderScale(v)
    end
    local function translation(w,x,y)
        local v=w.RenderTransform.Translation; v.X=x; v.Y=y; w:SetRenderTranslation(v)
    end
    local function fit(r)
        if not current(r) then return end
        r.widget:ForceLayoutPrepass()
        local size=r.parent:GetDesiredSize()
        local layout=X.object('/Script/UMG.Default__WidgetLayoutLibrary')
        local viewport=layout:GetViewportSize(r.widget); local dpi=layout:GetViewportScale(r.widget)
        assert(dpi>0 and viewport.Y>0,'viewport size/DPI not ready')
        local budget=math.max(200,viewport.Y/dpi-390+(C.HudColumnLift or 60))
        local scale=size.Y>0 and math.min(1,budget/size.Y) or 1
        local pivot=r.parent.RenderTransformPivot; pivot.X=1; pivot.Y=0
        r.parent:SetRenderTransformPivot(pivot)
        local v=r.parent.RenderTransform.Scale; v.X=scale; v.Y=scale; r.parent:SetRenderScale(v)
        X.once('hud:'..r.widget:GetAddress(),'HUD',r.count..' pots; '..r.mode..'; render scale='..string.format('%.3f',scale))
    end
    function api.refresh(w)
        if not X.live(w) then return end
        local box=w.CauldronBlock; assert(H.valid(box),'CauldronBlock missing')
        local parent=box:GetParent(); assert(H.valid(parent),'cauldron parent missing')
        local id=w:GetAddress(); building[id]=nil; X.Work.cancel('maps:hud:'..id)
        local blocks=X.values(box:GetAllChildren()); local count=#blocks
        scale(parent,1,1); translation(parent,0,0)
        if count<=(C.HudColumnThreshold or 7) then
            records[w:GetAddress()]=nil
            -- 6-7 pots: same single column, lifted into the empty space above it
            -- (in-game: an 8th block reaches the mana bar; the top ~60 px are free).
            local lift=count>5 and (C.HudColumnLift or 60) or 0
            if lift>0 then translation(parent,0,-lift) end
            X.once('hud:'..w:GetAddress(),'HUD',count..' pots; vanilla column'..(lift>0 and (' lifted '..lift) or ''))
            return
        end
        local id=w:GetAddress(); local epoch=X.Lifetime.epoch
        local token={}; building[id]=token; records[id]=nil
        local grid,failed,record
        local step=X.Work.sequence({function()
            grid=StaticConstructObject(X.asset('/Script/UMG.UniformGridPanel'),w.WidgetTree)
            assert(H.valid(grid),'UniformGridPanel construction failed')
            local padding=grid.SlotPadding
            padding.Left=0; padding.Top=0; padding.Right=12; padding.Bottom=10
            grid:SetSlotPadding(padding)
            return true
        end,function()
            box:ClearChildren(); box:AddChild(grid); return true
        end,X.Work.each(blocks,function(block,i)
            assert(H.valid(block),'destroyed cauldron block')
            local per=math.max(1,C.HudColumnThreshold or 7)
            local slot=grid:AddChildToUniformGrid(block,(i-1)%per,math.floor((i-1)/per))
            assert(H.valid(slot),'grid slot missing')
            slot:SetHorizontalAlignment(0); slot:SetVerticalAlignment(0)
        end),function()
            translation(parent,0,-(C.HudColumnLift or 60))
            record={widget=w,parent=parent,box=box,count=count,mode=failed and 'scaled column fallback' or 'two columns',world=X.Lifetime.worldKey(w)}
            records[id]=record
            return true
        end,function()
            X.guard('HUD/fit',fit)(record); building[id]=nil; return true
        end})
        local pass,live
        local function run()
            if building[id]~=token or epoch~=X.Lifetime.epoch then return true end
            if pass~=X.Work.pass then pass=X.Work.pass; live=X.live(w) end
            if not live then building[id]=nil; return true end
            local ok,done=pcall(step)
            if ok then return done end
            if failed then building[id]=nil; error(done) end
            failed=true
            X.log('HUD','FAILED grid injection: '..tostring(done)..'; scaling native parent')
            -- Recovery is bounded too: restore one native child per step.
            step=X.Work.sequence({function()
                box:ClearChildren(); return true
            end,X.Work.each(blocks,function(block) if H.valid(block) then box:AddChild(block) end end),function()
                if H.valid(grid) then grid:RemoveFromParent() end
                record={widget=w,parent=parent,box=box,count=count,mode='scaled column fallback',world=X.Lifetime.worldKey(w)}
                records[id]=record; return true
            end,function() X.guard('HUD/fit',fit)(record); building[id]=nil; return true end})
            return false
        end
        local key='maps:hud:'..id
        X.Work.cancel(key)
        if FAPP_TEST_NO_THROTTLE then X.Work.finish(run)
        else X.Work.submit(key,'HUD/grid',run) end
    end

    X.hook('HUD','/Game/UserInterface/ObjectiveMode/','WB_ObjectiveHudExtension','RefreshCauldronBlock',function(self)
        -- HUD improvement also works on official maps with an expanded cauldron count.
        local w=self:get(); X.guard('HUD/progress',api.progress)(w); api.refresh(w)
    end)
    function api.poll()
        for id,r in pairs(records) do
            if not current(r) then records[id]=nil
            elseif not C.CreativeMaps then
                scale(r.parent,1,1); records[id]=nil
                r.widget:RefreshCauldronBlock() -- disabled hook leaves the vanilla children
            else X.guard('HUD/resize',fit)(r) end
        end
    end
    X.log('HUD','module ready; >7 pots: first column of 7, overflow to a second column with DPI-aware parent scaling')
    function api.reset() records={}; building={}; progress.reset() end
    X.cachedPoll(api)
    local layoutPoll=api.poll
    function api.poll() progress.poll(); return layoutPoll() end
    return api
end
return M
