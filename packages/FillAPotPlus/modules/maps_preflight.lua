-- Read-only menu preflight. Native save/load POST frames are consumed immediately;
-- borrowed arrays/structs are never retained and Lua OUT-return tables are not read.
local M={}
local ROOT='/Script/PropWitchHuntModule.ProjectVersionBlueprint:'
local TIME='/Script/VictoryBPLibrary.VictoryBPFunctionLibrary:Victory_GetFileTimeStamp'
function M.init(X)
    local H,C=X.H,X.C; local api,cache={},{}
    -- Content identity is verified once per session, then invalidated by saves
    -- or explicit refresh. World/menu transitions do not edit layout files.
    local fingerprints={}; local invalidated={}
    function api.onInvalidate(fn) invalidated[#invalidated+1]=fn end
    function api.invalidate(path)
        if path then fingerprints[path]=nil else fingerprints={} end
        for _,fn in ipairs(invalidated) do fn(path) end
    end
    local directory=debug.getinfo(1,'S').source:match('^@(.+[\\/])')
    local PL=dofile(directory..'maps_pl_reader.lua')
    local scan,dirty; local scanParents={}; local catalogPaths=setmetatable({},{__mode='k'}); local unavailable={}
    local cacheFile=H.directory and H.directory..'maps_marker_cache.lua'
    if cacheFile then
        local file=io.open(cacheFile,'r')
        if file then
            local chunk=load(file:read('*a'),'@'..cacheFile,'t',{}); file:close()
            local valid,data=false,nil; if chunk then valid,data=pcall(chunk) end
            if valid and type(data)=='table' and data.version==6 and type(data.files)=='table' then
                for path,r in pairs(data.files) do
                    if type(path)=='string' and type(r)=='table' and type(r.stamp)=='string'
                        and (r.unknown==true or (type(r.pots)=='number' and r.pots>=0 and r.pots%1==0
                        and (r.props==nil or (type(r.props)=='number' and r.props>=0 and r.props%1==0))
                        and type(r.respawns)=='number' and r.respawns>=0 and r.respawns%1==0
                        and (r.target==nil or (type(r.target)=='number' and r.target>=1 and r.target<=4294967295 and r.target%1==0))
                        and (r.seekCoefficient==nil or (type(r.seekCoefficient)=='number'and r.seekCoefficient==r.seekCoefficient and math.abs(r.seekCoefficient)<=600))
                        and (r.targetRevision==nil or (type(r.targetRevision)=='number' and r.targetRevision>=0 and r.targetRevision<=9007199254740991 and r.targetRevision%1==0)) )) then cache[path]=r end
                end
            end
        end
    end
    local function persist()
        if not cacheFile then return end
        local keys={}; for path in pairs(cache) do keys[#keys+1]=path end; table.sort(keys)
        local lines={'-- Read-only marker observations; valid only while each file stamp matches.','return {version=6,files={'}
        for _,path in ipairs(keys) do
            local r=cache[path]
            if r.records then -- multi-record sources are re-inspected next session
            elseif r.unknown then
                lines[#lines+1]=string.format('[%q]={stamp=%q,unknown=true},',path,r.stamp)
            else
                lines[#lines+1]=string.format('[%q]={stamp=%q,pots=%d,respawns=%d,target=%d,targetRevision=%d,props=%d,seekCoefficient=%.9g},',
                    path,r.stamp,r.pots,r.respawns,r.target or math.max(1,math.min(3,r.pots)),r.targetRevision or 0,r.props or 0,r.seekCoefficient or 0)
            end
        end
        lines[#lines+1]='}}\n'
        local file,err=io.open(cacheFile..'.tmp','w')
        if not file then X.once('preflight/cache','Preflight','cache persistence unavailable: '..tostring(err)); return end
        local written=file:write(table.concat(lines,'\n')); local closed=file:close()
        if not written or not closed then return end
        if not os.rename(cacheFile..'.tmp',cacheFile) then
            -- Windows rename cannot always replace an existing destination.
            local dst=io.open(cacheFile,'w'); if dst then dst:write(table.concat(lines,'\n')); dst:close(); os.remove(cacheFile..'.tmp') end
        end
    end
    local timestamp
    local ok,lfs=pcall(require,'lfs'); if not ok then lfs=nil end
    local function filename(path)
        path=path:gsub('\\','/')
        local okFull,full=pcall(function()
            return X.object('/Script/Engine.Default__BlueprintPathsLibrary'):ConvertRelativePathToFull(path)
        end)
        if okFull and type(full)=='string' and full~='' then path=full:gsub('\\','/') end
        return path
    end
    local function nativeHook(path,fn)
        X.required[path]='Preflight'
        H.hook(path,function() end,X.guard('Preflight/native',function(...)
            if C.CreativeMaps then fn(...) end
        end))
    end
    nativeHook(TIME,function(_,value)
        if not timestamp then return end
        local mathlib=X.object('/Script/Engine.Default__KismetMathLibrary')
        -- Pass the native DateTime userdata, never its table-converted return value.
        local dt=value:get()
        timestamp.value=tostring(mathlib:ToUnixTimestamp(dt))..':'..tostring(mathlib:GetMillisecond(dt))
    end)
    local function modification(path,size)
        if lfs then local a=lfs.attributes(path);if a then return tostring(a.modification)..':'..tostring(a.size) end end
        if not H.installed(TIME) then return end
        timestamp={}
        local okTime=pcall(function()
            X.object('/Script/VictoryBPLibrary.Default__VictoryBPFunctionLibrary'):Victory_GetFileTimeStamp(path,{})
        end)
        local value=timestamp.value;timestamp=nil
        if okTime and value then return value..':'..tostring(size) end
    end
    function api.stamp(path)
        if lfs then local a=lfs.attributes(path); if a then return tostring(a.modification)..':'..tostring(a.size) end end
        local f=io.open(path,'rb'); if not f then return nil,'file unavailable: '..path end
        local size=f:seek('end'); f:seek('set',0)
        local mtime=modification(path,size)
        if mtime then f:close();return mtime end
        -- A content fingerprint detects same-size replacements if filesystem time
        -- support isn't present in this UE4SS distribution. It never parses a save.
        local data=f:read('*a'); if not data then f:close(); return nil,'file read failed: '..path end
        local hash=2166136261
        for i=1,#data do hash=((hash ~ data:byte(i))*16777619)&0xffffffff end
        f:close()
        X.once('preflight/mtime','Preflight','mtime provider unavailable; using size + content fingerprint')
        local stamp=tostring(size)..':'..hash; fingerprints[path]=stamp
        return stamp,nil,data
    end
    local function count(statics,prefabs)
        local pots,respawns=0,0; local markers={}
        local function scan(rows)
            for _,row in ipairs(X.values(rows)) do
                local marker=X.decode(X.read(row,'MaterialIndices'))
                -- Require the encoded carrier identity as well as the trailer.
                local id=X.read(row,'PrimaryAssetId'); local name=X.text(X.read(id,'PrimaryAssetName'))
                if marker and name:gsub('_C$','')==X.CARRIERS[marker.kind]:match('%.(.+)$'):gsub('_C$','') then
                    if marker.kind==1 then pots=pots+1; markers[#markers+1]=marker elseif marker.kind==2 then respawns=respawns+1 end
                end
            end
        end
        scan(statics)
        for _,prefab in ipairs(X.values(prefabs)) do scan(X.read(prefab,'Structures')) end
        local target,revision,conflict=X.target(markers)
        return pots,respawns,target,revision,conflict,X.markerSeekCoefficient(markers)
    end
    local function observe(saving,_,success,file,propActors,workshop,statics,lights,switches,prefabs)
        if success:get()~=true then return end
        local path=filename(X.text(file:get())); local pots,respawns,target,revision,conflict,seekCoefficient=count(statics:get(),prefabs:get())
        if saving then api.invalidate(path) end
        local stamp=api.stamp(path)
        if not stamp then return end
        local result={pots=pots,respawns=respawns,stamp=stamp,target=target,targetRevision=revision,seekCoefficient=seekCoefficient,props=#X.values(propActors:get())}
        cache[path]=result
        persist()
        X.once('preflight:'..path,'Preflight',path..' markers='..pots..'/'..respawns..'; Cauldrons to win='..target..
            (conflict and '; markers disagree, newest edit / tied max resolved' or ''))
    end
    for _,fn in ipairs({'LoadPropLayoutFromFile','LoadPropLayoutFromFileCompressed',
        'SavePropLayoutToFile','SavePropLayoutToFileCompressed'}) do
        nativeHook(ROOT..fn,function(...) observe(fn:sub(1,4)=='Save',...) end)
    end
    -- Native catalog keys are filenames, including absolute Steam Workshop paths.
    -- Keep those when a layout struct supplies only the leaf filename.
    function api.register(layout,key)
        local file=X.text(X.field(layout,'file')); key=X.text(X.get(key))
        if key:lower():match('%.pl$') and key:find('[\\/]') and not file:find('[\\/]') then
            catalogPaths[layout]=filename(key)
        end
    end
    function api.path(gi,layout)
        local path=X.text(X.field(layout,'file'))
        if path=='' or path=='None' or path=='nil' then return nil end
        if catalogPaths[layout] then return catalogPaths[layout] end
        if not path:find('[\\/]') then
            local current=X.text(X.read(X.read(gi,'MapManager'),'CurrentWorkshopFile')):gsub('\\','/')
            if current:match('([^/]+)$')==path and current:find('/') then return filename(current) end
        end
        -- io.open inside Wine runs in the Windows process: C:/... (including
        -- steamapps/workshop/content/559650/<published-id>/...) is already native.
        return filename(path)
    end
    function api.beginScan()
        scanParents[#scanParents+1]=scan or false
        scan={started=os.clock(),checked=0,decoded=0,hits=0,unknown=0,deferred=0,seen={}}
    end
    function api.endScan()
        if not scan then return end
        if dirty then persist(); dirty=false end
        X.log('Preflight',string.format('list scan: checked=%d decoded=%d cached=%d unknown=%d deferred=%d; %.1f ms',
            scan.checked,scan.decoded,scan.hits,scan.unknown,scan.deferred,(os.clock()-scan.started)*1000))
        scan=table.remove(scanParents) or nil
    end
    function api.probe(path,stamp,data)
        if not stamp then
            local why; stamp,why,data=api.stamp(path)
            if not stamp then
                X.once('preflight/read:'..path,'Preflight','layout hidden: '..path..'; '..tostring(why))
                return nil,why
            end
        end
        local ok,result=pcall(function()
            if not data then
                local f,err=io.open(path,'rb'); assert(f,err)
                data=f:read('*a'); f:close(); assert(data,'file read failed')
            end
            return PL.read(data,X)
        end)
        if not ok then
            X.once('preflight/read:'..path,'Preflight','layout hidden: '..path..'; '..tostring(result))
            result={unknown=true}
        end
        result.stamp=stamp; cache[path]=result; dirty=true
        if not scan then persist(); dirty=false end
        return result
    end
    local cacheOnly=0; local pendingFiles={}; local fileJobs={}
    function api.cacheOnly() return cacheOnly>0 end
    function api.cached(fn)
        return function(...)
            cacheOnly=cacheOnly+1
            local result=table.pack(pcall(fn,...))
            cacheOnly=cacheOnly-1
            if not result[1] then error(result[2],0) end
            return table.unpack(result,2,result.n)
        end
    end
    -- File-only worker: no borrowed Blueprint frame or UObject callback can
    -- reach this step. Fingerprint/read in 1 KiB chunks; decode cooperatively.
    function api.request(path,completed)
        if pendingFiles[path] then return false end
        local job={};pendingFiles[path]=job;fileJobs[path]=job
        local parts,hash,size={},2166136261,0;local decode,stamp
        local identityHash=2166136261
        for i=1,#path do identityHash=((identityHash ~ path:byte(i))*16777619)&0xffffffff end
        local function finish(result,reused)
            if job.file then job.file:close();job.file=nil end
            pendingFiles[path]=nil;fileJobs[path]=nil
            cache[path]=result
            if result then
                result.stamp=stamp;result.identityHash=identityHash;fingerprints[path]=stamp
                if not reused then dirty=true end
            end
            if completed then completed(result) end
            if dirty and next(fileJobs)==nil then
                X.Work.submit('maps:index:persist','maps/index persist',function() persist();dirty=false;return true end)
            end
            return true
        end
        X.Work.submit('maps:inspect:'..path,'maps/index',function()
            local previous=cache[path]
            if not job.opened and fingerprints[path] and previous and previous.stamp==fingerprints[path]
                and previous.identityHash then
                stamp=previous.stamp;identityHash=previous.identityHash
                return finish(previous,true)
            end
            if decode then
                local ok,done,result=pcall(decode)
                if not ok then return finish({unknown=true}) end
                if done then return finish(result) end
                return false
            end
            if not job.opened then
                job.opened=true;job.file=io.open(path,'rb')
                if not job.file then return finish(nil) end
                return false
            end
            local bytes=job.file:read(1024)
            if bytes then
                parts[#parts+1]=bytes;size=size+#bytes
                for i=1,#bytes do
                    local b=bytes:byte(i)
                    hash=((hash ~ b)*16777619)&0xffffffff
                    identityHash=((identityHash ~ b)*16777619)&0xffffffff
                end
                return false
            end
            job.file:close();job.file=nil
            stamp=tostring(size)..':'..hash
            -- The live runtime has no lfs module; use the same fingerprint as
            -- stamp() unless a genuine timestamp provider is installed.
            stamp=modification(path,size) or stamp
            if previous and previous.stamp==stamp then return finish(previous) end
            local data=table.concat(parts);parts=nil
            local ok,value=pcall(PL.readJob,data,X)
            if not ok then return finish({unknown=true}) end
            decode=value;return false
        end)
        return true
    end
    function api.reset()
        for path,job in pairs(fileJobs) do
            X.Work.cancel('maps:inspect:'..path)
            if job.file then job.file:close() end
            if job.temporary then os.remove(job.temporary) end
        end
        pendingFiles={};fileJobs={};catalogPaths=setmetatable({},{__mode='k'})
    end
    X.Lifetime.onReset(api.reset)
    function api.inspect(gi,layout)
        local path=api.path(gi,layout)
        if not path then return false,'layout file is empty' end
        local result=cache[path]
        if cacheOnly>0 then
            if not result or result.unknown then return false,'marker data unavailable' end
            return result.pots>=1,result.pots<1 and 'no Fill a Pot cauldron markers' or nil,result
        end
        -- Never read/decompress from poll/actor ticks. Unknown layouts wait for a
        -- list build. Cached selections still validate their stamp on event use.
        local function deferred()
            return scan and (scan.decoded>=20 or (scan.decoded>0 and os.clock()-scan.started>=0.025))
        end
        if scan then
            if scan.seen[path] then
                if result and not result.unknown then
                    return result.pots>=1,result.pots<1 and 'no Fill a Pot cauldron markers' or nil,result
                end
                return false,'marker data unavailable'
            end
            scan.seen[path]=true
            -- Skip opening genuinely new files once this build spent its budget;
            -- later cached maps remain visible even when they follow deferred ones.
            if not result and not unavailable[path] and deferred() then
                scan.deferred=scan.deferred+1
                return false,'layout inspection deferred until next list build'
            end
            scan.checked=scan.checked+1
        end
        if not scan and not result then return false,'marker data unavailable' end
        local stamp,why,data=api.stamp(path)
        if not stamp then
            if scan then
                if not unavailable[path] then scan.decoded=scan.decoded+1 end
                scan.unknown=scan.unknown+1
            end
            unavailable[path]=true
            X.once('preflight/read:'..path,'Preflight','layout hidden: '..path..'; '..tostring(why))
            return false,why
        end
        unavailable[path]=nil
        if result and result.stamp~=stamp then result=nil; cache[path]=nil; dirty=true end
        if not result and scan then
            if deferred() then
                scan.deferred=scan.deferred+1
                return false,'layout inspection deferred until next list build'
            end
            scan.decoded=scan.decoded+1; result=api.probe(path,stamp,data)
        elseif scan then scan.hits=scan.hits+1 end
        if not result or result.unknown then
            if scan then scan.unknown=scan.unknown+1 end
            return false,'marker data unavailable'
        end
        local reason; if result.pots<1 then reason='no Fill a Pot cauldron markers' end
        result.target=result.target or math.max(1,math.min(3,result.pots)); result.targetRevision=result.targetRevision or 0
        return result.pots>=1,reason,result
    end
    function api.records(gi,layout)
        local valid,why,info=api.inspect(gi,layout)
        if not valid then return nil,why end
        return info.records or {info}
    end
    function api.materialize(gi,layout,index)
        local path=assert(api.path(gi,layout)); local f=assert(io.open(path,'rb'))
        local data=f:read('*a'); f:close()
        local records=PL.records(data,X); local record=assert(records[index],'layout record no longer exists')
        local hash=2166136261
        local identity=path..data
        for i=1,#identity do hash=((hash ~ identity:byte(i))*16777619)&0xffffffff end
        local store=assert(FAPP_API).storage(); local name=string.format('vote-layout-%08x-%d.pl',hash,index)
        -- PL files may exceed the JSON/settings 256 KiB limit. Native layout bytes
        -- use the same package directory, with atomic tmp/rename, no source writes.
        local destination=store.path(name); local output=PL.pack(record.raw)
        local dst=assert(io.open(destination..'.tmp','wb')); assert(dst:write(output)); assert(dst:close())
        os.remove(destination); assert(os.rename(destination..'.tmp',destination))
        local holder=StaticConstructObject(X.asset('/Game/UserInterface/Maps/B_MapButtonData.B_MapButtonData_C'),gi)
        holder.LayoutData=layout
        holder.LayoutData[X.LAYOUT.file]=destination
        holder.LayoutData[X.LAYOUT.name]=X.text(X.field(layout,'name'))..' · layout '..index
        if X.Catalog then
            local _,origin=X.Catalog.origin(gi,layout)
            if origin then assert(X.Catalog.copyOrigin(destination,origin),'derived catalog origin unavailable') end
        end
        gi.MapManager.LayoutDataByFileName:Add(destination,holder.LayoutData)
        local result
        gi.MapManager.LayoutDataByFileName:ForEach(function(k,v) if X.text(X.get(k))==destination then result=X.get(v) end end)
        assert(result,'materialized layout catalog copy missing')
        record.raw=nil; record.stamp=assert(api.stamp(destination)); cache[destination]=record
        dirty=true; return result,record
    end
    function api.materializeJob(gi,layout,index,record,completed)
        assert(record.raw,'queued record bytes unavailable')
        local path=assert(api.path(gi,layout))
        local hash=assert(cache[path] and cache[path].identityHash,'queued source fingerprint unavailable')
        local store=assert(FAPP_API).storage()
        local destination=store.path(string.format('vote-layout-%08x-%d.pl',hash,index))
        local pack=PL.packJob(record.raw);local output,offset,file
        local result;local job={temporary=destination..'.tmp'};local jobKey='materialize:'..destination
        return function()
            if not output then local done,value=pack();if done then output=value end;return false end
            if not file and not offset then file=assert(io.open(destination..'.tmp','wb'));job.file=file;fileJobs[jobKey]=job;offset=1;return false end
            if file then
                assert(file:write(output:sub(offset,offset+16383)));offset=offset+16384
                if offset<=#output then return false end
                assert(file:close());file=nil;job.file=nil;fileJobs[jobKey]=nil;os.remove(destination);assert(os.rename(destination..'.tmp',destination));return false
            end
            if not result then
                local holder=StaticConstructObject(X.asset('/Game/UserInterface/Maps/B_MapButtonData.B_MapButtonData_C'),gi)
                holder.LayoutData=layout;holder.LayoutData[X.LAYOUT.file]=destination
                holder.LayoutData[X.LAYOUT.name]=X.text(X.field(layout,'name'))..' · layout '..index
                if X.Catalog then local _,origin=X.Catalog.origin(gi,layout)
                    if origin then assert(X.Catalog.copyOrigin(destination,origin),'derived catalog origin unavailable') end end
                gi.MapManager.LayoutDataByFileName:Add(destination,holder.LayoutData)
                gi.MapManager.LayoutDataByFileName:ForEach(function(k,v) if X.text(X.get(k))==destination then result=X.get(v) end end)
                assert(result,'materialized layout catalog copy missing')
                local info={};for k,v in pairs(record) do if k~='raw' then info[k]=v end end
                -- Fingerprint the stored stream cooperatively, never in a UI getter.
                cache[destination]=info
                api.request(destination,function(observed) if observed then completed(result,observed) end end)
                return true
            end
        end
    end
    function api.builtin(gi,map)
        -- Featured entries are SMapData cooked worlds and streamed MapLayouts,
        -- not .pl saves (B_RandomPropLayoutPicker.LoadLayout). Signed vanilla
        -- packages cannot contain our newly authored FAPM material trailer.
        local file=X.text(X.read(map,'FileName_10_98BC71FF40A2DA9A28FA21B92157D6D9'))
        X.once('preflight/cooked:'..file,'Preflight','Featured '..file..': cooked vanilla world, no authored marker payload')
        return false,'cooked Featured world has no Fill a Pot markers'
    end
    function api.poll() end
    X.Preflight=api
    return api
end
return M
