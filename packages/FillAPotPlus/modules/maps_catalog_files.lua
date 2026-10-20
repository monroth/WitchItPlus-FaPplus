-- Catalog lineage is its own native-file observer, never a save participant.
local M={}
function M.install(owner,catalog)
 local Core=owner.shared('Core');local F,D=Core.layout_files,owner.map_document
 local IO=Core.companion_io
 local source,working;local saves={}
 local function resolve(v)
  if working and working.owner==v.actor_key then return working end
  source=source or v;local e=source;local bytes=e.target_path and IO.read(e.target_path..'.fapcatalog',1024)
  local key
  if bytes then
   local row;row,key=catalog.decode(bytes,{map=e.world});assert(row,'invalid catalog companion: '..e.target_path..'.fapcatalog')
  else
   -- Only a known cooked origin or unique Featured world supplies lineage.
   -- Arbitrarily named saved files never acquire a guessed variant.
   key=v.world..'/'..tostring(v.origin_name or '')
   if not catalog.data.exports[key]then
    key=nil
    for _,family in pairs(catalog.data.families)do
     if family.tab==2 and family.available and family.world:match('([^/]+)$')==v.world then key=v.world..'/NativeWorld';break end
    end
   end
  end
  working={owner=v.actor_key,key=key,dirty=false};return working
 end
 local function observe(e,existing)
  if existing or e.kind=='load'and e.complete and e.success then source=e;working=nil;return end
  if e.kind~='save'then return end
  if e.phase=='entry'then
   local ok,s=pcall(function()
    local token,v=D.capture();if not token or not D.current(token)then return end
    if v.role~='host'or v.document_kind=='not_creative'then return end
    return {value=resolve(v),document=v}
   end)
   if ok then saves[e.serial]=s else owner.log('CatalogFiles: snapshot failed; companion preserved: '..tostring(s))end
  elseif e.complete then
   local s=saves[e.serial];saves[e.serial]=nil
   if not(e.success and s and s.document.actor_key==e.owner_key)then return end
   local value=s.value
   if not e.autosave then value.dirty=value.key~=nil;value.target_path=e.target_path end
   if not value.key then return end
   local ok,why=pcall(function()
    local done,reason=IO.writeBytes(e.target_path..'.fapcatalog',catalog.encode(value.key),owner.is_live,e.serial,true)
    assert(done,reason)
   end)
   if not ok then value.error=tostring(why)..'; save again to retry';owner.log('CatalogFiles: '..e.target_path..'.fapcatalog: '..value.error)
   else
    if not e.autosave then value.dirty=false;value.error=nil end
    owner.log('CatalogFiles: saved '..e.target_path..'.fapcatalog')
   end
  end
 end
 local stop=F.observe(observe,true)
 local cancel=D.on_change(function(_,reason)if reason=='new'then source=nil;working=nil;saves={}end end)
 local function close()stop();if cancel then cancel()end;return true end
 owner.own(close,close)
 return {status=function()return working end}
end
return M
