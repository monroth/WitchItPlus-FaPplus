-- FAPP-owned applied-label contract. No timers, broker topic, guessed OnRep or
-- shared WIR/Core mutation. A provider is a source boundary, not evidence that
-- a real Native implementation has been deployed.
local M={contract_version=1,semantics='GamemodeDisplayName.final_application'}
local function integer(n) return type(n)=='number' and n>=0 and n%1==0 and n<2147483648 end
local function copy(t) local r={};for k,v in pairs(t) do r[k]=v end;return r end
function M.new(api,Core,L,changed)
    assert(type(changed)=='function','label consumer required')
    local owner,binding;local generation=0;local version={};local stopped=false
    local function held(s)
        return owner==s and s~=nil and not L.transition and L.epoch==s.epoch
            and L.world==s.world and L.retired==s.retired and L.departed==s.departed
            and not L.retired[s.key] and not L.departed[s.world]
    end
    local function current(s)
        return held(s) and api.is_live()==true and held(s)
    end
    local function view(s)
        return {generation=s.generation,key=s.key,world=s.world,epoch=s.epoch,
            authority=s.authority,status=s.status,sequence=s.sequence,
            label=s.label,source=s.source}
    end
    local function notify(s,reason)
        local stamp=version
        local function live() return version==stamp and current(s) and version==stamp end
        if not live() then return end
        changed(view(s),live,reason)
    end
    local function cancel(s)
        local close=s and s.cancel
        if s then s.cancel=nil end
        if close then close() end -- provider cancellation must be pure and scoped
    end
    local function revoke(reason)
        local old=owner;owner=nil;version={}
        -- Rights disappear before arbitrary consumer/cancellation callbacks.
        if old then
            local stamp=version
            changed(nil,function() return owner==nil and version==stamp end,reason)
            cancel(old)
        end
    end
    local function apply(s,event,source)
        if type(event)~='table' or getmetatable(event)~=nil then return false end
        local sequence,kind,label=event.sequence,event.kind,event.label
        if not current(s) or not integer(sequence) or sequence<=s.sequence then return false end
        if kind~='applied' and kind~='revoked' then return false end
        if kind=='applied' and (type(label)~='string' or #label>4096) then return false end
        s.sequence=sequence;s.label=kind=='applied' and label or nil
        s.status=kind=='applied' and 'applied' or 'label_revoked'
        s.source=source;version={}
        local committed=version
        notify(s,kind)
        return current(s) and version==committed
    end
    local function open(s)
        local b=binding
        if not current(s) or s.authority or not b then return false end
        local function bound() return current(s) and binding==b and current(s) end
        s.status='awaiting_applied_snapshot';version={}
        notify(s,'provider awaiting applied snapshot')
        if not bound() then return false end
        local G=Core.guarded_native.new(api,L,bound)
        if not G.valid(s.gs) or not bound() then return false end
        -- Provider open must register first, then return its retained current
        -- snapshot. Its sequence covers every final client application/revoke
        -- for this exact admitted GS generation. No reflection in delivery.
        local ticket={contract_version=1,generation=s.generation,key=s.key,
            world=s.world,epoch=s.epoch}
        local handle=b.provider.open(s.gs,copy(ticket),function(event)
            if bound() then return apply(s,event,'client_applied_provider') end
            return false
        end)
        if not bound() then
            if type(handle)=='table' and type(handle.cancel)=='function' then handle.cancel() end
            return false
        end
        assert(type(handle)=='table' and type(handle.cancel)=='function','provider watch/cancel required')
        s.cancel=handle.cancel
        -- An event delivered during open supersedes an older returned snapshot.
        if handle.snapshot~=nil then apply(s,handle.snapshot,'client_applied_provider') end
        return bound()
    end
    local B={}
    function B.clear(reason) revoke(reason or 'label owner revoked') end
    function B.admit(gs,authority,G,admitted)
        assert(type(admitted)=='function','explicit admission guard required')
        if not admitted() or not G.valid(gs) or not admitted() then return end
        local key,world=G.key(gs),G.worldKey(gs)
        if not admitted() or not key or not world or world~=L.world then return end
        local old=owner
        if old and current(old) and old.key==key and old.world==world and old.authority==authority then
            return view(old) -- no repeat Native snapshot on ordinary observations
        end
        revoke('GS admission replaced')
        if not admitted() then return end
        generation=generation+1
        local s={gs=gs,key=key,world=world,epoch=L.epoch,retired=L.retired,
            departed=L.departed,generation=generation,authority=authority,
            sequence=-1,status=authority and 'authority_snapshot_pending' or 'provider_unbound'}
        owner=s;version={}
        notify(s,'GS admitted')
        if not current(s) or not admitted() then return end
        if authority then
            local walk=Core.guarded_native.new(api,L,function() return current(s) and admitted() end)
            local label=walk.text(walk.read(gs,'GamemodeDisplayName'))
            if not walk.current() or not current(s) or not admitted() then return end
            if type(label)=='string' then apply(s,{kind='applied',sequence=0,label=label},'authority_initial_snapshot') end
        else open(s) end
        if current(s) then return view(s) end
    end
    function B.bind_provider(provider)
        local admission=version
        if stopped or api.is_live()~=true or stopped or version~=admission then return function()end end
        assert(provider==nil or type(provider)=='table' and getmetatable(provider)==nil and provider.contract_version==1
            and provider.semantics==M.semantics and provider.intake=='ungated'
            and provider.snapshot_order=='register_before_snapshot' and type(provider.open)=='function',
            'exact applied-label provider contract required')
        local b=provider and {provider=provider} or nil
        binding=b;version={}
        local s=owner
        if s and current(s) and not s.authority then
            local oldCancel=s.cancel;s.cancel=nil
            s.label=nil;s.sequence=-1;s.status='provider_unbound';s.source=nil
            notify(s,'provider binding changed')
            if oldCancel then oldCancel() end
            if current(s) and binding==b then open(s) end
        end
        return function() if binding==b then B.bind_provider(nil) end end
    end
    function B.authority_commit(gs,G,admitted,label,expectedGeneration,expectedSequence)
        local s=owner;local stamp=version
        if not s or not s.authority or s.generation~=expectedGeneration or s.sequence~=expectedSequence
            or not admitted() or not current(s) or version~=stamp then return false end
        local key=G.key(gs)
        if not admitted() or not G.current() or not current(s) or version~=stamp or key~=s.key then return false end
        return apply(s,{kind='applied',sequence=s.sequence+1,label=label},'authority_local_final_write')
    end
    function B.snapshot()
        local s=owner
        if current(s) then return view(s) end
        return {status=binding and 'awaiting_GS_admission' or 'provider_unbound'}
    end
    -- General local-operation capture. An absent owner remains an absence;
    -- this grants no client applied-label fact or gameplay admission.
    function B.capture()
        local s,stamp=owner,version
        local epoch,world,retired,departed=L.epoch,L.world,L.retired,L.departed
        local function held()
            return owner==s and version==stamp and not stopped and not L.transition
                and L.epoch==epoch and L.world==world and L.retired==retired and L.departed==departed
                and (s==nil or current(s)) and owner==s and version==stamp
        end
        local function live() return held() and api.is_live()==true and held() end
        return s and view(s) or {status='owner_absent'},live
    end
    function B.hold(generationValue,sequenceValue)
        local s,stamp=owner,version
        local function live()
            return version==stamp and current(s) and version==stamp
                and s.generation==generationValue and s.sequence==sequenceValue
        end
        return live
    end
    function B.current(generationValue,sequenceValue)
        local s=owner
        return current(s) and s.generation==generationValue and (sequenceValue==nil or s.sequence==sequenceValue)
    end
    L.onReset(function() revoke('Core lifetime reset') end)
    L.onRetired(function() if owner and L.retired[owner.key] then revoke('GS retired') end end)
    api.own(function() stopped=true;revoke('FAPP package retired');binding=nil end)
    return B
end
return M
