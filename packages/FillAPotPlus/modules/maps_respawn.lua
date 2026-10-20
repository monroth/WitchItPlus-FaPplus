-- FaP life timers are independent of Creative-map conversion. Official levels
-- already contain points, but native discovery runs only at StartSeek.
local M={}
function M.init(X)
    local H,O=X.H,X.OM
    local POINT=O..'B_ObjectiveWitchRespawnPoint.B_ObjectiveWitchRespawnPoint_C'
    local starts={
        '/Game/Blueprints/StaticProps/Placeable/Utility/BP_WitchPlayerStart.BP_WitchPlayerStart_C',
        '/Game/Blueprints/Player/PlayerStarts/B_WitchPlayerStart.B_WitchPlayerStart_C',
    }
    local api,owned={},{}
    local function context(o)
        if not X.live(o) then return end
        local g=X.gameplay()
        local gm=H.class(o,'B_ObjectiveGameMode_C') and o or g:GetGameMode(o)
        local gs=g:GetGameState(o)
        if not X.live(gm) or not H.class(gm,'B_ObjectiveGameMode_C') or not H.authority(gm)
            or not X.live(gs) or not H.class(gs,'B_ObjectiveGameState_C') or not H.authority(gs)
            or not X.Lifetime.sameWorld(o,gm) or not X.Lifetime.sameWorld(gs,gm) then return end
        return gm
    end
    local function usable(gm,points)
        local result={}
        for _,p in ipairs(points) do
            if X.live(p) and X.Lifetime.sameWorld(p,gm) then result[#result+1]=p end
        end
        return result
    end
    function api.prepare(o)
        local gm=context(o); if not gm then return end
        local raw=X.values(gm.AllWitchRespawnPoints)
        local points=usable(gm,raw)
        if #points>0 then
            if #points~=#raw then gm.AllWitchRespawnPoints=points end
            return points
        end
        -- Registry membership comes from construction/BeginPlay/EndPlay. No
        -- FindAllOf, Blueprint OUT arrays, or periodic world discovery.
        points=X.actors(gm,POINT)
        local source='native points'
        if #points==0 then
            local gi=X.gi(gm); local options=H.valid(gi) and gi.UsedMatchOptions
            -- Custom marker priority and reload ownership remain with the adapter.
            if not H.valid(options) or options.CustomMapSelected
                or X.read(options.MapData,'IsBuiltInCustomMap_24_B260140C4981E09A0400EBBB5AF787AD')==true then return points end
            for _,path in ipairs(starts) do
                local candidates=X.actors(gm,path)
                if #candidates>0 then
                    source='official witch starts '..path:match('%.([^%.]+)$')
                    for _,start in ipairs(candidates) do
                        local key=start:GetAddress(); local point=owned[key]
                        if not X.live(point) then
                            local transform=X.native(start:GetTransform())
                            local g=X.gameplay()
                            point=g:BeginDeferredActorSpawnFromClass(gm,X.asset(POINT),transform,1,nil,2)
                            assert(X.live(point),'witch respawn point spawn failed')
                            local ok,err=pcall(function()
                                point:SetReplicates(true); point.bAlwaysRelevant=true
                                g:FinishSpawningActor(point,transform,2)
                                point:ForceNetUpdate()
                            end)
                            if not ok then pcall(function() point:K2_DestroyActor() end); error(err) end
                            owned[key]=point
                        end
                        points[#points+1]=point
                    end
                    break
                end
            end
        end
        if #points>0 then
            gm.AllWitchRespawnPoints=points
            X.log('Respawn','prepared '..#points..' '..source..'; '..gm:GetFullName())
        end
        return points
    end
    local function hook(asset,fn,cb)
        -- Deliberately independent of C.CreativeMaps, unlike X.hook's editor gate.
        H.hook(X.path(O,asset,fn),X.guard('Respawn/'..fn,cb))
    end
    for _,fn in ipairs({'ReceiveBeginPlay','InitializeOverride','HandleStartMatchOverride','HandleStartSeekOverride'}) do
        hook('B_ObjectiveGameMode',fn,function(self) api.prepare(X.get(self)) end)
    end
    for _,fn in ipairs({'ReceivePossessed','HandleClientProcessed','TimerFinished'}) do
        hook('B_ObjectiveKillSpectator',fn,function(self)
            local spectator=X.get(self); local gm=context(spectator)
            if not gm then return end
            if fn=='TimerFinished' then
                local pc=spectator:GetController()
                local ps=H.valid(pc) and X.read(pc,'PlayerState')
                local gs=X.gameplay():GetGameState(gm)
                -- TimerFinished can stop before RespawnWitch (zero lives / round
                -- end). This event line distinguishes that from a missing hook.
                X.log('RespawnTimer','lives='..tostring(X.read(ps,'Lives'))..' state='..tostring(X.read(gs,'State')))
            end
            api.prepare(gm)
        end)
    end
    hook('B_ObjectiveGameMode','RespawnWitch',function(self,controller)
        local gm=context(X.get(self)); if not gm then return end
        local pc=X.get(controller)
        local pawn=H.valid(pc) and X.read(pc,'Pawn')
        local ps=H.valid(pc) and X.read(pc,'PlayerState')
        local points=usable(gm,X.values(gm.AllWitchRespawnPoints))
        local success=X.live(pawn) and H.class(pawn,'B_ObjectiveWitch_C')
            and X.read(ps,'IsDead')==false
        local chosen,distance
        if success then
            local position=X.location(pawn)
            for _,point in ipairs(points) do
                local d=X.distance2(position,X.location(point))
                if not distance or d<distance then chosen=point; distance=d end
            end
        end
        local reason=success and 'possessed witch' or (#points==0 and 'no live points'
            or 'native rejection or spawn/controller failure; no living witch pawn')
        -- One line per native attempt, using Blueprint properties/pawn state,
        -- never an empty Lua OUT table. CheckPosition/GoodSpotFound/SpawnedWitch
        -- are FUNCTION LOCALS, not reflected GameMode fields. A successful pawn
        -- identifies the nearest source point; failed native selection is opaque.
        X.log('RespawnAttempt','points='..#points..' spawn-nearest='..(chosen and chosen:GetFullName() or '<native selection unavailable>')..
            (distance and ' distance='..math.sqrt(distance) or '')..
            ' lives='..tostring(X.read(ps,'Lives'))..' result='..reason)
        if not success then api.prepare(gm) end -- native failure retries on its own timer
    end)
    function api.poll() end -- no engine calls in steady state
    function api.reset() owned={} end -- never dereference departing actors
    return api
end
return M
