-- Cauldron metadata for native Objective map families.
local M={}
-- All variants within one map family share target/total.
M.defaults={WinterDream={target=3,pots=5},AutumnTownNew={target=3,pots=5},
 LibraryHalloween={target=3,pots=5},SpringTown={target=3,pots=5},
 IceFest={target=3,pots=5},Graveyard={target=3,pots=5},
 WitchForest={target=3,pots=5},GraveCanyon={target=3,pots=5},Castle={target=3,pots=5}}
local function copy(t) if not t then return end local r={} for k,v in pairs(t) do r[k]=v end return r end
function M.original(file,layout,objective)
 local leaf=file:gsub('\\','/'):match('([^/]+)$') or file
 local r=copy(M.defaults[leaf])
 if r then
  r.stock=true; r.originalFile=file; r.layout=layout; r.objective=objective
 end
 return r
end
function M.quantity(info)
 return tostring(math.max(1,math.min(info.pots,255,info.target or 3)))..'/'..tostring(info.pots)
end
function M.label(info) return M.quantity(info) end
-- All variants of a map share the same target/total; the first record is the
-- representative. No artificial min/max ranges or classification are stored.
function M.summary(records)
 local info=records[1];if not info then return end
 return {target=info.target,pots=info.pots,seekCoefficient=info.seekCoefficient}
end
function M.vote(name,info) return info and name..'\n'..M.label(info) or name end
return M
