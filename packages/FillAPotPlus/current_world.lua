-- Activation can follow every actor's BeginPlay. Read the native current world
-- once and query its relevant actors/widgets; future births use the usual handlers.
local M={}
function M.adopt(api,services,mode,context)
    local L,R=services.lifetime,services.registry
    local pc=context and context.controller
    if not L.rawValid(pc) then return end
    local gameplay=services.runtime.object('/Script/Engine.Default__GameplayStatics')
    local gm,gs=gameplay:GetGameMode(pc),gameplay:GetGameState(pc)
    if not L.rawValid(gm) then return end
    local class=gm:GetFullName():match('^(%S+)')
    if class~='B_CreativeGameMode_C' and class~='B_ObjectiveGameMode_C' then return end
    L.observe(pc,context.time)
    mode.observe(pc)
    for _,object in pairs({pc,gm,gs,gameplay:GetGameInstance(pc)}) do
        if L.rawValid(object) then R.ready(object) end
    end
    -- Specific world/class engine queries exclude templates and unrelated objects.
    R.eachExisting(pc,function(object)
        if L.valid(object) then R.ready(object) end
    end)
    return gm,pc
end
return M
