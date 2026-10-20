-- Creative maps: shared contracts and versioned, native-save-compatible metadata.
local M={}
M.OM='/Game/Blueprints/Gamemodes/ObjectiveMode/'
M.CREATIVE='/Game/Blueprints/Gamemodes/CreativeMode/'
M.CARRIERS={
    '/Game/Blueprints/StaticProps/Placeable/StaticProps/BP_WitchCauldron.BP_WitchCauldron_C',
    '/Game/Blueprints/StaticProps/Placeable/StaticProps/BP_WitchRuneStone01.BP_WitchRuneStone01_C',
}
-- Rune carrier stores endpoint identity; local presentation replaces its mesh.
M.CARRIERS[3]=M.CARRIERS[2]; M.CARRIERS[4]=M.CARRIERS[2]
M.NAMES={'Fill a Pot cauldron','Witch respawn point','Teleporter entrance','Teleporter exit'}
M.RESPAWN_TAG={70,65,80,82,1,2} -- FAPR, version 1, respawn kind 2
M.RESPAWN_GREEN={R=0,G=1,B=0,A=1}
-- Cooked Decal_GEN_VARIABLE: DecalSize=(32,256,256), Pitch=-90,
-- RelativeLocation omitted (zero), scale omitted (one). Local +X points down.
M.DECAL_DOWN=32; M.DECAL_UP=32; M.DECAL_MAX=2000
M.LAYOUT={name='LayoutName_8_C5C516E347406BABDAF0F59A6150BC5A',
    file='FileName_6_F3CC8069497D007AD2E96A9AE00D2700',map='MapName_10_67B8E5E54A16D786C60266AF5B396E36'}
M.MESH_LIST='MeshList_3_9A021886472783B7C6D4C1A40C1D892E'
M.MAX_EXCLUSIONS=64; M.MAX_TYPE_PAYLOAD=33000
M.MIN_DISTANCE=2500 -- native CDO; CreativeMapMinPropDistance overrides preview + real adapter.
function M.path(folder,asset,fn) return folder..asset..'.'..asset..'_C:'..fn end
M.read=FAPP_SERVICES.runtime.read
M.get=FAPP_SERVICES.runtime.unwrap
M.values=FAPP_SERVICES.runtime.values
function M.text(v)
    if type(v)=='string' then return v end
    local f=M.read(v,'ToString'); if type(f)=='function' then return v:ToString() end
    return tostring(v)
end
function M.field(s,k) return M.read(s,k) or M.read(s,M.LAYOUT[k] or '') end
local function finite(v) return type(v)=='number' and v==v and v~=math.huge and v~=-math.huge end
function M.colour(c)
    if not c then return nil end
    local t={R=c.R,G=c.G,B=c.B,A=1}
    for _,k in ipairs({'R','G','B'}) do if not finite(t[k]) or t[k]<0 or t[k]>1 then return nil end end
    return t
end
function M.lightColour(v)
    assert(v and finite(v.X) and finite(v.Y) and finite(v.Z),'invalid light Colour')
    local max=math.max(v.X,v.Y,v.Z,0)
    if max==0 then return {R=0,G=0,B=0,A=1} end
    return {R=math.max(0,v.X)/max,G=math.max(0,v.Y)/max,B=math.max(0,v.Z)/max,A=1}
end
-- Trailer is read only at the END; arbitrary native materials cannot match it.
-- A pot v2 holds float32 RGBA and source: 0 auto, 1 direct marker, 2 legacy light.
-- v3 appends uint32 map target + uint64 edit revision after the v2 RGBA.
-- v4 appends uint16 decalDown + uint16 decalUp (UU, 0..2000) to v3.
-- Revisions are monotonic Unix milliseconds (within Lua's exact integer range).
-- v5: v4 fixed fields + sorted class paths (uint16 count/lengths), then
-- uint32 total trailer length and FAP5. Bounded footer permits native material prefixes.
function M.exclusionPaths(excluded)
    local paths={}
    for path,on in pairs(excluded or {}) do
        assert(type(path)=='string' and #path<=512 and path:match('^/Game/[%w_/.%-]+%.[%w_]+_C$'),'invalid excluded class path')
        assert(on==true,'invalid excluded class flag')
        paths[#paths+1]=path
    end
    assert(#paths<=M.MAX_EXCLUSIONS,'too many excluded prop types')
    table.sort(paths); return paths
end
function M.classPath(cls)
    -- GetFullName is bound by UE4SS; GetPathName is not. Parse the actual
    -- native class identity instead of probing an unsupported member.
    local fullname=M.text(cls:GetFullName())
    local path=fullname:match('^%S+ (/Game/[^ ]+)$')
    assert(path and path:match('^/Game/'),'prop class path unavailable: '..fullname)
    return path
end
function M.decode(indices,prefix)
    local a=M.values(indices); local n=#a
    if n>=8 and a[n-3]==70 and a[n-2]==65 and a[n-1]==80 and (a[n]==53 or a[n]==54 or a[n]==55) then
        local ok,result=pcall(function()
            local footer={}; for i=n-7,n-4 do footer[#footer+1]=string.char(a[i]) end
            local length=string.unpack('<I4',table.concat(footer))
            assert(length>=49 and length<=M.MAX_TYPE_PAYLOAD and length<=n,'invalid v5 length')
            local start=n-length+1; assert(prefix==nil or start==prefix+1,'invalid v5 prefix')
            local version=a[n]-48
            assert(a[start]==70 and a[start+1]==65 and a[start+2]==80 and a[start+3]==77 and a[start+4]==version and a[start+5]==1,'invalid v5 signature')
            local fixed={}; for i=start,start+38 do fixed[#fixed+1]=a[i] end; fixed[5]=4
            local info=M.decode(fixed,0); assert(info,'invalid v5 fields')
            local bytes={}; for i=start+39,n-8 do bytes[#bytes+1]=string.char(a[i]) end
            local data=table.concat(bytes); local count,at=string.unpack('<I2',data)
            assert(count<=M.MAX_EXCLUSIONS,'too many excluded types'); local excluded={}
            for _=1,count do
                local size; size,at=string.unpack('<I2',data,at)
                assert(size>0 and size<=512 and at+size-1<=#data,'invalid class size')
                local path=data:sub(at,at+size-1); at=at+size
                assert(not excluded[path],'duplicate excluded class'); excluded[path]=true
            end
            if version==6 then
                local remaining=#data-at+1
                assert(remaining==12 or remaining==16,'invalid size extension length')
                -- Retired v6 extension: consume it without exposing/preserving it.
                at=#data+1
            end
            if version==7 then
                assert(#data-at+1==12,'invalid seek coefficient extension')
                info.seekCoefficient,info.seekRevision,at=string.unpack('<fI8',data,at)
                assert(finite(info.seekCoefficient) and math.abs(info.seekCoefficient)<=600 and info.seekRevision<=9007199254740991,'invalid seek coefficient')
            end
            assert(at==#data+1,'trailing metadata bytes'); M.exclusionPaths(excluded)
            info.version=version; info.prefix=start-1; info.excluded=excluded; return info
        end)
        return ok and result or nil
    end
    -- FAPT v2 appends one look byte to v1's exact kind/source/float32 colour.
    -- Legacy endpoints have look None and upgrade on their next native save.
    for _,spec in ipairs({{24,2},{23,1}}) do
        local at=n-spec[1]+1
        if at>0 and (prefix==nil or at==prefix+1) and a[at]==70 and a[at+1]==65 and a[at+2]==80
            and a[at+3]==84 and a[at+4]==spec[2] and (a[at+5]==3 or a[at+5]==4) and (a[at+6]==0 or a[at+6]==1) then
            local ok,info=pcall(function()
                local bytes={}; for i=at+7,at+22 do bytes[#bytes+1]=string.char(a[i]) end
                local r,g,b,alpha=string.unpack('<ffff',table.concat(bytes))
                local c=assert(M.colour({R=r,G=g,B=b})); assert(alpha==1)
                local look=spec[2]==2 and a[at+23] or 0
                assert(type(look)=='number' and look%1==0 and look>=0 and look<=4,'invalid teleporter look')
                return {kind=a[at+5],version=spec[2],prefix=at-1,colour=c,look=look,authored=a[at+6]==1,source=a[at+6]==1 and 'marker' or 'auto',tag='FAPT'}
            end)
            return ok and info or nil
        end
    end
    local start=n-5
    if start>0 and (prefix==nil or start==prefix+1) then
        local match=true
        for i,v in ipairs(M.RESPAWN_TAG) do if a[start+i-1]~=v then match=false; break end end
        if match then return {kind=2,version=1,prefix=start-1,authored=false,source='auto',tag='FAPR'} end
    end
    for _,spec in ipairs({{39,4},{35,3},{23,2},{6,1}}) do
        local start=n-spec[1]+1
        if start>0 and (prefix==nil or start==prefix+1) and a[start]==70 and a[start+1]==65
            and a[start+2]==80 and a[start+3]==77 and a[start+4]==spec[2] then
            local kind=a[start+5]
            if spec[2]==1 and (kind==1 or kind==2) then return {kind=kind,version=1,prefix=start-1,authored=false,source='auto',decalDown=M.DECAL_DOWN,decalUp=M.DECAL_UP} end
            if spec[2]>=2 and kind==1 and (a[start+6]==0 or a[start+6]==1 or a[start+6]==2) then
                local bytes={}
                for i=start+7,n do
                    if not finite(a[i]) or a[i]<0 or a[i]>255 or a[i]%1~=0 then return nil end
                    bytes[#bytes+1]=string.char(a[i])
                end
                local payload=table.concat(bytes)
                local r,g,b,alpha=string.unpack('<ffff',payload)
                local c=M.colour({R=r,G=g,B=b})
                local target,revision
                if spec[2]>=3 then
                    target,revision=string.unpack('<I4I8',payload,17)
                    if target<1 or revision<0 or revision>9007199254740991 then return nil end
                end
                local down,up=M.DECAL_DOWN,M.DECAL_UP
                if spec[2]==4 then
                    down,up=string.unpack('<I2I2',payload,29)
                    if down>M.DECAL_MAX or up>M.DECAL_MAX then return nil end
                end
                if c and alpha==1 then return {kind=1,version=spec[2],prefix=start-1,authored=a[start+6]~=0,
                    source=({[0]='auto',[1]='marker',[2]='light'})[a[start+6]],colour=c,target=target,revision=revision,decalDown=down,decalUp=up} end
            end
        end
    end
end
function M.encode(indices,prefix,kind,colour,authored,source,target,revision,decalDown,decalUp,excluded,seekCoefficient,seekRevision,look)
    assert(kind==1 or kind==2 or kind==3 or kind==4,'invalid marker kind')
    local a=M.values(indices); local t={}
    for i=1,prefix do t[i]=a[i] or 0 end
    if kind>=3 then
        local c=assert(M.colour(colour),'invalid teleporter colour')
        look=look or 0; assert(type(look)=='number' and look%1==0 and look>=0 and look<=4,'invalid teleporter look')
        for _,v in ipairs({70,65,80,84,2,kind,authored and 1 or 0})do t[#t+1]=v end
        local bytes=string.pack('<ffffB',c.R,c.G,c.B,1,look); for i=1,#bytes do t[#t+1]=bytes:byte(i)end
        return t
    end
    if kind==2 then for _,v in ipairs(M.RESPAWN_TAG) do t[#t+1]=v end; return t end
    local v4=kind==1 and (target~=nil or decalDown~=nil or decalUp~=nil or seekCoefficient~=nil)
    if v4 then target=target or 3 end
    if decalDown==nil then decalDown=M.DECAL_DOWN end
    if decalUp==nil then decalUp=M.DECAL_UP end
    for _,v in ipairs({decalDown,decalUp}) do
        assert(finite(v) and v>=0 and v<=M.DECAL_MAX and v%1==0,'invalid decal extent')
    end
    if v4 then
        assert(finite(target) and target>=1 and target<=4294967295 and target%1==0,'invalid map target')
        revision=revision or 0
        assert(finite(revision) and revision>=0 and revision<=9007199254740991 and revision%1==0,'invalid map target revision')
    end
    for _,v in ipairs({70,65,80,77,v4 and 4 or (kind==1 and colour and 2 or 1),kind}) do t[#t+1]=v end
    if kind==1 and (colour or v4) then
        local c=assert(M.colour(colour or {R=1,G=1,B=1}),'invalid marker colour'); t[#t+1]=authored and (source=='light' and 2 or 1) or 0
        local bytes=string.pack('<ffff',c.R,c.G,c.B,1)
        if v4 then bytes=bytes..string.pack('<I4I8I2I2',target,revision,decalDown,decalUp) end
        for i=1,#bytes do t[#t+1]=bytes:byte(i) end
    end
    if kind==1 and (excluded and next(excluded) or seekCoefficient~=nil) then
        assert(v4,'v5 requires fixed marker fields')
        t[prefix+5]=seekCoefficient~=nil and 7 or 5
        local paths=M.exclusionPaths(excluded or {}); local bytes=string.pack('<I2',#paths)
        for _,path in ipairs(paths) do bytes=bytes..string.pack('<I2',#path)..path end
        for i=1,#bytes do t[#t+1]=bytes:byte(i) end
        if seekCoefficient~=nil then
            assert(finite(seekCoefficient)and math.abs(seekCoefficient)<=600,'invalid seek coefficient')
            seekRevision=seekRevision or 0
            assert(finite(seekRevision)and seekRevision%1==0 and seekRevision>=0 and seekRevision<=9007199254740991,'invalid seek revision')
            local bytes=string.pack('<fI8',seekCoefficient,seekRevision);for i=1,#bytes do t[#t+1]=bytes:byte(i)end
        end
        local footer=string.pack('<I4',#t-prefix+8)..(seekCoefficient~=nil and 'FAP7'or 'FAP5')
        for i=1,#footer do t[#t+1]=footer:byte(i) end
        assert(#t-prefix<=M.MAX_TYPE_PAYLOAD,'v5 payload too large')
    end
    return t
end
function M.markerSeekCoefficient(markers)
    local value,revision=0,-1
    for _,p in ipairs(markers or {})do local info=p.info or p
        if info.seekCoefficient~=nil then
            local r=info.seekRevision or 0
            if r>revision or r==revision and info.seekCoefficient>value then value,revision=info.seekCoefficient,r end
        end
    end
    return value,revision
end
-- Greatest edit revision wins; ties (including legacy revisions) use max target.
function M.target(pots)
    local value,revision,conflict=nil,-1,false
    local first
    for _,p in ipairs(pots) do
        local info=p.info or p
        if info.target then
            if first and first~=info.target then conflict=true end
            first=first or info.target
            local r=info.revision or 0
            if r>revision then value,revision=info.target,r
            elseif r==revision then value=math.max(value,info.target) end
        end
    end
    if revision<=0 then value=nil end -- unedited defaults grow to 3 as markers are added
    return math.max(1,math.min(#pots>0 and #pots or 3,value or 3)),math.max(0,revision),conflict
end
function M.distance2(a,b) return (a.X-b.X)^2+(a.Y-b.Y)^2+(a.Z-b.Z)^2 end
local function hsv(h)
    local sector=(h%360)/60; local x=.95*.8*(1-math.abs(sector%2-1)); local c,m=.95*.8,.95*.2
    local rgb=({{c,x,0},{x,c,0},{0,c,x},{0,x,c},{x,0,c},{c,0,x}})[math.floor(sector)+1]
    return {R=rgb[1]+m,G=rgb[2]+m,B=rgb[3]+m,A=1}
end
function M.positionKey(p)
    local function q(n) return math.floor(n+.5) end
    return q(p.X)..','..q(p.Y)..','..q(p.Z)
end
function M.autoColour(p,rank)
    local hash=2166136261
    for c in M.positionKey(p):gmatch('.') do hash=((hash ~ c:byte())*16777619)&0xffffffff end
    return hsv(hash%360+(rank or 0)*137.507764)
end
-- Sort numerically, with stable native identity as the same-position tie breaker.
function M.sort(records)
    table.sort(records,function(a,b)
        for _,k in ipairs({'X','Y','Z'}) do if a.position[k]~=b.position[k] then return a.position[k]<b.position[k] end end
        return tostring(a.id)<tostring(b.id)
    end)
    return records
end
function M.requiredClasses(pots) return #pots+1 end
-- One numeric rule for native match pools and Creative snapshots. No UObject calls.
function M.requirements(pots,respawns,groups,minDistance,layoutClasses)
    minDistance=minDistance or M.MIN_DISTANCE
    local r={pots={},failures={},classes=0,copies=0,required=M.requiredClasses(pots),minimum=M.requiredClasses(pots),distance=minDistance}
    for _,g in pairs(groups) do
        r.copies=r.copies+#g
        if #g>=2 then r.classes=r.classes+1 end
    end
    r.layoutClasses=layoutClasses or r.classes
    for i,pot in ipairs(pots) do
        local row={index=i,id=pot.id,fullname=pot.fullname,count=0,candidates={},types={},short=0,near=0,excluded=0}
        local excluded=(pot.info or pot).excluded or {}; local byName={}
        for name,paths in pairs(pot.exclusionSources or {}) do byName[name]=paths end
        -- Native avoidance compares display names. Mirror name collisions so the
        -- visible count cannot promise more classes than GenerateWantedProp accepts.
        for id,g in pairs(groups) do
            local path=g[1].path or tostring(id)
            if excluded[path] then
                local name=g[1].name or tostring(id); byName[name]=byName[name] or {}; byName[name][#byName[name]+1]=path
            end
        end
        for id,g in pairs(groups) do
            local nearest=math.huge
            for _,prop in ipairs(g) do nearest=math.min(nearest,M.distance2(pot.position,prop.position)) end
            local path=g[1].path or tostring(id)
            local name=g[1].name or tostring(id)
            local entry={id=id,path=path,name=name,copies=#g,distance=math.sqrt(nearest),excluded=excluded[path]==true or byName[name]~=nil,exclusionPaths=byName[name]}
            entry.nativeExcluded=(pot.nativeAvoid or {})[entry.name]==true
            entry.eligible=#g>=2 and nearest>minDistance^2
            row.types[#row.types+1]=entry
            if entry.excluded or entry.nativeExcluded then row.excluded=row.excluded+1
            elseif #g<2 then row.short=row.short+1
            elseif nearest<=minDistance^2 then row.near=row.near+1
            else
                row.count=row.count+1
                row.candidates[#row.candidates+1]=entry
            end
        end
        local seen={}; for _,entry in ipairs(row.types) do seen[entry.path]=true end
        for path in pairs((pot.info or pot).excluded or {}) do if not seen[path] then
            row.types[#row.types+1]={path=path,name=path:match('%.(.+)$'),copies=0,distance=math.huge,excluded=true,eligible=false}
        end end
        table.sort(row.types,function(a,b) return a.path<b.path end)
        table.sort(row.candidates,function(a,b)
            if a.distance~=b.distance then return a.distance>b.distance end
            return a.name<b.name
        end)
        row.ok=row.count>=r.minimum
        r.pots[i]=row
        if not row.ok then r.failures[#r.failures+1]='cauldron '..i..' has '..row.count..' usable prop classes; needs '..r.minimum..
            ' with 2 copies each, all copies >'..minDistance..' UU from this cauldron' end
    end
    local reason
    if #pots==0 then reason='no Fill a Pot cauldron markers'
    elseif #pots<3 then reason='at least 3 cauldron markers are required (found '..#pots..')'
    elseif #respawns==0 then reason='no Witch respawn markers or normal witch player starts'
    elseif r.layoutClasses<r.required then reason='layout has '..r.layoutClasses..' distinct playable classes with >=2 copies; needs '..r.required
    elseif #r.failures>0 then reason=r.failures[1] end
    r.ok=reason==nil; r.reason=reason
    return r
end
function M.validation(pots,respawns,groups,minDistance,layoutClasses)
    local r=M.requirements(pots,respawns,groups,minDistance,layoutClasses)
    return r.ok,r.reason,r
end
function M.init(C,H)
    local E=FAPP_SERVICES.events
    local X={C=C,H=H,required={},reports={},loadAttempts={},revision=0,passiveUI=E.passiveUI}
    setmetatable(X,{__index=M})
    local nativeCleanup=FAPP_API.Native.scope(FAPP_API.id)
    function X.destroy(object)
        local done,why=nativeCleanup.destroy(object)
        assert(done,why or 'native destruction refused')
        return true
    end
    function X.log(stage,s) H.log('[Maps] '..stage..': '..tostring(s)) end
    function X.once(key,stage,s)
        if X.reports[key]~=s then X.reports[key]=s; X.log(stage,s) end
    end
    function X.guard(stage,fn)
        return function(...)
            local args=table.pack(...)
            local t0=os.clock()
            local ok,result=pcall(function() return fn(table.unpack(args,1,args.n)) end)
            if FAPP_SLOW then FAPP_SLOW('maps:'..stage,(os.clock()-t0)*1000) end
            if not ok then X.once('error:'..stage..':'..tostring(result),stage,'FAILED '..tostring(result)) end
            if ok then return result end
        end
    end
    function X.hook(stage,folder,asset,fn,callback,gate)
        local path=M.path(folder,asset,fn); X.required[path]=stage
        local guarded=X.guard(stage..'/'..fn,function(...)
            if stage=='Preview' then
                X.log('Preview',fn..' received; decision='..(not C.CreativeMaps and 'skip: CreativeMaps disabled'
                    or X.Lifetime and X.Lifetime.transition and 'skip: world transition' or 'validate self'))
            end
            if C.CreativeMaps and not (X.Lifetime and X.Lifetime.transition) then
                if E.hot(path) or E.passiveUiEvent(path,M.get(select(1,...))) then return callback(...) end -- idle callbacks own their Lua gate
                X.revision=X.revision+1
                local args=table.pack(...); local o=M.get(args[1]); X.Registry.track(o)
                if not o or H.valid(o) then return callback(...) end
                if stage=='Preview' then X.log('Preview',fn..' skipped: invalid self') end
            end
        end)
        if gate then
            H.hook(path,function(...)
                -- Reject unrelated menus before timing/unwrapping/tracking.
                if not gate() then return end
                return guarded(...)
            end)
        else H.hook(path,guarded) end
    end
    function X.asset(path)
        local obj=StaticFindObject(path)
        assert(H.valid(obj),'asset not loaded: '..path); return obj
    end
    function X.cauldronDefaults()
        local cdo=X.asset(M.OM..'B_ObjectiveCauldron.B_ObjectiveCauldron_C'):GetCDO()
        assert(H.valid(cdo),'native cauldron CDO unavailable')
        return cdo -- read only; never construct an Objective actor in Creative.
    end
    function X.minDistance()
        if finite(C.CreativeMapMinPropDistance) and C.CreativeMapMinPropDistance>0 then return C.CreativeMapMinPropDistance end
        local ok,value=pcall(function() return X.cauldronDefaults().MinPropDistance end)
        if ok and finite(value) and value>0 then return value end
        X.once('distance-cdo','Defaults','CDO MinPropDistance unavailable; using dumped native 2500 UU')
        return M.MIN_DISTANCE
    end
    function X.validation(pots,respawns,groups,layoutClasses) return M.validation(pots,respawns,groups,X.minDistance(),layoutClasses) end
    -- Host readiness only needs counts/reason, not the sorted editor report.
    -- Spread pot x class x copy distance checks over explicit Lua cursors.
    function X.validationJob(pots,respawns,groups,layoutClasses,done)
        local distance=X.minDistance(); local minimum=M.requiredClasses(pots)
        local classes,index,count,nearest,byName,key,group,copy={},1,0,math.huge,{},nil,nil,0
        local reason
        return X.Work.sequence({function()
            for id,g in pairs(groups) do classes[#classes+1]={id=id,list=g} end
            return true
        end,X.Work.defer(function()
            local phase='names'; local classIndex=0
            return function()
                local pot=pots[index]
                if not pot then return true end
                local excluded=(pot.info or pot).excluded or {}
                if phase=='names' then
                    classIndex=classIndex+1; local entry=classes[classIndex]
                    if entry then
                        local g=entry.list
                        local path=g[1].path or tostring(entry.id)
                        if excluded[path] then byName[g[1].name or tostring(entry.id)]=true end
                        return false
                    end
                    for name in pairs(pot.exclusionSources or {}) do byName[name]=true end
                    phase='copies'; classIndex=0
                end
                if not group then
                    classIndex=classIndex+1; local entry=classes[classIndex]
                    if not entry then
                        if count<minimum and not reason then reason='cauldron '..index..' has '..count..' usable prop classes; needs '..minimum..
                            ' with 2 copies each, all copies >'..distance..' UU from this cauldron' end
                        index=index+1; count=0; byName={}; phase='names'; classIndex=0
                        return index>#pots
                    end
                    key=entry.id; group=entry.list; copy=0; nearest=math.huge
                end
                copy=copy+1
                local prop=group[copy]
                if prop then nearest=math.min(nearest,M.distance2(pot.position,prop.position)); return false end
                local path=group[1].path or tostring(key); local name=group[1].name or tostring(key)
                if #group>=2 and nearest>distance^2 and not excluded[path] and not byName[name] and not (pot.nativeAvoid or {})[name] then count=count+1 end
                group=nil; return false
            end
        end),function()
            local total=layoutClasses
            if total==nil then total=0; for _,entry in ipairs(classes) do if #entry.list>=2 then total=total+1 end end end
            if #pots==0 then reason='no Fill a Pot cauldron markers'
            elseif #pots<3 then reason='at least 3 cauldron markers are required (found '..#pots..')'
            elseif #respawns==0 then reason='no Witch respawn markers or normal witch player starts'
            elseif total<minimum then reason='layout has '..total..' distinct playable classes with >=2 copies; needs '..minimum end
            done(reason==nil,reason); return true
        end})
    end
    function X.requirements(pots,respawns,groups,layoutClasses) return M.requirements(pots,respawns,groups,X.minDistance(),layoutClasses) end
    -- Cache CDO eligibility/display per class while copying only numeric positions.
    function X.propGroupsJob(props,alreadyLive,classCache,done)
        local grouped={}; classCache=classCache or {}
        return X.Work.sequence({X.Work.each(props,function(a)
            if ((alreadyLive and X.Lifetime.rawValid(a)) or (not alreadyLive and X.live(a))) and X.get(X.read(a,'IsControlledByWitch'))~=true then
                local cls=a:GetClass(); local id=cls:GetAddress(); local meta=classCache[id]
                if not meta then
                    meta={path=M.classPath(cls),common=X.get(X.read(cls:GetCDO(),'PropCategory'))==0,
                        name=X.text(X.object('/Script/Engine.Default__KismetSystemLibrary'):GetClassDisplayName(cls))}
                    classCache[id]=meta
                end
                if meta.common then
                    local pos=alreadyLive and a:K2_GetActorLocation() or X.location(a)
                    local g=grouped[id] or {}; grouped[id]=g
                    g[#g+1]={class=cls,path=meta.path,name=meta.name,position={X=pos.X,Y=pos.Y,Z=pos.Z}}
                end
            end
        end),function() done(grouped); return true end})
    end
    function X.propGroups(props,alreadyLive,classCache)
        local grouped
        X.Work.finish(X.propGroupsJob(props,alreadyLive,classCache,function(result) grouped=result end))
        return grouped
    end
    function X.object(p) return H.object(p) end
    function X.gameplay() return H.object('/Script/Engine.Default__GameplayStatics') end
    function X.mapRequiresMod(layout,gi)
        local path
        if type(layout)=='string' then path=layout
        elseif layout and X.Preflight then
            gi=gi or X.findAll('B_GameInstance_C')[1]
            path=X.Preflight.path(gi,layout)
        end
        if not path then return false end
        local file=io.open(path..'.faphidden','rb')
        if file then file:close(); return true end
        return false
    end
    function X.gi(o) local gi=X.gameplay():GetGameInstance(o); X.Registry.track(gi); return gi end
    function X.same(a,b) return H.valid(a) and H.valid(b) and a:GetAddress()==b:GetAddress() and a:GetFullName()==b:GetFullName() end
    local dir=debug.getinfo(1,'S').source:match('^@(.+[\\/])')
    X.Work=assert(FAPP_WORK,'Core work queue required')
    X.Lifetime=FAPP_SERVICES.lifetime
    X.Lifetime.onReset(X.Work.reset)
    if FAPP_METADATA then X.Lifetime.onReset(FAPP_METADATA.reset) end
    X.Identity=FAPP_SERVICES.match_identity
    X.Lifetime.onReset(E.clearPassiveUI)
    function X.live(o) return not X.Lifetime.transition and H.valid(o) and (H.valid==X.Lifetime.valid or X.Lifetime.valid(o)) and not o:GetFullName():find('Default__',1,true) end
    X.Registry=FAPP_SERVICES.registry
    function X.cachedPoll(api,pending) E.poll(api,X,X.Registry,pending) end
    X.findAll=X.Registry.list -- compatibility name: lookup only, never scans
    function X.actorsJob(ctx,cls,done,include_metadata)
        local result={};local records=include_metadata and {}
        -- Registry discovery avoids the experimentally broken actor-array OUT marshalling.
        local short=cls:match('%.([^%.]+)$') or cls
        if not X.live(ctx) then return function() done(result); return true end end
        local world; pcall(function() world=ctx:GetWorld():GetAddress() end)
        if not world then return function() done(result); return true end end
        local candidates,metadata
        if include_metadata then candidates,metadata=X.Registry.list(short,true) else candidates=X.findAll(short) end
        return X.Work.sequence({X.Work.each(candidates,function(a,i)
            -- Cached membership can outlive native destruction. Reject dead handles
            -- before GetWorld; pcall cannot recover a native access violation.
            -- Keep the full outer walk after the cheap same-world filter.
            if X.Lifetime.rawValid(a) then
                local ok,w=pcall(function() return a:GetWorld():GetAddress() end)
                if ok and w==world and X.live(a) and M.read(a,'IsPreview')~=true then
                    result[#result+1]=a;if records then records[#result]=metadata[i] end
                end
            end
        end),function() done(result,records); return true end})
    end
    function X.actors(ctx,cls)
        local result
        X.Work.finish(X.actorsJob(ctx,cls,function(actors) result=actors end))
        return result
    end
    -- Getter tables go through rooted, unspawned native property storage. No
    -- BeginPlay/ticks, source/CDO mutation, or Lua tables at UFunction boundaries.
    -- Returned storage is for an immediate call; retain scalar copies for delays.
    local scratchLevel,scratchColour
    local scratchMath={}
    -- Rooted worldless scratch objects fail gameplay validity (no world): H.valid made
    -- every call construct a NEW rooted B_StaticMeshProp, churning the registry (map
    -- maintenance + preview pool rebuilds, 3 FPS playtest) and leaking memory.
    local function scratch(o) return o~=nil and X.Lifetime.rawValid(o) end
    function X.native(v,slot)
        if type(v)~='table' then return v end
        if not scratch(scratchLevel) then
            scratchLevel=StaticConstructObject(X.asset('/Script/Engine.Level'),X.asset('/Engine/Transient'),
                FName('None'),EObjectFlags.RF_Transient,EInternalObjectFlags.RootSet)
        end
        local function copy(dst,src,fields)
            for _,k in ipairs(fields) do assert(finite(src[k]),'invalid native math scalar'); dst[k]=src[k] end
        end
        if v.R~=nil then
            if not scratch(scratchColour) then
                scratchColour=StaticConstructObject(X.asset('/Script/UMG.Image'),scratchLevel,
                    FName('None'),EObjectFlags.RF_Transient,EInternalObjectFlags.RootSet)
            end
            local c=scratchColour.ColorAndOpacity; copy(c,v,{'R','G','B','A'}); return c
        end
        slot=slot or 1
        if not scratch(scratchMath[slot]) then
            scratchMath[slot]=StaticConstructObject(X.asset('/Game/Blueprints/Props/Bases/B_StaticMeshProp.B_StaticMeshProp_C'),scratchLevel,
                FName('None'),EObjectFlags.RF_Transient,EInternalObjectFlags.RootSet)
        end
        local t=scratchMath[slot].InitialSleepTransform
        local translation=X.read(v,'Translation')
        if translation~=nil then
            copy(t.Translation,translation,{'X','Y','Z'}); copy(t.Rotation,v.Rotation,{'X','Y','Z','W'})
            copy(t.Scale3D,v.Scale3D,{'X','Y','Z'}); return t
        end
        copy(t.Translation,v,{'X','Y','Z'}); return t.Translation
    end
    function X.location(a) assert(X.live(a),'stale map actor'); return a:K2_GetActorLocation() end
    function X.kind(a)
        if not X.live(a) then return nil end
        local cls=a:GetClass():GetFName():ToString()
        for kind,path in ipairs(M.CARRIERS) do
            if cls==path:match('%.(.+)$') then
                local info=M.decode(a.SavedMaterialIndices,#M.values(a.MaterialOverwrites))
                if info and info.kind==kind then return info end
            end
        end
    end
    function X.stamp(a,kind,colour,authored,replicate,source,target,revision,decalDown,decalUp,excluded,seekCoefficient,seekRevision,look)
        X.Registry.track(a)
        if replicate then assert(H.authority(a),'refused client metadata replication') end
        local prefix=#M.values(a.MaterialOverwrites)
        local old=M.values(a.SavedMaterialIndices); local info=M.decode(old,prefix)
        -- Colour edits and native material-edit repair preserve the map property.
        if kind==1 and target==nil and info then target,revision=info.target,info.revision end
        if kind==1 then
            if excluded==nil then excluded=info and info.excluded end
            if seekCoefficient==nil and info then seekCoefficient,seekRevision=info.seekCoefficient,info.seekRevision end
            target=target or 3; revision=revision or 0
            if decalDown==nil then decalDown=info and info.decalDown or M.DECAL_DOWN end
            if decalUp==nil then decalUp=info and info.decalUp or M.DECAL_UP end
        end
        if kind>=3 and look==nil then look=info and info.look or 0 end
        local new=M.encode(old,prefix,kind,colour,authored,source,target,revision,decalDown,decalUp,excluded,seekCoefficient,seekRevision,look)
        local equal=#old==#new
        for i,v in ipairs(new) do if old[i]~=v then equal=false; break end end
        if equal then
            if X.onMarkerStamp then X.onMarkerStamp(a,kind) end
            return
        end
        X.revision=X.revision+1
        a.SavedMaterialIndices=new
        if X.Preview then X.Preview.invalidate() end
        if kind>=3 and X.Teleporters then X.Teleporters.invalidate() end
        assert(#M.values(a.SavedMaterialIndices)==#new,'SavedMaterialIndices write did not grow')
        if X.onMarkerStamp then X.onMarkerStamp(a,kind) end
        if replicate then
            assert(H.authority(a),'refused client metadata replication')
            a:FlushNetDormancy()
            H.object('/Script/Engine.Default__NetPushModelHelpers'):MarkPropertyDirtyFromRepIndex(a,10,FName('SavedMaterialIndices'))
            a:ForceNetUpdate()
        end
    end
    local typeBases={}
    X.Lifetime.onReset(function() typeBases={} end)
    function X.excludedNames(info)
        local names,sources={},{}
        for _,path in ipairs(M.exclusionPaths(info and info.excluded)) do
            local cls=StaticFindObject(path)
            if H.valid(cls) then
                local name=M.text(X.object('/Script/Engine.Default__KismetSystemLibrary'):GetClassDisplayName(cls))
                names[name]=true; sources[name]=sources[name] or {}; sources[name][#sources[name]+1]=path
            end
        end
        return names,sources
    end
    function X.applyTypeExclusions(pot,info)
        assert(X.live(pot) and H.authority(pot),'prop exclusions require host cauldron')
        local key=pot:GetAddress(); local base=typeBases[key]
        if not base or not X.same(base.actor,pot) then
            local source=M.values(M.read(pot,'PropClassesToAvoid'))
            if #source==0 then source=M.values(X.cauldronDefaults().PropClassesToAvoid) end
            base={actor=pot,names={}}; typeBases[key]=base
            for _,name in ipairs(source) do base.names[#base.names+1]=M.text(name) end
        end
        local names,seen={},{}
        for _,name in ipairs(base.names) do
            local text=M.text(name); if not seen[text] then names[#names+1]=text; seen[text]=true end
        end
        local authored={}; for name in pairs(X.excludedNames(info)) do authored[#authored+1]=name end
        table.sort(authored)
        for _,name in ipairs(authored) do if not seen[name] then names[#names+1]=name; seen[name]=true end end
        pot.PropClassesToAvoid=names
        local actual=M.values(pot.PropClassesToAvoid)
        assert(#actual==#names,'native prop exclusion property write failed')
        for i,name in ipairs(names) do assert(M.text(actual[i])==name,'native prop exclusion value mismatch') end
        if info and next(info.excluded or {}) then
            X.once('prop-types:'..key,'PropTypes',pot:GetFullName()..' native PropClassesToAvoid: '..table.concat(names,', '))
        end
    end
    function X.markersJob(ctx,done)
        local lists={{},{},{},{}}
        local steps,seen={},{}
        for _,path in ipairs(M.CARRIERS) do if not seen[path]then
            seen[path]=true
            local actors
            steps[#steps+1]=X.Work.defer(function()
                return X.actorsJob(ctx,path,function(result) actors=result end)
            end)
            steps[#steps+1]=X.Work.defer(function()
                return X.Work.each(actors,function(actor)
                    local info=X.kind(actor)
                    if info then
                        local marker={actor=actor,info=info,position=X.location(actor),id=actor:GetAddress(),fullname=actor:GetFullName()}
                        local list=lists[info.kind]; list[#list+1]=marker
                    end
                end)
            end)
        end
        end
        steps[#steps+1]=function() done(M.sort(lists[1]),M.sort(lists[2]),M.sort(lists[3]),M.sort(lists[4])); return true end
        return X.Work.sequence(steps)
    end
    function X.markers(ctx)
        local pots,respawns,entrances,exits
        X.Work.finish(X.markersJob(ctx,function(a,b,c,d) pots,respawns,entrances,exits=a,b,c,d end))
        return pots,respawns,entrances,exits
    end
    X.TeleporterPairs=dofile(assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))..'maps_teleporter_pairs.lua')
    function X.nextTeleporterColour(ctx,kind,exclude)
        local _,_,entrances,exits=X.markers(ctx)
        return X.TeleporterPairs.nextColour(entrances,exits,kind,exclude)
    end
    function X.inheritedTeleporterLook(ctx,colour,exclude,fallback)
        if not colour then return 0 end
        local _,_,entrances,exits=X.markers(ctx);local key=X.TeleporterPairs.key(colour)
        for _,list in ipairs({entrances,exits})do for _,p in ipairs(list)do
            if (not exclude or p.id~=exclude:GetAddress())and X.TeleporterPairs.key(p.info.colour)==key then return p.info.look or 0 end
        end end
        return fallback or 0
    end
    function X.seekCoefficient(ctx,pots)return M.markerSeekCoefficient(pots or X.markers(ctx))end
    if FAPP_METADATA then FAPP_METADATA.seek_coefficient=function(ctx)return X.seekCoefficient(ctx)end end
    function X.mapTarget(ctx,pots)
        pots=pots or X.markers(ctx)
        local value,revision,conflict=M.target(pots)
        if conflict then X.once('target-conflict:'..ctx:GetAddress(),'MapTarget',
            'markers disagree; newest edit wins, max on tied revisions; resolved N='..value..' revision='..revision) end
        return value,revision
    end
    function X.coloursJob(ctx,pots)
        local lights; local used,matched,pairs_,potDone={},{},{},{}
        return X.Work.sequence({X.Work.defer(function()
            return X.actorsJob(ctx,'/Game/Blueprints/StaticProps/Placeable/Utility/BP_PlaceableLight.BP_PlaceableLight_C',function(found) lights=found end)
        end),X.Work.each(pots,function(p)
            p.light=nil; p.colour=nil; p.authored=false; p.source=nil
            if p.info and p.info.source=='marker' and p.info.colour then
                p.colour=M.colour(p.info.colour); p.authored=true; p.source='marker'
                used[#used+1]=p.colour
            end
        end),X.Work.defer(function()
            local potIndex,lightIndex=1,1
            return function()
                local p,light=pots[potIndex],lights[lightIndex]
                if not p or not light then return true end
                local distance=M.distance2(p.position,X.location(light))
                if not p.colour and distance<=300*300 then pairs_[#pairs_+1]={d=distance,pi=potIndex,li=lightIndex} end
                lightIndex=lightIndex+1
                if lightIndex>#lights then potIndex=potIndex+1; lightIndex=1 end
                return potIndex>#pots
            end
        end),function()
            table.sort(pairs_,function(a,b) if a.d~=b.d then return a.d<b.d end if a.pi~=b.pi then return a.pi<b.pi end return a.li<b.li end)
            return true
        end,X.Work.defer(function()
            return X.Work.each(pairs_,function(c)
            local p,light=pots[c.pi],lights[c.li]
            if not potDone[c.pi] and not matched[c.li] then
                potDone[c.pi]=true; matched[c.li]=true
                p.light=light; p.colour=M.lightColour(light.Color); p.authored=true; p.source='light'
                used[#used+1]=p.colour
            end
            end)
        end),X.Work.each(pots,function(p,rank)
            if not p.colour then
                local offset=rank
                for attempt=1,360 do
                    local c=M.autoColour(p.position,offset); local collides=false
                    for _,other in ipairs(used) do if (c.R-other.R)^2+(c.G-other.G)^2+(c.B-other.B)^2<.01 then collides=true; break end end
                    if not collides then p.colour=c; break end
                    offset=offset+1
                end
                assert(p.colour,'could not allocate distinct auto colours'); p.authored=false; p.source='auto'; used[#used+1]=p.colour
            end
        end)})
    end
    function X.colours(ctx,pots)
        X.Work.finish(X.coloursJob(ctx,pots)); return pots
    end
    function X.message(ctx,msg)
        X.log('Validation',msg)
        local gs=X.gameplay():GetGameState(ctx)
        if H.valid(gs) and H.authority(gs) then gs:SendGameMessageMulticast(FText('FillAPotPlus: '..msg),FText(''),11)
        else
            local gi=X.gi(ctx); if H.valid(gi) and H.valid(gi.MenuUIManager) then
                gi.MenuUIManager:ShowMessageDialog('Fill a Pot',tostring(msg)) -- FString parameters
            end
        end
    end
    function X.hookStatus()
        if not C.CreativeMaps then return end
        local counts={}
        for path,stage in pairs(X.required) do
            counts[stage]=counts[stage] or {0,0,{}}
            local c=counts[stage]; c[2]=c[2]+1
            if H.installed(path) then c[1]=c[1]+1 else c[3][#c[3]+1]=path end
        end
        for stage,c in pairs(counts) do
            table.sort(c[3]); X.once('hooks:'..stage,stage,'hooks '..c[1]..'/'..c[2]..
                (#c[3]>0 and '; waiting for loaded functions: '..table.concat(c[3],', ') or '; ready'))
        end
    end
    -- Temporary call counters for the lag hunt: totals logged every 10 s.
    do
        local stats={}; local since=os.clock()
        local function wrap(tbl,name,label)
            local f=tbl[name]; if type(f)~='function' then return end
            tbl[name]=function(...)
                local t0=os.clock(); local r=table.pack(f(...)); local s=stats[label] or {n=0,ms=0}
                s.n=s.n+1; s.ms=s.ms+(os.clock()-t0)*1000; stats[label]=s
                local now=os.clock()
                if now-since>=10 then
                    local parts={}
                    for k,v in pairs(stats) do parts[#parts+1]=string.format('%s n=%d %.0fms',k,v.n,v.ms) end
                    table.sort(parts); print('[FillAPotPlus][PROF] calls 10s: '..table.concat(parts,' | ')..'\n')
                    stats={}; since=now
                end
                return table.unpack(r,1,r.n)
            end
        end
        wrap(X,'live','X.live'); wrap(X,'kind','X.kind'); wrap(X,'stamp','X.stamp'); wrap(X,'location','X.location')
        wrap(M,'values','values'); wrap(M,'decode','decode')
        X.profWrap=wrap; X.profStats=function() return stats end
    end
    dofile(dir..'maps_chat.lua').init(X)
    return X
end
return M
