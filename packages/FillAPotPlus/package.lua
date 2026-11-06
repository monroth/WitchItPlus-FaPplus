return function(R, C, U)
    local dir = debug.getinfo(1,'S').source:match('^@(.+[\\/])')
    local S = {dir=dir,R=R, C=C, U=U, codec=dofile(dir..'codec.lua'), calc=dofile(dir..'math.lua')}
    S.O = '/Game/Blueprints/Gamemodes/ObjectiveMode/'
    S.CR = '/Game/Blueprints/Gamemodes/CreativeMode/'
    S.CORE = '/Game/Blueprints/Core/'
    S.MATCH = '/Game/Blueprints/Match/'
    dofile(dir..'scope.lua')(S)
    S.carriers = {
        '/Game/Blueprints/StaticProps/Placeable/StaticProps/BP_WitchCauldron.BP_WitchCauldron_C',
        '/Game/Blueprints/StaticProps/Placeable/StaticProps/BP_WitchRuneStone01.BP_WitchRuneStone01_C',
    }
    S.carriers[3], S.carriers[4] = S.carriers[2], S.carriers[2]
    S.names = {'Fill a Pot cauldron','Witch respawn point','Teleporter entrance','Teleporter exit'}
    S.F = {
        file='FileName_10_98BC71FF40A2DA9A28FA21B92157D6D9',
        name='InterfaceName_12_C1C05170469A93A0C7D243A1F45D7B13',
        objective='UsedInObjectiveMode_16_14EC3F034A60C0E1B05A6499D0923C6F',
        builtin='IsBuiltInCustomMap_24_B260140C4981E09A0400EBBB5AF787AD',
        preview='PreviewImage_6_3020A08A433639F165C92FA2C9A4ED43',
        layouts='ObjectiveLayouts_54_B3B7A59246226E47D79F4E94921D6024',
    }
    S.L = {
        name='LayoutName_8_C5C516E347406BABDAF0F59A6150BC5A',
        file='FileName_6_F3CC8069497D007AD2E96A9AE00D2700',
        map='MapName_10_67B8E5E54A16D786C60266AF5B396E36',
        type='LayoutType_3_723A46B84CDA3855FEC9D49D6379A874',
        screenshot='ScreenshotFile_15_EAD1980E4D724129C57CEE95149A80DD',
    }
    function S.path(folder, name, method) return folder..name..'.'..name..'_C'..(method and ':'..method or '') end
    function S.text(value) return type(value)=='string' and value or value:ToString() end
    function S.values(array)
        if not array.ForEach then
            local out={};for i,value in ipairs(array) do out[i]=value:get() end;return out
        end
        local result = {}
        array:ForEach(function(_,value) result[#result+1]=value:get() end)
        return result
    end
    function S.choices(labels) local rows={} for i,label in ipairs(labels) do rows[i]={label=label,value=i} end return rows end
    function S.asset(path) return R.native.load_asset(path) end
    function S.new(path, outer) return StaticConstructObject(S.asset(path),outer) end
    function S.dirty(object, field, index)
        StaticFindObject('/Script/Engine.Default__NetPushModelHelpers'):
            MarkPropertyDirtyFromRepIndex(object,index,FName(field))
        object:ForceNetUpdate()
    end
    function S.write(object, field, value, index)
        object:FlushNetDormancy()
        object[field] = value
        S.dirty(object,field,index)
    end
    function S.distance(a,b) return (a.X-b.X)^2+(a.Y-b.Y)^2+(a.Z-b.Z)^2 end
    function S.classpath(class) return class:GetFullName():match('^%S+ (.+)$') end
    function S.players() return S.values(C.session().gs.PlayerArray) end
    function S.manager() return C.session().gi.ObjectiveMatchManager end
    function S.bytes(actor)
        local chars = {}
        actor.SavedMaterialIndices:ForEach(function(_,v) chars[#chars+1]=string.char(v:get()) end)
        return table.concat(chars)
    end
    function S.marker(actor)
        if not actor:IsA(S.carriers[1]) and not actor:IsA(S.carriers[2]) then return end
        local data = S.codec.decode(S.bytes(actor))
        if data and actor:IsA(S.carriers[data.kind]) then
            data=S.codec.defaults(data);S.markerColour(actor,data);return data
        end
    end
    function S.markerColour(actor,info)
        if info.kind~=1 or info.source~=0 then return end
        local index=1
        local name=actor:GetFullName()
        for _,other in ipairs(R.find_all(S.carriers[1])) do
            if other:GetFullName()<name then
                local data=S.codec.decode(S.bytes(other))
                if data and data.kind==1 then index=index+1 end
            end
        end
        info.colour=S.codec.palette[(index-1)%#S.codec.palette+1]
    end
    function S.stamp(actor, info)
        S.markerColour(actor,info)
        local bytes = S.bytes(actor)
        local prior = S.codec.decode(bytes)
        local prefix = prior and prior.prefix or #bytes
        local encoded = S.codec.encode(bytes:sub(1,prefix),info)
        local array = {}
        for i=1,#encoded do array[i]=encoded:byte(i) end
        S.write(actor,'SavedMaterialIndices',array,10)
    end
    function S.markers()
        local rows = {}
        for _,path in ipairs({S.carriers[1],S.carriers[2]}) do
            for _,actor in ipairs(R.find_all(path)) do
                local info = S.marker(actor)
                if info then rows[#rows+1]={actor=actor,info=info,position=actor:K2_GetActorLocation()} end
            end
        end
        return rows
    end
    for _,name in ipairs({'rules','featured','ground','abilities','possession','divination','respawn','gameplay','reconnect','results','maps','voting','world','preview','editor','progress','hud','events'}) do
        dofile(dir..name..'.lua')(S)
    end
    return S
end
