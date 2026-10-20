-- Read-only Creative diagnostics. Edits dirty the snapshot in O(1); only an
-- explicit check/panel open consumes it. No world scan or per-frame prop work.
local M={}
function M.init(X)
    local H,C=X.H,X.C; local api,worlds={},{}
    function api.invalidate(membership)
        for _,r in pairs(worlds) do r.dirty=true; r.membership=r.membership or membership end
    end
    X.Registry.onChange[#X.Registry.onChange+1]=function() api.invalidate(true) end
    function api.snapshot(ctx,force)
        local world=X.Lifetime.key(ctx:GetWorld()); local r=worlds[world]
        if not r then r={dirty=true,membership=true,props={},classes={}}; worlds[world]=r end
        if force then r.dirty=true; r.membership=true end
        if r.membership then
            r.props={}
            -- Event-fed identities; cheap actor validity, no X.live outer walk
            -- for each prop and no registry.list's repeated liveness traversal.
            for _,a in pairs(X.Registry.buckets.B_StaticMeshProp_C) do
                if H.valid(a) and X.Lifetime.key(a:GetWorld())==world and X.Lifetime.alive(a)
                    and X.read(a,'IsPreview')~=true then r.props[#r.props+1]=a end
            end
            r.membership=false
        end
        if r.dirty then
            r.groups=X.propGroups(r.props,true,r.classes); r.dirty=false
            r.refreshes=(r.refreshes or 0)+1
        end
        return r.groups,r
    end
    local STARTS={
        '/Game/Blueprints/StaticProps/Placeable/Utility/BP_WitchPlayerStart.BP_WitchPlayerStart_C',
        '/Game/Blueprints/Player/PlayerStarts/B_WitchPlayerStart.B_WitchPlayerStart_C',
        '/Game/Blueprints/Player/PlayerStarts/B_PlayerStart.B_PlayerStart_C'}
    function api.evaluate(ctx,force)
        local gm=X.gameplay():GetGameMode(ctx)
        assert(C.CreativeMaps and H.class(gm,'B_CreativeGameMode_C') and H.authority(gm),'fapmaps check requires host Creative')
        local pots,markers,entrances,exits=X.markers(ctx); X.colours(ctx,pots)
        local respawns=markers
        if #respawns==0 then
            for _,path in ipairs(STARTS) do
                local starts=X.actors(ctx,path)
                if #starts>0 then respawns=starts; break end
            end
        end
        local groups=api.snapshot(ctx,force)
        -- Same default avoidance as newly spawned native match cauldrons.
        local avoid={}; local ok,cdo=pcall(X.cauldronDefaults)
        if ok then for _,name in ipairs(X.values(cdo.PropClassesToAvoid)) do avoid[X.text(name)]=true end end
        local usable={}
        for id,g in pairs(groups) do if not avoid[g[1].name] then usable[id]=g end end
        local total=0; for _,g in pairs(groups) do if #g>=2 then total=total+1 end end
        for _,p in ipairs(pots) do p.nativeAvoid,p.exclusionSources=X.excludedNames(p.info) end
        local r=X.requirements(pots,respawns,usable,total)
        local pairs_,problems=X.TeleporterPairs.groups(entrances,exits)
        r.teleporterPairs=#pairs_;r.teleporterProblems=problems
        r.markers=pots; r.respawnMarkers=#markers; r.respawns=#respawns
        local copies,classes=0,0
        for _,g in pairs(groups) do copies=copies+#g; classes=classes+1 end
        r.commonCopies=copies; r.commonClasses=classes
        return r
    end
    function api.check(output)
        local function emit(s)
            X.log('Check',s)
            if output then output:Log(s) end -- borrowed output is used only synchronously
        end
        local gm=X.findAll('B_CreativeGameMode_C')[1]
        local ok,r=pcall(function() assert(gm,'fapmaps check requires host Creative'); return api.evaluate(gm,true) end)
        if not ok then X.log('Check',tostring(r));if output then output:Log('Could not check the map. Open Creative as host and try again.')end; return end
        emit('Map: '..r.commonCopies..' common props, '..r.commonClasses..' prop types; '..r.layoutClasses..
            ' usable prop types / '..r.required..' needed; cauldrons='..#r.pots..
            '; respawn points='..r.respawnMarkers..'; total spawn points='..r.respawns)
        for i,row in ipairs(r.pots) do
            local c=r.markers[i].colour
            emit(string.format('Cauldron %d (%.3f, %.3f, %.3f): wanted props %d/%d %s',i,c.R,c.G,c.B,row.count,r.minimum,row.ok and '✓' or '✗'))
            local candidates={}
            for j=1,math.min(8,#row.candidates) do
                local c=row.candidates[j]
                candidates[#candidates+1]=string.format('%s (%d copies, nearest %.0f cm)',c.name,c.copies,c.distance)
            end
            emit('  Wanted props: '..(#candidates>0 and table.concat(candidates,'; ') or 'none'))
            if not row.ok then emit('  Missing '..(r.minimum-row.count)..' prop types; '..row.near..' prop types have a copy within '..r.distance..
                ' cm; '..row.short..' prop types need a second copy.') end
        end
        emit('Teleporters: '..r.teleporterPairs..' pair(s); '..#r.teleporterProblems..' map problem(s)')
        for _,problem in ipairs(r.teleporterProblems)do emit('Map problem: '..problem)end
        local failures={}
        if #r.pots<3 then failures[#failures+1]='place at least 3 cauldrons (found '..#r.pots..')' end
        if r.respawns==0 then failures[#failures+1]='place a witch respawn point or witch start' end
        if r.layoutClasses<r.required then failures[#failures+1]='map prop types '..r.layoutClasses..'/'..r.required end
        for _,why in ipairs(r.failures) do failures[#failures+1]=why end
        emit(r.ok and 'Ready to play.' or 'Map problems: '..table.concat(failures,'; '))
        if X.Colour then X.Colour.checked(r) end
        return r
    end
    -- Reflected edit events only invalidate. Drag events never traverse a TArray
    -- or read prop transforms; positions are copied on the next panel open.
    for _,fn in ipairs({'UpdateActorTransformServer','UpdateSelectedActorsTransforms','StopModifyingAndDraggingActor'}) do
        X.hook('Check',X.CREATIVE,'B_CreativePlayerController',fn,function() api.invalidate(false) end)
    end
    for _,fn in ipairs({'PlaceActor','SpawnDuplicatedActors','DeleteMultipleServer','DeletePrefab'}) do
        X.hook('Check',X.CREATIVE,'B_CreativePlayerController',fn,function() api.invalidate(true) end)
    end
    X.hook('Check','/Game/Blueprints/Core/','B_GameMode','LoadPropLayoutFromSaveGame',function() api.invalidate(true) end)
    X.hook('Check','/Game/Blueprints/Match/','BFL_MapLayoutLoading','LoadStatics',function() api.invalidate(true) end)
    function api.poll() end
    function api.reset() worlds={} end
    X.Lifetime.onReset(api.reset)
    X.Check=api
    return api
end
return M
