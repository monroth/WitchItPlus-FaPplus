-- Complete native capability lists; native Match Rules are the only policy source.
-- Order matches the regular-mode CDOs; no IsListed/IsEnabled/CDO writes.
local M={}
M.lists={
    AllowedHunterSkills={
        "/Game/Blueprints/Skills/Hunter/Cannonball/B_CannonballSkill.B_CannonballSkill_C",
        "/Game/Blueprints/Skills/Hunter/Chicken/B_ChickenSkill.B_ChickenSkill_C",
        "/Game/Blueprints/Skills/Hunter/Garlic/B_GarlicSkill.B_GarlicSkill_C",
        "/Game/Blueprints/Skills/Hunter/Hook/B_HookSkill.B_HookSkill_C",
        "/Game/Blueprints/Skills/Hunter/Trap/B_TrapSkill.B_TrapSkill_C",
        "/Game/Blueprints/Skills/Hunter/PowerBall/B_PowerBallSkill.B_PowerBallSkill_C",
        "/Game/Blueprints/Skills/Hunter/Train/B_TrainSkill.B_TrainSkill_C",
    },
    AllowedWitchSkills={
        "/Game/Blueprints/Skills/Witch/Decoy/B_DecoySkill.B_DecoySkill_C",
        "/Game/Blueprints/Skills/Witch/Elixir/B_ElixirSkill.B_ElixirSkill_C",
        "/Game/Blueprints/Skills/Witch/Fly/B_FlySkill.B_FlySkill_C",
        "/Game/Blueprints/Skills/Witch/JumpScare/B_JumpScareSkill.B_JumpScareSkill_C",
        "/Game/Blueprints/Skills/Witch/Possess/B_PossessSkill.B_PossessSkill_C",
        "/Game/Blueprints/Skills/Witch/Eye/B_FlyingEyeSkill.B_FlyingEyeSkill_C",
    },
    AllowedWitchPickups={
        "/Game/Blueprints/Pickups/B_WitchPickupConfusionWave.B_WitchPickupConfusionWave_C",
        "/Game/Blueprints/Pickups/B_WitchPickupBuffInvisible.B_WitchPickupBuffInvisible_C",
        "/Game/Blueprints/Pickups/B_WitchPickupBuffManaBoost.B_WitchPickupBuffManaBoost_C",
        "/Game/Blueprints/Pickups/B_WitchPickupHeal.B_WitchPickupHeal_C",
    },
    AllowedHunterPickups={
        "/Game/Blueprints/Pickups/B_HunterPickupDetection.B_HunterPickupDetection_C",
        "/Game/Blueprints/Pickups/B_HunterPickupBuffSpeedboost.B_HunterPickupBuffSpeedboost_C",
        "/Game/Blueprints/Pickups/B_HunterPickupBuffRapidFire.B_HunterPickupBuffRapidFire_C",
        "/Game/Blueprints/Pickups/B_HunterPickupBuffCooldownReduction.B_HunterPickupBuffCooldownReduction_C",
    },
}
local CORE="/Game/Blueprints/Core/"
local O="/Game/Blueprints/Gamemodes/ObjectiveMode/"
local TRAIN=M.lists.AllowedHunterSkills[7]
local function path(folder,asset,fn) return folder..asset.."."..asset.."_C:"..fn end
function M.init(C,H)
    local E=FAPP_SERVICES.events
    H=E.scope(H)
    local Registry=FAPP_SERVICES.registry
    local api,reported,attempts,catalogs={}, {}, {}, {}
    local function once(key,msg)
        if not reported[key] then reported[key]=true; H.log("Capabilities: "..key..": "..tostring(msg)) end
    end
    local function same(a,b) return H.valid(a) and H.valid(b) and FAPP_SERVICES.lifetime.same(a,b) end
    local function values(a)
        local list={}; assert(a and type(a.ForEach)=="function","native array unavailable")
        a:ForEach(function(_,v) list[#list+1]=v:get() end); return list
    end
    local function asset(p)
        local a=StaticFindObject(p)
        if not H.valid(a) then once(p,"class unavailable; retaining this native list until loaded"); return end
        return a
    end
    local function replace(a,list)
        assert(type(a.Empty)=="function","native array Empty unavailable")
        a:Empty()
        for i,v in ipairs(list) do a[i]=v end -- UClass/UObject elements, never table-as-container marshalling
    end
    local function fill(o,key)
        local wanted={}
        for _,p in ipairs(M.lists[key]) do
            local cls=asset(p); if not cls then return false end
            wanted[#wanted+1]=cls
        end
        local old=values(o[key]); local equal=#old==#wanted
        for i,v in ipairs(wanted) do if not same(old[i],v) then equal=false end end
        if equal then return false end
        replace(o[key],wanted)
        H.log("Capabilities: complete "..key.." ("..#wanted..", native order)"); return true
    end
    local function fillJob(object,key,changed)
        local work=assert(FAPP_WORK)
        local wanted,previous={},{}
        local available,equal=true,true
        return work.sequence({work.each(M.lists[key],function(path)
            local class=asset(path)
            if class then wanted[#wanted+1]=class else available=false end
        end),work.defer(function()
            if not available then return function() return true end end
            return work.array(object[key],function(value) return value end,function(value) previous[#previous+1]=value end)
        end),work.each(M.lists[key],function(_,index)
            if available and not same(previous[index],wanted[index]) then equal=false end
        end),function()
            equal=equal and #previous==#wanted
            if available and not equal then object[key]:Empty() end
            return true
        end,work.each(M.lists[key],function(_,index)
            if available and not equal then object[key][index]=wanted[index] end
        end),function()
            if available and not equal then changed(); H.log('Capabilities: complete '..key..' ('..#wanted..', native order)') end
            return true
        end})
    end
    local function active(s)
        if not H.class(s,"B_ObjectiveGameState_C") or s:GetFullName():find("Default__",1,true) then return end
        if not H.valid(s.GameModeClass) or s.GameModeClass:GetFName():ToString()~="B_ObjectiveGameMode_C" then return end
        local g=H.object("/Script/Engine.Default__GameplayStatics")
        if same(g:GetGameState(s),s) then return s,g:GetGameInstance(s) end
    end
    local function catalog(gi)
        if not H.valid(gi) then return end
        local train=asset(TRAIN); if not train then return end
        local id=gi:GetAddress(); local r=catalogs[id] or {gi=gi,owned={},train=train}; catalogs[id]=r
        for _,key in ipairs({"HunterSkills","AllSkills"}) do
            local a=gi[key]; local old=values(a); local found=false
            for _,v in ipairs(old) do if same(v,train) then found=true end end
            if not found then a[#old+1]=train; r.owned[key]=true; H.log("Capabilities: Train catalog "..key) end
        end
    end
    local function state(s)
        local gs,gi=active(s); if not gs then return end
        local changed=fill(gs,"AllowedHunterSkills")
        changed=fill(gs,"AllowedWitchSkills") or changed
        catalog(gi)
        -- Native callback owns replicated UnlistedSkills. Never invoke it on clients.
        if changed and H.authority(gs) and H.world(gs) then gs:SkillsUpdated() end
        if changed then H.retryHooks() end
        return changed
    end
    local function pool(gm)
        if not H.authority(gm) or not H.world(gm) then return end
        fill(gm,"AllowedHunterPickups"); fill(gm,"AllowedWitchPickups")
        return true
    end
    for _,fn in ipairs({"InitializeOverride","ReceiveBeginPlay","UpdateCustomGameMatchOptions"}) do
        H.hook(path(O,"B_ObjectiveGameMode",fn),function(self) pool(self:get()) end)
    end
    H.hook(path(O,"B_ObjectiveGameState","ReceiveBeginPlay"),function(self) state(self:get()) end)
    for _,fn in ipairs({"OnRep_SkillRules","UpdateSkillRules"}) do
        H.hook(path(CORE,"B_GameState",fn),function(self) state(self:get()) end)
    end
    H.hook(path(CORE,"B_GameInstance","InitializeSkills"),function(self)
        local gi=self:get(); local s=H.object("/Script/Engine.Default__GameplayStatics"):GetGameState(gi)
        if active(s) then catalog(gi) end
    end)
    -- Native functions consume repaired arrays internally; no broken array OUT round-trip.
    local function refresh(self)
        local w=self:get(); local gs=H.object("/Script/Engine.Default__GameplayStatics"):GetGameState(w)
        if not active(gs) then return end
        if state(gs) then w:RefreshSkillList() end
    end
    H.hook(path("/Game/UserInterface/Skills/","WB_SkillListPopup","RefreshSkillList"),refresh)
    function api.poll()
        if not FAPP_TEST_NO_THROTTLE then
            local work=assert(FAPP_WORK)
            local stages={}
            local alive={}
            for _,gs in ipairs(Registry.list('B_ObjectiveGameState_C')) do
                local changed=false
                local function update() changed=true end
                stages[#stages+1]=work.defer(function()
                    local current,gi=active(gs)
                    if not current then return function() return true end end
                    if H.valid(gi) then alive[gi:GetAddress()]=true end
                    return work.sequence({fillJob(gs,'AllowedHunterSkills',update),fillJob(gs,'AllowedWitchSkills',update),
                        function() local _,gi=active(gs); catalog(gi); return true end,
                        function()
                            if changed and H.authority(gs) and H.world(gs) then gs:SkillsUpdated() end
                            if changed then H.retryHooks() end
                            return true
                        end})
                end)
            end
            for _,gm in ipairs(Registry.list('B_ObjectiveGameMode_C')) do
                stages[#stages+1]=work.defer(function()
                    if not H.authority(gm) or not H.world(gm) then return function() return true end end
                    return work.sequence({fillJob(gm,'AllowedHunterPickups',function() end),fillJob(gm,'AllowedWitchPickups',function() end)})
                end)
            end
            stages[#stages+1]=work.defer(function()
                local entries={}
                for id,record in pairs(catalogs) do entries[#entries+1]={id=id,record=record} end
                return work.each(entries,function(entry)
                    local record=entry.record
                    if not alive[entry.id] then
                        if H.valid(record.gi) then
                            for key in pairs(record.owned) do
                                local kept={}
                                for _,value in ipairs(values(record.gi[key])) do
                                    if not same(value,record.train) then kept[#kept+1]=value end
                                end
                                replace(record.gi[key],kept)
                            end
                            H.log('Capabilities: removed owned Train catalog entries on Objective exit')
                        end
                        catalogs[entry.id]=nil
                    end
                end)
            end)
            work.submit('capabilities:maintenance','capabilities/maintenance',work.sequence(stages))
            return
        end
        local alive={}
        for _,s in ipairs(Registry.list("B_ObjectiveGameState_C") or {}) do
            local current,gi=active(s)
            if current then
                if H.valid(gi) then alive[gi:GetAddress()]=true end
                H.guard("complete capabilities",state)(s)
            end
        end
        for id,r in pairs(catalogs) do if not alive[id] then
            if H.valid(r.gi) then for key in pairs(r.owned) do
                local kept={}; for _,v in ipairs(values(r.gi[key])) do if not same(v,r.train) then kept[#kept+1]=v end end
                replace(r.gi[key],kept)
            end; H.log("Capabilities: removed owned Train catalog entries on Objective exit") end
            catalogs[id]=nil
        end end
        for _,gm in ipairs(Registry.list("B_ObjectiveGameMode_C") or {}) do
            H.guard("complete pickup pools",pool)(gm)
        end
    end
    function api.beginPlay(a)
        if active(a) then state(a) elseif H.class(a,"B_ObjectiveGameMode_C") then pool(a) end
    end
    function api.reset() reported={}; attempts={}; end
    E.poll(api,H,Registry,nil)
    return api
end
return M
