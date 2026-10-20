-- Fixed custom-layout selection and a solo harness; never force an invalid round.
local M={}
local Context=dofile(assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))..'match_context.lua')
function M.init(X)
    local H,C=X.H,X.C; local api,selected={},{}; local pending={};local expandedFiles={};local expandedStamps={}
    local MAP='/Game/UserInterface/Maps/'; local PLAY='/Game/UserInterface/Play/'
    local objective=X.OM..'B_ObjectiveGameMode.B_ObjectiveGameMode_C'
    local FILE='FileName_10_98BC71FF40A2DA9A28FA21B92157D6D9'
    local BUILTIN='IsBuiltInCustomMap_24_B260140C4981E09A0400EBBB5AF787AD'
    local function isObjective(options)
        if FAPP_MODE and not FAPP_MODE.optionPlus(options) then return false end
        return H.valid(options) and H.valid(options.GameMode) and options.GameMode:GetFName():ToString()=='B_ObjectiveGameMode_C'
    end
    local function native(value,label)
        assert(type(value)=='userdata','refusing Lua table as '..label)
        return value
    end
    function api.publish(out,focus,items,flags)
        -- Data is TArray<UObject*> and FocusNeeded is TArray<bool>. Mutate the
        -- native OUT arrays; never feed Lua containers to the native setter.
        local data,needed=out:get(),focus:get()
        assert(type(data)=='userdata' and type(needed)=='userdata','native map-list OUT arrays required')
        assert(#items==#flags,'map-list data/focus length mismatch')
        for i,item in ipairs(items) do assert(H.valid(item) and type(flags[i])=='boolean','invalid native map-list item') end
        data:Empty();needed:Empty()
        for i,item in ipairs(items) do data[i]=item;needed[i]=flags[i] end
    end
    function api.resolve(gi,file)
        local entry=X.Catalog and X.Catalog.lookup(gi,file)
        if entry then return entry.layout end
        for _,layout in ipairs(api.catalog(gi,false,true)) do
            if X.text(X.field(layout,'file'))==file then return layout end
        end
        error('saved layout no longer catalogued: '..file)
    end
    local function mapFor(gi,layout)
        local level=X.text(X.field(layout,'map')); local mm=gi.MapManager; local found
        -- Struct out params of BP functions come back empty through UE4SS in-game,
        -- so read MapManager's TMaps directly (same lookup GetSpecificMapFromLevelName does).
        pcall(function() X.read(mm,'MapDataByLevelName'):ForEach(function(k,v)
            if not found and X.text(X.get(k))==level then found=v:get() end end) end)
        if not found then pcall(function() X.read(mm,'MapDataByFileName'):ForEach(function(_,v)
            if found then return end
            local d=v:get(); local f=X.text(X.read(d,FILE))
            local leaf=f:match('([^/%.]+)$') or f
            if leaf==level or f:match('/'..level..'%.'..level..'$') then found=d end
        end) end) end
        assert(found,'layout base map not resolved: '..level); return found
    end
    function api.catalog(gi,builtin,autosaves,unexpanded)
        local mm=gi.MapManager; local direct={}
        if builtin then
            for _,key in ipairs({'SmallBuiltInCustomMapList','BigBuiltInCustomMapList'}) do
                for _,map in ipairs(X.values(X.read(mm,key))) do direct[#direct+1]=map end
            end
        else
            local raw=X.read(mm,'LayoutDataByFileName')
            local function append(value,key)
                local layout=X.get(value); local name=X.text(X.field(layout,'name'))
                if key then X.Preflight.register(layout,key) end
                if autosaves==true or not name:find('_AutoSave$') then direct[#direct+1]=layout end
            end
            if raw then
                if type(raw)=='table' and not raw.ForEach then for k,v in pairs(raw) do append(v,k) end
                else raw:ForEach(function(k,v) append(v,k) end) end
            end
        end
        if not builtin and not unexpanded and api.expandRecords then
            if X.Preflight.cacheOnly() then
                local expanded={};local seen={}
                for _,layout in ipairs(direct) do
                    for _,entry in ipairs(expandedFiles[X.Preflight.path(gi,layout)] or {layout}) do
                        local file=X.text(X.field(entry,'file'))
                        if not seen[file] then expanded[#expanded+1]=entry;seen[file]=true end
                    end
                end
                direct=expanded
            else direct=api.expandRecords(gi,direct) end
        end
        X.once('catalog:'..tostring(builtin),'Selection','property catalog: '..#direct..' entries')
        return direct
    end
    function api.indexRecords(gi,layout,info,completed)
        local path=X.Preflight.path(gi,layout)
        if expandedFiles[path] and info and expandedStamps[path]==info.stamp then completed(false);return end
        if not info or not info.records or #info.records<=1 then
            local changed=expandedFiles[path]~=nil
            expandedFiles[path]=nil;expandedStamps[path]=nil;completed(changed);return
        end
        local expanded={};local jobs={}
        for index,record in ipairs(info.records) do if record.pots>0 then
            jobs[#jobs+1]=X.Preflight.materializeJob(gi,layout,index,record,function(entry)
                if X.Catalog then X.Catalog.origin(gi,entry) end
                expanded[#expanded+1]=entry
            end)
        end end
        jobs[#jobs+1]=function()
            expandedFiles[path]=expanded;expandedStamps[path]=info.stamp;completed(true);return true
        end
        X.Work.submit('maps:records:'..path,'maps/records',X.Work.sequence(jobs))
    end
    function api.expandRecords(gi,layouts)
        local expanded={}
        X.Preflight.beginScan()
        for _,layout in ipairs(layouts) do
            local records=X.Preflight.records(gi,layout)
            if records and #records>1 then
                for index,info in ipairs(records) do
                    if info.pots>0 then local concrete=X.Preflight.materialize(gi,layout,index); expanded[#expanded+1]=concrete end
                end
            else expanded[#expanded+1]=layout end
        end
        X.Preflight.endScan()
        local unique,seen={},{}
        for _,layout in ipairs(expanded) do local file=X.text(X.field(layout,"file")); if not seen[file] then unique[#unique+1]=layout; seen[file]=true end end
        return unique
    end
    api.mapFor=mapFor; api.isObjective=isObjective
    function api.inspect(gi,layout) return X.Preflight.inspect(gi,layout) end
    function api.official(gi)
        local found
        local maps=X.read(gi.MapManager,'MapDataByFileName')
        if maps then pcall(function() maps:ForEach(function(_,v)
            local map=v:get()
            if not found and X.read(map,'UsedInObjectiveMode_16_14EC3F034A60C0E1B05A6499D0923C6F')==true
                and X.read(map,BUILTIN)~=true then found=map end
        end) end) end
        if not found then for _,map in ipairs(X.values(gi.MapManager.QuickmatchMapList)) do
            if X.read(map,'UsedInObjectiveMode_16_14EC3F034A60C0E1B05A6499D0923C6F')==true
                and X.read(map,BUILTIN)~=true then found=map; break end
        end end
        return found
    end
    function api.fallback(gi,options,why)
        local map=api.official(gi); assert(map,'no official Objective fallback: '..tostring(why))
        options.MapData=native(map,'SMapData'); options.CustomMapSelected=false; options.SelectedLayout=-1
        selected[gi:GetAddress()]=nil
        X.log('Selection','Fill a Pot selection unavailable: '..tostring(why));X.message(gi,'Could not open this map. Using an official map.')
    end
    function api.apply(gi,options,file)
        local entry=X.Catalog and X.Catalog.lookup(gi,file)
        local layout=entry and entry.layout or api.resolve(gi,file)
        local valid,why=api.inspect(gi,layout); assert(valid,why)
        options.MapData=native(entry and entry.map or mapFor(gi,layout),'SMapData')
        options.LayoutData=native(layout,'S_PropLayoutData')
        options.CustomMapSelected=true; options.SelectedLayout=-1
        if X.ModSync then
            for _,gm in ipairs(X.findAll('B_ObjectiveGameMode_C')) do X.ModSync.warn(gm,layout,gi) end
        end
        return layout
    end
    local function rememberLayout(gi,layout,map)
        local file=X.text(X.field(layout,'file'));local entry=X.Catalog and X.Catalog.lookup(gi,file)
        -- Prefer native catalog storage, which outlives a menu/options copy.
        if entry then layout=entry.layout;map=entry.map end
        if FAPP_TEST_NO_THROTTLE and type(map)~='userdata' then map=mapFor(gi,layout) end
        return {gi=gi,file=file,layout=layout,map=map}
    end
    local function cache(gi,options)
        if not isObjective(options) then selected[gi:GetAddress()]=nil; return end
        if options.CustomMapSelected then
            if api.inspect(gi,options.LayoutData) then selected[gi:GetAddress()]=rememberLayout(gi,options.LayoutData,options.MapData) end
        elseif X.read(options.MapData,BUILTIN)==true then
            if X.Preflight.builtin(gi,options.MapData) then selected[gi:GetAddress()]={gi=gi,builtin=X.text(X.read(options.MapData,FILE)),map=options.MapData} end
        else selected[gi:GetAddress()]=nil end
    end
    api.remember=cache
    X.Preflight.onInvalidate(function() selected={} end) -- native catalog storage may be rebuilt
    function api.forget(gi) selected[gi:GetAddress()]=nil end
    local function restore(gi,options)
        local r=selected[gi:GetAddress()]
        if not r or not X.same(r.gi,gi) or not isObjective(options) then return end
        -- These native structs are the selection captured on the native event,
        -- not a catalogue search or another file stamp check on visibility.
        if r.map then
            options.MapData=native(r.map,'SMapData')
            if r.layout then options.LayoutData=native(r.layout,'S_PropLayoutData') end
            options.CustomMapSelected=r.layout~=nil; options.SelectedLayout=-1
        end
    end
    X.hook('Selection',MAP,'WB_MapList','GetIndividualItemDataAndFocus',X.Preflight.cached(function(self,_,salvage,out,focus)
        local w=self:get()
        X.once('selection-entry:'..tostring(w.CurrentMapCategory)..tostring(isObjective(w.NextMatchOptions)),'Selection',
            'map list category='..tostring(w.CurrentMapCategory)..' objective='..tostring(isObjective(w.NextMatchOptions)))
        local creative=H.valid(w.NextMatchOptions) and H.valid(w.NextMatchOptions.GameMode)
            and w.NextMatchOptions.GameMode:GetFName():ToString()=='B_CreativeGameMode_C'
        if not isObjective(w.NextMatchOptions) and not (creative and w.CurrentMapCategory==2) then return end
        local category=w.CurrentMapCategory; if category~=0 and category~=1 and category~=2 then return end
        if creative and category~=2 then return end
        local gi=X.gi(w); local items,flags={},{}
        if X.Catalog then X.Catalog.request(gi,w.ShowAutoSave) end
        local rows
        if isObjective(w.NextMatchOptions) and X.Catalog then
            X.Catalog.screen(w)
            if not FAPP_TEST_NO_THROTTLE then
                X.Catalog.observeList(w,salvage:get())
                X.Catalog.captureNative(w,out:get(),focus:get())
                local cached=X.Catalog.list(w)
                if cached then
                    local file=w.NextMatchOptions.CustomMapSelected and X.text(X.field(w.NextMatchOptions.LayoutData,'file'))
                        or X.text(X.read(w.NextMatchOptions.MapData,FILE))
                    local flags={}
                    -- Cached item data outlives tile widgets: native Initialize turns IsInitial
                    -- into IsSelected, so a stale IsSelected must be cleared on every publish.
                    for i,item in ipairs(cached.items) do flags[i]=cached.files[i]==file;item.IsInitial=flags[i];item.IsSelected=false end
                    api.publish(out,focus,cached.items,flags)
                end
                return
            end
            rows=X.Catalog.rows(gi,category,w.NextMatchOptions,w.ShowAutoSave,w.MenuState==1)
        end
        local catalog=rows or api.catalog(gi,category==2,w.ShowAutoSave)
        for _,item in ipairs(catalog) do
          local okItem,itemErr=pcall(function()
            local allowed,why
            if rows then allowed=true
            elseif category==2 then
                if creative then allowed=true else allowed,why=X.Preflight.builtin(gi,item) end
            else allowed,why=api.inspect(gi,item) end
            if not allowed then return end
            local current,map,layout
            if rows then
                map=item.map
                layout=item.layout or X.asset(MAP..'B_MapButtonData.B_MapButtonData_C'):GetCDO().LayoutData
                current=item.layout and w.NextMatchOptions.CustomMapSelected and
                    X.text(X.field(w.NextMatchOptions.LayoutData,'file'))==X.text(X.field(item.layout,'file')) or
                    (not item.layout and not w.NextMatchOptions.CustomMapSelected and
                    X.text(X.read(w.NextMatchOptions.MapData,FILE))==X.text(X.read(item.original or map,FILE)))
            elseif category==2 then
                -- GetBuiltInMaps returns SMapData, NOT S_PropLayoutData.
                map=item; layout=X.asset(MAP..'B_MapButtonData.B_MapButtonData_C'):GetCDO().LayoutData
                current=not w.NextMatchOptions.CustomMapSelected and
                    X.text(X.read(w.NextMatchOptions.MapData,FILE))==X.text(X.read(item,FILE))
            else
                layout=item; map=mapFor(gi,item)
                current=X.text(X.field(w.NextMatchOptions.LayoutData,'file'))==X.text(X.field(item,'file'))
                    and w.NextMatchOptions.CustomMapSelected
            end
            local data=X.Catalog.button(w,current==true,native(map,'SMapData'),native(layout,'S_PropLayoutData'),rows and item.info or nil)
            items[#items+1]=data; flags[#flags+1]=current==true
          end)
          if not okItem then X.once('item:'..tostring(itemErr),'Selection','skipped layout: '..tostring(itemErr)) end
        end
        if category==0 then
            -- Preserve native utility entries such as RandomMapCycle.
            local oldFlags=X.values(focus:get())
            for i,data in ipairs(X.values(out:get())) do
                local file=X.text(X.read(X.read(data,'MapData'),FILE))
                local known=false
                for _,f in pairs(X.Catalog.data.families) do
                    for _,path in ipairs(f.bases) do if file==path or file==(path:match('([^/]+)$')) then known=true; break end end
                    if known then break end
                end
                if not known then items[#items+1]=data; flags[#flags+1]=oldFlags[i]==true end
            end
        end
        api.publish(out,focus,items,flags); X.log('Selection','custom category '..category..' entries='..#items)
    end))
    X.hook('Selection',MAP,'WB_MapListButton','SetSingleMapForNextMatch',X.Preflight.cached(function(self)
        local w=self:get(); local gi=X.gi(w)
        -- ChangeMenu runs inside the native body; the new screen can clear options
        -- before this post hook. Recover the button's original reflected selection.
        if isObjective(gi.NextMatchOptions) then
            local data=X.read(w,'ItemData'); local source=data or w
            local layout=X.read(source,'LayoutData'); local map=X.read(source,'MapData')
            local file=layout and X.field(layout,'file')
            if file and X.text(file)~='' and X.text(file)~='None' then
                local allowed,why=api.inspect(gi,layout)
                if allowed then selected[gi:GetAddress()]=rememberLayout(gi,layout,map)
                else X.log('Selection','Layout cannot start Fill a Pot: '..tostring(why));X.message(w,'This map cannot start Fill a Pot. Open it in Creative and check map problems.') end
            elseif map and X.read(map,BUILTIN)==true then
                if X.Preflight.builtin(gi,map) then selected[gi:GetAddress()]={gi=gi,builtin=X.text(X.read(map,FILE)),map=map}
                else api.fallback(gi,gi.NextMatchOptions,'Featured map has no cauldron markers') end
            elseif map then selected[gi:GetAddress()]=nil
            else cache(gi,gi.NextMatchOptions) end
            restore(gi,gi.NextMatchOptions)
        end
        if isObjective(gi.NextMatchOptions) and gi.NextMatchOptions.CustomMapSelected then
            local valid,why=api.inspect(gi,gi.NextMatchOptions.LayoutData)
            if not valid then api.fallback(gi,gi.NextMatchOptions,why) end
        end
    end))
    X.hook('Selection',PLAY,'WB_Custommatch','StoreReferences',X.Preflight.cached(function(self)
        -- Construct calls this before UpdateWidgetVisibility clears CustomMapSelected.
        local w=self:get(); cache(X.gi(w),w.NextMatchOptions)
    end))
    X.hook('Selection',PLAY,'WB_Custommatch','ForceObjectiveMap',X.Preflight.cached(function(self)
        local w=self:get(); local gi=X.gi(w)
        if isObjective(w.NextMatchOptions) and w.NextMatchOptions.CustomMapSelected then cache(gi,w.NextMatchOptions) end
        restore(gi,w.NextMatchOptions)
    end))
    X.hook('Selection',PLAY,'WB_Custommatch','UpdateWidgetVisibility',X.Preflight.cached(function(self)
        local w=self:get(); local gi=X.gi(w)
        restore(gi,w.NextMatchOptions); restore(gi,gi.CustomMatchOptions)
    end))
    -- Native Create/Reset/Save/Load cycle controls work unchanged once the
    -- special-mode visibility gate and category edit flag are corrected.
    local function setCycleVisibility(self)
        local w=self:get()
        local featured=X.read(w,'Button_UserMaps')
        if H.valid(featured) then
            -- Native UMG collapses this tab in Creative although category 2
            -- already publishes original-world MapData. Set the widget property
            -- on screen events, breaking the old visibility binding; no Tick hook.
            local mode=X.read(w.NextMatchOptions,'GameMode')
            local creative=H.valid(mode) and mode:GetFName():ToString()=='B_CreativeGameMode_C'
            featured:SetVisibility(creative and 0 or w:Get_Button_UserMaps_Visibility_0())
        end
        if H.valid(w.CreateMapCycle) then
            local visibility=isObjective(w.NextMatchOptions) and (w.MenuState==0 and 0 or 1) or w:Get_CreateMapCycle_Visibility_0()
            w.CreateMapCycle:SetVisibility(visibility)
        end
    end
    for _,fn in ipairs({'Construct','InitializeMenu','SetMenuState'}) do
        X.hook('Selection',MAP,'WB_MapList',fn,setCycleVisibility)
    end
    X.hook('Selection',MAP,'WB_MapList','InitializeMenu',function(self)
        local w=self:get(); if not isObjective(w.NextMatchOptions) then return end
        local gi=X.gi(w); local cycle=gi.MapManager.CustomMapCycle
        if H.valid(cycle) and #X.values(cycle.FileNames)>0 then w:SetMenuState(1) end
    end)
    X.hook('Selection','/Game/Blueprints/Match/','B_MapManager','UpdateNextMapFromCustomMapCycle',function(self,options)
        local mm=self:get(); local o=options:get(); if not isObjective(o) then return end
        local gi=Context.instance(mm,'MapManager'); if not H.valid(gi) then return end
        local gs=X.gameplay():GetGameState(gi)
        if H.valid(gs) and not H.authority(gs) then return end
        local files=X.values(mm.CustomMapCycle.FileNames)
        -- Saved cycle files may have been edited/deleted since the cycle was made.
        -- Skip unusable members through the native filename/order path, not TArray writes.
        if api.cycleBusy then return end
        local function usable()
            if o.CustomMapSelected then return api.inspect(gi,o.LayoutData) end
            return X.read(o.MapData,'UsedInObjectiveMode_16_14EC3F034A60C0E1B05A6499D0923C6F')==true and X.read(o.MapData,BUILTIN)~=true
        end
        local valid,why=usable()
        if not valid then
            api.cycleBusy=true
            local random=mm.CustomMapCycle.RandomOrder
            mm.CustomMapCycle.RandomOrder=false -- bounded walk visits each remaining filename, even in a random cycle
            local ok,err=pcall(function()
                for _=1,#files do mm:UpdateNextMapFromCustomMapCycle(o); valid,why=usable(); if valid then break end end
            end)
            mm.CustomMapCycle.RandomOrder=random; api.cycleBusy=false; if not ok then error(err) end
        end
        if valid then
            if o.CustomMapSelected then api.apply(gi,o,X.text(X.field(o.LayoutData,'file'))) end
            cache(gi,o); X.log('Cycle','native next layout/map accepted')
        else
            -- Do not leave a deleted/unmarked layout selected for the next travel.
            local fallback
            for _,map in ipairs(X.values(mm.QuickmatchMapList)) do
                if X.read(map,'UsedInObjectiveMode_16_14EC3F034A60C0E1B05A6499D0923C6F')==true then fallback=map; break end
            end
            assert(fallback,'cycle unusable and no official Objective fallback')
            o.MapData=native(fallback,'SMapData'); o.CustomMapSelected=false; selected[gi:GetAddress()]=nil
            X.log('Selection','Fill a Pot cycle has no usable maps: '..tostring(why));X.message(gi,'No playable maps in this cycle. Using an official map.')
        end
    end)
    function api.start(name,mode)
        if not C.CreativeMaps then X.log('Harness','CreativeMaps is disabled'); return false end
        local gi
        for _,o in ipairs(X.findAll('B_GameInstance_C') or {}) do if X.live(o) then
            local gm=X.gameplay():GetGameMode(o); local gs=X.gameplay():GetGameState(o)
            if (not H.valid(gs) or H.authority(gs)) and (not H.valid(gm) or H.authority(gm)) then gi=o; break end
        end end
        assert(gi,'no local menu/listen-host GameInstance (clients cannot launch matches)')
        if mode=='creative' then
            assert(X.Featured,'Featured viewer unavailable')
            if name=='list' then X.Featured.list(gi);return true end
            return X.Featured.start(gi,name)
        end
        gi.MapManager:SetLayoutDataByFileName() -- rescan saves made during this session
        local matches={}
        for _,layout in ipairs(api.catalog(gi,false,false)) do
            if X.text(X.field(layout,'name'))==name then matches[#matches+1]=layout end
        end
        assert(#matches==1,#matches==0 and 'saved layout not found: '..name or 'ambiguous layout name; rename it uniquely')
        local layout=matches[1]; local usable,why=api.inspect(gi,layout)
        if not usable then X.log('Selection','Cannot start Fill a Pot: '..why);X.message(gi,'This map cannot start Fill a Pot. Open it in Creative and check map problems.'); return false end
        local options=gi.NextMatchOptions
        assert(H.valid(options),'NextMatchOptions missing; open Custom Match once before using the harness')
        options.GameMode=X.asset(objective); options.IsTournamentMode=false
        options.MapData=native(mapFor(gi,layout),'SMapData'); options.LayoutData=native(layout,'S_PropLayoutData')
        options.CustomMapSelected=true; options.SelectedLayout=-1
        cache(gi,options)
        -- OpenMatchByOptions needs UsedMatchOptions to point at this very object:
        -- the base-level picker reads it on BeginPlay to load the requested layout.
        gi.UsedMatchOptions=options; gi.IsCustomMatch=true
        if FAPP_MODE then FAPP_MODE.select(gi,options,true); FAPP_MODE.commit(gi,options) end
        gi:SetIsCurrentlyInMatch(true)
        X.log('Harness','starting Fill a Pot layout '..name..'; use normal team selection + Ready')
        gi:OpenMatchByOptions(options)
        return true
    end
    if type(FAPP_SERVICES.runtime.command)=='function' then
        function api.command(args,output)
            local action=args[1]
            local emit=X.queueReply or X.log
            if (action=='start' or action=='creative') and #args>=2 then
                local pieces={}; for i=2,#args do pieces[#pieces+1]=args[i] end
                local name=table.concat(pieces,' ')
                -- Command handler returns synchronously; UObject work is scheduled on game thread.
                pending[#pending+1]={name=name,mode=action} -- consumed on game thread
            elseif action=='check' then
                -- Use the console's borrowed OutputDevice synchronously. This
                -- read-only check neither launches nor queues a match.
                if X.Check then
                    if X.command then X.command(X.Check.check,output) else X.Check.check(output) end
                end
            elseif action=='resultpreview' then
                pending[#pending+1]={resultpreview=true}
            elseif action=='barpreview' then
                pending[#pending+1]={barpreview=true,n=args[2],filled=args[3]}
            elseif action=='resync' then
                pending[#pending+1]={resync=true}
            elseif action=='refresh' then
                pending[#pending+1]={refresh=true}
            elseif action=='status' then
                pending[#pending+1]={status=true}
            else
                emit('Harness','usage: fapmaps start <saved layout> | fapmaps creative <Featured name|list> | fapmaps check | fapmaps resync | fapmaps refresh | fapmaps status | fapmaps barpreview <N> <filled> (or off) | fapmaps resultpreview')
                if output then pcall(function() output:Log('fapmaps start <saved layout> | fapmaps creative <Featured name|list> | fapmaps check | fapmaps resync | fapmaps refresh | fapmaps status | fapmaps barpreview <N> <filled> (or off) | fapmaps resultpreview') end) end
            end
            return true
        end
        FAPP_SERVICES.runtime.command('fapmaps',function(_,parameters,output) return api.command(X.values(parameters),output) end)
        X.log('Harness','registered fapmaps start <layout name> and fapmaps status')
    else X.log('Harness','FAILED FAPP_SERVICES.runtime.command unavailable') end
    function api.poll()
        local work=pending; pending={}
        local emit=X.queueReply or X.log
        for _,r in ipairs(work) do
            if r.resultpreview then
                local function preview()
                    assert(H.resultpreview,'WIN2 module unavailable')
                    emit('WIN2',H.resultpreview())
                end
                if X.command then X.command(preview) else X.guard('WIN2/preview',preview)() end
            elseif r.barpreview then
                local function preview()
                    assert(X.PotProgress,'BAR3 module unavailable')
                    return X.PotProgress.preview(r.n,r.filled)
                end
                if X.command then X.command(preview) else X.guard('BAR3/preview',preview)() end
            elseif r.status then
                emit('Harness',C.CreativeMaps and 'Creative maps enabled.'or 'Creative maps disabled.')
                local stages={}
                for path,stage in pairs(X.required) do
                    local c=stages[stage] or {0,0}; stages[stage]=c; c[2]=c[2]+1
                    if H.installed(path) then c[1]=c[1]+1 end
                end
                local names={} for stage in pairs(stages) do names[#names+1]=stage end; table.sort(names)
                for _,stage in ipairs(names) do local c=stages[stage]; emit('Harness',stage..': '..(c[1]==c[2]and 'Ready' or 'Loading…')) end
            elseif r.resync then
                X.guard('Registry/resync',X.Registry.resync)('console')
                emit('Harness','Map objects refreshed.')
            elseif r.refresh then
                X.Preflight.invalidate()
                if X.Catalog then
                    for _,gi in ipairs(X.Registry.list('B_GameInstance_C')) do
                        if H.valid(gi) then X.Catalog.request(gi,true) end
                    end
                end
                emit('Harness','Refreshing saved maps…')
            elseif X.command then X.command(api.start,r.name,r.mode)
            else X.guard('Harness/start',api.start)(r.name,r.mode) end
        end
        for id,r in pairs(selected) do if not X.live(r.gi) or not C.CreativeMaps then selected[id]=nil end end
    end
    function api.pending() return #pending>0 end
    X.Selection=api
    dofile(assert(debug.getinfo(1,"S").source:match("^@(.+[\\/])")).."maps_concrete.lua").init(X,api,dofile(assert(debug.getinfo(1,"S").source:match("^@(.+[\\/])")).."maps_layout_info.lua"))
    if FAPP_METADATA then
        FAPP_METADATA.resolve=function(gi)
            local options=gi.UsedMatchOptions
            if options.CustomMapSelected then
                X.Preflight.beginScan()
                local ok,_,info=api.inspect(gi,options.LayoutData)
                X.Preflight.endScan()
                assert(ok and info and not info.records,'selected layout metadata unavailable / unresolved records')
                return info
            end
            local info=api.currentInfo(gi); if info then return info end
            return FAPP_METADATA.forMap(X.text(X.read(options.MapData,FILE)))
        end
    end
    function api.reset() expandedFiles={}; expandedStamps={}; selected={}; pending={}; visibility={}; if X.Catalog then X.Catalog.reset() end end
    X.cachedPoll(api,function() return #pending>0 end)
    local directory=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
    dofile(directory..'maps_catalog.lua').init(X,api)
    return api
end
return M
