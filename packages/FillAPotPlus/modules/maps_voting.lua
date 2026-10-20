-- Host bridge: native SMapData offers/vote RPCs, bounded host tally, native travel.
-- Custom layout identity stays in a host-side token -> filename dictionary.
local M={}
local Info=dofile(assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))..'maps_layout_info.lua')
local CORE='/Game/Blueprints/Core/'; local MATCH='/Game/Blueprints/Match/'
local FILE='FileName_10_98BC71FF40A2DA9A28FA21B92157D6D9'
local NAME='InterfaceName_12_C1C05170469A93A0C7D243A1F45D7B13'
local OBJECTIVE='UsedInObjectiveMode_16_14EC3F034A60C0E1B05A6499D0923C6F'
local BUILTIN='IsBuiltInCustomMap_24_B260140C4981E09A0400EBBB5AF787AD'
local QUICK='UsedInQuickmatch_14_394D12A648FFAF00AC52CA8DD1704959'
local PREVIEW='PreviewImage_6_3020A08A433639F165C92FA2C9A4ED43'
local AUTHOR='AuthorName_27_0C5D90204AC324D5FE2F288413EA2779'
function M.init(X)
    local H,C,S=X.H,X.C,X.Selection; local api,states={},{}
    -- Logged on every match end (rare): a once-per-session dedupe hid the
    -- second-half reason in the first live test.
    local function skip(why) X.log('Vote','no vote offers: '..why) end
    local function native(v,label) assert(type(v)=='userdata','refusing Lua table as '..label); return v end
    local function context(gm,dispatch)
        if not C.CreativeMaps or C.CreativeMapVoting==false then return skip('disabled in settings') end
        if not X.live(gm) or not H.class(gm,'B_ObjectiveGameMode_C') or not H.authority(gm) then return end
        local gi=X.gi(gm); local gs=X.gameplay():GetGameState(gm)
        if not X.live(gi) or not X.live(gs) or not H.authority(gs) then return skip('no host game instance/state') end
        local scope=X.Identity.session(gi)
        local custom=gi.IsCustomMatch==true or X.read(gi.UsedMatchOptions,'CustomMapSelected')==true
            or X.read(gi.NextMatchOptions,'CustomMapSelected')==true
        if scope and custom then scope.custom=true end
        if not (custom or (scope and scope.custom)) then return skip('not a custom match (native quickmatch vote untouched)') end
        if not dispatch and (not S.isObjective(gi.UsedMatchOptions) or not S.isObjective(gi.NextMatchOptions)) then return skip('match options are not Fill a Pot') end
        if gi.UsedMatchOptions.IsTournamentMode==true or gi.NextMatchOptions.IsTournamentMode==true
            or gi.UsedMatchOptions.IsRecordingMode==true or gi.NextMatchOptions.IsRecordingMode==true then return skip('tournament/recording mode') end
        local cycle=gi.MapManager.CustomMapCycle
        if H.valid(cycle) and #X.values(cycle.FileNames)>0 then return skip('a saved Custom Match map cycle is set ('..#X.values(cycle.FileNames)..' maps); native cycle order has precedence') end
        -- Native StartNewGame/UpdateCustomGameMatchOptions also test this flag.
        -- Repair only an eligible session with positive custom-match evidence.
        gi.IsCustomMatch=true
        return gi,gs
    end
    local function allowed(gi,layout)
        return not X.mapRequiresMod(layout,gi) or (X.ModSync and X.ModSync.everyoneModded()==true)
    end
    local function official(gi)
        local maps,seen={},{}
        for _,key in ipairs({'SmallMapList','BigMapList','QuickmatchMapList'}) do
            for _,map in ipairs(X.values(X.read(gi.MapManager,key))) do
                local file=X.text(X.read(map,FILE))
                if file~='' and file~='RandomMapCycle' and not seen[file] and X.read(map,OBJECTIVE)==true
                    and X.read(map,BUILTIN)~=true then
                    for _,entry in ipairs(S.officialEntries(gi,map)) do maps[#maps+1]=entry end; seen[file]=true end
            end
        end
        return maps
    end
    local function shuffled(pool)
        for i=#pool,2,-1 do local j=math.random(i); pool[i],pool[j]=pool[j],pool[i] end
        return pool
    end
    function api.offers(gm)
        local gi,gs=context(gm); if not gi then return false end
        local match=gi.ObjectiveMatchManager
        if not H.valid(match) or X.read(match,'IsMatchOver')~=true then
            skip('match is not over (IsMatchOver='..tostring(H.valid(match) and X.read(match,'IsMatchOver'))..' managerRound='..tostring(H.valid(match) and X.read(match,'CurrentRound'))..' gsRound='..tostring(X.read(gs,'CurrentRound'))..')'); return false
        end
        local standard=shuffled(official(gi)); local custom={}
        if C.CreativeMapVotePool=='custom' or C.CreativeMapVotePool=='both' then
            gi.MapManager:SetLayoutDataByFileName()
            local seen={}
            for _,layout in ipairs(S.catalog(gi,false,false)) do
                local usable,_,info=S.inspect(gi,layout)
                local file=X.text(X.field(layout,'file'))
                if usable and allowed(gi,layout) and file~='' and not seen[file] then
                    custom[#custom+1]={file=file,layout=layout,info=info}; seen[file]=true
                end
            end
            shuffled(custom)
        end
        local repeatEntry=S.repeatEntry(gi)
        assert(repeatEntry,"repeat layout was not recorded before match end")
        local offers={repeatEntry}
        local function add(pool,index)
            local e=pool[index]
            if e and not (e.file==repeatEntry.file and (not e.map or (e.layout==repeatEntry.layout and e.objective==repeatEntry.objective))) then offers[#offers+1]=e end
        end
        if C.CreativeMapVotePool=='custom' then
            for i=1,#custom do if #offers<5 then add(custom,i) end end
        elseif C.CreativeMapVotePool=='both' then
            -- Alternate so both pools appear whenever each contains at least one.
            local a,b=1,1
            while #offers<5 and (a<=#custom or b<=#standard) do
                if a<=#custom then add(custom,a); a=a+1 end
                if #offers<5 and b<=#standard then add(standard,b); b=b+1 end
            end
        else for i=1,#standard do if #offers<5 then add(standard,i) end end end
        if #offers==0 then
            -- An empty custom-only pool cannot silently offer official maps.
            gs.MapsToVote:Empty(); gm.MapsToVoteUpdateNeeded=false; states[gm:GetAddress()]=nil
            api.dirty(gs)
            X.message(gm,'No playable maps to vote on. Keeping the current map.')
            return false
        end
        -- Build on a temporary native UObject BEFORE replacing the live array.
        -- UE4SS CopyCompleteValue copies struct userdata; indexed TArray writes
        -- grow the native array. No Lua table is a UFunction/container argument.
        local store=StaticConstructObject(X.asset(MATCH..'B_MapManager.B_MapManager_C'),gi)
        assert(H.valid(store),'vote scratch MapManager unavailable')
        local holder=StaticConstructObject(X.asset('/Game/UserInterface/Maps/B_MapButtonData.B_MapButtonData_C'),gi)
        assert(H.valid(holder),'vote SMapData holder unavailable')
        local array=native(store.BigMapList,'TArray<SMapData>'); array:Empty()
        local tokens,files={},{}
        for i,entry in ipairs(offers) do
            if entry.map then
                holder.MapData=native(S.pinOffer(gi,entry),'SMapData')
                -- Native LastMapBox hides slot zero for non-quickmatch records.
                -- Slot zero repeats the concrete layout played; four offers follow.
                holder.MapData[QUICK]=true
                local name=entry.baseName or X.text(X.read(entry.map,NAME))
                if name=='' or name=='nil' then name=entry.file:match('([^/]+)$') end
                if entry.layout then name=name..' · '..(entry.layout:match('([^/%.]+)%.[^/]+$') or entry.layout:match('([^/]+)$') or entry.layout) end
                if entry.objective then name=name..' · '..(entry.objective:match('([^/%.]+)%.[^/]+$') or entry.objective:match('([^/]+)$')) end
                holder.MapData[NAME]=FText(Info.vote(name,entry.info))
                S.notePinned(holder.MapData,entry)
                array[i]=native(holder.MapData,'SMapData'); files[i]=entry.file
            else
                local layout=entry.layout or S.resolve(gi,entry.file)
                holder.MapData=native(S.mapFor(gi,layout),'SMapData')
                local map=native(holder.MapData,'SMapData'); local token='FAPM:'..i
                map[FILE]=FName(token); map[NAME]=FText(Info.vote(X.text(X.field(layout,'name')),entry.info))
                map[BUILTIN]=true; map[QUICK]=true; map[OBJECTIVE]=true; map[AUTHOR]=FText('')
                if not H.valid(X.read(map,PREVIEW)) then
                    map[PREVIEW]=X.asset('/Game/UserInterface/Maps/T_MapPicPlaceholder.T_MapPicPlaceholder')
                end
                array[i]=map; tokens[token]=entry.file; files[i]=token
            end
        end
        gs.MapsToVote=array -- deep copy of a native TArray, never a Lua container
        assert(#X.values(gs.MapsToVote)==#offers,'native vote array copy did not persist')
        states[gm:GetAddress()]={gm=gm,gs=gs,gi=gi,tokens=tokens,files=files,count=#offers,epoch=X.Lifetime.epoch,
            current=gi.NextMatchOptions.CustomMapSelected and X.text(X.field(gi.NextMatchOptions.LayoutData,'file')) or nil}
        gm.MapsToVoteUpdateNeeded=false; api.dirty(gs)
        X.log('Vote','pool='..tostring(C.CreativeMapVotePool or 'official')..'; native offers='..#offers..
            '; custom candidates='..#custom..'; official candidates='..#standard)
        return true
    end
    function api.dirty(gs)
        gs:FlushNetDormancy()
        X.object('/Script/Engine.Default__NetPushModelHelpers'):MarkPropertyDirtyFromRepIndex(gs,36,FName('MapsToVote'))
        gs:ForceNetUpdate()
    end
    local function state(gm)
        if C.CreativeMapVoting==false or not C.CreativeMaps or X.Lifetime.transition then return end
        local gi,gs=context(gm,true); if not gi then return end
        local r=states[gm:GetAddress()]
        if r and r.epoch==X.Lifetime.epoch and X.same(r.gm,gm) and X.same(r.gs,gs) and X.same(r.gi,gi) then return r end
    end
    function api.chosen(gm)
        local r=state(gm); if not r then return false end
        local gi=r.gi; local maps=X.values(r.gs.MapsToVote)
        assert(#maps==r.count and #maps>0,'vote offers changed before travel')
        -- Vanilla preinitializes five indices and index zero means "repeat".
        -- Count the same native votes/disconnect exclusion, bounded to our real
        -- pool; ties (including no votes) are random over valid offers only.
        local counts={}
        -- Roster and sidecars can change while the native screen is open. Do not
        -- renumber replicated slots; discard now-incompatible votes at dispatch.
        for i,map in ipairs(maps) do
            local token=X.text(X.read(map,FILE)); assert(token==r.files[i],'vote offer identity changed before travel')
            local file=r.tokens[token]
            if not file then counts[i]=0
            else
                local ok,usable=pcall(function()
                    local layout=S.resolve(gi,file)
                    return S.inspect(gi,layout) and allowed(gi,layout)
                end)
                if ok and usable then counts[i]=0 end
            end
        end
        for _,ps in ipairs(X.values(r.gs.PlayerArray)) do
            if H.valid(ps) and X.read(ps,'IsPendingDisconnect')~=true then
                local index=X.read(ps,'VotedMapIndex')
                if type(index)=='number' and index%1==0 and index>=0 and index<#maps and counts[index+1]~=nil then counts[index+1]=counts[index+1]+1 end
            end
        end
        local highest,ties=-1,{}
        for i=1,#maps do
            local v=counts[i]
            if v~=nil then
                if v>highest then highest=v; ties={i} elseif v==highest then ties[#ties+1]=i end
            end
        end
        local index=#ties>0 and ties[math.random(#ties)] or nil
        local winner=index and maps[index]
        local file=winner and r.tokens[X.text(X.read(winner,FILE))]
        if index then X.log('Vote','selected native index='..(index-1)..'; votes='..highest) end
        if file or not winner then
            local valid,why=false,'no offered layout remains usable/compatible'
            if file then valid,why=pcall(function()
                S.apply(gi,gi.UsedMatchOptions,file); S.apply(gi,gi.NextMatchOptions,file)
            end) end
            if not valid then
                X.log('Vote','Voted layout is no longer usable: '..tostring(why));X.message(gm,'The voted map is unavailable. Choose another map.')
                local restored=r.current and pcall(function()
                    assert(allowed(gi,S.resolve(gi,r.current)),'previous layout requires compatible clients')
                    S.apply(gi,gi.UsedMatchOptions,r.current); S.apply(gi,gi.NextMatchOptions,r.current)
                end)
                if not restored then
                    S.fallback(gi,gi.UsedMatchOptions,why)
                    gi.NextMatchOptions.MapData=native(gi.UsedMatchOptions.MapData,'SMapData')
                    gi.NextMatchOptions.CustomMapSelected=false; gi.NextMatchOptions.SelectedLayout=-1
                end
            end
            gi.CurrentOpenedMap=native(gi.UsedMatchOptions.MapData,'SMapData')
            gi.NextMapToOpen=X.read(gi.UsedMatchOptions.MapData,FILE)
            S.remember(gi,gi.NextMatchOptions)
            X.log('Vote',(valid and 'winner custom='..file or 'fallback')..'; travel base='..X.text(gi.NextMapToOpen))
        else
            assert(X.read(winner,OBJECTIVE)==true and X.read(winner,BUILTIN)~=true,'unknown/non-Objective voted map')
            gi.CurrentOpenedMap=native(winner,'SMapData')
            for _,options in ipairs({gi.UsedMatchOptions,gi.NextMatchOptions}) do
                options.MapData=native(winner,'SMapData'); options.CustomMapSelected=false; options.SelectedLayout=0
            end
            S.forget(gi); gi.NextMapToOpen=X.read(winner,FILE)
            X.log('Vote','winner official='..X.text(gi.NextMapToOpen))
        end
        r.chosen=true; return true
    end
    -- No tick/poll validation of UObjects. Native end/travel events own all work;
    -- Lifetime reset drops Lua handles even if Unreal reuses world addresses.
    function api.poll() end
    function api.reset() states={} end
    X.Lifetime.onReset(api.reset)
    X.Voting=api
    if C.CreativeMapVoting==false then return api end
    local function ensureOffers(gm)
        -- Repeated end callbacks must not shuffle slots after players voted.
        if state(gm) then return end
        api.offers(gm)
    end
    X.hook('Vote',X.OM,'B_ObjectiveGameMode','HandleStartMatchOverride',function(self)
        context(self:get()) -- latch custom-session evidence before inter-round travel
    end)
    X.hook('Vote',CORE,'B_GameInstance','UnregisterSession',function(self)
        X.Identity.forget(self:get())
    end)
    -- Native result -> Objective -> rewards takes 6+10+7=23 seconds.
    -- A 30-second host floor keeps 14 seconds of vote after rewards skip, ten seconds shorter.
    X.hook('Vote',CORE,'B_GameMode','DetermineNewMapsForVote',function(self) ensureOffers(self:get()) end)
    X.hook('Vote',X.OM,'B_ObjectiveGameMode','HandleEndMatchOverride',function(self)
        -- Objective sets IsMatchOver here before the base EndMatch/UI/timer body.
        -- Force final-match offers even if the round-one native flag was cleared.
        ensureOffers(self:get())
    end)
    X.hook('Vote',CORE,'B_GameMode','DetermineNextMapFromVotes',function(self) api.chosen(self:get()) end)
    X.hook('Vote',X.OM,'B_ObjectiveGameMode','GetRoundEndTimerUntilRestart',function(self,out)
        local r=state(self:get())
        if r and r.count>0 and X.read(r.gi.ObjectiveMatchManager,'IsMatchOver')==true then
            local seconds=out:get(); out:set(math.max(30,type(seconds)=='number' and seconds or 0))
        end
    end)
    X.hook('Vote',CORE,'B_GameMode','UpdateCustomGameMatchOptions',function(self)
        local gm=self:get(); local r=state(gm); if not r then return end
        if FAPP_MODE and not FAPP_MODE.selected(r.gi.NextMatchOptions) then
            local used=r.gi.UsedMatchOptions
            if used.CustomMapSelected or X.text(X.read(used.MapData,FILE))=='RandomMapCycle' then
                S.fallback(r.gi,used,'leaving Fill a Pot+')
                r.gi.NextMatchOptions.MapData=native(used.MapData,'SMapData')
                r.gi.NextMatchOptions.CustomMapSelected=false; r.gi.NextMatchOptions.SelectedLayout=-1
            end
            S.forget(r.gi); states[gm:GetAddress()]=nil
            X.log('Vote','leaving Plus: native next-mode selection takes precedence over Plus offers')
            return
        end
        -- StartNewGame tests UsedMatchOptions.MapData == RandomMapCycle before
        -- calling DetermineNextMapFromVotes. Change only that dispatch field;
        -- chosen() restores the actual base map + LayoutData before ServerTravel.
        r.gi.UsedMatchOptions.MapData=native(r.gi.MapManager.RandomMapCycle,'SMapData')
        r.gi.UsedMatchOptions.CustomMapSelected=false
    end)
    X.hook('Vote','/Game/UserInterface/Maps/','WB_MapVote','UpdateMapData',function(self)
        local w=self:get(); local map=X.read(w.MapEntry,'MapData')
        local file=X.text(X.read(map,FILE))
        local name=X.text(X.read(map,NAME)); local label=name:match('\n(.+)$')
        if label then
            if H.valid(w.MapName) then w.MapName:SetText(FText(name:match('^(.-)\n') or name)) end
            if X.Catalog then X.Catalog.voteLabel(w.MapEntry,label) end
        end
        if file:match('^FAPM:') then
            if H.valid(w.MapType) then w.MapType:SetText(FText('Custom with cauldrons')) end
            if H.valid(w.MapAuthor) then w.MapAuthor:SetVisibility(1) end
        end
    end)
    return api
end
return M
