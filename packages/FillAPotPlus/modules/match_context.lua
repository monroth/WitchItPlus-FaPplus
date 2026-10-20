local M={}
function M.instance(manager,field)
    local services=assert(FAPP_SERVICES)
    local lifetime=services.lifetime
    for _,instance in pairs(services.registry.buckets.B_GameInstance_C or {}) do
        if lifetime.valid(instance)
            and lifetime.same(services.runtime.read(instance,field or 'ObjectiveMatchManager'),manager) then
            return instance
        end
    end
    return nil
end
return M
