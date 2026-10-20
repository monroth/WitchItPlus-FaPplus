-- Use the cooked load path on the LIVE GameState. It owns the world scan,
-- typed AllProps/Proplist/S_PropList and Common / two-copy eligibility.
-- This indivisible native call is a load continuation, never a menu callback.
local M={}
function M.init(X)
    local loading={}
    function M.isLoading(gs) return loading[gs:GetAddress()]==true end
    function M.job(gs,done,key)
        local epoch=X.Lifetime.epoch
        key=key or 'pool:'..gs:GetAddress()
        return X.Work.sequence({X.Work.native(function()
            if epoch~=X.Lifetime.epoch or not X.live(gs) then return end
            local id=gs:GetAddress()
            -- Native rebuilding relocates borrowed array/map storage. Expire
            -- other validation cursors, preserving the caller's continuation.
            for _,prefix in ipairs({'discovery:','client-discovery:','client-native-load:'}) do
                if prefix..id~=key then X.Work.cancel(prefix..id) end
            end
            loading[id]=true
            local ok,err=pcall(function()
                -- The Blueprint appends to Proplist. Expire the previous pool
                -- before rebuilding so a second saved-layout load cannot double
                -- copies or keep classes/actors belonging to the old layout.
                gs.Proplist:Empty();gs.ValidProps:Empty()
                FAPP_SERVICES.runtime.access('method:LoadPropsAndCauldrons',function() gs:LoadPropsAndCauldrons() end) -- native owns both OUT arrays
            end)
            loading[id]=nil
            if not ok then error(err) end
            X.log('Pool/source','native LoadPropsAndCauldrons: AllProps='..gs.AllProps:GetArrayNum()..
                ' ValidProps='..gs.ValidProps:GetArrayNum()..' cauldrons='..gs.Cauldrons:GetArrayNum()..
                ' world='..tostring(X.Lifetime.worldKey(gs)))
        end),function()
            if epoch==X.Lifetime.epoch and X.live(gs) and done then done() end
            return true
        end})
    end
    function M.reportJob(gs)
        local counts,order,eligible={},{},{}
        return X.Work.sequence({X.Work.defer(function()
            return X.Work.array(gs.AllProps,X.get,function(actor)
                local cls=actor:GetClass();local key=X.Lifetime.key(cls)
                local row=counts[key]
                if not row then row={class=cls,count=0};counts[key]=row;order[#order+1]=row end
                row.count=row.count+1
            end)
        end),X.Work.defer(function()
            return X.Work.array(gs.ValidProps,X.get,function(cls) eligible[X.Lifetime.key(cls)]=true end)
        end),function()
            X.log('Pool/validation','source=native LoadPropsAndCauldrons; AllProps='..gs.AllProps:GetArrayNum()..
                ' ValidProps='..gs.ValidProps:GetArrayNum()..' classes='..#order..
                ' membership='..X.Registry.versions.B_StaticMeshProp_C)
            return true
        end,X.Work.each(order,function(row)
            local admitted=eligible[X.Lifetime.key(row.class)] and 1 or 0
            X.log('Pool/class',row.class:GetFullName()..' alive='..row.count..
                ' CDO category='..tostring(X.get(X.read(row.class:GetCDO(),'PropCategory')))..
                ' native eligible='..admitted)
        end)})
    end
    X.Lifetime.onReset(function() loading={} end)
    return M
end
return M
