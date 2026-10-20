-- Resolve native layout records while the owning MapData is live. CopyCompleteValue
-- publishes singleton native arrays; both picker random branches then pick the offer.
local M={}
local LAYOUTS='Layouts_19_A000B3E94244355BDF441A9F8E04F536'
local EVENTS='MapLayouts_48_AE297EC34B13F1944AB59AA0ADAD72B1'
local OBJECTIVE='ObjectiveLayouts_54_B3B7A59246226E47D79F4E94921D6024'
local NAME='InterfaceName_12_C1C05170469A93A0C7D243A1F45D7B13'
local FILE='FileName_10_98BC71FF40A2DA9A28FA21B92157D6D9'
function M.init(X,S,Info)
 local played={}; local api={}
 local catalog=dofile(assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))..'maps_catalog_data.lua')
 -- Strings/scalars only: native MapData copies survive round travel in the GI.
 -- A visible concrete-layout name carries the identity through those copies;
 -- never retain a retiring-world wrapper to recover it.
 local pinned={}
 function S.notePinned(map,entry)
  local key=X.text(X.read(map,FILE))..'|'..X.text(X.read(map,NAME))
  pinned[key]={layout=entry.layout,objective=entry.objective,event=entry.event,info=entry.info,baseName=entry.baseName}
 end
 S.layoutInfo=Info
 -- UE4SS's soft-property pusher copies a C++ FSoftObjectPtr and AVs in
 -- this game's FSoftWorldReference read. Even reading the member
 -- can AV. Keep native structs opaque; only copy them through native properties.
 Info.nativeLayouts=dofile(assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))..'maps_native_layouts.lua')
 local function count(array) return array:GetArrayNum() end
 local function identity(file,event,index,objective)
  local native=Info.nativeLayouts[file]
  local paths=native and (objective and native.objective or native.events[event])
  return paths and paths[index] or file..(objective and '#objective:' or '#event:'..event..':')..index
 end
 -- Calling GetLayoutsForMap with Lua OUT tables recursively marshals
 -- SMapLayouts -> FSoftWorldReference -> WorldAsset after its POST hook.
 -- Ask only for the byte OUT; walk borrowed native containers for counts.
 local function priority(gi)
  local out={}
  local manager=X.read(gi,'EventManager')
  FAPP_SERVICES.runtime.access('method:GetCurrentPriorityEventClass',function() manager:GetCurrentPriorityEventClass(out) end)
  local field,event=next(out) -- one byte OUT; do not depend on its Blueprint pin name
  assert(type(event)=='number' and next(out,field)==nil,'priority event byte unavailable')
  return event
 end
 function api.entries(gi,map)
  local file=X.text(X.read(map,FILE)); local event=priority(gi); local regular=0
  local source=X.read(map,EVENTS); local counts={}
  if source then source:ForEach(function(k,v)
   counts[X.get(k)]=count(X.read(X.get(v),LAYOUTS))
  end) end
  if counts[event]==nil then event=1 end -- same None fallback as native GetLayoutsForMap
  regular=counts[event] or 0
  local objective=X.read(X.read(map,OBJECTIVE),LAYOUTS)
  local goals=objective and count(objective) or 0
  local known=pinned[file..'|'..X.text(X.read(map,NAME))]
  if known and regular==1 and goals<=1 then
   return {{map=map,file=file,index=0,objectiveIndex=0,event=event,layout=known.layout,objective=known.objective,info=known.info,baseName=known.baseName}}
  end
  local result={}
  for i=1,math.max(1,regular) do for j=1,math.max(1,goals) do
   local layout=regular>0 and identity(file,event,i,false); local goal=goals>0 and identity(file,event,j,true)
   local info=Info.original(file,layout,goal)
   result[#result+1]={map=map,file=file,index=i-1,objectiveIndex=j-1,event=event,layout=layout,objective=goal,info=info,baseName=X.text(X.read(map,NAME))}
  end end
  return result
 end
 function S.mapInfo(gi,map)
  local infos={}; for _,entry in ipairs(api.entries(gi,map)) do if entry.info then infos[#infos+1]=entry.info end end
  local r=Info.summary(infos); if r then r.originalFile=X.text(X.read(map,FILE)); r.stock=true end
  return r
 end
 local function one(array,index,source)
  local value=X.values(source)[index+1]
  if value then array:Empty(); array[1]=value end
 end
 function api.pin(gi,entry)
  local holder=StaticConstructObject(X.asset('/Game/UserInterface/Maps/B_MapButtonData.B_MapButtonData_C'),gi)
  assert(X.H.valid(holder),'concrete layout MapData holder missing')
  holder.MapData=entry.map
  local chosen
  local source=X.read(entry.map,EVENTS)
  if source then source:ForEach(function(key,value)
   if X.get(key)==entry.event then chosen=X.read(X.get(value),LAYOUTS)[entry.index+1] end
  end) end
  local events=X.read(holder.MapData,EVENTS)
  if events and chosen then
   -- Write into native structs through TMap:Add, never a TMap [] assignment.
   local stage=StaticConstructObject(X.asset('/Game/UserInterface/Maps/B_MapButtonData.B_MapButtonData_C'),gi)
   stage.MapData=entry.map
   local staged=X.read(stage.MapData,EVENTS)
   local keys={}; staged:ForEach(function(k) keys[#keys+1]=X.get(k) end)
   for _,key in ipairs(keys) do
    local value; staged:ForEach(function(k,v) if X.get(k)==key then value=X.get(v) end end)
    if value then local array=X.read(value,LAYOUTS); array:Empty(); array[1]=chosen; events:Add(key,value) end
   end
  end
  local objective=X.read(X.read(holder.MapData,OBJECTIVE),LAYOUTS)
  if objective then one(objective,entry.objectiveIndex,X.read(X.read(entry.map,OBJECTIVE),LAYOUTS)) end
  local function leaf(path) return path and (path:match('([^/%.]+)%.[^/]+$') or path:match('([^/]+)$')) end
  local name=entry.baseName or X.text(X.read(entry.map,NAME))
  local layoutName=leaf(entry.layout) or leaf(entry.objective)
  local origin=layoutName and catalog.exports[leaf(entry.file)..'/Copy_'..layoutName]
  if layoutName then name=name..' · '..(origin and origin.label or layoutName) end
  -- Different authored prop/Objective pairs must retain distinct scalar names
  -- through native MapData copies/travel; identical names are a single layout.
  local goalName=leaf(entry.objective)
  if goalName and goalName~=layoutName then name=name..' ('..goalName..')' end
  holder.MapData[NAME]=FText(name)
  S.notePinned(holder.MapData,entry)
  return holder.MapData
 end
 function S.currentInfo(gi)
  local r=played[gi:GetAddress()]; if r and X.same(r.gi,gi) then return r.entry.info end
  local options=gi.UsedMatchOptions
  local entries=api.entries(gi,options.MapData)
  local entry=entries[math.max(1,(options.SelectedLayout or 0)+1)] or entries[1]
  return entry and entry.info
 end
 function S.repeatEntry(gi)
  local options=gi.UsedMatchOptions
  if options.CustomMapSelected then
   local layout=options.LayoutData; local ok,_,info=S.inspect(gi,layout)
   if ok then return {file=X.text(X.field(layout,'file')),layout=layout,info=info} end
  end
  local r=played[gi:GetAddress()]
  if r and X.same(r.gi,gi) then return r.entry end
  local entries=api.entries(gi,options.MapData)
  return entries[math.max(1,(options.SelectedLayout or 0)+1)]
 end
 function S.prepare(gi,map)
  local file=X.text(X.read(map,FILE)); local r=played[gi:GetAddress()]
  if r and X.same(r.gi,gi) and r.entry.file==file then return r.map end
  local entries=api.entries(gi,map); if #entries==0 then return map end
  local index=gi.NextMatchOptions.SelectedLayout
  local wanted=gi.UsedMatchOptions and gi.UsedMatchOptions.MapData
  local remembered
  if wanted and X.text(X.read(wanted,FILE))==file then
   local choices=api.entries(gi,wanted)
   if #choices==1 then
    for _,candidate in ipairs(entries) do
     if candidate.layout==choices[1].layout and candidate.objective==choices[1].objective then remembered=candidate; break end
    end
   end
  end
  local choices={}
  if type(index)=='number' and index>=0 then
   for _,candidate in ipairs(entries) do if candidate.index==index then choices[#choices+1]=candidate end end
  end
  if #choices==0 then choices=entries end
  local entry=remembered or choices[math.random(#choices)]
  local pinned=api.pin(gi,entry)
  for _,options in ipairs({gi.UsedMatchOptions,gi.NextMatchOptions}) do
   if not options.CustomMapSelected then options.MapData=pinned; options.SelectedLayout=0 end
  end
  entry.map=gi.UsedMatchOptions.MapData; entry.index=0; entry.objectiveIndex=0
  played[gi:GetAddress()]={gi=gi,entry=entry,map=gi.UsedMatchOptions.MapData}
  if FAPP_METADATA then FAPP_METADATA.observe(entry.info) end
  return pinned
 end
 X.hook('Selection','/Game/Blueprints/Match/','B_MapManager','GetSpecificMapFromLevelName',function(self,level,out)
  if not FAPP_MODE or not FAPP_MODE.state.plus then return end
  local gi=X.gi(self:get()); if not X.H.valid(gi) or gi.UsedMatchOptions.CustomMapSelected then return end
  out:set(S.prepare(gi,out:get()))
 end)
 function S.pinOffer(gi,entry) return api.pin(gi,entry) end
 function S.officialEntries(gi,map) return api.entries(gi,map) end
 X.Lifetime.onReset(function() played={} end)
 return api
end
return M
