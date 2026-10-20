-- Append+close per event survives process exit; manifest rotation runs once/session.
local M={}
function M.init(options)
    options=options or {}; local api={}; local path,attempted
    local function start()
        if attempted then return path end
        attempted=true
        local store=options.storage and options.storage() or FAPP_SERVICES.storage.open()
        local folder=store.root..'/'
        local names={}
        for line in (store.read('sessions.txt') or ''):gmatch('[^\r\n]+') do
            if line:match('^session%-%d+%-%d+%.log$') then names[#names+1]=line end
        end
        local f
        local serial=1; local stamp=tostring(math.floor(os.time()))
        for _,old in ipairs(names) do
            local n=old:match('^session%-'..stamp..'%-(%d+)%.log$')
            if n then serial=math.max(serial,tonumber(n)+1) end
        end
        local filename
        repeat
            filename='session-'..stamp..'-'..serial..'.log'
            f=io.open(folder..filename,'r'); if f then f:close(); serial=serial+1 end
        until not f
        path=folder..filename
        f=assert(io.open(path,'a')); f:close()
        names[#names+1]=filename
        while #names>10 do os.remove(folder..table.remove(names,1)) end
        store.write('sessions.txt',table.concat(names,'\n')..'\n')
        api.path=path
        if options.log then options.log("EventLog session: "..path) end
        return path
    end
    function api.emit(event,fields)
        local ok,err=pcall(function()
            if not start() then return end
            local parts={tostring(os.time()),event}
            local keys={}; for k in pairs(fields or {}) do keys[#keys+1]=k end; table.sort(keys)
            for _,k in ipairs(keys) do
                parts[#parts+1]=k..'='..tostring(fields[k]):gsub('[\r\n\t ]','_')
            end
            local f=assert(io.open(path,'a')); local wrote,why=f:write(table.concat(parts,' '),'\n')
            f:close(); assert(wrote,why)
        end)
        if not ok and not api.failed then
            api.failed=true
            if options.log then options.log('EventLog unavailable: '..tostring(err)) end
        end
    end
    return api
end
return M
