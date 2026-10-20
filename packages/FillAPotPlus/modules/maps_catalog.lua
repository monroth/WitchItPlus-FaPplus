-- CAT1: event-owned family catalog. No polling, async/synchronous asset loads,
-- gameplay-class hooks, or modifications to cooked MapData / user .pl files.
local M={}
local MAP='/Game/UserInterface/Maps/'
local PLAY='/Game/UserInterface/Play/'
local FILE='FileName_10_98BC71FF40A2DA9A28FA21B92157D6D9'
local OBJECTIVE='UsedInObjectiveMode_16_14EC3F034A60C0E1B05A6499D0923C6F'
local BUILTIN='IsBuiltInCustomMap_24_B260140C4981E09A0400EBBB5AF787AD'
local function leaf(s) return s:gsub('\\','/'):match('([^/]+)$') or s end
function M.init(X,S)
    local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
    local D=dofile(dir..'maps_catalog_data.lua')
    local Info=dofile(dir..'maps_layout_info.lua')
    local api={data=D}; local snapshots,buttons,combos,dataInfo={},{},{},{}
    local views={list={},custom={}};local origins={}
    local lists,producers={},{};local published=0
    local nativeLists={};local knownMaps={};local revision=0
    for _,family in pairs(D.families) do for _,path in ipairs(family.bases) do knownMaps[path]=true;knownMaps[leaf(path)]=true end end
    local address,capture; local objectiveScreen,creativeScreen=false,false
    -- GetAddress is a UE4SS wrapper helper, not a UFunction. Capture the helper
    -- on state events, avoiding reflected member lookups in bound UI getters.
    local function id(w)
        address=address or w.GetAddress
        return address(w)
    end
    local function hook(folder,asset,fn,cb)
        local path=X.path(folder,asset,fn); X.required[path]='Catalog'
        local guarded=X.guard('Catalog/'..fn,function(...)
            if not X.C.CreativeMaps then if api.reset then api.reset() end; return end
            if not X.Lifetime.transition then return cb(...) end
        end)
        -- UI observations must not invalidate the Creative maintenance revision.
        -- This build invokes Blueprint RegisterHook callbacks after the body.
        X.H.hook(path,X.Preflight.cached(guarded))
    end
    local function base(layout) return leaf(X.text(X.field(layout,'map'))) end
    function api.encode(key)
        assert(D.exports[key],'unknown catalog source')
        return 'FAPP_CATALOG_V1\n'..key..'\n'
    end
    function api.decode(text,layout)
        if type(text)~='string' or #text>1024 then return nil end
        local key=text:match('^FAPP_CATALOG_V1\n([^\r\n]+)\n$')
        local row=key and D.exports[key]
        if row and leaf(row.base)==base(layout) then return row,key end
    end
    function api.origin(gi,layout)
        local path=X.Preflight.path(gi,layout)
        if path and X.Preflight.cacheOnly() and origins[path] and origins[path].base==base(layout) then
            return origins[path].row,origins[path].key
        end
        local function remember(row,key)
            if path and not X.Preflight.cacheOnly() then origins[path]={row=row,key=key,base=base(layout)} end
            return row,key
        end
        if path and not X.Preflight.cacheOnly() then
            local f=io.open(path..'.fapcatalog','rb')
            if f then
                local text=f:read(1025); f:close()
                -- A malformed/conflicting sidecar never falls back to a guessed name.
                return remember(api.decode(text,layout))
            end
        end
        local stem=leaf(X.text(X.field(layout,'file'))):gsub('%.pl$','')
        local key=base(layout)..'/'..stem
        if D.exports[key] then return remember(D.exports[key],key) end
        -- A save on a complete cooked Featured world carries its unique world
        -- as MapName. Generic authoring bases remain ambiguous and need origin.
        for _,f in pairs(D.families) do
            if f.tab==2 and f.available and base(layout)==leaf(f.world) then
                key=leaf(f.world)..'/NativeWorld'; return remember(D.exports[key],key)
            end
        end
        return remember(nil,nil)
    end
    -- Legacy derived-layout preflight callers retain this API. It is NOT a
    -- Save operation participant and no Load/Save POST hook calls it now.
    function api.copyOrigin(path,key)
        local text=api.encode(key)
        local layout=io.open(path,'rb'); if not layout then return nil,'saved layout unavailable' end; layout:close()
        local existing=io.open(path..'.fapcatalog','rb')
        if existing then
            local old=existing:read(1025); existing:close()
            return old==text,old==text and nil or 'existing catalog metadata differs; preserved'
        end
        -- Publish complete metadata only after the native save. Existing sidecars
        -- and abandoned temp files are preserved; only our newly created temp is
        -- removed on failure. All work runs serially on the game thread.
        local temporary=path..'.fapcatalog.tmp'
        local occupied=io.open(temporary,'rb')
        if occupied then occupied:close(); return nil,'catalog temp file exists; preserved' end
        local f,err=io.open(temporary,'wb'); if not f then return nil,err end
        local written=f:write(text); local closed=f:close()
        if not written or not closed then os.remove(temporary); return nil,'catalog metadata write failed' end
        existing=io.open(path..'.fapcatalog','rb')
        if existing then existing:close(); os.remove(temporary); return nil,'catalog destination appeared; preserved' end
        local ok,why=os.rename(temporary,path..'.fapcatalog')
        if not ok then os.remove(temporary) end
        return ok,why
    end
    api.files=dofile(dir..'maps_catalog_files.lua').install(FAPP_API,api)
    local function nativeMaps(gi)
        local byFile={}; local mm=gi.MapManager
        local function add(map)
            local file=X.text(X.read(map,FILE))
            if file~='' and file~='nil' and file~='None' then byFile[file]=map end
        end
        for _,key in ipairs({'SmallMapList','BigMapList','QuickmatchMapList','SmallBuiltInCustomMapList','BigBuiltInCustomMapList'}) do
            for _,map in ipairs(X.values(X.read(mm,key))) do add(map) end
        end
        local raw=X.read(mm,'MapDataByFileName')
        if raw then pcall(function() raw:ForEach(function(_,v) add(X.get(v)) end) end) end
        return byFile
    end
    local function matchingMap(maps,path)
        if maps[path] then return maps[path] end
        for file,map in pairs(maps) do if leaf(file)==leaf(path) then return map end end
    end
    function api.build(gi,autosaves)
        local maps=nativeMaps(gi); local result={families={},custom={}}
        -- Stock originals are retained only when the native MapData enables FaP.
        for family,f in pairs(D.families) do
            local display=matchingMap(maps,f.world); local original
            if f.tab==0 then
                -- The tile shows f.world, so its original is that world when FaP-enabled.
                local order={f.world}; for _,path in ipairs(f.bases) do if path~=f.world then order[#order+1]=path end end
                for _,path in ipairs(order) do
                    local map=matchingMap(maps,path)
                    if map and X.read(map,OBJECTIVE)==true and X.read(map,BUILTIN)~=true then original=map; break end
                end
            end
            if display or original then
                result.families[family]={family=family,tab=f.tab,map=display or original,original=original,variants={}}
            end
        end
        for _,layout in ipairs(S.catalog(gi,false,autosaves)) do
            local usable,_,info=S.inspect(gi,layout)
            if usable then
                local origin,key=api.origin(gi,layout)
                local group=origin and result.families[origin.family]
                if info.records then info=Info.summary(info.records) end
                local row={layout=layout,info=info,file=X.text(X.field(layout,'file')),origin=origin,key=key}
                if group and (group.original or group.tab==2) then group.variants[#group.variants+1]=row
                else result.custom[#result.custom+1]=row end
            end
        end
        for _,group in pairs(result.families) do
            table.sort(group.variants,function(a,b)
                local x,y=a.origin,b.origin
                if x.season~=y.season then return x.season<y.season end
                if x.number~=y.number then return x.number<y.number end
                return a.file<b.file
            end)
        end
        snapshots[gi:GetAddress()]={gi=gi,data=result}
        return result
    end
    -- Build metadata off the Blueprint stack: one map/family/layout per step.
    function api.buildJob(gi,done)
        local buildEpoch=X.Lifetime.epoch;local catalogRevision=revision
        local maps,byLeaf,result,layouts,families={},{},{families={},custom={},byFile={},byMap={}},nil,{}
        for key in pairs(D.families) do families[#families+1]=key end
        local function add(map)
            local file=X.text(X.read(map,FILE))
            if file~='' and file~='None' then maps[file]=map;byLeaf[leaf(file)]=map end
        end
        local stages={}
        for _,field in ipairs({'SmallMapList','BigMapList','QuickmatchMapList','SmallBuiltInCustomMapList','BigBuiltInCustomMapList'}) do
            stages[#stages+1]=X.Work.defer(function()
                local array=X.read(gi.MapManager,field)
                if not array then return function() return true end end
                return X.Work.array(array,X.get,add)
            end)
        end
        -- Native TMap ForEach is indivisible: only collect borrowed wrappers in
        -- it. Reflection/metadata work happens one entry at a time afterward.
        stages[#stages+1]=X.Work.defer(function()
            local entries={};local raw=X.read(gi.MapManager,'MapDataByFileName')
            if raw then raw:ForEach(function(_,v) entries[#entries+1]=X.get(v) end) end
            local levels=X.read(gi.MapManager,'MapDataByLevelName')
            if levels then levels:ForEach(function(_,v) entries[#entries+1]=X.get(v) end) end
            return X.Work.each(entries,add)
        end)
        stages[#stages+1]=X.Work.each(families,function(family)
            local f=D.families[family];local display=maps[f.world] or byLeaf[leaf(f.world)];local original
            local order={f.world}; for _,path in ipairs(f.bases) do if path~=f.world then order[#order+1]=path end end
            if f.tab==0 then for _,path in ipairs(order) do
                local map=maps[path] or byLeaf[leaf(path)]
                if map and X.read(map,OBJECTIVE)==true and X.read(map,BUILTIN)~=true then original=map;break end
            end end
            if display or original then
                local group={family=family,tab=f.tab,map=display or original,original=original,variants={}}
                result.families[family]=group
                if original then result.byMap[X.text(X.read(original,FILE))]=group end
            end
        end)
        stages[#stages+1]=X.Work.defer(function()
            layouts=X.Preflight.cached(function() return S.catalog(gi,false,true) end)()
            return X.Work.each(layouts,X.Preflight.cached(function(layout)
                local usable,_,info=S.inspect(gi,layout)
                if not usable then return end
                local origin,key=api.origin(gi,layout);local group=origin and result.families[origin.family]
                if info.records then info=Info.summary(info.records) end
                local file=X.text(X.field(layout,'file'));local map=byLeaf[base(layout)]
                local row={layout=layout,info=info,file=file,origin=origin,key=key,map=map}
                if not map then return end
                result.byFile[file]=row
                if group and (group.original or group.tab==2) then group.variants[#group.variants+1]=row else result.custom[#result.custom+1]=row end
            end))
        end)
        stages[#stages+1]=X.Work.each(families,function(family)
            local group=result.families[family];if not group then return end
            table.sort(group.variants,function(a,b)
                if a.origin.season~=b.origin.season then return a.origin.season<b.origin.season end
                if a.origin.number~=b.origin.number then return a.origin.number<b.origin.number end
                return a.file<b.file
            end)
            group.originalInfo=group.original and Info.original(X.text(X.read(group.original,FILE)))
            local infos={};if group.originalInfo then infos[#infos+1]=group.originalInfo end
            for _,v in ipairs(group.variants) do infos[#infos+1]=v.info end
            group.info=Info.summary(infos);group.choices=api.variants(group)
            for _,choice in ipairs(group.choices) do choice.text=FText(choice.label) end
        end)
        stages[#stages+1]=function()
            published=published+1;lists={}
            snapshots[id(gi)]={gi=gi,data=result};done();return true
        end
        local work=X.Work.sequence(stages)
        return function()
            if X.Lifetime.transition or buildEpoch~=X.Lifetime.epoch or catalogRevision~=revision then return true end
            return work()
        end
    end
    function api.lookup(gi,file)
        local snapshot=snapshots[id(gi)]
        return snapshot and snapshot.data.byFile and snapshot.data.byFile[file]
    end
    local requests={};local refreshVersions={};local stamps={}
    function api.request(gi,autosaves)
        local key=id(gi);local previous=requests[key]
        if previous and X.same(previous.gi,gi) then return end
        requests[key]={gi=gi};local epoch=revision
        local function refresh()
            if epoch~=revision then return end
            refreshVersions[key]=(refreshVersions[key] or 0)+1
            X.Work.submit('maps:catalog:refresh:'..key,'maps/catalog refresh',X.Work.defer(function()
                local function build()
                    local jobs={}
                    for _,view in pairs(views.list) do
                        local w=view.widget
                        if not FAPP_TEST_NO_THROTTLE and X.H.valid(w) and X.same(X.gi(w),gi)
                            and S.isObjective(w.NextMatchOptions) then
                            jobs[#jobs+1]=api.listJob(w)
                        else
                            jobs[#jobs+1]=X.Work.native(function()
                                if epoch~=revision or not X.H.valid(w) or views.list[id(w)]~=view or not X.same(X.gi(w),gi) then return end
                                local category=X.read(w,'CurrentCategoryButton')
                                w:UpdateCategoryContent(X.H.valid(category) and category or nil,view.salvage)
                            end)
                        end
                    end
                    for _,w in pairs(views.custom) do
                        jobs[#jobs+1]=function()
                            if epoch==revision and X.H.valid(w) and X.same(X.gi(w),gi) then api.dropdown(w) end
                            return true
                        end
                    end
                    return X.Work.sequence(jobs)
                end
                local version=refreshVersions[key];local step=build()
                return function()
                    if epoch~=revision then return true end
                    local result=step()
                    if result==true and version~=refreshVersions[key] then
                        version=refreshVersions[key];step=build();return false
                    end
                    return result
                end
            end))
        end
        -- Publish known/cached maps before inspecting any new save. File
        -- discovery and decoding refine this snapshot, never gate the first list.
        X.Work.submit('maps:catalog:initial:'..key,'maps/catalog initial',api.buildJob(gi,function()
            if epoch==revision then refresh() end
        end))
        X.Work.submit('maps:catalog:'..key,'maps/catalog',X.Work.sequence({
            -- The native picker/save events already maintain MapManager's list.
            -- Do not force its additional ~300 ms directory rebuild here.
            X.Work.defer(function()
                if epoch~=revision or not X.H.valid(gi) then return function() return true end end
                -- Index autosaves too: changing the visibility checkbox only
                -- filters cached rows, never starts another directory/file scan.
                -- Inspect source archives, not their cached concrete substitutes:
                -- explicit refresh must detect edits to multi-record .pl files.
                local paths={};local layouts=X.Preflight.cached(function() return S.catalog(gi,false,true,true) end)()
                for _,layout in ipairs(layouts) do local path=X.Preflight.path(gi,layout);if path then paths[path]=layout end end
                local list={};for path in pairs(paths) do list[#list+1]=path end
                -- Rebuilding the native list costs ~300 ms (live 2026-10-08): do it once
                -- per batch, after every requested file finished, and only on change.
                local outstanding,submitted,changed=0,false,false
                local building=false
                local function settle()
                    if submitted and outstanding==0 and not building then
                        building=true
                        X.Work.submit('maps:metadata:'..key,'maps/metadata',api.buildJob(gi,function()
                            if epoch==revision and changed then changed=false;refresh() end
                        end))
                    end
                end
                return X.Work.sequence({
                    X.Work.each(list,function(path)
                        local accepted=X.Preflight.request(path,function(info)
                            if epoch~=revision then return end
                            local stamp=info and info.stamp
                            if stamp==nil or stamps[path]~=stamp then stamps[path]=stamp;changed=true end
                            -- Sidecar observations are scalar session data. The
                            -- explicit origin accessor still validates on request.
                            if not origins[path] then api.origin(gi,paths[path]) end
                            S.indexRecords(gi,paths[path],info,function(recordsChanged)
                                outstanding=outstanding-1
                                changed=changed or recordsChanged;settle()
                            end)
                        end)
                        if accepted then outstanding=outstanding+1 end
                    end),
                    function() submitted=true;settle();return true end,
                })
            end)
        }))
    end
    X.Preflight.onInvalidate(function(path)
        requests={};snapshots={}
        if path then origins[path]=nil else origins={} end
    end)
    function api.snapshot(gi)
        local r=snapshots[gi:GetAddress()]
        if r and X.same(r.gi,gi) then return r.data end
        if FAPP_TEST_NO_THROTTLE then return api.build(gi,false) end
        return {families={},custom={}}
    end
    function api.rows(gi,category,options,autosaves,editable)
        local catalog=FAPP_TEST_NO_THROTTLE and api.build(gi,autosaves) or api.snapshot(gi); local rows={}
        if category==1 then
            for _,v in ipairs(catalog.custom) do
                if autosaves or not X.text(X.field(v.layout,'name')):find('_AutoSave$') then
                    rows[#rows+1]={layout=v.layout,map=v.map or S.mapFor(gi,v.layout),info=v.info}
                end
            end
        else
            for _,group in pairs(catalog.families) do
                if group.tab==category and (group.original or #group.variants>0) then
                    local originalInfo=group.originalInfo or (FAPP_TEST_NO_THROTTLE and group.original and S.mapInfo(gi,group.original))
                    local infos={}
                    if originalInfo then infos[#infos+1]=originalInfo end
                    for _,variant in ipairs(group.variants) do infos[#infos+1]=variant.info end
                    local familyInfo=group.info or Info.summary(infos)
                    if editable then
                        if group.original then rows[#rows+1]={map=group.map,original=group.original,family=group.family,info=originalInfo} end
                        for _,v in ipairs(group.variants) do rows[#rows+1]={map=group.map,layout=v.layout,family=group.family,info=v.info} end
                    else
                    local row=group.variants[1]
                    if X.read(options,'CustomMapSelected')==true then
                        for _,v in ipairs(group.variants) do if v.file==X.text(X.field(options.LayoutData,'file')) then row=v; break end end
                    end
                    local useOriginal=group.original and not (X.read(options,'CustomMapSelected')==true and row and row.file==X.text(X.field(options.LayoutData,'file')))
                    rows[#rows+1]={map=group.map,original=useOriginal and group.original or nil,layout=not useOriginal and row and row.layout or nil,
                        family=group.family,info=familyInfo or (useOriginal and originalInfo or row.info)}
                    end
                end
            end
            table.sort(rows,function(a,b)
                if a.family~=b.family then return a.family<b.family end
                return X.text(a.layout and X.field(a.layout,'file') or '')<X.text(b.layout and X.field(b.layout,'file') or '')
            end)
        end
        return rows
    end
    -- UE4SS Blueprint OUT tables are empty. Capture the actual native POST
    -- frame synchronously, before the borrowed parameter goes out of scope.
    hook('/Game/UserInterface/UIElements/MenuTileView/','B_MenuTileViewManager','GetMapButtonData',function(_,_,_,_,_,_,out)
        if capture then capture.data=out:get() end
    end)
    function api.button(w,current,map,layout,info)
        local frame={}; local parent=capture; capture=frame
        local out={}
        local ok,err=pcall(function()
            w.TileViewManager:GetMapButtonData(current,w,map,layout,w.MenuState==1,out)
        end)
        capture=parent; if not ok then error(err) end
        -- The fallback supports older UE4SS releases that DO populate OUT tables.
        local data=frame.data or out.Data
        assert(X.H.valid(data),'native GetMapButtonData POST frame unavailable')
        if info then
            dataInfo[id(data)]={info=info,quantity=FText(Info.label(info)),details=FText(api.details(info))}
        end
        return data
    end
    function api.captureNative(w,data,flags)
        local items=X.values(data)
        nativeLists[id(w)]={items=items,flags=X.values(flags)}
        -- Native stock cards are usable immediately, before any snapshot/job.
        for _,item in ipairs(items) do
            local map=X.read(item,'MapData')
            local info=map and Info.original(X.text(X.read(map,FILE)))
            if info then dataInfo[id(item)]={info=info,quantity=FText(Info.label(info)),details=FText(api.details(info))} end
        end
    end
    function api.listJob(w)
        -- Family/variant rows are an Objective-only replacement. Creative owns
        -- native original-world cards and its separate saved-layout category.
        if not X.H.valid(w) or not X.H.valid(w.NextMatchOptions) or not S.isObjective(w.NextMatchOptions)
            or not X.H.valid(w.TileViewManager) then return function() return true end end
        local key=id(w);local options=w.NextMatchOptions;local view=views.list[key];local worldEpoch=X.Lifetime.epoch
        local category=w.CurrentMapCategory;local editable=w.MenuState==1;local version=published
        local gi=X.gi(w);if not X.H.valid(gi) then return function() return true end end
        local snapshot=snapshots[id(gi)];local manager=w.TileViewManager
        local nativeList=X.read(w,'MapListTileView')
        local rows=api.rows(gi,category,w.NextMatchOptions,w.ShowAutoSave,editable)
        local record={items={},files={},category=category,editable=editable,version=version,autosaves=w.ShowAutoSave,
            widget=w,options=options,view=view,epoch=worldEpoch,gi=gi,snapshot=snapshot,manager=manager,nativeList=nativeList}
        local file=w.NextMatchOptions.CustomMapSelected and X.text(X.field(w.NextMatchOptions.LayoutData,'file'))
            or X.text(X.read(w.NextMatchOptions.MapData,FILE))
        local selectedFile=file
        -- Existing native utility entries stay rooted throughout preparation.
        -- The final native category refresh clears/repopulates the list in its
        -- single synchronous frame; no Lua-held object waits unrooted for it.
        local function current()
            -- A reused screen can change mode/tab while this job waits.
            return not X.Lifetime.transition and X.Lifetime.epoch==worldEpoch and published==version
                and X.H.valid(w) and X.H.valid(w.NextMatchOptions)
                and X.same(w.NextMatchOptions,options) and S.isObjective(w.NextMatchOptions)
                and X.H.valid(gi) and X.same(X.gi(w),gi) and snapshot and snapshots[id(gi)]==snapshot
                and X.H.valid(manager) and X.same(w.TileViewManager,manager)
                and X.H.valid(nativeList) and X.same(X.read(w,'MapListTileView'),nativeList)
                and w.CurrentMapCategory==category and (w.MenuState==1)==editable
                and w.ShowAutoSave==record.autosaves and view and views.list[id(w)]==view
        end
        return X.Work.native(function()
            if not current() then return end
            local function sameOwner(row)
                return row and row.view==view and row.version==version and row.epoch==worldEpoch
                    and row.snapshot==snapshot and X.same(row.gi,gi) and X.same(row.manager,manager)
                    and X.same(row.nativeList,nativeList)
            end
            local ready=lists[key]
            if sameOwner(ready) then return end
            local active=producers[key]
            if sameOwner(active) then return end
            -- Native factory hooks may re-enter before the cache is committed.
            -- Claim scalar ownership first; a newer view can supersede this job.
            producers[key]=record
            local function owned() return producers[key]==record and current() end
            -- A cache-miss job and a metadata-refresh job may share this view.
            -- The first completed native phase owns its publication.
            -- Create and publish in one native queue phase. No new UObject is
            -- held only by Lua across a queue boundary, and preparation never
            -- appends to the visible ListView. The native refresh clears it and
            -- consumes this exact record before this phase returns.
            local ok,err=pcall(function()
                local seen={}
                local function append(data,file,key)
                    if key and seen[key] then return end
                    if key then seen[key]=true end
                    record.items[#record.items+1]=data;record.files[#record.files+1]=file
                end
                for _,row in ipairs(rows) do
                    if not owned() then return end
                    local layout=row.layout or X.asset(MAP..'B_MapButtonData.B_MapButtonData_C'):GetCDO().LayoutData
                    local file=row.layout and X.text(X.field(row.layout,'file')) or X.text(X.read(row.original or row.map,FILE))
                    -- Filenames/paths identify maps and authored layouts. Display
                    -- names and object addresses never collapse distinct layouts.
                    local key=row.layout and ('layout:'..base(row.layout)..':'..tostring(X.Preflight.path(gi,row.layout) or file))
                        or ('map:'..file)
                    if not seen[key] then
                        local item=api.button(w,file==selectedFile,row.map,layout,row.info)
                        append(item,file,key)
                    end
                end
                local native=nativeLists[key]
                for _,data in ipairs(category==0 and native and native.items or {}) do
                    local file=X.text(X.read(X.read(data,'MapData'),FILE))
                    if not knownMaps[file] then
                        -- Preserve native utility items without inventing identity
                        -- for entries that carry no map filename.
                        local key=file~='' and file~='None' and file~='nil' and ('map:'..file) or nil
                        append(data,file,key)
                    end
                end
                if not owned() then return end
                lists[key]=record
                local button=X.read(w,'CurrentCategoryButton')
                -- WB_MapList's own SetMenuState/UpdateByAutosaveSetting pass None.
                -- Its parent UpdateCategoryContent accepts the same native route.
                w:UpdateCategoryContent(X.H.valid(button) and button or nil,view.salvage)
            end)
            if producers[key]==record then producers[key]=nil end
            if not ok then if lists[key]==record then lists[key]=nil end;error(err) end
        end)
    end
    function api.list(w)
        local key=id(w);local r=lists[key]
        if r and r.version==published and r.category==w.CurrentMapCategory and r.editable==(w.MenuState==1)
            and r.autosaves==w.ShowAutoSave and r.epoch==X.Lifetime.epoch and r.view==views.list[key]
            and X.same(r.widget,w) and X.same(r.options,w.NextMatchOptions) and S.isObjective(w.NextMatchOptions)
            and X.H.valid(r.gi) and X.same(X.gi(w),r.gi) and r.snapshot==snapshots[id(r.gi)]
            and X.H.valid(r.manager) and X.same(w.TileViewManager,r.manager)
            and X.H.valid(r.nativeList) and X.same(X.read(w,'MapListTileView'),r.nativeList) then
            local valid=true;for _,item in ipairs(r.items) do if not X.H.valid(item) then valid=false;break end end
            if valid then return r end
            lists[key]=nil
        end
        local gi=X.gi(w)
        if not snapshots[id(gi)] then return end
        X.Work.submit('maps:tiles:'..key,'maps/tiles',api.listJob(w))
    end
    function api.voteLabel(w,label)
        local key=id(w); local quantity=FText(label)
        buttons[key]={quantity=quantity,details=quantity}
        -- SetButtonParameters has already copied its OUT value into GridButton.
        -- Quantity on MapButton itself is a function OUT, not a widget property.
        local grid=X.read(w,'GridButton')
        if X.H.valid(grid) then grid.Quantity=quantity; grid.bShowQuantity=true end
    end
    function api.quantity(info)
        return Info.quantity(info)
    end
    function api.details(info)
        return 'Cauldrons to win / total: '..api.quantity(info)..
            ''..
            (info.stock and '\nOriginal Fill a Pot map' or '\nWitch respawn markers: '..tostring(info.respawns)..'')
    end
    local function bind(self)
        local w=self:get(); local key=id(w); buttons[key]=nil
        if not objectiveScreen and not creativeScreen then return end
        local source=X.read(w,'ItemData') or w
        local layout=X.read(source,'LayoutData'); local map=X.read(source,'MapData'); local info
        local gi=X.gi(w)
        if creativeScreen then
            -- Saved Featured exports can use a generic Creative base. Describe
            -- that route without changing the user's layout, preview or target.
            -- Never infer missing user-authored structures from the filename.
            local origin=layout and api.origin(gi,layout)
            local family=origin and D.families[origin.family]
            if family and family.tab==2 and base(layout)~=leaf(family.world) then
                buttons[key]={quantity=FText('Saved copy'),details=FText('Saved map. Scenery from the original Featured map is not included.')}
            end
            return
        end
        local sourceId=address(source); info=sourceId and dataInfo[sourceId]
        if info then buttons[key]=info;return -- Catalog tile carries its own goal/total observation.
        elseif layout and X.text(X.field(layout,'file'))~='' and X.text(X.field(layout,'file'))~='nil' then
            local _,_,observed=S.inspect(gi,layout); info=observed
        elseif map and X.read(map,OBJECTIVE)==true then
            local snapshot=snapshots[id(gi)];local group=snapshot and snapshot.data.byMap and snapshot.data.byMap[X.text(X.read(map,FILE))]
            info=group and group.originalInfo or Info.original(X.text(X.read(map,FILE)))
        end
        if info and not info.unknown and info.pots>0 then
            buttons[key]={quantity=FText(Info.label(info)),details=FText(api.details(info))}
        end
    end
    for _,asset in ipairs({'WB_MapButton','WB_MapListButton'}) do
        hook(MAP,asset,'SetIndividualParameters',bind)
        hook(MAP,asset,'GetQuantityVisibility',function(self,out)
            if address and buttons[address(self:get())] then out:set(true) end
        end)
    end
    hook(MAP,'WB_MapButton','GetQuantityText',function(self,out)
        local r=address and buttons[address(self:get())]
        if r then out:set(r.quantity) end
    end)
    hook(MAP,'WB_MapButton','GetPlayernumberText',function(self)
        -- ReturnValue is the hook result, not a callback OUT argument.
        local r=address and buttons[address(self:get())]; if r then return r.quantity end
    end)
    hook(MAP,'WB_MapListButton','GetMapFileName',function(self,valid,file)
        if not objectiveScreen then return end
        local w=self:get(); local data=X.read(w,'ItemData') or w
        local layout=X.read(data,'LayoutData'); local name=layout and X.field(layout,'file')
        if name and X.text(name)~='' and X.text(name)~='None' then
            file:set(X.text(name)); valid:set(true)
        else
            local key=address and address(data); local info=key and dataInfo[key]
            if info and info.info.originalFile then file:set(info.info.originalFile); valid:set(true) end
        end
    end)
    hook(MAP,'WB_MapListButton','GetTooltip',function(self,out)
        local r=address and buttons[address(self:get())]; local tip=out:get()
        if (objectiveScreen or creativeScreen) and r and X.H.valid(tip) then
            tip.Playernumber=r.quantity; tip.Instructions=r.details
            local label=X.read(tip,'PlayernumberText'); if X.H.valid(label) then label:SetText(r.quantity); label:SetVisibility(4) end
            local instructions=X.read(tip,'MapCycleInstructions')
            if X.H.valid(instructions) then instructions:SetText(r.details); instructions:SetVisibility(4) end
        elseif X.H.valid(tip) and X.read(tip,'Playernumber')~=nil then
            -- The text bindings were replaced on our previous tooltip use.
            local label=X.read(tip,'PlayernumberText'); if X.H.valid(label) then label:SetText(tip.Playernumber) end
            local instructions=X.read(tip,'MapCycleInstructions'); if X.H.valid(instructions) then instructions:SetText(tip.Instructions) end
        end
    end)
    function api.observeList(w,salvage)
        assert(type(salvage)=='number','native SalvageCategory byte required')
        local key=id(w);local prior=views.list[key];local options=w.NextMatchOptions
        local mode=X.read(options,'GameMode')
        local modeName=X.H.valid(mode) and mode:GetFName():ToString() or ''
        local category=w.CurrentMapCategory;local editable=w.MenuState==1;local autosaves=w.ShowAutoSave
        -- Selection and Catalog both observe the same native list event. Keep
        -- its token stable unless the actual view changed, not on every callback.
        if prior and X.same(prior.widget,w) and X.same(prior.options,options) and prior.mode==modeName
            and prior.category==category and prior.editable==editable and prior.autosaves==autosaves
            and prior.salvage==salvage then return end
        views.list[key]={widget=w,salvage=salvage,options=options,mode=modeName,
            category=category,editable=editable,autosaves=autosaves}
    end
    function api.screen(w)
        objectiveScreen=S.isObjective(w.NextMatchOptions)
        local mode=X.read(w.NextMatchOptions,'GameMode')
        creativeScreen=not objectiveScreen and X.H.valid(mode) and mode:GetFName():ToString()=='B_CreativeGameMode_C'
        if not objectiveScreen then buttons={}; combos={} end
    end
    for _,fn in ipairs({'Construct','InitializeMenu','SetMenuState'}) do hook(MAP,'WB_MapList',fn,function(self) api.screen(self:get()) end) end
    -- Cache the native tab visibility rule on screen events; the binding
    -- performs no per-frame options or game-instance lookup.
    function api.variants(group)
        local rows={}; local labels={}
        for _,v in ipairs(group.variants) do
            local label=v.origin.label..(v.origin.season~='None' and ' - '..v.origin.season or '')
            labels[label]=(labels[label] or 0)+1
        end
        if group.original then
            local label=leaf(X.text(X.read(group.original,FILE)))=='LibraryHalloween' and 'Original - Halloween' or 'Original'
            rows[#rows+1]={label=label,map=group.original}
        end
        for _,v in ipairs(group.variants) do
            local label=v.origin.label..(v.origin.season~='None' and ' - '..v.origin.season or '')
            if labels[label]>1 then label=label..' ('..leaf(v.file):gsub('%.pl$','')..')' end
            rows[#rows+1]={label=label,file=v.file,season=v.origin.season}
        end
        if #group.variants>1 then
            -- Random pools are separated by actual authored season. Never pick an
            -- arbitrary event overlay or a map without cauldron markers.
            local pools={}
            for _,v in ipairs(group.variants) do
                local season=v.origin.season; pools[season]=pools[season] or {}; pools[season][#pools[season]+1]=v.file
            end
            local seasons={}; for season in pairs(pools) do seasons[#seasons+1]=season end; table.sort(seasons)
            for _,season in ipairs(seasons) do if #pools[season]>1 then rows[#rows+1]={label='Random'..(season~='None' and ' - '..season or ''),pool=pools[season]} end end
        end
        return rows
    end
    local function familyFor(gi,options,catalog)
        if X.read(options,'CustomMapSelected')==true then
            local origin=api.origin(gi,options.LayoutData); return origin and catalog.families[origin.family]
        end
        local file=X.text(X.read(options.MapData,FILE))
        for _,group in pairs(catalog.families) do
            if group.original and X.text(X.read(group.original,FILE))==file then return group end
        end
    end
    api.dropdown=X.Preflight.cached(function(w)
        views.custom[id(w)]=w
        api.screen(w); combos[id(w)]=nil
        if not objectiveScreen then return end
        local gi=X.gi(w); api.request(gi,false); local options=w.NextMatchOptions
        local cycle=X.read(gi.MapManager,'CustomMapCycle')
        if X.H.valid(cycle) and #X.values(cycle.FileNames)>0 then return end
        local group=familyFor(gi,options,api.snapshot(gi)); if not group then return end
        local rows=group.choices or api.variants(group); local combo=X.read(w,'ComboBox_Layout')
        if not X.H.valid(combo) or #rows==0 then return end
        local array=combo.Options; assert(type(array)=='userdata','native combo Options unavailable')
        array:Empty(); local index=0
        for i,row in ipairs(rows) do
            array[i]=row.text or FText(row.label)
            if options.CustomMapSelected and row.file==X.text(X.field(options.LayoutData,'file')) then index=i-1 end
        end
        combo:SetOptionIndex(index); combo:SetVisibility(#rows>1 and 0 or 1)
        combos[id(w)]={rows=rows,group=group,gi=gi}
    end)
    function api.choose(gi,options,row)
        if row.map then
            S.forget(gi); options.MapData=row.map; options.CustomMapSelected=false
            options.UseCustomLayouts=false; options.SelectedLayout=-1
        else
            local file=row.file or row.pool[math.random(#row.pool)]
            S.apply(gi,options,file); options.UseCustomLayouts=false; S.remember(gi,options)
        end
    end
    hook(PLAY,'WB_Custommatch','UpdateLayoutComboBox',function(self) api.dropdown(self:get()) end)
    hook(PLAY,'WB_Custommatch','BndEvt__WB_Custommatch_ComboBox_Layout_K2Node_ComponentBoundEvent_19_OnSelectionChanged__DelegateSignature',function(self)
        local w=self:get(); local r=combos[id(w)]; if not r or not S.isObjective(w.NextMatchOptions) then return end
        local row=r.rows[w.ComboBox_Layout.SelectedOptionIndex+1]; if row then api.choose(r.gi,w.NextMatchOptions,row) end
    end)
    hook(MAP,'WB_MapListButton','SetSingleMapForNextMatch',function(self)
        local button=self:get(); local gi=X.gi(button)
        if S.isObjective(gi.NextMatchOptions) then
            local source=X.read(button,'ItemData') or button
            local layout=X.read(source,'LayoutData'); local file=layout and X.field(layout,'file')
            if not file or X.text(file)=='' or X.text(file)=='None' then
                local mapFile=X.text(X.read(X.read(source,'MapData'),FILE))
                for _,group in pairs(api.snapshot(gi).families) do
                    if group.original and X.text(X.read(group.map,FILE))==mapFile then
                        api.choose(gi,gi.NextMatchOptions,{map=group.original}); break
                    end
                end
            end
        end
        for _,w in ipairs(X.Registry.list('WB_Custommatch_C')) do
            if X.H.valid(w) and X.same(X.gi(w),gi) then api.dropdown(w) end
        end
    end)
    -- LoadLayout and SaveLayout Blueprint POST are not operation producers:
    -- they carry neither captured entry owner/revision nor actual local target.
    -- The former POST lineage copier is deliberately absent in this STAGED
    -- Native-gated composition. Current installed V13 remains unchanged.
    -- Other match modes admit only confirmed unmarked saves; deferred/unknown
    -- files wait for the next finite list build. Creative retains all layouts.
    hook(MAP,'WB_MapList','GetIndividualItemDataAndFocus',function(self,_,salvage,out,focus)
        local w=self:get(); api.observeList(w,salvage:get()); api.screen(w)
        if objectiveScreen or w.CurrentMapCategory~=1 then return end
        local mode=X.read(w.NextMatchOptions,'GameMode')
        if X.H.valid(mode) and mode:GetFName():ToString()=='B_CreativeGameMode_C' then return end
        local gi=X.gi(w); api.request(gi,w.ShowAutoSave); local items,flags={},{}; local oldflags=X.values(focus:get())
        local paths={}
        for _,layout in ipairs(S.catalog(gi,false,w.ShowAutoSave)) do
            local key=base(layout)..'/'..leaf(X.text(X.field(layout,'file')))
            paths[key]=paths[key] or {}; paths[key][#paths[key]+1]=layout
        end
        for i,item in ipairs(X.values(out:get())) do
            local layout=X.read(item,'LayoutData'); local info
            local clean=layout~=nil
            if layout then
                -- Native item data may copy a layout with only its leaf filename;
                -- use the original catalog wrappers registered with absolute keys.
                local key=base(layout)..'/'..leaf(X.text(X.field(layout,'file')))
                for _,source in ipairs(paths[key] or {layout}) do
                    local _,_,observed=S.inspect(gi,source)
                    if not observed or observed.unknown or observed.pots~=0 then clean=false; break end
                end
            end
            if clean then items[#items+1]=item; flags[#flags+1]=oldflags[i]==true end
        end
        S.publish(out,focus,items,flags)
    end)
    function api.reset() revision=revision+1; requests={}; refreshVersions={}; views={list={},custom={}}; lists={}; producers={}; nativeLists={}; snapshots={}; buttons={}; combos={};  objectiveScreen=false; creativeScreen=false;  dataInfo={} end
    X.H.hook('/Script/UMG.UserWidget:Destruct',function(self)
        if not address or (next(views.list)==nil and next(views.custom)==nil) then return end
        local key=address(self:get());views.list[key]=nil;views.custom[key]=nil;lists[key]=nil;producers[key]=nil;nativeLists[key]=nil
    end)
    -- Custom Match's combo can request a snapshot before WB_MapList.Construct
    -- populates MapManager. Observe the actual producer, including later native
    -- rebuilds; never keep that early empty snapshot or rescan in tile getters.
    local catalogScope=assert(FAPP_API.Native.scope(FAPP_API.id),'catalog native scope unavailable')
    assert(catalogScope.on_call('/Game/Blueprints/Match/B_MapManager.B_MapManager_C:SetLayoutDataByFileName','post',function(manager)
        local instances={}
        for _,request in pairs(requests) do
            if X.H.valid(request.gi) and X.same(X.read(request.gi,'MapManager'),manager) then
                instances[#instances+1]=request.gi
            end
        end
        if #instances==0 then return end -- no cached snapshot to replace yet
        revision=revision+1;requests={};snapshots={};lists={};producers={};nativeLists={};combos={};buttons={};dataInfo={}
        X.log('Catalog','native saved-map catalog updated; rebuilding Fill a Pot entries')
        for _,gi in ipairs(instances) do
            -- The finite work queue deduplicates by key. Retire old revision
            -- jobs before submitting replacements, including an unrun cold job.
            for _,prefix in ipairs({'maps:catalog:initial:','maps:catalog:','maps:metadata:','maps:catalog:refresh:'}) do
                X.Work.cancel(prefix..id(gi))
            end
            api.request(gi,true)
        end
    end),'native saved-map catalog observer unavailable')
    X.Lifetime.onReset(api.reset)
    X.Catalog=api
    return api
end
return M
