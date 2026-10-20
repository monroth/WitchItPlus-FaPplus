local M={}
function M.new(api)
    local modules={}
    local root=api.path:gsub('\\','/'):gsub('/+$','')..'/modules/'
    local loader={}
    function loader.module(name)
        assert(type(name)=='string' and name:match('^[%w_%-]+$'),'invalid FAPP module')
        if modules[name]==nil then
            local read=function() return assert(loadfile(root..name..'.lua','t',_ENV))() end
            if api.profile then modules[name]=api.profile('module:'..name,read) else modules[name]=read() end
        end
        return modules[name]
    end
    dofile=function(path)
        local normalized=path:gsub('\\','/')
        assert(normalized:sub(1,#root)==root,'FAPP module outside package')
        return loader.module(assert(normalized:sub(#root+1):match('^([%w_%-]+)%.lua$')))
    end
    return loader
end
return M
