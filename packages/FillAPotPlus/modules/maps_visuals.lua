-- Cooked Objective appearance, shared by edit markers, preview and custom matches.
-- Component overrides are transient: layout saves the carrier class/signature, not these meshes.
local M={BODY='/Game/ObjectiveModeContent/SM_Cauldron01.SM_Cauldron01',
    FLUID='/Game/ObjectiveModeContent/SM_CauldronFluid.SM_CauldronFluid',
    RAYS='/Game/ObjectiveModeContent/SM_PotRuneRays.SM_PotRuneRays',
    SHAFT='/Game/ObjectiveModeContent/Lightshaft.Lightshaft',
    DECAL='/Game/ObjectiveModeContent/M_CauldronDecal.M_CauldronDecal'}
function M.init(X)
    local H,C=X.H,X.C; local api,records={},{}
    local Restore=dofile(assert(debug.getinfo(1,"S").source:match("^@(.+[\\/])")).."maps_material_restore.lua").init(X)
    local current
    local function need(o,label) assert(H.valid(o),'missing '..label); return o end
    local function invalid() return type(CreateInvalidObject)=='function' and CreateInvalidObject() or nil end
    local function vector(v,default)
        return v and {X=v.X,Y=v.Y,Z=v.Z} or {X=default,Y=default,Z=default}
    end
    -- Placed Creative components are Static mobility: SetStaticMesh silently
    -- refuses to swap the mesh at runtime unless the component is Movable.
    local function movable(c) pcall(function() c:SetMobility(2) end) end
    function api.decal(d,info,r)
        need(d,'Objective decal')
        local down=info and info.decalDown or X.DECAL_DOWN
        local up=info and info.decalUp or X.DECAL_UP
        local half,center=(up+down)/2,(up-down)/2
        local size=X.read(d,'DecalSize') or {X=32,Y=256,Z=256}
        local loc=X.read(d,'RelativeLocation') or {X=0,Y=0,Z=0}
        if size.X==half and loc.Z==center then return end
        -- Pitch -90 maps local +X to cauldron -Z: a negative local-axis
        -- offset moves the box upward. Parent-space Z is (up-down)/2.
        d.DecalSize={X=half,Y=size.Y,Z=size.Z}
        -- K2_SetRelativeLocation converts its FHitResult OUT even with sweep
        -- disabled. Update the scalar and force native transform refresh through
        -- boolean-only SetAbsolute, restoring all authored flags synchronously.
        local al,ar,as=X.read(d,'bAbsoluteLocation'),X.read(d,'bAbsoluteRotation'),X.read(d,'bAbsoluteScale')
        assert(type(al)=='boolean' and type(ar)=='boolean' and type(as)=='boolean','decal transform flags unavailable')
        d.RelativeLocation.Z=center
        d:SetAbsolute(not al,ar,as);if r then current(r) end;d:SetAbsolute(al,ar,as);if r then current(r) end
        local mat=X.read(d,'DecalMaterial')
        if H.valid(mat) then
            d:SetDecalMaterial(invalid());if r then current(r) end;d:SetDecalMaterial(mat);if r then current(r) end -- rebuild proxy after changing size
        end
    end
    function api.cauldron(a,info)
        local mesh=need(X.read(a,'Cauldron'),'Objective cauldron mesh component')
        local body=need(X.asset(M.BODY),'official SM_Cauldron01')
        if not X.same(X.read(mesh,'StaticMesh'),body) then
            movable(mesh); mesh:SetStaticMesh(body); mesh:SetMaterial(0,body:GetMaterial(0))
        end
        mesh:SetRelativeScale3D(X.native({X=1.2,Y=1.2,Z=1.2}))
        api.decal(a.Decal,info)
        X.once('pot-look:'..a:GetAddress(),'Appearance','SM_Cauldron01; native body scale 1.2; per-cauldron rune extents')
    end
    local respawns={}
    local function obsolete(r) return X.Lifetime.transition or r.epoch~=X.Lifetime.epoch end
    current=function(r) assert(not obsolete(r),'appearance owner retired during operation') end
    -- Re-applying an already applied look every poll cost ~250 ms/s (18 markers x2).
    -- Successful looks are re-verified at most every 10 s per actor; explicit edits bypass.
    local verified={}
    local editorFailed,editorDesired,respawnFailed={},{},{}
    local function fresh(a)
        local ok,key=pcall(function() return a:GetAddress() end)
        return ok and not FAPP_TEST_NO_THROTTLE and verified[key] and os.clock()-verified[key]<10
    end
    local function mark(a) pcall(function() verified[a:GetAddress()]=os.clock() end) end
    -- Cosmetic presentation may use a replicated Creative GameState on a
    -- guest. Authoritative editing and preview simulation retain their gates.
    local function creativePresentation(a)
        if X.Lifetime.transition or not X.live(a) then return false end
        local gp=X.gameplay();local gm=gp:GetGameMode(a)
        if H.valid(gm) then
            return H.class(gm,'B_CreativeGameMode_C') and X.Lifetime.sameWorld(a,gm)
        end
        local gs=gp:GetGameState(a)
        return X.live(gs) and H.class(gs,'B_CreativeGameState_C') and X.Lifetime.sameWorld(a,gs)
    end
    local function paintRespawn(a)
        if fresh(a) then return true end
        if not C.CreativeMaps or not X.live(a) then return end
        if not creativePresentation(a) then return end
        local info=X.decode(a.SavedMaterialIndices,#X.values(a.MaterialOverwrites))
        if not info or info.kind~=2 then return end
        local body=need(Restore.firstBody(a),'respawn carrier mesh')
        local r=respawns[a:GetAddress()]
        if r and r.cleanup_pending then return false end
        if not r then
            r={actor=a,actorKey=X.Lifetime.key(a),body=body,epoch=X.Lifetime.epoch,scale=vector(X.read(body,'RelativeScale3D'),1),
                location=vector(X.read(body,'RelativeLocation'),0),rotation=(function(v) return v and {Pitch=v.Pitch,Yaw=v.Yaw,Roll=v.Roll} end)(X.read(body,'RelativeRotation'))}
            respawns[a:GetAddress()]=r -- own before capture can allocate/fail
            r.retained=Restore.capture(a,body);current(r)
        end
        -- Exact cooked mesh/material used by BP_WitchPlayerStart's component template.
        local mesh=X.asset('/Game/Characters/Witch/SM_DefaultWitch.SM_DefaultWitch')
        local material=X.asset('/Game/Materials/M_PropPlacePreview.M_PropPlacePreview')
        if not X.same(body.StaticMesh,mesh) then
            movable(body);current(r);body:SetStaticMesh(mesh);current(r)
            local location,rotation=body.RelativeLocation,body.RelativeRotation
            for _,key in ipairs({'X','Y','Z'}) do location[key]=0 end
            for _,key in ipairs({'Pitch','Yaw','Roll'}) do rotation[key]=0 end
            body:SetRelativeScale3D(X.native({X=1,Y=1,Z=1}));current(r)
        end
        -- SM_DefaultWitch has fewer than 6 material slots; a missing slot returns no MID.
        local slots=6; pcall(function() local n=body:GetNumMaterials(); if type(n)=='number' and n>0 then slots=n end end)
        local painted=0
        for slot=0,slots-1 do
            local mid=r[slot]
            if not H.valid(mid) or not X.same(body:GetMaterial(slot),mid) then
                mid=body:CreateDynamicMaterialInstance(slot,material,FName('None'));current(r);r[slot]=mid;r.painted=false
            end
            if H.valid(mid) then
                for _,name in ipairs({'Color','Color2'}) do
                    local ok,c=pcall(function() return mid:K2_GetVectorParameterValue(FName(name)) end)
                    if not r.painted or (ok and c and (c.R~=0 or c.G~=1 or c.B~=0)) then
                        mid:SetVectorParameterValue(FName(name),X.native(X.RESPAWN_GREEN));current(r)
                    end
                end
                painted=painted+1
            end
        end
        r.painted=true
        need(painted>0 and body or nil,'respawn preview MID')
        mark(a)
        X.once('respawn-look','RespawnAppearance',(X.same(body.StaticMesh,mesh) and 'witch start mesh' or 'MESH SWAP REFUSED')..', '..painted..'/'..slots..' material slots green')
        return true
    end
    local function forgetRecord(map,id,r)
        if r.retained then Restore.forget(r.retained) end
        if map[id]==r then map[id]=nil end
    end
    local function releaseRecord(map,id,r,slots)
        if obsolete(r) then forgetRecord(map,id,r);return true end
        r.cleanup_pending=true
        local ok,err=pcall(function()
            local actor
            if r.retained then actor=Restore.checkRelease(r.retained)
            else
                local done,why=Restore.cleanupAbandoned(r.actor,r.body,r.epoch)
                assert(done,why);current(r)
                return -- setup never acquired a complete retained snapshot
            end
            current(r)
            for i,c in pairs(r.components or {}) do
                if H.valid(c) then
                    assert(X.same(c:GetOwner(),actor),'owned appearance component owner changed')
                    current(r);X.destroy(c);current(r)
                end
                r.components[i]=nil
            end
            local body=Restore.restore(r.retained,slots);current(r)
            if body then
                if r.location then for key,value in pairs(r.location) do body.RelativeLocation[key]=value end end
                if r.rotation then for key,value in pairs(r.rotation) do body.RelativeRotation[key]=value end end
                if r.scale then body:SetRelativeScale3D(X.native(r.scale));current(r) end
            end
            Restore.drop(r.retained);current(r)
        end)
        if obsolete(r) then forgetRecord(map,id,r);return true end
        if not ok then r.cleanup_error=tostring(err);return false,err end
        if map[id]==r then map[id]=nil end
        return true
    end
    local function recordFor(map,a)
        for id,r in pairs(map) do if r.actor==a then return id,r end end
        if X.Lifetime.transition or next(map)==nil then return end
        local id=a:GetAddress();return id,map[id]
    end
    function api.releaseRespawn(a)
        local id,r=recordFor(respawns,a);if not r then return true end
        verified[id]=nil
        return releaseRecord(respawns,id,r,6)
    end
    function api.respawn(a)
        if X.Lifetime.transition then return false end
        local id,r=recordFor(respawns,a)
        if r and r.cleanup_pending or id and respawnFailed[id] and respawnFailed[id].actor==a then return false end
        local ok,result=pcall(paintRespawn,a)
        if not ok then
            local key,owned=recordFor(respawns,a)
            if owned and not owned.cleanup_pending then pcall(releaseRecord,respawns,key,owned,6) end
            if owned and not obsolete(owned) then respawnFailed[key]={actor=a} end
            error(result,0)
        end
        return result
    end
    X.respawnLook=api.respawn
    X.releaseRespawnLook=function(a) local done,err=api.releaseRespawn(a);assert(done,err or 'respawn cleanup pending');return done end
    local editingCache
    local function editorModes()
        local modes={}
        for _,pc in ipairs(X.findAll('B_CreativePlayerController_C')) do
            if X.live(pc) and pc:IsLocalController() and pc.CurrentPlayMode~=3 then
                if creativePresentation(pc) then modes[X.Lifetime.worldKey(pc)]=true end
            end
        end
        return modes
    end
    local function editing(a)
        if not C.CreativeMaps then return false end
        return creativePresentation(a) and (editingCache or editorModes())[X.Lifetime.worldKey(a)]==true
    end
    -- Blueprint SCS templates live under the generated class, even when CDO
    -- component fields are null. Read them without spawning/loading an Objective.
    local function template(name)
        local path=X.OM..'B_ObjectiveCauldron.B_ObjectiveCauldron_C'
        local cls=StaticFindObject(path)
        local cdo=H.valid(cls) and cls:GetCDO()
        local c=H.valid(cdo) and X.read(cdo,name)
        if H.valid(c) then return c end
        c=StaticFindObject(path..':'..name..'_GEN_VARIABLE')
        if H.valid(c) then return c end
    end
    local function resident(t,field,path)
        local value=t and X.read(t,field)
        if H.valid(value) then return value end
        return need(StaticFindObject(path),'resident Objective '..path)
    end
    local function component(r,cls,t)
        current(r)
        local c=r.actor:AddComponentByClass(X.asset('/Script/Engine.'..cls),false,X.native(t),false)
        current(r);if c then r.components[#r.components+1]=c end -- own before validation/configuring
        need(c,cls);c:SetMobility(2);current(r) -- movable components follow Creative transform edits
        return c
    end
    local function transform(t,location,scale,pitch)
        local loc=t and X.read(t,'RelativeLocation') or location or {X=0,Y=0,Z=0}
        local size=t and X.read(t,'RelativeScale3D') or scale or {X=1,Y=1,Z=1}
        local rot=t and X.read(t,'RelativeRotation')
        local p=math.rad(rot and rot.Pitch or pitch or 0)/2
        local y=math.rad(rot and rot.Yaw or 0)/2; local r=math.rad(rot and rot.Roll or 0)/2
        -- UE FRotator -> FQuat (Pitch/roll have negative sine).
        local sp,cp,sy,cy,sr,cr=math.sin(p),math.cos(p),math.sin(y),math.cos(y),math.sin(r),math.cos(r)
        return {Translation=vector(loc,0),Scale3D=vector(size,1),Rotation={
            X=cr*sp*sy-sr*cp*cy,Y=-cr*sp*cy-sr*cp*sy,Z=cr*cp*sy-sr*sp*cy,W=cr*cp*cy+sr*sp*sy}}
    end
    local function meshComponent(r,t,mesh,fallback)
        local c=component(r,'StaticMeshComponent',transform(t,fallback.location,fallback.scale))
        c:SetStaticMesh(mesh);current(r);c:SetCollisionEnabled(0);current(r)
        local overrides=t and X.values(X.read(t,'OverrideMaterials')) or {}
        for slot,mat in ipairs(overrides) do if H.valid(mat) then c:SetMaterial(slot-1,mat);current(r) end end
        return c
    end
    local function bodyLook(r)
        current(r);local body=r.body
        if not X.same(X.read(body,'StaticMesh'),r.official) then movable(body); body:SetStaticMesh(r.official);current(r);r.bodyDirty=true end
        local loc=X.read(body,'RelativeLocation'); local rot=X.read(body,'RelativeRotation'); local scale=X.read(body,'RelativeScale3D')
        if not loc or loc.X~=0 or loc.Y~=0 or loc.Z~=0 or not rot or rot.Pitch~=0 or rot.Yaw~=0 or rot.Roll~=0
            or not scale or math.abs(scale.X-1.2)>1e-6 or math.abs(scale.Y-1.2)>1e-6 or math.abs(scale.Z-1.2)>1e-6 then
            body.RelativeLocation={X=0,Y=0,Z=0}; body.RelativeRotation={Pitch=0,Yaw=0,Roll=0}
            body:SetRelativeScale3D(X.native({X=1.2,Y=1.2,Z=1.2}));current(r)
        end
        -- Native material edits/undo can reset the carrier without changing its signature.
        if r.bodyDirty or not X.same(body:GetMaterial(0),r.bodyMID) then
            for i=0,math.max(r.retained.count,1)-1 do body:SetMaterial(i,invalid());current(r) end
            r.bodyMID=body:CreateDynamicMaterialInstance(0,r.bodyMaterial,FName('None'));current(r);need(r.bodyMID,'editor body MID')
            r.bodyDirty=false; r.colourSignature=nil
        end
    end
    local function colourChanged(mid,c)
        local ok,v=pcall(function() return mid:K2_GetVectorParameterValue(FName('Color')) end)
        return ok and v and (math.abs(v.R-c.R)>1e-6 or math.abs(v.G-c.G)>1e-6 or math.abs(v.B-c.B)>1e-6)
    end
    local function paintEditor(a,colour)
        if not X.live(a) or not editing(a) then return end
        local info=X.kind(a); if not info or info.kind~=1 then return end
        local c=colour or info.colour or X.autoColour(X.location(a),1)
        local key=a:GetAddress()
        -- Only unchanged background work may reuse a verified look. Metadata edits,
        -- replacement actors and explicit colour edits must remain immediately visible.
        local desired=a:GetFullName()..string.pack('<fffdd',c.R,c.G,c.B,
            info.decalDown or X.DECAL_DOWN,info.decalUp or X.DECAL_UP)
        local verifiedLook=editorDesired[key]
        if colour==nil and verifiedLook and verifiedLook.desired==desired and X.live(verifiedLook.actor)
            and X.same(verifiedLook.actor,a) and fresh(a) then return true end
        local failed=editorFailed[key]
        if colour==nil and failed and failed.desired==desired and X.live(failed.actor)
            and X.same(failed.actor,a) then return end
        local body=Restore.firstBody(a); if not H.valid(body) then return end
        local r=records[a:GetAddress()]
        if r and (obsolete(r) or not X.live(r.actor)) then forgetRecord(records,key,r);r=nil end
        if r and r.cleanup_pending then return false end
        if r and (not X.same(r.actor,a) or not X.same(r.body,body)) then if not api.release(r.actor) then return false end;r=nil end
        if r then
            for _,c in ipairs(r.components) do if not H.valid(c) then if not api.release(a) then return false end;r=nil;break end end
        end
        if not r then
            -- Resolve ALL assets before touching the decorative carrier. Missing
            -- resident assets leave it intact and are retried on stamps/polls.
            local ts={}; for _,name in ipairs({'Cauldron','Fluid','RuneRays','Lightshaft','SpotLight','Decal'}) do ts[name]=template(name) end
            local official=resident(ts.Cauldron,'StaticMesh',M.BODY)
            local fluid=resident(ts.Fluid,'StaticMesh',M.FLUID)
            local rays=resident(ts.RuneRays,'StaticMesh',M.RAYS)
            local shaft=resident(ts.Lightshaft,'StaticMesh',M.SHAFT)
            local decal=resident(ts.Decal,'DecalMaterial',M.DECAL)
            local fluidMaterial=StaticFindObject('/Game/ObjectiveModeContent/M_CauldronFillFluid.M_CauldronFillFluid')
            if not H.valid(fluidMaterial) then fluidMaterial=need(fluid:GetMaterial(0),'resident Objective fluid material') end
            local overrides=ts.Cauldron and X.values(X.read(ts.Cauldron,'OverrideMaterials')) or {}
            r={actor=a,actorKey=X.Lifetime.key(a),body=body,epoch=X.Lifetime.epoch,scale=vector(X.read(body,'RelativeScale3D'),1),
                location=vector(X.read(body,'RelativeLocation'),0),rotation=(function(v) return v and {Pitch=v.Pitch,Yaw=v.Yaw,Roll=v.Roll} end)(X.read(body,'RelativeRotation')),
                components={},
                official=official,bodyMaterial=H.valid(overrides[1]) and overrides[1] or need(official:GetMaterial(0),'Objective body material'),bodyDirty=true}
            records[key]=r -- own before capture can allocate/fail
            local ok,err=pcall(function()
                r.retained=Restore.capture(a,body);current(r)
                bodyLook(r)
                r.fluid=meshComponent(r,ts.Fluid,fluid,{scale={X=1.2,Y=1.2,Z=1.2}})
                r.mid=r.fluid:CreateDynamicMaterialInstance(0,fluidMaterial,FName('None'));current(r);need(r.mid,'editor fluid MID')
                r.rays=meshComponent(r,ts.RuneRays,rays,{location={X=0,Y=0,Z=5},scale={X=1.28,Y=1.28,Z=2.2}})
                r.shaft=meshComponent(r,ts.Lightshaft,shaft,{location={X=0,Y=0,Z=150},scale={X=1.678532,Y=1.678532,Z=3.478532}})
                r.shaft:SetVisibility(false,false);current(r) -- native Init: the beam lights up only on completion
                local light=component(r,'SpotLightComponent',transform(ts.SpotLight,{X=-.0000096857557,Y=0,Z=-50},
                    {X=.833333313,Y=.833333313,Z=.833333313},90)); r.light=light
                -- Native SpotLight is a child of Fluid; keep that hierarchy/scale.
                light:K2_AttachToComponent(r.fluid,FName('None'),0,0,0,false);current(r)
                local function setting(name,default) return ts.SpotLight and X.read(ts.SpotLight,name) or default end
                light.bUseInverseSquaredFalloff=setting('bUseInverseSquaredFalloff',false)
                light:SetLightFalloffExponent(setting('LightFalloffExponent',4));current(r)
                light:SetAttenuationRadius(setting('AttenuationRadius',600));current(r); light:SetIntensity(setting('Intensity',15));current(r)
                light:SetInnerConeAngle(setting('InnerConeAngle',17.55238151550293));current(r); light:SetOuterConeAngle(setting('OuterConeAngle',48.400001525878906));current(r)
                light:SetCastShadows(setting('CastShadows',false));current(r); light:SetVolumetricScatteringIntensity(setting('VolumetricScatteringIntensity',10));current(r)
                r.decal=component(r,'DecalComponent',transform(ts.Decal,nil,nil,-90))
                if ts.Decal then r.decal.DecalSize=X.read(ts.Decal,'DecalSize') end
                r.decalMID=X.object('/Script/Engine.Default__KismetMaterialLibrary'):CreateDynamicMaterialInstance(a,decal,FName('None'),0);current(r);need(r.decalMID,'editor rune MID')
                r.decal:SetDecalMaterial(r.decalMID);current(r); api.decal(r.decal,info,r)
                r.decalMID:SetScalarParameterValue(FName('Fill'),1);current(r)
                r.rays:SetScalarParameterValueOnMaterials(FName('Fill'),1);current(r)
            end)
            if not ok then pcall(api.release,a);if not obsolete(r) then editorFailed[key]={actor=a,desired=desired} end;error(err,0) end -- immediate rollback, never alternate broken/restore polls
            X.log('EditorAppearance','SM_Cauldron01; native body scale 1.2; Cauldron/Fluid/RuneRays/Lightshaft/SpotLight/Decal; marker '..a:GetAddress())
        end
        bodyLook(r)
        api.decal(r.decal,info,r)
        local signature=string.pack('<fff',c.R,c.G,c.B)
        if not X.same(r.fluid:GetMaterial(0),r.mid) then r.fluid:SetMaterial(0,r.mid);current(r); r.colourSignature=nil end
        if not X.same(X.read(r.decal,'DecalMaterial'),r.decalMID) then r.decal:SetDecalMaterial(r.decalMID);current(r); r.colourSignature=nil end
        if r.colourSignature~=signature or colourChanged(r.mid,c) or colourChanged(r.decalMID,c) or colourChanged(r.bodyMID,c) then
            r.mid:SetVectorParameterValue(FName('Color'),X.native(c));current(r);r.decalMID:SetVectorParameterValue(FName('Color'),X.native(c));current(r)
            for _,mesh in ipairs({r.body,r.rays,r.shaft}) do mesh:SetVectorParameterValueOnMaterials(FName('Color'),X.native({X=c.R,Y=c.G,Z=c.B}));current(r) end
            r.light:SetLightColor(X.native(c),true);current(r); r.colourSignature=signature
        end
        editorDesired[key]={actor=a,desired=desired}; editorFailed[key]=nil
        mark(a); return true
    end
    function api.release(a)
        local id,r=recordFor(records,a);if not r then return true end
        verified[id]=nil;editorDesired[id]=nil
        return releaseRecord(records,id,r,1)
    end
    function api.editor(a,colour)
        if X.Lifetime.transition then return false end
        local id,r=recordFor(records,a)
        if r and r.cleanup_pending then return false end
        local ok,result=pcall(paintEditor,a,colour)
        if not ok then
            local key,owned=recordFor(records,a)
            if owned and not owned.cleanup_pending then pcall(releaseRecord,records,key,owned,1) end
            error(result,0)
        end
        return result
    end
    function api.cleanup()
        local errors={}
        for _,entry in ipairs({{records,1,'cauldron'},{respawns,6,'respawn'}}) do
            for id,r in pairs(entry[1]) do
                local done,why=releaseRecord(entry[1],id,r,entry[2])
                if not done then errors[#errors+1]='appearance '..entry[3]..' '..tostring(r.actorKey or id)..': '..tostring(why) end
            end
        end
        local done,why=Restore.cleanupAbandonedOwned()
        if not done then errors[#errors+1]=why end
        if #errors==0 then editorFailed={};respawnFailed={};return true end
        return false,table.concat(errors,' | ')
    end
    function api.cleanupPending(identity)
        for _,map in ipairs({records,respawns}) do
            for _,r in pairs(map) do if r.cleanup_pending and (identity==nil or r.actorKey==identity) then return true end end
        end
        return false
    end
    function api.poll()
        if X.Lifetime.transition then return end
        editingCache=editorModes()
        for _,a in ipairs(X.findAll('BP_WitchCauldron_C')) do X.guard('EditorAppearance',api.editor)(a) end
        for _,a in ipairs(X.findAll('BP_WitchRuneStone01_C')) do X.guard('RespawnAppearance',api.respawn)(a) end
        for id,r in pairs(respawns) do
            if obsolete(r) or not X.live(r.actor) then forgetRecord(respawns,id,r)
            elseif not r.cleanup_pending and ( not C.CreativeMaps or not X.kind(r.actor)) then X.guard('RespawnAppearance/release',api.releaseRespawn)(r.actor) end
        end
        for id,r in pairs(records) do
            if obsolete(r) or not X.live(r.actor) then forgetRecord(records,id,r)
            elseif not r.cleanup_pending and ( not editing(r.actor) or not X.kind(r.actor)) then X.guard('EditorAppearance/restore',api.release)(r.actor) end
        end
        editingCache=nil
    end
    -- Native edits can replace the mesh/material without changing saved colour.
    -- Wake verified looks only for those committed mutations, never UI selection.
    local function edited()
        verified={}; editorDesired={}; editorFailed={};respawnFailed={}
        if api.invalidate then api.invalidate() end
    end
    for _,fn in ipairs({'UpdateActorTransformServer','UpdateSelectedActorsTransforms','UpdateMaterialServer',
        'SetActorDefaultRotation','SetActorDefaultScale','HandleResetScale'}) do
        X.hook('EditorAppearance',X.CREATIVE,'B_CreativePlayerController',fn,edited)
    end
    X.hook('EditorAppearance','/Game/Blueprints/StaticProps/Placeable/','BP_PlaceableStaticProp','InitMaterialsBySavedIndices',edited)
    X.visualCleanupPending=api.cleanupPending
    X.applyCauldronLook=api.cauldron;X.editorCauldronLook=api.editor
    X.releaseEditorLook=function(a) local done,err=api.release(a);assert(done,err or 'editor cleanup pending');return done end
    X.log('Appearance','module ready; official mesh + transient editor rune; per-cauldron decal extents')
    function api.reset() respawns={}; records={}; editingCache=nil; verified={}; editorDesired={}; editorFailed={};respawnFailed={} end
    X.Lifetime.onReset(api.reset)
    if FAPP_API and FAPP_API.own then FAPP_API.own(api.cleanup,api.reset) end
    if FAPP_API and FAPP_API.command then FAPP_API.command('fappvisualcleanup',api.cleanup) end
    X.cachedPoll(api,nil)
    return api
end
return M
