-- Presentation facts only, carried by the already verified owned-controller RPC
-- pair. This envelope never proposes rules or changes replicated gameplay state.
local M={VERSION=1}
local PREFIX='FAPPHUD1:'
local PC='/Game/Blueprints/Player/B_PlayerController.B_PlayerController_C:'
local reasons={['']=0,['Waiting for players']=1,['Waiting for players to choose a team']=2,
    ['Waiting for a player on each team']=3,['Waiting for ready players']=4,['Starting match']=5}
local labels={[0]='',[1]='Waiting for players',[2]='Waiting for players to choose a team',
    [3]='Waiting for a player on each team',[4]='Waiting for ready players',[5]='Starting match'}
local function integer(value,low,high)
    return type(value)=='number' and value==math.floor(value) and value>=low and value<=high
end
function M.init(H)
    local L,read=H.Lifetime,FAPP_SERVICES.runtime.read
    local clock=H.now or os.time
    local api,peers,queue={revision=0}, {},{}
    local localPC,nativeInput,nativeOwned,objects,scope,guest,host,received
    local serial=0
    local function nonce() serial=serial+1; return tostring(math.floor(clock()))..'-'..serial end
    local function clear()
        if FAPP_WORK then FAPP_WORK.cancel('HUD:metadata') end
        peers={}; queue={}; guest=nil; host=nil; received=nil; scope=nil
        localPC=nil; nativeInput=nil; nativeOwned=false; objects=nil
        api.revision=api.revision+1
    end
    local function live(o) return not L.transition and L.valid(o) end
    local function localController(pc) return live(pc) and pc:IsLocalPlayerController()==true end
    local function controller()
        -- Native input adoption identifies a replacement controller even while
        -- its predecessor is still present in the registry during teardown.
        local input=WIR_RUNTIME and WIR_RUNTIME.input and WIR_RUNTIME.input.controller
        if input~=nativeInput or objects~=H.Registry.revision or (localPC~=nil and not live(localPC)) then
            nativeInput=input; objects=H.Registry.revision; localPC=nil
            -- Re-certify the native choice after inventory changes instead of
            -- letting list order restore a still-live departing controller.
            if H.class(input,'B_ObjectivePlayerController_C') and localController(input) then
                nativeOwned=true; localPC=input; return localPC
            end
            -- Once native input identified this connection's owner, losing it
            -- makes presentation unknown until native adoption recovers. A
            -- retained registry handle cannot take over that authority.
            if nativeOwned then return end
            -- Bootstrap without a native input proof remains possible for one
            -- unambiguous current local controller; two live locals are unsafe.
            for _,pc in ipairs(H.Registry.list('B_ObjectivePlayerController_C') or {}) do
                if localController(pc) then
                    if localPC and not L.same(localPC,pc) then localPC=nil; break end
                    localPC=pc
                end
            end
        end
        return localPC
    end
    local function context(pc)
        -- Check the epoch before any retained UObject access. The package's Plus
        -- admission gate remains the authority for using these presentation facts.
        if L.transition or not FAPP_MODE or not FAPP_MODE.state.plus or not live(pc) then return end
        local g=H.object('/Script/Engine.Default__GameplayStatics')
        local gs=g:GetGameState(pc)
        if not H.class(gs,'B_ObjectiveGameState_C') or not L.sameWorld(pc,gs) then return end
        local round=read(gs,'CurrentRound')
        if not integer(round,0,255) then return end
        local key=tostring(L.epoch)..':'..L.key(gs)..':'..tostring(round)..':'..L.key(pc)
        return gs,round,key
    end
    local function current()
        if L.transition then return end
        local pc=controller(); local gs,round,key=context(pc)
        if key~=scope then
            local wasKnown=received~=nil
            peers={}; queue={}; received=nil; host=nil; guest=nil; scope=key
            api.revision=api.revision+1
            if key then
                if pc:HasAuthority()==true then host={epoch=nonce(),mark=nil,revision=0}
                else guest={hello=nonce(),next=0,deadline=clock()+30} end
            end
            if FAPP_WORK then FAPP_WORK.cancel('HUD:metadata') end
            if wasKnown then H.changed() end
        end
        return pc,gs,round,key
    end
    local function enqueue(pc,text,up)
        if #queue>=64 then return false end
        queue[#queue+1]={pc=pc,key=L.key(pc),scope=scope,text=text,up=up}; return true
    end
    local function facts(gs,round)
        local gm,mm,currentGS=H.world(gs)
        if not gm or not L.same(currentGS,gs) then return end
        local rules=H.settings(mm)
        local infinite=rules.MaxLives=='infinite'
        if not infinite and not integer(rules.MaxLives,1,255) then return end
        local reason=H.reason(gs)
        return {infinite=infinite,maximum=infinite and 0 or rules.MaxLives,
            ready=rules.StartWhenEveryoneReady==true,unequal=rules.UnequalTeams==true,
            empty=rules.AllowEmptyTeams==true,reason=reasons[reason] or 6,round=round}
    end
    local function mark(f)
        return table.concat({f.round,f.infinite and 1 or 0,f.maximum,f.ready and 1 or 0,
            f.unequal and 1 or 0,f.empty and 1 or 0,f.reason},':')
    end
    local function publish(peer,f)
        if enqueue(peer.pc,PREFIX..'STATE:'..peer.token..':'..host.revision..':'..host.mark,false) then
            peer.sent=host.revision
        end
    end
    local function update(gs,round)
        local f=facts(gs,round); if not f then return end
        local value=mark(f)
        if value~=host.mark then host.mark=value; host.revision=host.revision+1 end
        return f
    end
    function api.upstream(self,value)
        local text=FAPP_SERVICES.runtime.text(FAPP_SERVICES.runtime.unwrap(value))
        if type(text)~='string' or #text>180 or text:sub(1,#PREFIX)~=PREFIX then return end
        local localOwner,gs,round,key=current(); if not key or not host then return end
        local pc=FAPP_SERVICES.runtime.unwrap(self)
        if not live(pc) or pc:HasAuthority()~=true or localController(pc) or not L.sameWorld(pc,gs) then return end
        local address=L.key(pc); local peer=peers[address]; local now=clock()
        local hello=text:match('^FAPPHUD1:HELLO:([%d]+%-%d+)$')
        if hello and #hello<=40 then
            if peer and now-peer.helloTime<2 then return end
            if not peer then local count=0; for _ in pairs(peers) do count=count+1 end; if count>=32 then return end end
            peer={pc=pc,token=host.epoch..'.'..hello,helloTime=now,touched=now}
            peers[address]=peer
            enqueue(pc,PREFIX..'WELCOME:'..hello..':'..host.epoch,false)
            local f=update(gs,round); if f then publish(peer,f) end
        elseif peer and text==PREFIX..'GET:'..peer.token and (not peer.getTime or now-peer.getTime>=2) then
            peer.getTime=now; peer.touched=now
            local f=update(gs,round); if f then publish(peer,f) end
        end
    end
    function api.downstream(self,value)
        local text=FAPP_SERVICES.runtime.text(FAPP_SERVICES.runtime.unwrap(value))
        if type(text)~='string' or #text>180 or text:sub(1,#PREFIX)~=PREFIX then return end
        local pc,gs,round,key=current(); if not key or not guest then return end
        local destination=FAPP_SERVICES.runtime.unwrap(self)
        if not localController(destination) or destination:HasAuthority()==true or not L.same(pc,destination) then return end
        local hello,epoch=text:match('^FAPPHUD1:WELCOME:([%d]+%-%d+):([%d]+%-%d+)$')
        if hello and #hello<=40 and #epoch<=40 and hello==guest.hello then
            local token=epoch..'.'..hello
            -- A delayed WELCOME cannot roll an acknowledged hello back to a
            -- previous host epoch. A timeout starts a new hello when needed.
            if guest.token and guest.token~=token then return end
            if not guest.token then guest.token=token; guest.revision=0; received=nil; api.revision=api.revision+1 end
            guest.touched=clock(); return
        end
        local token,rev,r,inf,max,ready,unequal,empty,reason=text:match(
            '^FAPPHUD1:STATE:([%d%.%-]+):(%d+):(%d+):([01]):(%d+):([01]):([01]):([01]):(%d+)$')
        rev,r,max,reason=tonumber(rev),tonumber(r),tonumber(max),tonumber(reason)
        if token~=guest.token or not integer(rev,1,2147483647) or rev<(guest.revision or 0)
            or r~=round or not integer(reason,0,6) or not integer(max,0,255)
            or (inf=='1' and max~=0) or (inf=='0' and max<1) then return end
        if rev==guest.revision then
            if received and received.infinite==(inf=='1') and received.maximum==max
                and received.ready==(ready=='1') and received.unequal==(unequal=='1')
                and received.empty==(empty=='1') and received.reason==labels[reason] then guest.touched=clock() end
            return
        end
        received={infinite=inf=='1',maximum=max,ready=ready=='1',unequal=unequal=='1',
            empty=empty=='1',reason=labels[reason],round=r,token=token,revision=rev,scope=key}
        guest.revision=rev; guest.touched=clock()
        api.revision=api.revision+1
        H.changed()
    end
    function api.policy(pc)
        local owner,gs,round,key=current()
        if not key or not live(pc) or not L.same(owner,pc) then return end
        if host then return facts(gs,round) end
        if received and received.scope==key and received.round==round then return received end
    end
    function api.poll()
        local pc,gs,round,key=current(); if not key then return end
        local now=clock()
        if host then
            if not next(peers) and #queue==0 then return end
            local f=update(gs,round)
            for id,peer in pairs(peers) do
                if not live(peer.pc) or not L.sameWorld(peer.pc,gs) or now-peer.touched>30 then peers[id]=nil
                elseif f and peer.sent~=host.revision then publish(peer,f) end
            end
        elseif guest then
            if guest.token and now-(guest.touched or 0)>15 then
                guest={hello=nonce(),next=0,deadline=now+30}; received=nil
                api.revision=api.revision+1; H.changed()
            end
            if now>=guest.next and (guest.token or now<=guest.deadline) then
                guest.next=now+2
                enqueue(pc,PREFIX..(guest.token and 'GET:'..guest.token or 'HELLO:'..guest.hello),true)
            end
        end
        if FAPP_WORK and FAPP_WORK.keys['HUD:metadata'] then return end
        local batch={}; for _=1,4 do local p=table.remove(queue,1); if not p then break end; batch[#batch+1]=p end
        local function dispatch(p)
            if L.transition or p.scope~=scope or not live(p.pc) or p.key~=L.key(p.pc) or not L.sameWorld(p.pc,gs) then return end
            if p.up then p.pc:ExecuteConsoleCommandFromClient(p.text) else p.pc:ClientSetRevisionNumber(p.text) end
        end
        if #batch>0 then
            if FAPP_WORK then FAPP_WORK.submit('HUD:metadata','HUD presentation metadata',FAPP_WORK.each(batch,dispatch))
            else for _,p in ipairs(batch) do dispatch(p) end end
        end
    end
    function api.reset() clear() end
    function api.matchBoundary(self)
        if L.transition then return end
        local actor=FAPP_SERVICES.runtime.unwrap(self)
        local _,gs,_,key=current()
        if not key or not live(actor) or not L.same(actor,gs) then return end
        -- The native match/round multicast proves this boundary even when a fast
        -- round-zero interval was not observed by the 500ms heartbeat.
        clear(); H.changed()
    end
    H.hook(PC..'ExecuteConsoleCommandFromClient',api.upstream)
    H.hook(PC..'ClientSetRevisionNumber',api.downstream)
    for _,name in ipairs({'OnGameStartedMulti','OnMatchStartedMulti'}) do
        H.hook('/Game/Blueprints/Gamemodes/ObjectiveMode/B_ObjectiveGameState.B_ObjectiveGameState_C:'..name,api.matchBoundary)
    end
    L.onReset(clear)
    return api
end
return M
