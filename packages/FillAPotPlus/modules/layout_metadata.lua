-- Cauldron snapshots contain scalars, never UObject wrappers.
local M={}
function M.new(Info)
 local api={version=2,defaults=Info.defaults}; local current
 local fields={seekCoefficient=true,target=true,pots=true,respawns=true,props=true,targetRevision=true,conflict=true,layout=true,objective=true,stock=true,originalFile=true}
 api.label=Info.label; api.summary=Info.summary
 function api.observe(info)
  current=nil; if info then current={} for k,v in pairs(info) do
   local t=type(v)
   if fields[k] and (t=='string' or t=='boolean' or (t=='number' and v==v and math.abs(v)~=math.huge)) then current[k]=v end
  end end
 end
 function api.current() if not current then return end local r={} for k,v in pairs(current) do r[k]=v end return r end
 function api.for_options(gi)
  assert(api.resolve,'layout metadata resolver not initialized')
  local info=api.resolve(gi); local r={}
  for k,v in pairs(info or {}) do
   local t=type(v); if fields[k] and (t=='string' or t=='boolean' or (t=='number' and v==v and math.abs(v)~=math.huge)) then r[k]=v end
  end
  return r
 end
 function api.reset() current=nil end
 return api
end
return M
