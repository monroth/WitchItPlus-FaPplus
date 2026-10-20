-- Original appearance lives in actor-owned native UPROPERTY references, not Lua pointers.
local M={}
function M.init(X)
    if X.MaterialRestore then return X.MaterialRestore end
    local api={}; local owned,abandoned={},{}; local H,L=X.H,X.Lifetime
    local function invalid() return CreateInvalidObject() end
    -- Scalar ownership is revoked before native world teardown. Re-check it
    -- after each reflected boundary, including same-epoch reset/forget reentry.
    local function current(r)
        assert(not r.closed and not L.transition and r.epoch==L.epoch
            and r.holderPath and owned[r.holderPath]==r,'appearance owner retired during restore')
    end
    local function checked(r,fn,...)
        current(r);local result=table.pack(fn(...));current(r)
        return table.unpack(result,1,result.n)
    end
    -- Only call this on a current native property result or a fresh name lookup.
    -- GetClass is a bound UE4SS method, so reject a null class before IsA/flags.
    local function native(o,r)
        local function read(fn,...)
            if r then return checked(r,fn,...) end
            return fn(...)
        end
        if not o or not read(o.IsValid,o) or read(o.GetAddress,o)==0 then return nil end
        local cls=read(o.GetClass,o)
        if not cls or not read(cls.IsValid,cls) or not read(L.rawValid,o) then return nil end
        return o
    end
    local function original(o)
        if not o or o:GetAddress()==0 then return nil end
        return assert(native(o),'non-null original appearance reference is invalid')
    end
    local function path(o,r)
        local name=r and checked(r,o.GetFullName,o) or o:GetFullName()
        return assert(name:match('^%S+ (.+)$'),'native object path unavailable')
    end
    local function find(p,r)
        if p then
            local value
            if r then value=checked(r,StaticFindObject,p) else value=StaticFindObject(p) end
            return native(value,r)
        end
    end
    local function address(o,r) return o and (r and checked(r,o.GetAddress,o) or o:GetAddress()) or 0 end
    local function same(a,b,r) return address(a,r)==address(b,r) end
    local function describe(o) return {address=address(o),path=o and path(o) or nil} end
    local function unchanged(o,d,r)
        return address(o,r)==d.address and (not o or path(o,r)==d.path)
    end
    local function ownerHolder(r)
        if r.closed or L.transition or r.epoch~=L.epoch or not r.holderPath or owned[r.holderPath]~=r then return end
        local actor=find(r.actorPath,r)
        if not actor or address(actor,r)~=r.actorAddress or not checked(r,X.live,actor) then return end
        local world=native(checked(r,actor.GetWorld,actor),r)
        if address(world,r)~=r.worldAddress then return end
        local holder=find(r.holderPath,r)
        if not holder or address(holder,r)~=r.holderAddress
            or not checked(r,holder.IsA,holder,'/Script/Engine.StaticMeshComponent')
            or not same(native(checked(r,holder.GetOwner,holder),r),actor,r) then return end
        return actor,holder
    end
    local function resolve(r)
        local actor,holder=ownerHolder(r)
        if not actor then return end
        local body=find(r.bodyPath,r)
        if not body or address(body,r)~=r.bodyAddress or not checked(r,body.IsA,body,'/Script/Engine.StaticMeshComponent')
            or not same(native(checked(r,body.GetOwner,body),r),actor,r) then return end
        return actor,holder,body
    end
    function api.capture(actor,body,slot)
        assert(not L.transition and X.live(actor),'appearance capture outside live world')
        assert(same(native(body:GetOwner()),actor),'appearance capture target owner mismatch')
        local bodyPath=path(body)
        local prior=abandoned[bodyPath]
        assert(not prior,'partial holder cleanup pending; explicit owned cleanup required')
        local originalMesh=slot==nil and original(body.StaticMesh) or nil
        local materials={}; local count
        if slot~=nil then count=1; materials[1]=original(body:GetMaterial(slot))
        else
            count=body:GetNumMaterials()
            assert(type(count)=='number' and count>=0 and count%1==0,'material slot count unavailable')
            for i=1,count do materials[i]=original(body:GetMaterial(i-1)) end
        end
        local r={epoch=L.epoch,actorPath=path(actor),actorAddress=address(actor),worldAddress=address(native(actor:GetWorld())),
            bodyPath=bodyPath,bodyAddress=address(body),count=count,slot=slot,
            originalMesh=describe(originalMesh),materials={}}
        for i=1,count do r.materials[i]=describe(materials[i]) end
        local holder
        local function current() assert(not L.transition and r.epoch==L.epoch,'appearance owner retired during capture') end
        local ok,err=pcall(function()
            holder=actor:AddComponentByClass(X.asset('/Script/Engine.StaticMeshComponent'),false,
                X.native({Translation={X=0,Y=0,Z=0},Rotation={X=0,Y=0,Z=0,W=1},Scale3D={X=0,Y=0,Z=0}}),false)
            current()
            -- Own the returned allocation before reflected validation can fail.
            r.partialHolder=holder; if holder then abandoned[bodyPath]=r end
            r.holderAddress=address(holder)
            if r.holderAddress==0 then r.partialHolder=nil;abandoned[bodyPath]=nil end
            holder=assert(native(holder),'native material holder unavailable')
            r.holderPath=path(holder);r.partialHolder=nil;owned[r.holderPath]=r
            holder:SetVisibility(false,false);current();holder:SetHiddenInGame(true,false);current()
            holder:SetCollisionEnabled(0);current();holder:SetGenerateOverlapEvents(false);current();holder:SetMobility(2);current()
            assert(same(native(holder:GetOwner()),actor),'material holder owner mismatch')
            for _,mesh in ipairs(X.values(actor.MeshComponents)) do
                assert(not same(mesh,holder),'material holder entered carrier mesh/save enumeration')
            end
            if slot==nil then holder:SetStaticMesh(originalMesh or invalid());current() end
            for i=1,count do holder:SetMaterial(i-1,materials[i] or invalid());current() end
            assert(slot~=nil or same(native(holder.StaticMesh),originalMesh),'native mesh retention failed')
            for i=1,count do assert(same(native(holder:GetMaterial(i-1)),materials[i]),'native material retention failed') end
        end)
        if not ok then
            if L.transition or r.epoch~=L.epoch then
                r.partialHolder=nil -- the departing native owner owns its component
            elseif holder and r.holderAddress~=0 then
                abandoned[bodyPath]=r -- keep failed cleanup owned and block repeated allocations
                pcall(api.cleanupAbandoned,actor,body,r.epoch) -- rollback failure cannot replace the setup error
            end
            error(err,0)
        end
        abandoned[bodyPath]=nil
        return r
    end
    function api.cleanupAbandoned(actor,body,epoch)
        if L.transition or epoch~=L.epoch then return false,'partial holder belongs to another epoch' end
        local ok,err=pcall(function()
            assert(X.live(actor) and native(body),'partial holder cleanup outside live actor/body')
            local bodyPath=path(body); local r=abandoned[bodyPath]
            if not r then return end
            assert(r.holderPath and r.holderAddress and r.holderAddress~=0,
                'partial holder has no admitted identity; waiting for native owner teardown')
            assert(r.epoch==epoch and X.live(actor),'partial holder cleanup outside original live epoch')
            assert(path(actor)==r.actorPath and address(actor)==r.actorAddress,'partial holder actor identity changed')
            assert(bodyPath==r.bodyPath and address(body)==r.bodyAddress,'partial holder body identity changed')
            assert(same(native(body:GetOwner()),actor),'partial holder body owner changed')
            api.drop(r) -- exact existing holder only; no allocation/capture
        end)
        if not ok then return false,err end
        return true
    end
    function api.cleanupAbandonedOwned()
        local errors={}
        for _,r in pairs(abandoned) do
            if L.transition or r.epoch~=L.epoch then
                abandoned[r.bodyPath]=nil
            elseif not r.holderPath then errors[#errors+1]='partial material holder '..tostring(r.bodyPath)..': holder path unavailable'
            else
                local ok,done,why=pcall(function()
                    local actor,_,body=resolve(r)
                    if not actor or not body then return false,'original actor/body unavailable' end
                    return api.cleanupAbandoned(actor,body,r.epoch)
                end)
                if not ok or not done then errors[#errors+1]='partial material holder '..tostring(r.bodyPath)..': '..tostring(ok and why or done) end
            end
        end
        return #errors==0,table.concat(errors,' | ')
    end
    function api.isHolder(o)
        local p=path(o);return owned[p]~=nil
    end
    function api.forget(r)
        -- A retired native owner owns component destruction; do not touch that world.
        if r.holderPath and owned[r.holderPath]==r then owned[r.holderPath]=nil end
        if abandoned[r.bodyPath]==r then abandoned[r.bodyPath]=nil end
        r.partialHolder=nil;r.closed=true
    end
    function api.checkRelease(r)
        local actor,holder=ownerHolder(r)
        assert(actor,'appearance release outside original live owner/epoch')
        return actor,holder
    end
    function api.restore(r,minimumSlots)
        current(r)
        local actor,holder,body=checked(r,resolve,r)
        if not actor then
            local owner=checked(r,ownerHolder,r)
            if owner then return nil end -- target component was replaced/destroyed; nothing to write
            error('original appearance holder/owner unavailable; stale pointers refused')
        end
        local function freshBody()
            local a,h,b=checked(r,resolve,r)
            assert(a and h and b,'appearance target changed during restore')
            return b
        end
        -- Validate the complete original snapshot before the first carrier write.
        -- Native component enumeration must not silently replace our retained refs.
        local materials={}
        for i=1,r.count do
            local value=checked(r,holder.GetMaterial,holder,i-1)
            materials[i]=native(value,r)
            assert(unchanged(materials[i],r.materials[i],r),'retained original material changed or vanished')
        end
        if r.slot~=nil then
            local material=materials[1]
            checked(r,body.SetMaterial,body,r.slot,material or invalid())
            body=freshBody()
            local value=checked(r,body.GetMaterial,body,r.slot)
            assert(same(native(value,r),material,r),'material restore did not stick')
        else
            local mesh=native(holder.StaticMesh,r)
            assert(unchanged(mesh,r.originalMesh,r),'retained original mesh changed or vanished')
            local clearCount=math.max(r.count,minimumSlots or 0,checked(r,body.GetNumMaterials,body))
            checked(r,body.SetStaticMesh,body,mesh or invalid())
            body=freshBody()
            assert(same(native(body.StaticMesh,r),mesh,r),'mesh restore did not stick')
            for i=1,clearCount do
                local material=materials[i]
                checked(r,body.SetMaterial,body,i-1,material or invalid())
                body=freshBody()
                if i<=r.count then
                    local value=checked(r,body.GetMaterial,body,i-1)
                    assert(same(native(value,r),material,r),'material restore did not stick')
                end
            end
        end
        current(r)
        return body
    end
    function api.matches(r,materialAddress)
        if r.closed or L.transition or r.epoch~=L.epoch or not r.holderPath or owned[r.holderPath]~=r then return false end
        local _,_,body=checked(r,resolve,r)
        if not body then return false end
        local value=checked(r,body.GetMaterial,body,r.slot)
        return address(native(value,r),r)==materialAddress
    end
    function api.firstBody(actor)
        for _,body in ipairs(X.values(actor.MeshComponents)) do
            if not api.isHolder(body) then return body end
        end
    end
    function api.drop(r)
        if r.closed then return end
        local actor,holder=ownerHolder(r)
        if not actor then error('material holder cleanup unavailable; ownership retained') end
        X.destroy(holder)
        if L.transition or r.epoch~=L.epoch then api.forget(r);return end
        current(r)
        r.closed=true;owned[r.holderPath]=nil
        if abandoned[r.bodyPath]==r then abandoned[r.bodyPath]=nil end
    end
    -- World teardown owns the native components. Forget only scalar records here.
    function api.reset() owned={};abandoned={} end
    L.onReset(api.reset)
    if FAPP_API and FAPP_API.own then FAPP_API.own(api.cleanupAbandonedOwned,api.reset) end
    X.MaterialRestore=api
    return api
end
return M
