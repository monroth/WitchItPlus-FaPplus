return function(api)
    local loader=api.module('loader').new(api)
    -- Runtime supplies the private, package-prefixed print capability.
    FAPP_API=api
    FAPP_WORK=api.shared('Core').work_budget.new(api,{automatic=true,ms=3,reserve=1.5,items=1,profile=function(key,ms)
        if FAPP_SLOW then FAPP_SLOW(key,ms) end
    end})
    FAPP_SERVICES={lifetime=api.shared('Core').lifetime.new(api,{tick_owners=false})}
    FAPP_SERVICES.storage=api.shared('Core').storage.new(api)
    FAPP_SERVICES.settings_factory=api.shared('Core').settings
    FAPP_SERVICES.events=api.shared('Core').events.new(FAPP_SERVICES.lifetime)
    FAPP_SERVICES.event_clock=api.shared('Core').event_clock.new()
    FAPP_SERVICES.match_identity=api.shared('Core').match_identity.new(FAPP_SERVICES.lifetime)
    FAPP_SERVICES.runtime=api.shared('Core').runtime.new(api,FAPP_SERVICES.lifetime)
    FAPP_METADATA=loader.module('layout_metadata').new(loader.module('maps_layout_info'))
    api.publish({layout_metadata=FAPP_METADATA})
    api.shared('Core').capabilities.claim(api,'layout_metadata',FAPP_METADATA)
    FAPP_MODE=api.module('mode').new(api)
    api.gate(function(context)
        return context.mode=='menu' or context.mode=='creative' or context.fapp_plus==true
    end)
    FAPP_SERVICES.runtime=FAPP_SERVICES.runtime.group(FAPP_MODE.work)
    FAPP_SERVICES.registry=api.shared('Core').registry.new(api,FAPP_SERVICES.lifetime,loader.module('inventory'),{
        persistent={B_GameInstance_C=true},changed_bucket='B_StaticMeshProp_C',
        ready_events=false,validate_list=false,inherited={B_StaticMeshProp_C=true},
    })
    FAPP_SERVICES.match_context=loader.module('match_context')
    api.module('plus').install(api,FAPP_MODE,loader.module('config'))
    api.command('fapp',function()
        api.log('mode='..FAPP_MODE.state.mode..' Plus='..tostring(FAPP_MODE.state.plus))
        return true
    end)
    local gameplayLoaded=false
    local function gameplay(critical)
        if not gameplayLoaded then
            gameplayLoaded=true
            FAPP_WORK.cancel('startup:gameplay')
            loader.module('gameplay')
        end
        if critical and FAPP_INITIALIZE_GAMEPLAY then FAPP_INITIALIZE_GAMEPLAY(true) end
    end
    -- Definitions install synchronously at gameplay class/begin-play boundaries.
    -- The initial menu can prepare them in a finite background slice.
    for _,path in ipairs({
        '/Game/Blueprints/Gamemodes/ObjectiveMode/B_ObjectiveGameMode.B_ObjectiveGameMode_C',
        '/Game/Blueprints/Gamemodes/CreativeMode/B_CreativeGameMode.B_CreativeGameMode_C',
    }) do api.notify(path,function() gameplay(true) end,{ungated=true}) end
    api.on('begin_play_pre',function() gameplay(true) end,{ungated=true,priority=100,
        class_filter=function(name) return name=='B_ObjectiveGameMode_C' or name=='B_CreativeGameMode_C' end})
    if FAPP_MODE.state.mode~='menu' then gameplay(true)
    else FAPP_WORK.submit('startup:gameplay','gameplay declarations',function() gameplay(false); return true end,true) end
    FAPP_MODE.installBoundary()
end
