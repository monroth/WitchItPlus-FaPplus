-- Selected Creative marker exclusion sphere. Native wire-outline candidate:
-- SphereComponent rendering in the shipping build needs a visual acceptance check.
-- No asset guesses, collision, replication, saved metadata or gameplay changes.
local M={}
function M.init(X)
    local H,C=X.H,X.C
    local api,owned={},{}
    local cleanupPending=false
    local lastSetting
    local function release(key)
        local r=owned[key]; if not r then return true end
        -- Deleted/departing actors own their components; never touch stale worlds.
        if not X.live(r.actor) then owned[key]=nil; return true end
        r.retiring=true
        if H.valid(r.component) then
            -- Hide first; a failed destroy retains ownership for the next poll.
            pcall(function() r.component:SetVisibility(false,false) end)
            local ok,err=pcall(function() r.component:K2_DestroyComponent(r.actor) end)
            if not ok then
                cleanupPending=true
                X.once('radius-cleanup:'..key,'Radius','cleanup pending: '..tostring(err))
                return false
            end
        end
        owned[key]=nil; return true
    end
    local function selected()
        local result={}
        if not C.CreativeMaps or X.Lifetime.transition then return result end
        for _,pc in ipairs(X.findAll('B_CreativePlayerController_C')) do
            if X.live(pc) and pc:IsLocalController() and (pc.CurrentPlayMode==0 or pc.CurrentPlayMode==1 or pc.CurrentPlayMode==2) then
                local gm=X.gameplay():GetGameMode(pc)
                local gs=X.gameplay():GetGameState(pc)
                if H.class(gm,'B_CreativeGameMode_C') and not (H.valid(gs) and X.read(gs,'IsPlayTestMode')==true) then
                    for _,a in ipairs(X.values(pc.SelectedActors)) do
                        if X.live(a) and X.Lifetime.sameWorld(pc,a) and X.read(a,'IsPreview')~=true then
                            local info=X.kind(a)
                            if info and info.kind==1 then result[X.Lifetime.key(a)]=a end
                        end
                    end
                end
            end
        end
        return result
    end
    local function create(key,a,radius)
        local r={actor=a}; owned[key]=r
        local ok,err=pcall(function()
            local transform={Translation={X=0,Y=0,Z=0},Rotation={X=0,Y=0,Z=0,W=1},Scale3D={X=1,Y=1,Z=1}}
            r.component=a:AddComponentByClass(X.asset('/Script/Engine.SphereComponent'),false,X.native(transform),false)
            local c=r.component; assert(H.valid(c),'native SphereComponent unavailable')
            -- Own before configuring, follow the actor pivot, ignore carrier scale.
            c:SetCollisionEnabled(0); c:SetGenerateOverlapEvents(false)
            c:SetMobility(2); c:SetAbsolute(false,true,true)
            c:SetSphereRadius(radius,false); r.radius=radius
            c:SetVisibility(true,false); c:SetHiddenInGame(false,false)
        end)
        if not ok then
            release(key)
            X.once('radius-build:'..key,'Radius','outline unavailable: '..tostring(err))
        end
    end
    function api.poll()
        -- The reset path is Lua-only. The old world owns its native components.
        if X.Lifetime.transition then api.reset(); return end
        cleanupPending=false; lastSetting=C.CreativeMapMinPropDistance
        local targets=selected()
        for key,r in pairs(owned) do
            if r.retiring or not targets[key] or not X.same(r.actor,targets[key]) or not H.valid(r.component) then release(key) end
        end
        if next(targets)==nil then return end
        local radius=X.minDistance()
        for key,a in pairs(targets) do
            local r=owned[key]
            if not r then create(key,a,radius)
            elseif not r.retiring and r.radius~=radius then
                local ok,err=pcall(function() r.component:SetSphereRadius(radius,false) end)
                if ok then r.radius=radius
                else release(key); X.once('radius-resize:'..key,'Radius','outline unavailable: '..tostring(err)) end
            end
        end
    end
    function api.reset() owned={}; cleanupPending=false; lastSetting=nil end
    X.cachedPoll(api,function() return cleanupPending or lastSetting~=C.CreativeMapMinPropDistance end)
    -- These committed selection/mode events are already evidenced in maps_palette
    -- and maps_preview. No per-frame selection query or new native draw API.
    local function refresh() api.invalidate(); api.poll() end
    for _,name in ipairs({'SelectActor','SelectMultiple','DeselectSingleActor','DeselectMultipleActors','ChangePlayerMode'}) do
        X.hook('Radius',X.CREATIVE,'B_CreativePlayerController',name,refresh)
    end
    X.hook('Radius',X.CREATIVE,'B_CreativeGameMode','BeginPlayTest',refresh)
    X.hook('Radius',X.CREATIVE,'B_CreativeGameMode','EndPlayTest',refresh)
    X.hook('Radius',X.CREATIVE,'B_CreativeGameState','OnRep_IsPlayTestMode',refresh)
    return api
end
return M
