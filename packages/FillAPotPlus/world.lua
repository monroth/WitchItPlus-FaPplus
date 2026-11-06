return function(S)
    local R,C=S.R,S.C
    local teleporter='/Game/Blueprints/StaticProps/B_TeleporterZone.B_TeleporterZone_C'
    S.asset(teleporter)
    local problem=nil
    local objects={}
    local appearances={}
    local function hideMarker(actor)
        actor:SetReplicates(true);actor.bAlwaysRelevant=true;actor.NetDormancy=1
        actor:SetActorHiddenInGame(true);actor:SetActorEnableCollision(false)
        actor:FlushNetDormancy();actor:ForceNetUpdate()
    end
    function S.propGroups()
        local groups={}
        local system=StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
        for _,actor in ipairs(R.find_all('/Game/Blueprints/Props/Bases/B_StaticMeshProp.B_StaticMeshProp_C')) do
            if actor:GetClass():GetCDO().PropCategory==0 then
                local class=actor:GetClass();local path=S.classpath(class)
                local group=groups[path]
                if not group then
                    group={path=path,class=class,name=S.text(system:GetClassDisplayName(class)),props={}}
                    groups[path]=group
                end
                group.props[#group.props+1]={actor=actor,position=actor:K2_GetActorLocation()}
            end
        end
        return groups
    end
    function S.eligible(row,groups)
        local eligible={}
        local avoid={}
        local defaults=S.asset(S.path(S.O,'B_ObjectiveCauldron')):GetCDO()
        for _,name in ipairs(S.values(defaults.PropClassesToAvoid)) do avoid[S.text(name)]=true end
        for path in pairs(row.info.excluded) do if groups[path] then avoid[groups[path].name]=true end end
        for _,group in pairs(groups) do
            local allowed=#group.props>=2 and not row.info.excluded[group.path] and not avoid[group.name]
            for _,prop in ipairs(group.props) do
                if S.distance(row.position,prop.position)<=row.info.radius^2 then allowed=false end
            end
            if allowed then eligible[#eligible+1]=group end
        end
        table.sort(eligible,function(a,b) return a.path<b.path end)
        return eligible
    end
    function S.checkMap(rows)
        rows=rows or S.markers()
        local failures,warnings,pots,starts,pairsById={},{},{},{},{}
        local groups=S.propGroups()
        for _,row in ipairs(rows) do
            local d=row.info
            if d.kind==1 then pots[#pots+1]=row
            elseif d.kind==2 then
                row.destination=S.ground(row.actor)
                if row.destination then starts[#starts+1]=row
                else warnings[#warnings+1]='A witch respawn point has no safe position.' end
            else
                local id=d.pairId
                if id then
                    local pair=pairsById[id] or {[3]={},[4]={}};pairsById[id]=pair
                    pair[d.kind][#pair[d.kind]+1]=row
                else warnings[#warnings+1]='A teleporter needs a pair number.' end
            end
        end
        if #pots<3 then failures[#failures+1]='Place at least 3 cauldrons.' end
        if #starts==0 then
            local normal=R.find('/Game/Blueprints/StaticProps/Placeable/Utility/BP_WitchPlayerStart.BP_WitchPlayerStart_C')
            if not R.valid(normal) then failures[#failures+1]='Add a witch respawn point.' end
        end
        for i,row in ipairs(pots) do
            row.pool=S.eligible(row,groups)
            if #row.pool<#pots+1 then failures[#failures+1]='Cauldron '..i..' needs '..(#pots+1)..' eligible prop kinds, with two copies of each outside its radius.' end
            for j=i+1,#pots do
                if S.distance(row.position,pots[j].position)<1 then failures[#failures+1]='Two cauldrons overlap.' end
            end
        end
        for id,pair in pairs(pairsById) do
            if #pair[3]~=1 or #pair[4]~=1 then warnings[#warnings+1]='Teleporter '..id..' needs one entrance and one exit.' end
        end
        return failures,warnings,pots,starts,pairsById,groups
    end
    function S.mapExplanation(errors,warnings,pots,starts,teleporters,groups)
        if not errors then errors,warnings,pots,starts,teleporters,groups=S.checkMap() end
        local copies,kinds=0,0
        for _,group in pairs(groups) do copies=copies+#group.props;kinds=kinds+1 end
        -- Problems first: the details below can be longer than the dialog.
        local lines={}
        for _,why in ipairs(errors) do lines[#lines+1]='Map problem: '..why end
        for _,why in ipairs(warnings) do lines[#lines+1]='Map warning: '..why end
        lines[#lines+1]=#errors==0 and 'Ready to play.' or 'Fix the map problems before playing.'
        lines[#lines+1]=''
        lines[#lines+1]='Map: '..copies..' common props, '..kinds..' prop types; cauldrons='..#pots..'; witch respawn points='..#starts
        for i,row in ipairs(pots) do
            local colour=row.info.colour
            local pool=S.eligible(row,groups)
            lines[#lines+1]=string.format('Cauldron %d (%.3f, %.3f, %.3f): wanted props %d/%d %s',i,colour.R,colour.G,colour.B,#pool,#pots+1,#pool>=#pots+1 and '✓' or '✗')
            local names={}
            for j=1,math.min(8,#pool) do
                local group=pool[j];local nearest=math.huge
                for _,prop in ipairs(group.props) do nearest=math.min(nearest,S.distance(row.position,prop.position)^.5) end
                names[#names+1]=string.format('%s (%d copies, nearest %.0f cm)',group.name,#group.props,nearest)
            end
            lines[#lines+1]='  Wanted props: '..(#names>0 and table.concat(names,'; ') or 'none')
            local near,short,excluded=0,0,0
            for path,group in pairs(groups) do
                if #group.props<2 then short=short+1 end
                if row.info.excluded[path] then excluded=excluded+1 end
                for _,prop in ipairs(group.props) do
                    if S.distance(row.position,prop.position)<=row.info.radius^2 then near=near+1;break end
                end
            end
            lines[#lines+1]=string.format('  %d types have a copy within %d cm; %d types need a second copy; %d manually excluded.',near,row.info.radius,short,excluded)
            if #pool<#pots+1 then lines[#lines+1]='  Missing '..(#pots+1-#pool)..' eligible prop types.' end
        end
        local n=0;for _ in pairs(teleporters) do n=n+1 end
        lines[#lines+1]='Teleporters: '..n..' numbered pair(s).'
        return table.concat(lines,'\n')
    end
    function S.potAppearance(pot,info)
        pot.Color=info.colour
        pot.Cauldron:SetMobility(2)
        local mesh=S.asset('/Game/ObjectiveModeContent/SM_Cauldron01.SM_Cauldron01')
        pot.Cauldron:SetStaticMesh(mesh);pot.Cauldron:SetMaterial(0,mesh:GetMaterial(0))
        pot.Cauldron:SetRelativeScale3D({X=1.2,Y=1.2,Z=1.2})
        pot:Init()
        local decal=pot.Decal
        local size=decal.DecalSize;size.X=(info.down+info.up)/2;decal.DecalSize=size
        decal.RelativeLocation.Z=(info.up-info.down)/2
        local al,ar,asc=decal.bAbsoluteLocation,decal.bAbsoluteRotation,decal.bAbsoluteScale
        decal:SetAbsolute(not al,ar,asc);decal:SetAbsolute(al,ar,asc)
    end
    function S.target()
        local session=C.session()
        if session.is_creative then return end
        local count=session.gs.Cauldrons:GetArrayNum()
        if count==0 then return end
        local base,revision=3,-1
        for _,row in ipairs(S.markers()) do
            local d=row.info
            if d.kind==1 and (d.revision>revision or (d.revision==revision and d.target>base)) then base,revision=d.target,d.revision end
        end
        local mm=S.manager()
        local offset=S.rules().targetOffset
        S.ceiling=math.max(1,math.min(count,255,base+offset))
        local target=S.ceiling
        if mm.CurrentRound==2 then
            local first=mm.RoundStates[1]
            target=math.min(first.TotalCauldronsFilled+1,target)
        end
        S.write(session.gs,'CauldronTarget',target,46)
        S.log('Target round=%d cauldrons=%d layout=%d offset=%d ceiling=%d target=%d',
            mm.CurrentRound,count,base,offset,S.ceiling,target)
        S.refreshHUD()
    end
    local function convertPot(row)
        local s=C.session();local g=StaticFindObject('/Script/Engine.Default__GameplayStatics')
        local t=row.actor:GetTransform()
        local pot=g:BeginDeferredActorSpawnFromClass(s.gm,S.asset(S.path(S.O,'B_ObjectiveCauldron')),t,1,nil,2)
        pot:SetReplicates(true);pot.bAlwaysRelevant=true;pot.NetDormancy=1;pot:SetOwner(row.actor)
        pot.Color=row.info.colour;pot.MinPropDistance=row.info.radius
        local names={}
        for _,name in ipairs(S.values(pot.PropClassesToAvoid)) do names[#names+1]=S.text(name) end
        local groups=S.propGroups()
        for path in pairs(row.info.excluded) do if groups[path] then names[#names+1]=groups[path].name end end
        pot.PropClassesToAvoid=names
        g:FinishSpawningActor(pot,t,2)
        pot.GameState=s.gs;pot.Gamemode=s.gm
        pot.MinPropSphere:SetSphereRadius(row.info.radius,false)
        S.potAppearance(pot,row.info)
        hideMarker(row.actor)
        pot:FlushNetDormancy();pot:ForceNetUpdate()
        return pot
    end
    function S.portals(pairsById)
        local s=C.session()
        local zones={}
        local function zone(entry,exit)
            local dest=exit.position
            local z=R.native.spawn(teleporter,s.gm,entry.position,function(a)
                a:SetReplicates(true);a:SetReplicateMovement(true);a.bAlwaysRelevant=true;a:SetActorEnableCollision(false)
            end)
            local target=z.TargetLocation
            target.RelativeLocation={X=dest.X,Y=dest.Y,Z=dest.Z+92}
            target.RelativeRotation={Pitch=0,Yaw=exit.actor:K2_GetActorRotation().Yaw,Roll=0}
            target:SetAbsolute(true,true,false);target:SetIsReplicated(true)
            z.Zone:SetBoxExtent({X=100,Y=100,Z=125},false)
            R.native.teleporter_exit(z,exit.actor)
            z:SetActorEnableCollision(true);z.Zone:SetGenerateOverlapEvents(true);z:ForceNetUpdate()
            zones[#zones+1]=z
            return z
        end
        for _,pair in pairs(pairsById) do
            for _,kind in ipairs({3,4}) do for _,row in ipairs(pair[kind]) do S.markerLook(row.actor,row.info) end end
            if #pair[3]==1 and #pair[4]==1 then
                local a,b=pair[3][1],pair[4][1]
                local entrance=zone(a,b)
                if a.info.twoWay or b.info.twoWay then R.native.teleporter_pair(entrance,zone(b,a)) end
            end
        end
        return zones
    end
    -- Loading a saved layout destroys the hunter starts the carriage carries (child actors
    -- of B_Carriage_C on Castle) and spawns free copies on the road, so hunters stayed
    -- behind (user 11-04, PROBE19). The carriage's components survive: rebuild their starts
    -- and drop the free copies.
    local carriagePath='/Game/Features/Experimental/CastleDoorSequence/B_Carriage.B_Carriage_C'
    local function restoreCarriageStarts()
        local carriages=R.find_all(carriagePath)
        if #carriages==0 then return end
        local childClass=StaticFindObject('/Script/Engine.ChildActorComponent')
        local rebuilt=0
        for _,carriage in ipairs(carriages) do
            for _,wrapped in ipairs(carriage:K2_GetComponentsByClass(childClass)) do
                local component=wrapped:get()
                if R.valid(component) and not R.valid(component.ChildActor) and R.valid(component.ChildActorClass) then
                    component:SetChildActorClass(component.ChildActorClass);rebuilt=rebuilt+1
                end
            end
        end
        if rebuilt==0 then return end
        local removed=0
        -- Witch It's starts are placeable props, not engine PlayerStarts.
        for _,start in ipairs(R.find_all('/Game/Blueprints/StaticProps/Placeable/Utility/BP_HunterPlayerStart.BP_HunterPlayerStart_C')) do
            if not R.valid(start:GetAttachParentActor()) then start:K2_DestroyActor();removed=removed+1 end
        end
        S.log('Carriage starts: rebuilt %d, removed %d free copies',rebuilt,removed)
    end
    local function convertLayout()
        restoreCarriageStarts()
        for _,actor in ipairs(objects) do if R.valid(actor) then actor:K2_DestroyActor() end end
        objects={}
        local rows=S.markers()
        if #rows==0 then problem=nil;return end
        local failures,warnings,pots,starts,pairsById,groups=S.checkMap(rows)
        problem=failures[1]
        if problem then S.U.message('Map problems',S.mapExplanation(failures,warnings,pots,starts,pairsById,groups));return end
        local looks={}
        for _,row in ipairs(pots) do
            objects[#objects+1]=convertPot(row)
            local p=row.position
            looks[#looks+1]={position={X=p.X,Y=p.Y,Z=p.Z},info=row.info}
        end
        C.net.publish('fap.cauldrons',looks)
        local s=C.session();local points={}
        for _,row in ipairs(starts) do
            local destination=row.destination
            local g=StaticFindObject('/Script/Engine.Default__GameplayStatics')
            local t=S.transform(row.actor,destination.witch)
            local point=g:BeginDeferredActorSpawnFromClass(s.gm,S.asset(S.path(S.O,'B_ObjectiveWitchRespawnPoint')),t,1,nil,2)
            point:SetReplicates(true);point:SetOwner(row.actor);g:FinishSpawningActor(point,t,2)
            objects[#objects+1]=point;points[#points+1]=point;hideMarker(row.actor)
        end
        if #points>0 then s.gm.AllWitchRespawnPoints=points end
        s.gs.Proplist:Empty();s.gs.ValidProps:Empty();s.gs:LoadPropsAndCauldrons()
        for _,zone in ipairs(S.portals(pairsById)) do objects[#objects+1]=zone end
        S.target()
    end
    S.onMatchHost.post(S.path(S.CORE,'B_GameMode','LoadPropLayoutFromSaveGame'),function(gm,...)
        local gi=C.session().gi
        S.trace('layout load world=%s used %s',gm:GetWorld():GetFName():ToString(),S.options(gi.UsedMatchOptions))
        convertLayout(gm,...)
    end)
    S.onModeHost.on('layout_loaded',function(info)
        if info.is_creative and info.is_playtest then S.startPreview() end
    end)
    S.onMatchHost.post(S.path(S.CORE,'B_GameMode','HandleShouldGameStart'),function(gm,out)
        if problem then out:set(false) end
    end)
    S.onMatchHost.on('round_start',S.target)
    -- A guest joining a running round restarts it natively, which puts the native target
    -- back without a round_start (user 11-04: 3 instead of 7).
    -- Only then: every other restart reaches round_start, and a join after the match has
    -- ended starts a new match, whose RoundStates can be empty.
    S.onMatchHost.post(S.path(S.O,'B_ObjectiveGameMode','StartNewGameOverride'),function(_,byJoin)
        if byJoin and not S.manager().IsMatchOver then S.target() end
    end)
    S.onModeHost.post(S.path(S.O,'B_ReviveTotem','RevieWitch'),function(pot,found)
        if not found:get() then return end
        local destination=S.ground(pot)
        found:set(destination~=nil)
        if destination then pot:K2_TeleportTo(destination.witch,pot:K2_GetActorRotation()) end
    end)
    local function clientPot(pot)
        local p=pot:K2_GetActorLocation()
        for _,row in ipairs(appearances) do
            if S.distance(p,row.position)<1 then
                S.potAppearance(pot,row.info)
                return
            end
        end
    end
    C.net.watch('fap.cauldrons',function(rows)
        if S.host() then return end
        appearances=rows
        for _,pot in ipairs(R.find_all(S.path(S.O,'B_ObjectiveCauldron'))) do clientPot(pot) end
    end)
    S.onMatch.post('/Script/Engine.Actor:OnRep_Owner',function(actor)
        if not S.host() and actor:IsA(S.path(S.O,'B_ObjectiveCauldron')) then clientPot(actor) end
    end)
    S.onMode.post('/Game/Blueprints/StaticProps/Placeable/BP_PlaceableStaticProp.BP_PlaceableStaticProp_C:InitMaterialsBySavedIndices',function(actor)
        local info=S.marker(actor)
        if not info then return end
        if C.session().is_creative and not C.session().gs.IsPlayTestMode then S.markerLook(actor,info)
        elseif info.kind>=3 then S.markerLook(actor,info) end
    end)
    R.on('world_end',function() appearances={}; problem=nil;objects={};S.ceiling=nil end)
end
