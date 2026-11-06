return function(S)
    local R=S.R
    local roles={}
    local function featured(actor)
        if S.C.session().is_vanilla_session~=false then return false end
        local gi=R.valid(StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetGameInstance(actor))
        if not gi then return false end
        local options=gi.UsedMatchOptions
        if options.CustomMapSelected or not options.IsCreativeMode then return false end
        local map=options.MapData
        return map[S.F.builtin]==true or S.text(map[S.F.file]):find('/Game/Maps/GameMaps/UserMaps/',1,true)==1
    end
    RegisterBeginPlayPreHook(function(actor)
        actor=R.valid(actor);if not actor then return end
        local class=actor:GetClass():GetFName():ToString()
        if class~='B_RandomPropLayoutPicker_C' and class~='B_CreativeGameMode_C' then return end
        if not featured(actor) then return end
        if class=='B_RandomPropLayoutPicker_C' then
            roles[#roles+1]=actor.Role;actor.Role=1
        else actor.EnablePropLayouts=false end
    end)
    RegisterBeginPlayPostHook(function(actor)
        actor=R.valid(actor);if not actor then return end
        if actor:GetClass():GetFName():ToString()=='B_RandomPropLayoutPicker_C' and featured(actor) then
            actor.Role=table.remove(roles)
        end
    end)
    R.on('world_end',function() roles={} end)
end
