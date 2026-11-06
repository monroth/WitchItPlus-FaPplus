local M = {}
M.legacyRadius=2500
M.palette={
    {R=.33834901452064514,G=0,B=.921999990940094,A=1},
    {R=1,G=.8192780017852783,B=.09399999678134918,A=1},
    {R=0,G=.5219209790229797,B=.8999999761581421,A=1},
    {R=.2274789959192276,G=.9734449982643127,B=.05315500125288963,A=1},
    {R=.6927080154418945,G=.08415199816226959,B=0,A=1},
    {R=1,G=.2,B=.44,A=1},{R=1,G=1,B=1,A=1},
    {R=0,G=1,B=1,A=1},{R=1,G=.35,B=0,A=1},{R=.25,G=.05,B=.12,A=1}}
local oldPink=string.pack('<ffff',1,1-.896,1-.896*.7,1)

local function colour(r, g, b, a)
    if r ~= r or g ~= g or b ~= b or a ~= 1 then return end
    if math.min(r, g, b) < 0 or math.max(r, g, b) > 1 then return end
    if string.pack('<ffff',r,g,b,a)==oldPink then return {R=1,G=.2,B=.44,A=1} end
    return {R=r, G=g, B=b, A=1}
end
local function fixed(s, prefix)
    local magic, version, kind = s:sub(1,4), s:byte(5), s:byte(6)
    if magic == 'FAPR' and s == 'FAPR\1\2' then
        return {kind=2, prefix=prefix}
    end
    if magic == 'FAPT' then
        local sizes = {23,24,29}
        if not sizes[version] or #s ~= sizes[version] or (kind ~= 3 and kind ~= 4) then return end
        local authored = s:byte(7)
        local c = colour(string.unpack('<ffff', s, 8))
        local look = version >= 2 and s:byte(24) or 0
        if authored > 1 or not c or look > 4 then return end
        local pair, twoWay
        if version == 3 then
            pair = string.unpack('<I4', s, 25)
            local flag = s:byte(29)
            if pair == 0 or flag > 1 then return end
            twoWay = flag == 1
        end
        return {kind=kind, prefix=prefix, colour=c, look=look, pairId=pair,
            twoWay=twoWay, authored=authored==1}
    end
    local sizes = {6,23,35,39}
    if magic ~= 'FAPM' or not sizes[version] or #s ~= sizes[version] then return end
    if version == 1 then
        if kind == 1 or kind == 2 then return {kind=kind, prefix=prefix} end
        return
    end
    if kind ~= 1 or s:byte(7) > 2 then return end
    local c = colour(string.unpack('<ffff', s, 8))
    if not c then return end
    local target, revision, down, up = 3, 0, 32, 32
    if version >= 3 then
        target, revision = string.unpack('<I4I8', s, 24)
        if target == 0 or revision < 0 or revision > 9007199254740991 then return end
    end
    if version == 4 then
        down, up = string.unpack('<I2I2', s, 36)
        if down > 2000 or up > 2000 then return end
    end
    return {kind=1, prefix=prefix, colour=c, target=target, revision=revision,
        down=down, up=up, source=s:byte(7), radius=M.legacyRadius, excluded={}}
end
function M.decode(s)
    local n = #s
    local footer = s:sub(-4)
    local version = ({FAP5=5,FAP6=6,FAP7=7,FAP8=8})[footer]
    if version then
        if n < 49 then return end
        local size = string.unpack('<I4', s, n-7)
        if size < 49 or size > 33000 or size > n then return end
        local first = n-size+1
        local data = s:sub(first,n-8)
        if data:sub(1,6) ~= 'FAPM'..string.char(version,1) then return end
        local info = fixed(data:sub(1,4)..'\4'..data:sub(6,39), first-1)
        if not info then return end
        local count, at = string.unpack('<I2', data, 40)
        if count > 64 then return end
        for _=1,count do
            if at+1 > #data then return end
            local length; length, at = string.unpack('<I2', data, at)
            if length == 0 or length > 512 or at+length-1 > #data then return end
            local path = data:sub(at,at+length-1); at = at+length
            if not path:match('^/Game/[%w_/.%-]+%.[%w_]+_C$') or info.excluded[path] then return end
            info.excluded[path] = true
        end
        local remaining = #data-at+1
        if version == 5 and remaining ~= 0 then return end
        if version == 6 and remaining ~= 12 and remaining ~= 16 then return end
        if version == 7 and remaining ~= 12 then return end
        if version == 8 then
            if remaining ~= 2 then return end
            info.radius = string.unpack('<I2',data,at)
            if info.radius > 10000 then return end
        end
        return info
    end
    for _,size in ipairs({29,24,23,6,39,35}) do
        if n >= size then
            local info = fixed(s:sub(n-size+1), n-size)
            if info then return info end
        end
    end
end
function M.defaults(info)
    if info.kind==1 then info.source=info.source or 0 end
    info.colour = info.colour or {R=1,G=.2,B=.44,A=1}
    info.target, info.revision = info.target or 3, info.revision or 0
    info.down, info.up = info.down or 32, info.up or 32
    info.radius = info.radius == nil and M.legacyRadius or info.radius
    info.excluded = info.excluded or {}
    -- A new teleporter shows where it stands; the codec keeps a chosen None.
    info.look = info.look or (info.kind >= 3 and 1 or 0)
    return info
end
function M.encode(prefix, info)
    local k = info.kind
    if k == 2 then return prefix..'FAPR\1\2' end
    local c = info.colour
    local rgba = string.pack('<ffff', c.R,c.G,c.B,1)
    if k >= 3 then
        return prefix..'FAPT'..string.char(3,k,info.authored and 1 or 0)..rgba
            ..string.pack('<BI4B',info.look,info.pairId,info.twoWay and 1 or 0)
    end
    local paths = {}
    for path in pairs(info.excluded) do paths[#paths+1] = path end
    table.sort(paths)
    local payload = 'FAPM\8\1'..string.char(info.source or 0)..rgba
        ..string.pack('<I4I8I2I2I2',info.target,info.revision,info.down,info.up,#paths)
    for _,path in ipairs(paths) do payload = payload..string.pack('<I2',#path)..path end
    payload = payload..string.pack('<I2',info.radius)
    return prefix..payload..string.pack('<I4',#payload+8)..'FAP8'
end
return M
