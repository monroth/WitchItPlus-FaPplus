return function(S)
    local R,C=S.R,S.C
    local pointClass=S.path(S.O,'B_ObjectiveWitchRespawnPoint')
    local starts={'/Game/Blueprints/StaticProps/Placeable/Utility/BP_WitchPlayerStart.BP_WitchPlayerStart_C',
        '/Game/Blueprints/Player/PlayerStarts/B_WitchPlayerStart.B_WitchPlayerStart_C'}
    local attempts={}
    function S.prepareRespawns()
        local s=C.session()
        local points=S.values(s.gm.AllWitchRespawnPoints)
        if #points>0 then return points end
        points=R.find_all(pointClass)
        local options=s.gi.UsedMatchOptions
        if #points==0 and not options.CustomMapSelected and not options.MapData[S.F.builtin] then
            for _,path in ipairs(starts) do
                local candidates=R.find_all(path)
                if #candidates>0 then
                    for _,start in ipairs(candidates) do
                        local p,r=start:K2_GetActorLocation(),start:K2_GetActorRotation()
                        points[#points+1]=R.native.spawn(pointClass,s.gm,{X=p.X,Y=p.Y,Z=p.Z,Yaw=r.Yaw},function(a)
                            a:SetReplicates(true);a.bAlwaysRelevant=true
                        end)
                    end
                    break
                end
            end
        end
        s.gm.AllWitchRespawnPoints=points
        return points
    end
    S.onMatchHost.pre(S.path(S.O,'B_ObjectiveGameMode','SpawnReviveTotem'),function() S.prepareRespawns() end)
    S.onMatchHost.pre(S.path(S.O,'B_ObjectiveGameMode','RespawnWitch'),function(gm)
        local points=S.prepareRespawns()
        local attempt={points=points,poses={}}
        attempts[#attempts+1]=attempt
        local safe={}
        for _,point in ipairs(points) do
            local destination=S.ground(point)
            if destination then
                local p,r,scale=point:K2_GetActorLocation(),point:K2_GetActorRotation(),point:GetActorScale3D()
                attempt.poses[#attempt.poses+1]={actor=point,position={X=p.X,Y=p.Y,Z=p.Z},
                    rotation={Pitch=r.Pitch,Yaw=r.Yaw,Roll=r.Roll},scale={X=scale.X,Y=scale.Y,Z=scale.Z},
                    moved=S.distance(p,destination.witch)>.0001}
                point.RootComponent:SetMobility(2);point:SetActorScale3D({X=1,Y=1,Z=1})
                if attempt.poses[#attempt.poses].moved then
                    point:K2_TeleportTo(destination.witch,{Pitch=0,Yaw=r.Yaw,Roll=0})
                end
                safe[#safe+1]=point
            end
        end
        gm.AllWitchRespawnPoints=safe
    end)
    S.onMatchHost.post(S.path(S.O,'B_ObjectiveGameMode','RespawnWitch'),function(gm)
        local attempt=table.remove(attempts)
        for _,row in ipairs(attempt.poses) do
            row.actor:SetActorScale3D(row.scale)
            if row.moved then row.actor:K2_TeleportTo(row.position,row.rotation) end
        end
        gm.AllWitchRespawnPoints=attempt.points
    end)
    function S.groundTotem(totem)
        local destination=S.ground(totem)
        if not destination then totem:SetActorEnableCollision(false);totem:K2_DestroyActor();return false end
        totem.RootComponent:SetMobility(2);totem:SetActorScale3D({X=1,Y=1,Z=1})
        totem:K2_TeleportTo(destination.marker,{Pitch=0,Yaw=totem:K2_GetActorRotation().Yaw,Roll=0})
        return true
    end
    R.on('world_end',function() attempts={} end)
end
