-- Reversible per-layout base scenery suppression; chat + legacy console interfaces.
local M={}
local HEADER='FAPP_HIDDEN_V1'
local LIMIT=256
local STATUE={
 SM_WomanStatue02B_26=true,
 SM_Crystal16=true,SM_Crystal17=true,SM_Crystal18=true,SM_Crystal19=true,
 SM_Crystal20=true,SM_Crystal21=true,SM_Crystal22=true,
 NS_DesertBLueCrystal=true,
 SM_RuneRayCircle3=true,SM_RuneRayCircle4=true,SM_RuneRayCircle5=true,
}
local function copy(t) local r={} for k,v in pairs(t) do r[k]=v end return r end
local function equal(a,b) for k in pairs(a) do if not b[k] then return false end end;for k in pairs(b) do if not a[k] then return false end end;return true end
local function keys(t) local r={} for k in pairs(t) do r[#r+1]=k end table.sort(r) return r end
local function safe(s) return type(s)=='string' and #s>0 and #s<=1024 and not s:find('[%c]') end
function M.encode(level,set)
 assert(safe(level),'invalid level')
 local rows={HEADER,level}
 local list=keys(set); assert(#list<=LIMIT,'too many hidden actors')
 for _,key in ipairs(list) do assert(safe(key),'invalid actor identity'); rows[#rows+1]=key end
 return table.concat(rows,'\n')..'\n'
end
function M.decode(text,level)
 assert(type(text)=='string' and #text<=300000,'invalid suppression file')
 local rows={}
 for line in (text..'\n'):gmatch('(.-)\n') do
  line=line:gsub('\r$','')
  if line~='' then rows[#rows+1]=line end
 end
 assert(rows[1]==HEADER and rows[2]==level,'suppression file version/map mismatch')
 local set={}
 for i=3,#rows do
  assert(safe(rows[i]) and not set[rows[i]],'invalid/duplicate actor identity')
  set[rows[i]]=true
 end
 assert(#rows-2<=LIMIT,'too many hidden actors')
 return set
end
function M.init(X)
 local owner=dofile(assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))..'baseworld_owner.lua')
 if not X.hideKeysRegistered then
  X.hideKeysRegistered=true
  for key,action in pairs({Home='aim',Insert='_aimhide',PageUp='undo'}) do
   FAPP_API.hotkey({id='hide_'..action,default_chord=key,
    description=({_aimhide='Hide tool: hide aimed object',aim='Hide tool: aim mode on/off',
     undo='Hide tool: undo last hide'})[action],context={'creative'},ungated=true},function()
    assert(X.Suppression,'hide tool not initialized')
    X.Suppression.key(action)
   end)
  end
 end
 if owner.enabled then
  -- Build the unchanged fallback only when the optional owner leaves.
  local delegate
  local api={}
  for _,name in ipairs({'poll','tick','reset','cleanup','abandon','active','enqueue','key'}) do
   api[name]=function(...)
    if owner.enabled then
     if name=='key' then return assert(owner.service(),'BaseWorldPlus hide service unavailable').key(...) end
     return name=='active' and false or nil
    end
    if not delegate then delegate=M.init(X) end
    return delegate[name](...)
   end
  end
  X.Suppression=api
  X.log('Suppression','BaseWorldPlus runtime capability owns hiding; FAPP yielded')
  owner.watch(function() if not owner.enabled then X.revision=(X.revision or 0)+1 end end)
  return api
 end
 local H,C=X.H,X.C
 local api,queue={},{}
 local state
 local clientState
 local pendingRestores={}
 local geometryDir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
 local D=assert((X.api or FAPP_API).map_document,'common document service required')
 local Scope=dofile(geometryDir..'maps_geometry_scope.lua')
 local Store=dofile(geometryDir..'maps_geometry_io.lua')
 local GeometrySteps=dofile(geometryDir..'scenery_steps.lua')
 local Native=dofile(geometryDir..'maps_geometry_native.lua')
 local function tokenCurrent(token) return token and not X.Lifetime.transition and D.current(token) end
 local function bindContext(ctx,client)
  if not ctx then return end
  local token,v=D.capture()
  if not token or not D.current(token) or v.world~=ctx.level
   or v.document_kind=='not_creative' or v.role~=(client and 'client' or 'host') then return end
  if client and (v.document_kind~='saved' or client.level~=v.world or client.name~=v.name
   or client.document_generation~=v.source_generation or client.document_revision~=v.source_revision) then return end
  if X.Lifetime.world and ctx.world~=X.Lifetime.world then return end
  local N=Native.new(X,function() return tokenCurrent(token)==true end)
  if not N.valid(ctx.gm) or N.worldKey(ctx.gm)~=ctx.world or N.pipeKey(ctx.gm)~=v.actor_key then return end
  ctx.documentToken=token;ctx.documentGeneration=v.document_generation;ctx.ownerGeneration=v.owner_generation
  ctx.worldGeneration=v.world_generation;ctx.worldKey=v.world_key;ctx.epoch=X.Lifetime.epoch;ctx.coreEpoch=v.core_epoch
  ctx.documentName=v.name;ctx.documentKind=v.document_kind
  if not client then ctx.path=v.target_path end
  ctx.geometryScope=Scope.new(D,X.Lifetime,X.Registry,ctx)
  return ctx
 end
 local function lease(s,cleanup)
  return s.geometryScope and (cleanup and s.geometryScope.cleanup() or s.geometryScope.edit())
 end
 local function nativeOwner(s,l,actorCheck)
  return Native.new(X,function()
   return s.geometryScope.current(l)==true and (not actorCheck or actorCheck()==true)
  end)
 end
 local function native(s,l,fn,...)
  local N=nativeOwner(s,l)
  if fn==X.call then return N.call(...) end
  if fn==X.read then return N.read(...) end
  error('unscoped geometry Native operation',0)
 end
 local function checked(s,l,a,identity,class,admission)
  assert(s.geometryScope.actor(l,a,identity,class,admission),'geometry actor owner unavailable')
 end
 local function actorGuard(s,l,r)
  return function()
   s.geometryScope.check(l);checked(s,l,r.actor,r.identity,r.class,r.admission)
   assert(not r.components or not r.components.identity or not (X.Lifetime.retired or {})[r.components.identity],'geometry component retired')
  end
 end
 local function validate(s,l,a,identity,guard)
  local valid,full,key
  local step=GeometrySteps.check(nativeOwner(s,l,guard and function() guard();return true end).bridge(),a,s.world,function(ok,f,k) valid,full,key=ok,f,k end,identity,guard or function() s.geometryScope.check(l) end)
  repeat until step()
  assert(valid,'geometry actor retired/replaced')
  return full,key
 end
 local function scoped(s,l,check)
  return nativeOwner(s,l,check).bridge()
 end

 local function log(s) X.log('Suppression',s) end
 local function context()
  if not C.CreativeMaps or X.Lifetime.transition then return end
  local token,v=D.capture()
  if not token or not tokenCurrent(token) or v.role~='host' or v.document_kind=='not_creative'
   or not safe(v.world) then return end
  local path=v.target_path
  if v.document_kind=='saved' and (type(path)~='string' or not path:lower():match('%.pl$')
   or not (path:sub(1,1)=='/' or path:match('^%a:[/\\]'))) then return end
  local N=Native.new(X,function() return tokenCurrent(token)==true end)
  for _,class in ipairs({'B_CreativeGameMode_C','B_ObjectiveGameMode_C','B_GameMode_C'}) do
   -- Registry.list may perform an opaque validity walk. Use admitted scalar
   -- membership, then explicitly guard each Native lookup and invocation.
   for id,gm in pairs(X.Registry.buckets[class] or {}) do
    local md=(X.Registry.metadata[class] or {})[id]
    if md and md.world==X.Lifetime.world and not (X.Lifetime.retired or {})[id]
     and N.valid(gm) and N.authority(gm) and N.pipeKey(gm)==v.actor_key then
     return bindContext({gm=gm,path=path,level=v.world,world=X.Lifetime.world,creative=class=='B_CreativeGameMode_C'})
    end
   end
  end
 end
 local function restore(s)
  if X.Lifetime.transition or s.epoch~=X.Lifetime.epoch then s.applied={};return true end
  local l=lease(s,true)
  if not l then s.cleanup_pending=next(s.applied)~=nil;return not s.cleanup_pending end
  local failed={}
  for key,r in pairs(s.applied) do
   if (X.Lifetime.retired or {})[r.identity] then -- delivered native retirement owns this actor
   else
    local guard=actorGuard(s,l,r)
    local N=nativeOwner(s,l,function() guard();return true end)
    local ok,err=pcall(function()
     guard();validate(s,l,r.actor,r.identity,guard)
     if r.hidden~=nil then
      guard();N.call(r.actor,'SetActorHiddenInGame',r.hidden)
      guard();assert(N.read(r.actor,'bHidden')==r.hidden,'actor did not restore hidden flag')
     end
     if r.collision~=nil then
      guard();N.call(r.actor,'SetActorEnableCollision',r.collision)
      guard();assert(N.read(r.actor,'bActorEnableCollision')==r.collision,'actor did not restore collision flag')
     end
    end)
    if X.Lifetime.transition or s.epoch~=X.Lifetime.epoch then s.applied={};return true end
    if not ok then failed[key]=r;s.cleanup_error=err end
   end
  end
  s.applied=failed;s.cleanup_pending=next(failed)~=nil
  return not s.cleanup_pending
 end
 -- Failed live rollback stays owned until a retry succeeds. Proven travel
 -- drops snapshots before any read through departing engine objects.
 local function generation() return WIR_RUNTIME and WIR_RUNTIME.world_generation end
 local function rememberRestore(s)
  if s and next(s.applied or {}) then
   pendingRestores[#pendingRestores+1]={snapshot=s,
    epoch=X.Lifetime.epoch,generation=generation()}
  end
 end
 local function retryRestores()
  if X.Lifetime.transition or WIR_RUNTIME and WIR_RUNTIME.loading then pendingRestores={};return true end
  local failed={}
  for _,r in ipairs(pendingRestores) do
   if r.epoch==X.Lifetime.epoch and r.generation==generation() then
    if not restore(r.snapshot) then failed[#failed+1]=r end
   end
  end
  pendingRestores=failed
  local errors={};for _,r in ipairs(failed) do local s=r.snapshot;errors[#errors+1]='hidden scenery '..tostring(s.level)..'/'..tostring(s.documentName)..': '..tostring(s.cleanup_error or 'rollback document unavailable') end
  return #failed==0,table.concat(errors,' | ')
 end
 local function inventory(s)
  local l=assert(lease(s,false),'geometry document retired');local found={}
  for _,class in ipairs({'StaticMeshActor','NiagaraActor','DecalActor'}) do
   for id,a in pairs(X.Registry.buckets[class] or {}) do
    if X.Registry.metadata[class][id].world==s.world then
     local admission=assert(s.geometryScope.admission(l,a,id,class))
    local guard=function() s.geometryScope.check(l);checked(s,l,a,id,class,admission) end
     local full,key=validate(s,l,a,id,guard)
     if native(s,l,X.call,a,'HasAnyFlags',(EObjectFlags and EObjectFlags.RF_WasLoaded) or 0x80000)==true then
      local identity=full:gsub('UEDPIE_%d+_','');local name=identity:match('[:%.]PersistentLevel%.([%w_]+)$')
      if name and identity:find('/Game/Maps/',1,true) and safe(identity) then
       assert(not found[identity],'ambiguous actor identity');found[identity]={actor=a,name=name,identity=key,class=class,admission=admission}
      end
     end
    end
   end
  end
  return found
 end
 local function apply(s,desired)
  local l=assert(lease(s,false),'geometry document retired')
  local found=next(desired) and inventory(s) or {}
  for key in pairs(desired) do assert(found[key],'saved actor not found: '..key) end
  if not restore(s) then return false,'could not restore previous state' end
  local ok,err=pcall(function()
   for _,key in ipairs(keys(desired)) do
    local row=found[key];local a=row.actor
    local r={actor=a,identity=row.identity,class=row.class,admission=row.admission}
    local guard=actorGuard(s,l,r);local N=nativeOwner(s,l,function() guard();return true end);guard();validate(s,l,a,r.identity,guard)
    r.hidden=N.read(a,'bHidden');guard()
    r.collision=N.read(a,'bActorEnableCollision');guard()
    assert(type(r.hidden)=='boolean' and type(r.collision)=='boolean','actor flags unavailable')
    s.applied[key]=r -- own partial allocation/mutation before any Native setter
    guard();N.call(a,'SetActorHiddenInGame',true)
    guard();N.call(a,'SetActorEnableCollision',false)
    guard();assert(N.read(a,'bHidden')==true,'actor did not accept hidden flag')
    guard();assert(N.read(a,'bActorEnableCollision')==false,'actor did not accept collision flag')
   end
  end)
  if not ok then
   if tokenCurrent(l.token) then restore(s) else s.cleanup_pending=next(s.applied)~=nil end
   return false,err
  end
  return true
 end
 local Files=(X.api or FAPP_API).shared('Core').geometry_files.new(X.api or FAPP_API,X,M,Store,function()return state end)
 local function load(s)
  s.applied=s.applied or {};s.desired=s.desired or {};s.committed=s.committed or {};s.undo={}
  local ok,rows,dirty=pcall(Files.read,s)
  if not ok then Files.failed(s,rows);error(rows,0)end
  Files.loaded(s);s.error=nil
  s.applied={};s.desired=rows;s.undo={};s.pendingApply=false
  s.committed=dirty and {}or copy(rows);s.geometryRevision=0;s.dirty=dirty
  if not s.path and not next(rows)then return end
  s.pendingApply=true
  if X.work then
   applyAsync(s,s.desired,function(ok,err)
    s.pendingApply=not ok;s.error=not ok and tostring(err)or nil
    if ok then log('loaded '..#keys(s.desired)..' hidden actors for '..tostring(s.path))end
   end)
  else
   local ok,err=apply(s,s.desired);assert(ok,err);s.pendingApply=false
   log('loaded '..#keys(s.desired)..' hidden actors for '..tostring(s.path))
  end
 end
 local function change(s,set)
  assert(s.creative,'edit suppression only in Creative')
  assert(tokenCurrent(s.documentToken),'geometry document retired')
  local changeToken=s.documentToken
  local previous=copy(s.desired)
  local ok,err=apply(s,set)
  if not ok then
   if not tokenCurrent(changeToken) then s.cleanup_pending=next(s.applied)~=nil;error(err,0) end
   local recovered,rerr=apply(s,previous)
   if not recovered then log('rollback incomplete: '..tostring(rerr)) end
   error(err)
  end
  assert(tokenCurrent(changeToken),'geometry document retired')
  s.undo[#s.undo+1]=previous
  s.desired=copy(set)
  -- Like every other Creative edit: written to the sidecar only by a manual
  -- Save / Save As (owned Native operation participant); leaving without saving discards it.
  s.geometryRevision=(s.geometryRevision or 0)+1
  s.dirty=not equal(s.desired,s.committed or {})
  if X.ModSync then X.ModSync.publish(s.gm,s.level,s.desired,s.documentToken) end
  log(#keys(set)..' hidden actors (unsaved) for '..tostring(s.path or '(unsaved document)'))
 end
 local function undo(s)
  local previous=s.undo[#s.undo]; assert(previous,'nothing to undo in this layout session')
  change(s,previous)
  table.remove(s.undo); table.remove(s.undo)
 end
 local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
 local tools=dofile(dir..'maps_hide_tools.lua').init(X,{inventory=inventory,change=change,undo=undo,enqueue=function(...) return api.enqueue(...) end,
  current=function(s) return s and tokenCurrent(s.documentToken) end,
  nativeOwner=function(s,cleanup,actor,id,class,parentCurrent,admission)
   local l=assert(lease(s,cleanup),'geometry document unavailable')
   return nativeOwner(s,l,function()
    return (not parentCurrent or parentCurrent()==true) and (not actor or s.geometryScope.actor(l,actor,id,class,admission)==true)
   end)
  end,
  blinkGuard=function(s,a,id,class,cleanup)
   local l=assert(lease(s,cleanup),'blink document cleanup pending')
   return function() s.geometryScope.check(l);checked(s,l,a,id,class) end
  end,
  editable=function() return state and state.creative and not state.error and C.CreativeMaps and not X.Lifetime.transition end})
 local function run(s,args,chat)
  local action=args[1] or 'help'
  if action=='cleanup' then assert(api.cleanup(),'hide cleanup pending; replacement blocked');return end
  if chat or action=='near' or action=='aim' or action=='save' or tonumber(action) or (action=='show' and tonumber(args[2])) then
   return tools.run(s,args)
  end
  assert(tools.reset()~=false,'hide cleanup pending; use /hide cleanup') -- before any backend snapshot
  local token,view=D.capture()
  assert(token and type(view)=='table','Save the Creative layout first, then use bwhide')
  assert(view.role=='host','Host only: guests cannot edit base objects')
  assert(view.document_kind=='saved','Save the Creative layout first, then use bwhide')
  assert(s,'Current Creative world scenery is not available; use bwhide reload')
  assert(not s.error or action=='reload','layout suppression needs reload: '..tostring(s.error))
  if action=='diagnose' then
   local l=assert(lease(s,false));local N=nativeOwner(s,l)
   for _,cls in ipairs({'StaticMeshActor','NiagaraActor','DecalActor'}) do
    local n=0
    for id,a in pairs(X.Registry.buckets[cls] or {}) do
     if s.geometryScope.actor(l,a,id,cls) and N.valid(a) then
      log('raw='..N.call(a,'GetFullName')..'; sameWorld='..tostring(N.sameWorld(a,s.gm)))
      n=n+1;if n>=5 then break end
     end
    end
    log(cls..' admitted count='..n)
   end
  elseif action=='list' then
   log('eligible actors='..#keys(inventory(s)))
   local filter=(args[2] or ''):lower()
   for key,r in pairs(inventory(s)) do
    if r.name:lower():find(filter,1,true) then log((s.desired[key] and '[hidden] ' or '')..r.name) end
   end
  elseif action=='inspect' then
    local matched=false
    for _,r in pairs(inventory(s)) do
        if r.name==args[2] then
            matched=true
            local a=r.actor
            local l=assert(lease(s,false));local N=nativeOwner(s,l,function() return s.geometryScope.actor(l,a,r.identity,r.class,r.admission)==true end)
            local component=N.read(a,'StaticMeshComponent')
            local collision='unknown'
            if N.valid(component) then
                local ok,value=pcall(function() return N.call(component,'GetCollisionEnabled') end)
                if ok then collision=tostring(value) end
            end
            log(r.name..' hidden='..tostring(N.read(a,'bHidden'))..
                ' actorCollision='..tostring(N.read(a,'bActorEnableCollision'))..
                ' primitiveCollision='..collision)
        end
    end
    assert(matched,'no eligible actor matched')
  elseif action=='hide' or action=='show' or action=='statue' then
   local set=copy(s.desired); local count=0
   if action=='statue' then assert(s.level=='DesertTown','statue preset is DesertTown only') end
   for key,r in pairs(inventory(s)) do
    if (action=='statue' and STATUE[r.name]) or (action~='statue' and r.name==args[2]) then
     set[key]=action~='show' or nil; count=count+1
    end
   end
   assert(count>0,'no eligible actor matched')
   if action=='statue' then assert(count==12,'statue group incomplete; no changes applied') end
   change(s,set)
  elseif action=='clear' then change(s,{})
  elseif action=='undo' then
   undo(s); log('Undone; Save the layout to commit geometry')
  elseif action=='reload' then
   assert(restore(s),'restore failed')
   load(s)
   s.error=nil
  else
   log('faphide list [text] | inspect <exact actor name> | hide <exact actor name> | show <exact actor name> | statue | undo | clear | reload')
  end
 end
 if type(FAPP_SERVICES.runtime.command)=='function' then
  FAPP_SERVICES.runtime.command('faphide',function(_,parameters)
   api.enqueue(X.values(parameters),false)
   return true
  end)
 end
 function api.enqueue(args,chat,key)
  if owner.enabled then return end
  if #queue<16 then queue[#queue+1]={args=args,chat=chat,key=key}
  elseif X.queueReply then X.queueReply('Hide','Command queue full; retry') end
 end
 function api.key(action)
  if owner.enabled then local service=owner.service(); if service and service.key then return service.key(action) end
  else return tools.key(action) end
 end
 function api.active() return not owner.enabled and (tools.active() or #queue>0) end
 function api.tick(time)
  if owner.enabled then return end
  if #queue>0 then api.poll() end
  tools.tick(state,time)
 end
 function api.poll()
  if owner.enabled then return end
  if X.Lifetime.transition then return end
  if not retryRestores() then return end
  local ctx=context()
  if X.ModSync then
   local snapshot=X.ModSync.clientSnapshot()
   if not ctx and snapshot and C.CreativeMaps and X.Lifetime.world==snapshot.world then
    if clientState and (clientState.world~=snapshot.world or clientState.session~=snapshot.session) then
     if not restore(clientState) then return end
     clientState=nil
    end
    if not clientState then clientState=bindContext({gm=snapshot.gm,world=snapshot.world,level=snapshot.level,session=snapshot.session,applied={}},snapshot);if not clientState then return end end
    if clientState.revision~=snapshot.revision then
     local ok,result,err=pcall(apply,clientState,snapshot.desired)
     if ok and result then
      clientState.revision=snapshot.revision
      clientState.desired=copy(snapshot.desired)
      log('client applied revision='..snapshot.revision..'; hidden='..#keys(snapshot.desired))
     else
      if clientState.desired then pcall(apply,clientState,clientState.desired) end
      X.once('suppression-client-wait:'..snapshot.world,'Suppression','waiting for local map actors: '..tostring(ok and err or result))
     end
    end
   elseif clientState then
    if not restore(clientState) then return end
    clientState=nil
   end
  end
  local different=state and (not ctx or ctx.path~=state.path or ctx.world~=state.world or ctx.documentGeneration~=state.documentGeneration or ctx.ownerGeneration~=state.ownerGeneration)
  if different then
   if X.ModSync and tokenCurrent(state.documentToken) then X.ModSync.publish(state.gm,state.level,{},state.documentToken) end
   if not restore(state) then return end
   if tools.reset()==false then return end
   state=nil
  end
  if ctx and not state then
   state=ctx
   local ok,err=pcall(load,state)
   if not ok then state.error=tostring(err); log('load refused: '..state.error) end
   if X.ModSync then
    X.ModSync.publish(state.gm,state.level,state.error and {} or state.desired,state.documentToken)
    X.ModSync.warn(state.gm,state.path)
   end
  end
  if state and state.error and state.pendingApply and state.lastAttempt~=(X.Registry and X.Registry.revision) then
   state.lastAttempt=X.Registry and X.Registry.revision
   local ok,result,err=pcall(apply,state,state.desired)
   if ok and result then state.error=nil;state.pendingApply=false
   else state.error=tostring(ok and err or result) end
  end
  local pending=queue; queue={}
  for _,request in ipairs(pending) do
   -- Hotkey actions never open the modal dialog (it kept input after closing in
   -- Creative); their result is visible on the object and in UE4SS.log.
   if X.command and not request.key then X.command(run,state,request.args,request.chat)
   else
    local ok,err=pcall(run,state,request.args,request.chat)
    if not ok then log('command refused: '..tostring(err)) end
   end
  end
  if state and X.ModSync and not state.error then X.ModSync.publish(state.gm,state.level,state.desired,state.documentToken) end
 end
 local ownershipEpoch=X.Lifetime.epoch
 function api.abandon()
  state=nil;clientState=nil;queue={};pendingRestores={};tools.abandon();ownershipEpoch=X.Lifetime.epoch
  return true
 end
 function api.cleanup()
  if X.Lifetime.transition or ownershipEpoch~=X.Lifetime.epoch then return api.abandon() end
  local done,why=tools.cleanup(state);if done==false then return false,why end
  return api.reset()
 end
 function api.reset()
  if X.Lifetime.transition or ownershipEpoch~=X.Lifetime.epoch then return api.abandon() end
  local done,why=tools.reset();if done==false then return false,why end
  rememberRestore(state);rememberRestore(clientState)
  state=nil;clientState=nil;queue={}
  return retryRestores()
 end
 X.Lifetime.onReset(function() Files.clear();api.abandon() end)
 if FAPP_API and FAPP_API.own then FAPP_API.own(api.cleanup,api.abandon) end
 D.on_change(function(v,reason)
  if state and v and reason=='native manual target' and v.owner_generation==state.ownerGeneration
   and v.document_generation==state.documentGeneration and v.world_key==state.worldKey
   and v.world_generation==state.worldGeneration and v.core_epoch==(state.coreEpoch or state.epoch) then
   local token,current=D.capture()
   if token and D.current(token) and current.publication_revision==v.publication_revision then
    state.documentToken=token;state.path=v.target_path;state.documentName=v.name;state.documentKind=v.document_kind
   end
  end
  if api.invalidate then api.invalidate() end
 end)
 X.hook('Suppression',X.CREATIVE,'B_CreativeGameState','LoadLayoutMulticast',function() end)
 X.hook('Suppression','/Game/Blueprints/Core/','B_GameMode','LoadPropLayoutFromSaveGame',function() end)
 X.cachedPoll(api,function() return #queue>0 end)
 owner.watch(function()
  if owner.enabled then assert(api.cleanup()~=false,'fallback hide cleanup pending; provider replacement refused')
  elseif api.invalidate then api.invalidate() end
 end)
 FAPP_API.shared('Core').capabilities.claim(FAPP_API,'fapp_geometry',{current=function()return FAPP_API.is_live()and not owner.enabled end})
 X.Suppression=api
 return api
end
return M
