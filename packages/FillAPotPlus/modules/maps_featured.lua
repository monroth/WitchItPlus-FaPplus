-- Browse original cooked Featured worlds in Creative. No automatic additions,
-- .pl import, removal of authored props, or reconstruction of baked structures.
local M={}
local FILE='FileName_10_98BC71FF40A2DA9A28FA21B92157D6D9'
local BUILTIN='IsBuiltInCustomMap_24_B260140C4981E09A0400EBBB5AF787AD'
local GM='/Game/Blueprints/Gamemodes/CreativeMode/B_CreativeGameMode.B_CreativeGameMode_C'
function M.init(X)
    local api,pickers={},{}
    local directory=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'),'Featured module directory unavailable')
    local catalogue=dofile(directory..'maps_featured_catalog.lua')
    function api.creative(options)
        if not X.Lifetime.rawValid(options) or options.CustomMapSelected then return false end
        local mode=X.read(options,'GameMode')
        return X.Lifetime.rawValid(mode) and mode:GetFName():ToString()=='B_CreativeGameMode_C'
            and X.read(options.MapData,BUILTIN)==true
    end
    function api.begin(actor)
        -- Picker can BeginPlay before destination GM releases the travel latch.
        if not X.Lifetime.rawValid(actor) then return end
        local class=actor:GetClass():GetFName():ToString()
        if class=='B_RandomPropLayoutPicker_C' then
            local gi=X.gi(actor)
            if X.Lifetime.rawValid(gi) and api.creative(gi.UsedMatchOptions) then
                pickers[actor:GetAddress()]={actor=actor,role=actor.Role}
                actor.Role=1 -- simulated only during this helper's native BeginPlay
                X.log('Featured','preserving original props during picker BeginPlay')
            end
            return
        end
        if class~='B_CreativeGameMode_C' then return end
        local gi=X.gi(actor)
        if X.Lifetime.rawValid(gi) and api.creative(gi.UsedMatchOptions) then
            actor.EnablePropLayouts=false
            X.log('Featured','Creative full world preserved; no auto pots, respawns or layout import')
        end
    end
    -- Native Blueprint authority checks can bypass ProcessEvent hooks. Scope the
    -- cleanup bypass to this layout-helper's BeginPlay and restore its role before
    -- any subsequent ticks; editor/gameplay actors are never modified.
    FAPP_API.on('begin_play_post',function(param)
        local actor=param:get();local r=pickers[actor:GetAddress()]
        if r and X.Lifetime.rawValid(actor) then actor.Role=r.role;pickers[actor:GetAddress()]=nil end
    end,{class_filter=function(name) return name=='B_RandomPropLayoutPicker_C' end})
    function api.start(gi,name)
        local matches,seen={},{}
        for _,map in ipairs(X.Selection.catalog(gi,true)) do
            local file=X.text(X.read(map,FILE));local leaf=file:match('([^/]+)$') or file
            local entry=catalogue[file]
            local match=file:lower()==name:lower() or leaf:lower()==name:lower()
            for _,alias in ipairs(entry and entry.aliases or {}) do if alias:lower()==name:lower() then match=true end end
            if match and not seen[file] then matches[#matches+1]=map;seen[file]=true end
        end
        assert(#matches==1,#matches==0 and 'Featured map not found: '..name or 'ambiguous Featured map: '..name)
        local map=matches[1];local options=gi.CreativeMatchOptions
        assert(catalogue[X.text(X.read(map,FILE))],'Featured world package not verified in installed assets: '..name)
        assert(X.H.valid(options),'CreativeMatchOptions unavailable')
        options:SetGameMode(X.asset(GM))
        options.MapData=map
        options.IsCreativeMode=true;options.IsPublicCreative=false;options.IsPublic=false
        options.IsTournamentMode=false;options.MaxPlayers=1;options.EnableIdleKick=false
        options.CustomMapSelected=false;options.UseCustomLayouts=false
        options.MapChangedAfterLoadingCustomLayout=false;options.SelectedLayout=-1
        options.LayoutData[X.LAYOUT.file]=''
        gi.UsedMatchOptions=options
        local file=X.text(X.read(map,FILE))
        X.log('Featured','opening original Creative world '..file..'; no .pl / no automatic markers')
        X.gameplay():OpenLevel(gi,FName(file),true,'?game='..GM)
        return true
    end
    function api.list(gi)
        local seen={}
        for _,map in ipairs(X.Selection.catalog(gi,true)) do
            local file=X.text(X.read(map,FILE))
            if catalogue[file] and not seen[file] then X.log('Featured',catalogue[file].name);seen[file]=true end
        end
    end
    function api.poll() end
    function api.reset() end
    X.Featured=api;return api
end
return M
