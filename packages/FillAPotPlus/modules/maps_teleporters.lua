-- Native-layout endpoint markers. Server owns vanilla zones; local presentation is independent.
local M={}
function M.init(X)
 local H=X.H;local E=assert(FAPP_API.Native.scope(FAPP_API.id))
 local Zone=assert(FAPP_API.shared('Core').teleporter_zone)
 local api={};local state
 local dirty,discover=true,true
 local snapshot,versions,contextWorld,enabled
 function api.invalidate(queryWorld)
  dirty=true
  if queryWorld then discover=true end
 end
 local function log(s)X.log('Teleporters',s)end
 local function valid(a)return a and X.live(a)end
 local function remove(a)
  if not valid(a)then return true end
  local ok,why=E.destroy(a);assert(ok,'teleporter resource '..a:GetFullName()..': '..tostring(why));return true
 end
 local function clearRows(rows,errors)
  for id,r in pairs(rows)do
   local ok,why=pcall(remove,r.actor)
   if ok then rows[id]=nil else errors[#errors+1]='teleporter '..tostring(id)..': '..tostring(why)end
  end
 end
 function api.reset()
  state=nil;snapshot=nil;versions=nil;contextWorld=nil;dirty=true;discover=true
 end
 function api.cleanup()
  if not state then return true end
  if X.Lifetime.transition or state.world~=X.Lifetime.world or state.epoch~=X.Lifetime.epoch then api.reset();return true end
  local errors={};clearRows(state.zones,errors)
  if state.overlay then
   local ok,why=pcall(function()if H.valid(state.overlay)then state.overlay:RemoveFromParent()end end)
   if ok then state.overlay=nil else errors[#errors+1]='teleporter map-problem overlay: '..tostring(why)end
  end
  if #errors==0 then state=nil;return true end
  return false,table.concat(errors,' | ')
 end
 local function point(p)
  local r=p.actor:K2_GetActorRotation()
  return {X=p.position.X,Y=p.position.Y,Z=p.position.Z,Pitch=r.Pitch,Yaw=r.Yaw,Roll=r.Roll}
 end
 local function signature(entry,exit)
  return string.pack('<dddddddddddd',entry.X,entry.Y,entry.Z,entry.Pitch,entry.Yaw,entry.Roll,
   exit.X,exit.Y,exit.Z,exit.Pitch,exit.Yaw,exit.Roll)
 end
 local function overlay(s,pc,playing)
  local show=playing and #s.problems>0 and not (X.Preview and X.Preview.active())
  if show and not s.overlay and not s.overlayFailed and valid(pc)then
   local ok,why=pcall(function()
    local path='/Game/UserInterface/UIElements/WB_TooltipTextContent.WB_TooltipTextContent_C'
    s.overlay=X.object('/Script/UMG.Default__WidgetBlueprintLibrary'):Create(pc,X.asset(path),pc)
    assert(H.valid(s.overlay),'teleporter map-problem overlay unavailable')
    for _,child in ipairs(X.values(s.overlay.WidgetTree.RootWidget:GetAllChildren()))do
     if H.class(child,'TextBlock')then s.overlayText=child;break end
    end
    assert(H.valid(s.overlayText),'teleporter map-problem text unavailable')
    s.overlay:AddToViewport(200);s.overlay:SetPositionInViewport({X=12,Y=70},false)
    s.overlay:SetDesiredSizeInViewport({X=540,Y=0});s.overlay:SetRenderTransformPivot({X=0,Y=0})
    s.overlay:SetRenderScale({X=.55,Y=.55});s.overlayText:SetAutoWrapText(true)
   end)
   if not ok then s.overlayFailed=true;log(tostring(why))end
  end
  if H.valid(s.overlay)then
   if H.valid(s.overlayText)then s.overlayText:SetText(FText(table.concat(s.problems,'\n')))end
   s.overlay:SetVisibility(show and 4 or 1) -- hit-test-invisible; never captures input
  end
 end
 local function resident(s)
  local class=StaticFindObject(Zone.CLASS)
  if H.valid(class)then
   for _,flag in ipairs({'RF_NeedInitialization','RF_NeedLoad','RF_NeedPostLoad','RF_NeedPostLoadSubobjects'})do
    if EObjectFlags[flag] and class:HasAnyFlags(EObjectFlags[flag])then return end
   end
   return class
  end
  if not s.requested then
   s.requested=true;s.requestTime=X.gameplay():GetTimeSeconds(s.gm);E.load_class(Zone.CLASS,s.gm)
  elseif not s.loadError and X.gameplay():GetTimeSeconds(s.gm)-s.requestTime>30 then
   s.loadError='teleporter class not resident after async request; re-enable FillAPotPlus to retry'
   log(s.loadError)
  end
 end
 function api.problems()return state and state.problems or {}end
 function api.active()return state~=nil end
 function api.poll(context)
  -- Discovery belongs to enable/adoption and native layout-load events. A
  -- steady tick reads cached playtest state, never enumerates actors or markers.
  if context then
   local world=context.world and context.world:GetAddress()
   if world~=contextWorld then
    if not X.Lifetime.rawValid(context.controller) or not X.Lifetime.observe(context.controller,context.time)then return end
    if state and (state.world~=X.Lifetime.world or state.epoch~=X.Lifetime.epoch)then api.reset()end
    contextWorld=world;api.invalidate(true)
   end
   if discover then
    if X.EndpointLooks then X.EndpointLooks.adopt(context)
    else local actors,why=E.find(X.CARRIERS[2],context.controller);assert(actors,why);for _,actor in ipairs(actors)do X.Registry.track(actor)end end
    discover=false
   end
  end
  if X.Lifetime.transition then return end
  if enabled~=X.C.CreativeMaps then enabled=X.C.CreativeMaps;dirty=true end
  if not X.C.CreativeMaps then if state then local ok,why=api.cleanup();assert(ok,why)end;return end
  if state and (state.world~=X.Lifetime.world or state.epoch~=X.Lifetime.epoch)then api.reset()end
  local currentVersion=X.Registry.versions.BP_WitchRuneStone01_C or 0
  if currentVersion~=versions then dirty=true end
  local playing=state and (not state.creative or state.gs and state.gs.IsPlayTestMode==true)
  if not dirty and state and playing==state.playing and not state.awaitingClass then return end
  if not dirty and not state then return end
  if dirty then
   local anchor
   for _,a in ipairs(X.findAll('BP_WitchRuneStone01_C'))do
    local info=X.kind(a)
    if info and info.kind>=3 and X.read(a,'IsPreview')~=true then anchor=a;break end
   end
   if not anchor then
    local ok,why=api.cleanup();assert(ok,why)
    snapshot=nil;versions=currentVersion;dirty=false;return
   end
   local g=X.gameplay();local gm=g:GetGameMode(anchor)
   if not valid(gm)or not H.authority(gm)then
    versions=currentVersion;dirty=false;return -- clients use replicated actors
   end
   if not state then state={gm=gm,world=X.Lifetime.world,epoch=X.Lifetime.epoch,zones={},problems={}}end
   state.gs=g:GetGameState(gm);state.creative=H.class(gm,'B_CreativeGameMode_C')
   local _,_,entrances,exits=X.markers(gm)
   local pairs_,problems,groups=X.TeleporterPairs.groups(entrances,exits)
   snapshot={entrances=entrances,exits=exits,pairs=pairs_,problems=problems,groups=groups}
   dirty=false;versions=currentVersion
  end
  local s=state;local gm=s.gm;local g=X.gameplay()
  playing=not s.creative or H.valid(s.gs) and s.gs.IsPlayTestMode==true
  s.playing=playing
  local entrances,exits,pairs_,groups=snapshot.entrances,snapshot.exits,snapshot.pairs,snapshot.groups
  s.problems={table.unpack(snapshot.problems)}
  local current={};for _,p in ipairs(entrances)do current[p.id]=p end;for _,p in ipairs(exits)do current[p.id]=p end
  local pc=g:GetPlayerController(gm,0);if not valid(pc)or not pc:IsLocalController()then pc=nil end
  local wanted={};for _,pair in ipairs(pairs_)do if playing then wanted[pair.entrances[1].id]=pair end end
  for id,r in pairs(s.zones)do
   local pair=wanted[id];local sig=pair and signature(point(pair.entrances[1]),point(pair.exits[1]))
   if not pair or r.signature~=sig then remove(r.actor);s.zones[id]=nil end
  end
  local class=#pairs_>0 and not s.loadError and resident(s)
  s.awaitingClass=#pairs_>0 and not class and not s.loadError
  for id,pair in pairs(wanted)do if class and not s.zones[id]then
   local entry,exit=point(pair.entrances[1]),point(pair.exits[1]);local r={signature=signature(entry,exit)};s.zones[id]=r
   local ok,why=pcall(Zone.spawn,E,class,gm,entry,exit,function(actor)r.actor=actor end,pair.exits[1].actor)
   if ok then log('marker pair active: '..X.TeleporterPairs.label(pair.colour)..' entrance='..id..' exit='..pair.exits[1].id)
   else r.error=tostring(why);log('marker pair '..id..' unavailable: '..r.error)end
  end end
  if s.loadError then s.problems[#s.problems+1]=s.loadError end
  overlay(s,pc,playing)
  local summary=table.concat(s.problems,' | ')
  X.once('teleporter-map-problems','TeleporterCheck',summary=='' and #pairs_..' complete pair(s)'or 'Map problem: '..summary)
 end
 -- The carrier loader may run in vanilla Hunt/Objective with FAPP's normal
 -- hooks gated off. Preserve only endpoint bytes on these exact loaded actors;
 -- the one subsequent current-world query completes discovery after load.
 assert(E.on_call('/Game/Blueprints/Match/BFL_MapLayoutLoading.BFL_MapLayoutLoading_C:LoadStatics','post',function(_,args)
  if not X.C.CreativeMaps then return end
  api.invalidate(true)
  local rows,loaded,context=X.values(args[3]),X.values(args[5]),args[4]
  for i,row in ipairs(rows)do
   local info=X.decode(row.MaterialIndices)
   if info and info.kind>=3 then
    local actor=loaded[i]
    assert(X.Lifetime.rawValid(context)and X.Lifetime.rawValid(actor),'loaded teleporter carrier unavailable')
    assert(actor:GetClass():GetFName():ToString()==X.CARRIERS[info.kind]:match('%.(.+)$')
     and actor:GetWorld():GetAddress()==context:GetWorld():GetAddress(),'loaded teleporter carrier class/world differs')
    if actor:HasAuthority()then
     assert(X.decode(row.MaterialIndices,#X.values(actor.MaterialOverwrites)),'loaded teleporter material prefix differs')
     assert(E.set(actor,'SavedMaterialIndices',X.values(row.MaterialIndices)),'loaded teleporter metadata restore refused')
    end
    X.Registry.track(actor)
   end
  end
 end),'teleporter native layout load hook unavailable')
 -- One scoped tick also serves vanilla modes where the FAPP event lane is idle.
 local elapsed=0
 assert(E.on_tick(function(delta,context)
  local mode=FAPP_MODE and FAPP_MODE.state
  if not mode or mode.mode=='menu'then return end
  elapsed=elapsed+(delta or 0)
  if elapsed>=.25 then elapsed=0;X.guard('Teleporters/world',api.poll)(context)end
 end),'teleporter world tick unavailable')
 X.Lifetime.onReset(api.reset)
 FAPP_API.own(api.cleanup,api.reset)
 X.Teleporters=api
 return api
end
return M
