-- Optional runtime capability; no sibling paths or standalone mod marker.
local M={}
local function service()
 local core=FAPP_API and FAPP_API.shared and FAPP_API.shared('Core')
 return core and core.capabilities
end
function M.detect()
 local capabilities=service()
 if not capabilities then return false end
 local value,id=capabilities.get('layout_hiding')
 return value~=nil and id=='BaseWorldPlus'
end
function M.service()
 local caps=service(); if caps then return caps.get('layout_hiding') end
end
function M.watch(fn)
 local capabilities=service()
 if capabilities then return capabilities.watch(FAPP_API,'layout_hiding',fn) end
end
return setmetatable(M,{__index=function(_,key) if key=='enabled' then return M.detect() end end})
