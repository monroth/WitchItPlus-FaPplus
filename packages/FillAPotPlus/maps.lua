return function(S)
    local R,C=S.R,S.C
    local F,L=S.F,S.L
    local definitions=dofile(S.dir..'bundles.lua')
    local metadata=C.files.read_json('FillAPotPlus/catalog.json') or {}
    local inspected={}
    local reader='/Script/PropWitchHuntModule.ProjectVersionBlueprint:'
    local function readMetadata(_,success,path,props,workshop,statics,lights,switches,prefabs)
        if not success then return end
        props,statics,prefabs=props:get(),statics:get(),prefabs:get()
        local info={pots=0,respawns=0,target=3,revision=-1,classes=0}
        local function scan(rows)
            rows:ForEach(function(_,value)
                local row=value:get();local bytes={}
                row.MaterialIndices:ForEach(function(_,byte) bytes[#bytes+1]=string.char(byte:get()) end)
                local marker=S.codec.decode(table.concat(bytes))
                local name=S.text(row.PrimaryAssetId.PrimaryAssetName):gsub('_C$','')
                if not marker or name~=S.carriers[marker.kind]:match('%.(.+)$'):gsub('_C$','') then return end
                if marker.kind==1 then
                    marker=S.codec.defaults(marker);info.pots=info.pots+1
                    if marker.revision>info.revision or marker.revision==info.revision and marker.target>info.target then
                        info.target,info.revision=marker.target,marker.revision
                    end
                elseif marker.kind==2 then info.respawns=info.respawns+1 end
            end)
        end
        scan(statics)
        prefabs:ForEach(function(_,value) scan(value:get().Structures) end)
        local counts={}
        props:ForEach(function(_,value)
            local name=S.text(value:get().PrimaryAssetId.PrimaryAssetName)
            counts[name]=(counts[name] or 0)+1
            if name~='' and counts[name]==2 then info.classes=info.classes+1 end
        end)
        metadata[S.text(path)]=info
    end
    for _,name in ipairs({'LoadPropLayoutFromFile','LoadPropLayoutFromFileCompressed'}) do R.post(reader..name,readMetadata) end
    local function inspect(file)
        if inspected[file] then return end
        inspected[file]=true
        local input=io.open(file,'rb');if not input then return end
        local header=input:read(8)
        input:close()
        local compressed=header and #header==8 and string.unpack('<I8',header)==0x222222229e2a83c1
        local library=StaticFindObject('/Script/PropWitchHuntModule.Default__ProjectVersionBlueprint')
        if compressed then library:LoadPropLayoutFromFileCompressed(file,{},{},{},{},{},{},{})
        else library:LoadPropLayoutFromFile(file,{},{},{},{},{},{},{}) end
    end
    local bundled,byId={},{}
    -- Bundled maps by id or layout file; file paths compare without case or slash style.
    local function key(file) return (file:gsub('\\','/'):lower()) end
    local function bundle(file) return byId[key(file)] end
    local manager
    local buttonClass='/Game/UserInterface/Maps/B_MapButtonData.B_MapButtonData_C'
    local function leaf(value) return value:gsub('\\','/'):match('([^/]+)$') end
    function S.baseMap(level)
        local result
        C.session().gi.MapManager.MapDataByFileName:ForEach(function(_,v)
            local map=v:get();local file=S.text(map[F.file])
            if file==level or leaf(file)==leaf(level) then result=map end
        end)
        return result
    end
    function S.registerBundles()
        local gi=C.session().gi
        local mm=gi.MapManager
        if manager==mm:GetAddress() then return end
        manager=mm:GetAddress();bundled={};byId={}
        for _,d in ipairs(definitions) do
            local file=S.dir..'bundled-maps/'..d.key..'.pl'
            local id='FAPB:'..d.key
            local holder=S.new(buttonClass,gi)
            holder.MapData=S.baseMap(d.world)
            holder.MapData[F.file]=FName(id);holder.MapData[F.name]=FText(d.name)
            holder.MapData[F.objective]=true;holder.MapData[F.builtin]=false
            holder.LayoutData[L.name]=d.name;holder.LayoutData[L.file]=file
            holder.LayoutData[L.map]=leaf(d.world);holder.LayoutData[L.type]=1
            holder.LayoutData[L.screenshot]=S.dir..'bundled-maps/'..d.preview
            local texture=StaticFindObject('/Script/PropWitchHuntModule.Default__ImageLoader'):
                LoadImageFromDisk(gi,holder.LayoutData[L.screenshot])
            if R.valid(texture) then
                holder.MapData[F.preview]=texture;mm.CustomMapTextureImages:Add(holder.LayoutData[L.screenshot],texture)
            end
            mm.MapDataByFileName:Add(id,holder.MapData);mm.LayoutDataByFileName:Add(file,holder.LayoutData)
            local row={file=file,id=id,world=d.world,name=d.name,info=d,kind='bundle'}
            bundled[#bundled+1]=row;byId[key(id)]=row;byId[key(file)]=row
        end
    end
    function S.mapData(row)
        return C.session().gi.MapManager.MapDataByFileName:Find(row.id or row.file):get()
    end
    function S.pinStock(row)
        local gi=C.session().gi
        local holder=S.new(buttonClass,gi)
        holder.MapData=S.mapData(row)
        local events=holder.MapData.MapLayouts_48_AE297EC34B13F1944AB59AA0ADAD72B1
        local keys={}
        events:ForEach(function(k) keys[#keys+1]=k:get() end)
        for _,key in ipairs(keys) do
            local entry=events:Find(key):get()
            local array=entry.Layouts_19_A000B3E94244355BDF441A9F8E04F536
            local count=array:GetArrayNum()
            if count>0 then
                local selected=array[math.random(count)]
                -- Copy before Empty; FSoftWorldReference remains an opaque native value.
                local stage=S.new(buttonClass,gi);stage.MapData=holder.MapData
                local staged=stage.MapData.MapLayouts_48_AE297EC34B13F1944AB59AA0ADAD72B1:Find(key):get()
                local target=staged.Layouts_19_A000B3E94244355BDF441A9F8E04F536
                target:Empty();target[1]=selected;events:Add(key,staged)
            end
        end
        local goals=holder.MapData[F.layouts].Layouts_19_A000B3E94244355BDF441A9F8E04F536
        if goals:GetArrayNum()>0 then
            local stage=S.new(buttonClass,gi);stage.MapData=holder.MapData
            local target=stage.MapData[F.layouts].Layouts_19_A000B3E94244355BDF441A9F8E04F536
            local selected=goals[math.random(goals:GetArrayNum())]
            target:Empty();target[1]=selected;holder.MapData=stage.MapData
        end
        return holder.MapData
    end
    function S.layoutData(row)
        S.registerBundles()
        return C.session().gi.MapManager.LayoutDataByFileName:Find(row.file):get()
    end
    function S.playable(info)
        return not info or (info.pots>=3 and info.respawns>0 and info.classes>=info.pots+1)
    end
    function S.catalogue()
        S.registerBundles()
        local pools={vanilla={},official=bundled,featured={},custom={}}
        local mm=C.session().gi.MapManager
        local seen={}
        for _,key in ipairs({'SmallMapList','BigMapList','QuickmatchMapList'}) do
            for _,map in ipairs(S.values(mm[key])) do
                local file=S.text(map[F.file])
                if map[F.objective] and not map[F.builtin] and file~='RandomMapCycle' and not seen[file] then
                    seen[file]=true
                    pools.vanilla[#pools.vanilla+1]={file=file,name=S.text(map[F.name]),kind='stock',info={pots=5,target=3}}
                end
            end
        end
        mm.LayoutDataByFileName:ForEach(function(k,v)
            local layout=v:get();local file=S.text(k:get())
            local ownFile=S.text(layout[L.file])
            if not ownFile:find('[\\/]') and file:find('[\\/]') then layout[L.file]=file end
            if not bundle(file) then inspect(file) end
            if not bundle(file) and S.playable(metadata[file]) then
                pools.custom[#pools.custom+1]={file=file,name=S.text(layout[L.name]),kind='custom',info=metadata[file]}
            end
        end)
        table.sort(pools.custom,function(a,b) return a.name==b.name and a.file<b.file or a.name<b.name end)
        return pools
    end
    function S.currentMap()
        local gi=C.session().gi;local options=gi.UsedMatchOptions
        if options.CustomMapSelected then
            local file=S.text(options.LayoutData[L.file])
            return bundle(file) or {file=file,name=S.text(options.LayoutData[L.name]),kind='custom',info=metadata[file]}
        end
        local file=S.text(options.MapData[F.file])
        return {file=file,name=S.text(options.MapData[F.name]),kind='stock',info={target=3,pots=5}}
    end
    function S.selectMap(options,row)
        if row.kind=='stock' then
            options.MapData=S.mapData(row);options.CustomMapSelected=false
            options.SelectedLayout=-1;options.UseCustomLayouts=false
        else
            local layout=S.layoutData(row)
            options.MapData=S.baseMap(row.world or S.text(layout[L.map]))
            options.LayoutData=layout;options.CustomMapSelected=true
            options.SelectedLayout=-1;options.UseCustomLayouts=false
        end
    end
    local function bundleEntry(_,gi)
        if R.valid(gi) and S.selected(gi.NextMatchOptions) then S.registerBundles() end
    end
    R.post(S.path(S.MATCH,'B_MapManager','Initialize'),bundleEntry)
    R.post(S.path(S.MATCH,'B_MapManager','SetLayoutDataByFileName'),function(mm)
        manager=nil
        if not S.selected(C.session().gi.NextMatchOptions) then return end
        S.registerBundles()
    end)
    local capture
    R.post('/Game/UserInterface/UIElements/MenuTileView/B_MenuTileViewManager.B_MenuTileViewManager_C:GetMapButtonData',
        function(_,_,_,_,_,_,out) capture=out:get() end)
    local quantities={}
    local function describe(info)
        local label=S.calc.quantity(info)
        return {label=label,details='Cauldrons to win / total: '..label..
            (info.stock and '\nOriginal Fill a Pot map' or info.respawns and '\nWitch respawn markers: '..info.respawns or '')}
    end
    local function card(w,row,current)
        local layout=row.kind=='stock' and S.asset(buttonClass):GetCDO().LayoutData or S.layoutData(row)
        local map=row.kind=='custom' and S.asset(buttonClass):GetCDO().MapData or S.mapData(row)
        capture=nil
        w.TileViewManager:GetMapButtonData(current,w,map,layout,w.MenuState==1,{})
        local data=capture
        quantities[data:GetAddress()]=row.info and describe(row.info) or nil
        return data
    end
    R.post('/Game/UserInterface/Maps/WB_MapList.WB_MapList_C:GetIndividualItemDataAndFocus',function(w,_,_,out,focus)
        if not S.selected(w.NextMatchOptions) or w.CurrentMapCategory==2 then return end
        local pools=S.catalogue()
        local items,flags={},{}
        local current=w.NextMatchOptions.CustomMapSelected and S.text(w.NextMatchOptions.LayoutData[L.file])
            or S.text(w.NextMatchOptions.MapData[F.file])
        local function add(row)
            local selected=row.file==current or row.id==current
            items[#items+1]=card(w,row,selected);flags[#flags+1]=selected
        end
        if w.CurrentMapCategory==1 then for _,row in ipairs(pools.custom) do add(row) end
        else
            for _,item in ipairs(S.values(out:get())) do
                local file=S.text(item.MapData[F.file])
                if file~='RandomMapCycle' and not bundle(file) then
                    if item.MapData[F.objective] then quantities[item:GetAddress()]=describe({target=3,pots=5,stock=true}) end
                    items[#items+1]=item;flags[#flags+1]=file==current
                end
            end
            for _,row in ipairs(bundled) do add(row) end
            if w.MenuState==0 then
                capture=nil
                local random=S.new(buttonClass,C.session().gi)
                random.MapData=C.session().gi.MapManager.RandomMapCycle;random.MapData[F.objective]=true
                w.TileViewManager:GetMapButtonData(current=='RandomMapCycle',w,random.MapData,
                    S.asset(buttonClass):GetCDO().LayoutData,false,{})
                quantities[capture:GetAddress()]={label='',details=''}
                items[#items+1]=capture;flags[#flags+1]=current=='RandomMapCycle'
            end
        end
        out:set(items);focus:set(flags)
    end)
    local function quantity(w)
        if not S.selected(StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetGameInstance(w).NextMatchOptions) then return end
        local data=w.ItemData
        return R.valid(data) and quantities[data:GetAddress()] or nil
    end
    R.post('/Game/UserInterface/Maps/WB_MapButton.WB_MapButton_C:GetQuantityText',function(w,out)
        local value=quantity(w)
        if value then out:set(FText(value.label)) end
    end)
    R.post('/Game/UserInterface/Maps/WB_MapButton.WB_MapButton_C:GetPlayernumberText',function(w)
        local value=quantity(w)
        if value then return FText(value.label) end
    end)
    for _,asset in ipairs({'WB_MapButton','WB_MapListButton'}) do
        R.post('/Game/UserInterface/Maps/'..asset..'.'..asset..'_C:GetQuantityVisibility',function(w,out)
            local value=quantity(w)
            if value then out:set(value.label~='') end
        end)
    end
    R.post('/Game/UserInterface/Maps/WB_MapListButton.WB_MapListButton_C:GetTooltip',function(w,out)
        local value=quantity(w)
        local tip=out:get()
        if not value or not R.valid(tip) then return end
        tip.Playernumber=FText(value.label);tip.Instructions=FText(value.details)
        tip.PlayernumberText:SetText(FText(value.label));tip.PlayernumberText:SetVisibility(4)
        tip.MapCycleInstructions:SetText(FText(value.details));tip.MapCycleInstructions:SetVisibility(4)
    end)
    R.post('/Game/UserInterface/Maps/WB_MapListButton.WB_MapListButton_C:SetSingleMapForNextMatch',function(w)
        local gi=StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetGameInstance(w)
        if not S.selected(gi.NextMatchOptions) then return end
        local row=bundle(S.text(w.ItemData.MapData[F.file]))
        if row then S.selectMap(gi.NextMatchOptions,row) end
        S.trace('list pick item=%s bundle=%s gi.next %s',S.text(w.ItemData.MapData[F.file]),row and row.id or '-',S.options(gi.NextMatchOptions))
    end)
    -- Leaving Fill a Pot+ drops a modpack map: other modes never load our layouts.
    S.modeChanged=function(plus,options)
        if plus then return end
        local row=bundle(S.text(options.MapData[F.file]))
        if row then options.MapData=S.baseMap(row.world) end
        if options.CustomMapSelected and bundle(S.text(options.LayoutData[L.file])) then options.CustomMapSelected=false end
        S.trace('left mode %s',S.options(options))
    end
    R.post(S.path(S.MATCH,'B_MapManager','GetSpecificMapOrCustomMapFromFileName'),function(mm,file,foundMap,foundLayout,map,layout)
        if not S.selected(C.session().gi.NextMatchOptions) then return end
        S.registerBundles()
        local row=bundle(S.text(file))
        if row then
            foundMap:set(false);foundLayout:set(true);map:set(S.baseMap(row.world));layout:set(S.layoutData(row))
        end
        S.trace('lookup file=%s bundle=%s',S.text(file),row and row.id or '-')
    end)
    R.post(S.path(S.MATCH,'B_MapManager','UpdateNextMapFromCustomMapCycle'),function(mm,options)
        if not R.valid(options) or not S.selected(options) then return end
        S.registerBundles()
        local row=bundle(S.text(options.MapData[F.file]))
        if options.CustomMapSelected then row=bundle(S.text(options.LayoutData[L.file])) end
        if row then S.selectMap(options,row) end
        S.trace('cycle update %s',S.options(options))
    end)
    R.pre(S.path(S.CORE,'B_GameInstance','OpenMatchByOptions'),function(gi)
        if not R.valid(gi) then return end
        S.trace('open match used %s next %s',S.options(gi.UsedMatchOptions),S.options(gi.NextMatchOptions))
        if not S.selected(gi.UsedMatchOptions) or not S.host() then return end
        S.registerBundles()
        local options=gi.UsedMatchOptions
        -- A picked layout decides; MapData can still name an earlier pick (user 11-04).
        local row
        if options.CustomMapSelected then row=bundle(S.text(options.LayoutData[L.file]))
        else row=bundle(S.text(options.MapData[F.file])) end
        if not options.CustomMapSelected and S.text(options.MapData[F.file])=='RandomMapCycle' then
            local pools=S.catalogue();local candidates={}
            for _,pool in ipairs({pools.vanilla,pools.official}) do for _,v in ipairs(pool) do candidates[#candidates+1]=v end end
            row=candidates[math.random(#candidates)]
        end
        if row then
            S.selectMap(options,row);gi.CurrentOpenedMap=options.MapData
            gi.CurrentOpenedRandomMap=options.MapData[F.file]
            S.trace('open match chose %s %s',row.id or row.file,S.options(options))
        end
    end)
    local function observe(info)
        local markers=S.markers();local pots,starts,target,revision=0,0,3,-1
        for _,row in ipairs(markers) do
            local d=row.info
            if d.kind==1 then
                pots=pots+1
                if d.revision>revision or (d.revision==revision and d.target>target) then target,revision=d.target,d.revision end
            elseif d.kind==2 then starts=starts+1 end
        end
        local counts,classes={},0
        for _,actor in ipairs(R.find_all('/Game/Blueprints/Props/Bases/B_StaticMeshProp.B_StaticMeshProp_C')) do
            if actor:GetClass():GetCDO().PropCategory==0 then
                local path=S.classpath(actor:GetClass());counts[path]=(counts[path] or 0)+1
                if counts[path]==2 then classes=classes+1 end
            end
        end
        metadata[info.layout_id]={pots=pots,respawns=starts,target=target,classes=classes}
        C.files.write_json('FillAPotPlus/catalog.json',metadata)
    end
    R.pre(S.path(S.CORE,'B_GameInstance','HostGame'),function(gi)
        if R.valid(gi) then S.trace('host game used %s next %s',S.options(gi.UsedMatchOptions),S.options(gi.NextMatchOptions)) end
    end)
    R.post('/Game/Blueprints/Match/B_MatchOptions.B_MatchOptions_C:CopyMatchOptions',function(options,source)
        local gi=C.session().gi
        if not R.valid(gi) or not R.valid(source) then return end
        local function name(o) return o==gi.NextMatchOptions and 'next' or o==gi.UsedMatchOptions and 'used' or 'other' end
        S.trace('copy %s <- %s: %s',name(options),name(source),S.options(options))
    end)
    S.onModeHost.on('layout_saved',observe);S.onModeHost.on('layout_loaded',observe)
    R.on('world_end',function() manager=nil;bundled={};byId={};quantities={} end)
end
