-- Map victory target. All writes are native scalar properties on the listen host.
local M={}
function M.init(X)
    local H=X.H; local api={}; local leases={}; local offsetPath
    local function readOffset(world)
        if not offsetPath then return 0 end
        local file=io.open(offsetPath,'r'); if not file then return 0 end
        local data=file:read(256) or ''; file:close()
        local key,time,value=data:match('^MRPPCT1\n([^\n]+)\n(%d+)\n([%-]?%d+)\n$')
        time,value=tonumber(time),tonumber(value)
        if key~=world or not time or os.time()-time<0 or os.time()-time>3
            or not value or value%1~=0 or value< -10 or value>10 then return 0 end
        return value
    end
    function api.offset(gs)
        -- Resolve engine path/world only in an event-driven apply. Watchdog reads
        -- the small cross-VM lease with ordinary Lua I/O and compares scalars.
        if not offsetPath then
            local ok,path=pcall(function()
                local saved=X.text(X.object('/Script/Engine.Default__KismetSystemLibrary'):GetProjectSavedDirectory())
                return saved:gsub('[\\/]$','')..'/MatchRulesPlusPlus/cauldron_target_offset.txt'
            end)
            if ok then offsetPath=path end
        end
        return readOffset(tostring(gs:GetWorld():GetAddress()))
    end
    function api.apply(gm,knownPots)
        if not X.live(gm) or not H.authority(gm) or not H.class(gm,'B_ObjectiveGameMode_C') then return end
        local gs=X.gameplay():GetGameState(gm)
        if not X.live(gs) or not H.authority(gs) or not H.class(gs,'B_ObjectiveGameState_C')
            or X.Lifetime.worldKey(gs)~=X.Lifetime.worldKey(gm) then return end
        local count=knownPots and #knownPots or 0
        if not knownPots then
            for _,pot in ipairs(X.values(gs.Cauldrons)) do if X.live(pot) then count=count+1 end end
        end
        if count==0 then return end
        local gi=X.gi(gm); local mm=H.valid(gi) and X.read(gi,'ObjectiveMatchManager')
        local round=H.valid(mm) and X.read(mm,'CurrentRound') or X.read(gs,'CurrentRound') or 0
        local base=X.mapTarget(gm,knownPots); local offset=api.offset(gs)
        if FAPP_METADATA then
            local info
            if knownPots and #knownPots>0 then info={target=base,pots=count}
            elseif X.Selection and X.Selection.currentInfo then info=X.Selection.currentInfo(gi) end
            if info then FAPP_METADATA.observe(info) end
        end
        leases[gs:GetAddress()]={world=tostring(gs:GetWorld():GetAddress()),offset=offset}
        local scope=X.Identity.session(gi); local matchKey=X.Identity.key(mm)
        local ceiling=math.max(1,math.min(count,255,base+offset))
        if round==2 and scope and scope.ceilingMatch==matchKey and scope.ceiling
            and (scope.ceilingWorld~=X.Lifetime.worldKey(gs) or scope.ceilingAppliedOffset==offset) then
            ceiling=scope.ceiling
        elseif scope then scope.ceiling=ceiling; scope.ceilingMatch=matchKey end
        if scope then scope.ceilingWorld=X.Lifetime.worldKey(gs); scope.ceilingAppliedOffset=offset end
        local target=ceiling
        if round==2 then
            local first=X.values(mm.RoundStates)[1]
            if not first or type(X.read(first,'TotalCauldronsFilled'))~='number' then
                X.once('target-round2:'..gs:GetAddress(),'MapTarget','waiting for native round-1 TotalCauldronsFilled'); return
            end
            target=math.min(first.TotalCauldronsFilled+1,ceiling)
        end
        if gs.CauldronTarget~=target then
            gs:FlushNetDormancy(); gs.CauldronTarget=target
            X.object('/Script/Engine.Default__NetPushModelHelpers'):MarkPropertyDirtyFromRepIndex(gs,46,FName('CauldronTarget'))
            gs:ForceNetUpdate()
            if X.PotProgress then X.PotProgress.invalidate(gs,true) end
        end
        X.once('target:'..gs:GetAddress(),'MapTarget','round='..round..' map N='..base..' offset='..offset..' ceiling='..ceiling..' target='..target)
        return target
    end
    X.hook('MapTarget',X.OM,'B_ObjectiveGameMode','HandleStartMatchOverride',function(self) api.apply(self:get()) end)
    function api.poll()
        if not X.C.CreativeMaps then return end
        for _,gm in ipairs(X.findAll('B_ObjectiveGameMode_C')) do X.guard('MapTarget/apply',api.apply)(gm) end
    end
    -- Full-win target belongs to the GI's manager, not the reloaded GameState.
    function api.ceiling(gs)
        local gi=X.gi(gs); local scope=X.Identity.session(gi)
        local mm=H.valid(gi) and X.read(gi,'ObjectiveMatchManager')
        if scope and scope.ceilingMatch==X.Identity.key(mm)
            and (scope.ceilingWorld==X.Lifetime.worldKey(gs) or X.read(gs,'CurrentRound')==2) then return scope.ceiling end
    end
    X.Targets=api
    function api.reset() leases={} end
    X.cachedPoll(api,function()
        if not X.C.CreativeMaps then return false end
        for _,lease in pairs(leases) do if readOffset(lease.world)~=lease.offset then return true end end
        return false
    end)
    return api
end
return M
