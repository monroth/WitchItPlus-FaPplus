-- Local endpoint presentation. The replicated FAPT bytes are the source of truth;
-- the vanilla zone remains a separate, server-owned overlap trigger.
local M={NAMES={'None','Island portal','Tower pad','Doorway','Green rune'}}
local SPHERE='/Game/StarterContent/Shapes/SM_Shape_Sphere.SM_Shape_Sphere'
-- Cooked translucent material; Color alpha controls the editor ghost opacity.
local GHOST='/Engine/EngineDebugMaterials/M_SimpleUnlitTranslucent.M_SimpleUnlitTranslucent'
local ISLAND='/Game/Blueprints/Unused/ObjectiveMode/B_WitchPortalVisualOnly.B_WitchPortalVisualOnly_C'
local DOOR='/Game/Environment/WitchHouse/WitchPortal/'
function M.assets(look,kind,stoneAge)
 if look==0 then return {SPHERE,GHOST} end
 if look==1 then return {ISLAND} end
 if look==2 then local n=kind==3 and 'NS_TowerPortalEntrance' or 'NS_TowerPortalExit';return {'/Game/Effects/Tower/'..n..'.'..n} end
 if look==3 then
  local n=kind==3 and 'MI_WitchPortalTwistEntry' or 'MI_WitchPortalTwistExit'
  return {DOOR..'SM_WitchPortal.SM_WitchPortal',stoneAge and '/Game/Environment/StoneAge/MI_WitchPortalStoneAge.MI_WitchPortalStoneAge' or DOOR..n..'.'..n}
 end
 assert(look==4,'invalid teleporter look')
 return {'/Game/Environment/WitchForest/SM_RuneRayCircle.SM_RuneRayCircle','/Game/Environment/WitchForest/MI_RuneRaysGreen.MI_RuneRaysGreen'}
end
function M.init(X)
 local E=assert(FAPP_API.Native.scope(FAPP_API.id));local H=X.H
 local api={};local records,candidates,held={},{},{};local worldKey,gameState,creativeState
 local function live(a)return a and X.live(a)end
 local function identity()return {Translation={X=0,Y=0,Z=0},Rotation={X=0,Y=0,Z=0,W=1},Scale3D={X=1,Y=1,Z=1}}end
 -- Object queries used by Creative TransformTrace include WorldStatic. This
 -- editor-only selector ignores every channel, including Projectile, Pawn and
 -- PhysicsBody: it can be selected by the editor without a blocking hit/sweep.
 local function noCollision(c)
  c:SetSimulatePhysics(false);c:SetGenerateOverlapEvents(false)
  c:SetCollisionProfileName(FName('NoCollision'),false);c:SetCollisionResponseToAllChannels(0);c:SetCollisionEnabled(0)
  c.bCanEverAffectNavigation=false
 end
 local function nonblocking(actor,hide)
  for _,c in ipairs(X.values(actor:K2_GetComponentsByClass(X.asset('/Script/Engine.PrimitiveComponent'))))do
   noCollision(c)
   if hide then c:SetVisibility(false,false);c:SetHiddenInGame(true,false)end
  end
 end
 local function remove(r,restore)
  for i=#r.components,1,-1 do
   local ok,why=E.destroy(r.components[i]);assert(ok,'teleporter look component: '..tostring(why));table.remove(r.components,i)
  end
  if r.cosmetic then local ok,why=E.destroy(r.cosmetic);assert(ok,'teleporter look actor: '..tostring(why));r.cosmetic=nil end
  if restore and live(r.actor)then
   for _,v in ipairs(r.original)do if H.valid(v.component)then
    v.component:SetCollisionProfileName(v.profile,false);v.component:SetCollisionEnabled(v.collision)
    v.component:SetVisibility(v.visible,false);v.component:SetHiddenInGame(v.hidden,false);v.component.bCanEverAffectNavigation=v.navigation
   end end
  end
 end
 local function component(r,cls)
  local c=assert(r.actor:AddComponentByClass(X.asset('/Script/'..(cls=='NiagaraComponent' and 'Niagara.' or 'Engine.')..cls),false,X.native(identity()),false),'teleporter '..cls..' unavailable')
  r.components[#r.components+1]=c;c:SetMobility(2);noCollision(c);return c
 end
 local function editor(a)
  if X.read(a,'IsPreview')==true then return true end
  if not gameState or not gameState:IsValid()then
   gameState=X.gameplay():GetGameState(a)
   creativeState=gameState and gameState:IsValid()and H.class(gameState,'B_CreativeGameState_C')
  end
  return creativeState and gameState:IsValid()and gameState.IsPlayTestMode~=true
 end
 local function present(r,info,editing)
  if not r.prepared then
  remove(r,false)
  -- No original rune mesh or child collider is retained as a visible endpoint.
  nonblocking(r.actor,true)
  if editing and X.read(r.actor,'IsPreview')~=true then
   r.selector=component(r,'BoxComponent');r.selector:SetBoxExtent(X.native({X=50,Y=50,Z=75}),false)
   r.selector.RelativeLocation.Z=75;r.selector:SetAbsolute(true,false,false);r.selector:SetAbsolute(false,false,false)
   r.selector:SetCollisionObjectType(0);r.selector:SetCollisionResponseToAllChannels(0);r.selector:SetCollisionEnabled(1)
  end
  if editing then
   local c=component(r,'TextRenderComponent');c:SetHorizontalAlignment(1);c:SetWorldSize(18)
   c.RelativeLocation.Z=115;c:SetAbsolute(true,false,false);c:SetAbsolute(false,false,false)
   c:K2_SetText(FText(X.NAMES[info.kind]..' — '..X.TeleporterPairs.label(info.colour)..(info.kind==4 and ' →' or '')))
   local colour=c.TextRenderColor
   for _,key in ipairs({'R','G','B'})do colour[key]=math.floor(math.max(.12,info.colour[key])^(1/2.2)*255+.5)end
   colour.A=210;c:SetTextRenderColor(colour)
  end
  r.prepared=true
  end
  r.ready=false
  if info.look==0 and not editing then r.ready=true;return end
  local paths=M.assets(info.look,info.kind,r.actor:GetWorld():GetFullName():lower():find('stoneage',1,true)~=nil)
  local assets={}
  for i,path in ipairs(paths)do held[path]=true;assets[i]=E.asset(path);if not assets[i]then return end end
  if info.look==1 then
   local p=r.actor:K2_GetActorLocation();local rot=r.actor:K2_GetActorRotation()
   r.cosmetic=assert(E.spawn_local(assets[1],r.actor,{X=p.X,Y=p.Y,Z=p.Z,Pitch=rot.Pitch,Yaw=rot.Yaw,Roll=rot.Roll},function(a)
    a:SetReplicates(false);a:SetActorEnableCollision(false)
   end),'island portal spawn unavailable')
   nonblocking(r.cosmetic,false)
   assert(r.cosmetic:K2_AttachToActor(r.actor,FName('None'),1,1,1,false),'island portal attachment unavailable')
  elseif info.look==2 then
   local c=component(r,'NiagaraComponent');c:SetAsset(assets[1],true);c:Activate(true)
  else
   local c=component(r,'StaticMeshComponent');assert(c:SetStaticMesh(assets[1]),'teleporter mesh assignment refused')
   c:SetMaterial(0,assets[2]);c:SetCastShadow(false)
   if info.look==0 then
    c:SetRelativeScale3D(X.native({X=.45,Y=.45,Z=.8}));c.RelativeLocation.Z=50
    c:SetAbsolute(true,false,false);c:SetAbsolute(false,false,false)
    local mid=assert(c:CreateDynamicMaterialInstance(0,assets[2],FName('None')),'teleporter ghost material unavailable')
    local colour={R=info.colour.R,G=info.colour.G,B=info.colour.B,A=.18}
    mid:SetVectorParameterValue(FName('Color'),X.native(colour))
   elseif info.look==4 then local scale=info.kind==3 and 1 or .65;c:SetRelativeScale3D(X.native({X=scale,Y=scale,Z=scale}))end
  end
  r.ready=true
  X.log('TeleporterLook',M.NAMES[info.look+1]..' kind='..info.kind..' editor='..tostring(editing)..' actor='..r.actor:GetFullName()..' collision=NoCollision Projectile=Ignore')
 end
 function api.update(a,editing,registered)
  if not registered and not live(a)then return end
  candidates[a:GetAddress()]=a
  local bytes=assert(E.read_bytes(a,'SavedMaterialIndices'),'teleporter data unavailable')
  local id=a:GetAddress();local r=records[id]
  if editing==nil then editing=editor(a)end
  local signature=bytes..tostring(editing)
  if r and r.signature==signature and (r.ready or r.failed)then return end
  local values={bytes:byte(1,#bytes)};local info=X.decode(values)
  if not info or info.kind<3 then
   if r then remove(r,true);records[id]=nil end
   return
  end
  if not r then
   r={actor=a,components={},original={}};records[id]=r
   for _,c in ipairs(X.values(a:K2_GetComponentsByClass(X.asset('/Script/Engine.PrimitiveComponent'))))do
    r.original[#r.original+1]={component=c,profile=c:GetCollisionProfileName(),collision=c:GetCollisionEnabled(),visible=c.bVisible,hidden=c.bHiddenInGame,navigation=c.bCanEverAffectNavigation}
   end
   -- Apply before waiting on any optional asset. Selection geometry is separate.
   nonblocking(a,true)
  end
  if r.signature~=signature then r.signature=signature;r.ready=false;r.prepared=false;r.failed=nil end
  if not r.ready and not r.failed then
   local ok,why=pcall(present,r,info,editing)
   if not ok then r.failed=tostring(why);X.log('TeleporterLook','failed '..a:GetFullName()..': '..r.failed)end
  end
 end
 function api.adopt(context)
  local world=context and context.world
  if not world then return end
  local key=world:GetAddress();if worldKey==key then return end
  if not live(context.controller)then return end
  api.reset();worldKey=key
  local actors,why=E.find(X.CARRIERS[2],context.controller);assert(actors,why)
  for _,a in ipairs(actors)do X.Registry.track(a);api.update(a)end
 end
 function api.reset()
  -- New Map may keep the same UWorld. Attached local actors must be destroyed,
  -- rather than abandoned on the assumption that travel will collect them.
  local ok,why=api.cleanup();assert(ok,why)
  records={};candidates={};worldKey=nil;gameState=nil;creativeState=nil
 end
 function api.cleanup()
  local errors={}
  for id,r in pairs(records)do
   local ok,why=pcall(remove,r,false)
   if ok then records[id]=nil else errors[#errors+1]='teleporter look '..tostring(id)..': '..tostring(why)end
  end
  if #errors>0 then return false,table.concat(errors,' | ')end
  for path in pairs(held)do E.release_asset(path)end;held={};candidates={};worldKey=nil;gameState=nil;creativeState=nil;return true
 end
 function api.poll()end
 -- Plain replicated byte arrays have no RepNotify UFunction in this engine.
 -- Read only registered rune actors, never rediscover the world on maintenance.
 -- Components attach to their carrier, so replicated movement needs no polling.
 local elapsed=0
 assert(E.on_tick(function(delta,context)
  if X.Lifetime.transition then return end
  api.adopt(context);elapsed=elapsed+(delta or 0);if elapsed<.25 then return end;elapsed=0
  local editing=context and context.controller and context.controller:IsValid() and editor(context.controller) or false
  for id,a in pairs(candidates)do
   if a:IsValid()and not a:IsActorBeingDestroyed()then X.guard('TeleporterLook/update',api.update)(a,editing,true)else
    local r=records[id];if r then remove(r,false);records[id]=nil end;candidates[id]=nil
   end
  end
 end),'teleporter local presentation tick unavailable')
 local stop=X.Registry.onCommitted(function(key)
  local a=X.Registry.buckets.BP_WitchRuneStone01_C and X.Registry.buckets.BP_WitchRuneStone01_C[key]
  if live(a)then candidates[a:GetAddress()]=a;X.guard('TeleporterLook/birth',api.update)(a)end
 end)
 -- Initial replicated bytes are present by actor BeginPlay. Disable the carrier
 -- immediately; the inexpensive byte observer handles subsequent replication.
 assert(E.on_call('/Game/Blueprints/StaticProps/Placeable/BP_PlaceableStaticProp.BP_PlaceableStaticProp_C:ReceiveBeginPlay','post',function(a)
  if H.class(a,'BP_WitchRuneStone01_C')then X.Registry.track(a);X.guard('TeleporterLook/BeginPlay',api.update)(a)end
 end),'teleporter carrier BeginPlay hook unavailable')
 X.Lifetime.onReset(api.reset)
 FAPP_API.own(function()stop();return api.cleanup()end,api.reset)
 X.EndpointLooks=api;return api
end
return M
