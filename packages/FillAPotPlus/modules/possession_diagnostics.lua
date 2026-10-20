-- Read-only, one-shot evidence for POSS1. Never change targeting or prop physics.
local M={}
local SKILL='/Game/Blueprints/Skills/Witch/Possess/B_PossessSkill.B_PossessSkill_C'
local TRACE='/Game/Blueprints/Player/Libraries/B_WitchHuntFunctionLibrary.B_WitchHuntFunctionLibrary_C:PossessTrace'
local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
function M.init(H)
    local L=FAPP_SERVICES.lifetime
    local seen,armed={},nil
    local read=FAPP_SERVICES.runtime.read
    local call=FAPP_SERVICES.runtime.call
    local function label(o) return H.valid(o) and call(o,'GetFullName') or '<none>' end
    local function objective(owner)
        if L.transition or not H.valid(owner) then return end
        local gs=H.object('/Script/Engine.Default__GameplayStatics'):GetGameState(owner)
        if not H.class(gs,'B_ObjectiveGameState_C') then return end
        local cls=read(gs,'GameModeClass')
        if not H.valid(cls) or call(cls,'GetFName'):ToString()~='B_ObjectiveGameMode_C' then return end
        return owner,gs
    end
    local function context(skill)
        if not H.valid(skill) then return end
        return objective(call(skill,'GetOwner'))
    end
    local function flags(p)
        if not H.valid(p) then return '<none>' end
        local parts={'class='..label(call(p,'GetClass'))}
        for _,k in ipairs({'IsFreezed','StartAwake','IsSleeping','IsControlledByWitch','IsDecoy',
            'SelectedForEditing','IsDissolving','PropCategory'}) do
            parts[#parts+1]=k..'='..tostring(read(p,k))
        end
        local mesh=read(p,'Mesh')
        if H.valid(mesh) then
            parts[#parts+1]='objectChannel='..tostring(call(mesh,'GetCollisionObjectType'))
            parts[#parts+1]='collision='..tostring(call(mesh,'GetCollisionEnabled'))
        end
        return table.concat(parts,' ')
    end
    local reasons={[0]='ViewIsBlocked',[1]='FrozenProp'}
    local function report(skill,phase,reason,target)
        local owner,gs=context(skill); if not owner then return end
        local id=L.key(skill); if not id then return end
        local key=id..':'..phase..':'..tostring(reason)
        if seen[key] then return end
        seen[key]=true
        local aimed=call(skill,'GetTargetProp')
        local current=read(skill,'CurrentTargetProp')
        local manaClass=StaticFindObject('/Game/Blueprints/Player/Components/B_ManaComponent.B_ManaComponent_C')
        local mana=H.valid(manaClass) and call(owner,'GetComponentByClass',manaClass)
        local subsystemClass=StaticFindObject('/Game/Blueprints/Skills/B_SkillParametersSubsystem.B_SkillParametersSubsystem_C')
        local subsystem
        if H.valid(subsystemClass) then
            local library=StaticFindObject('/Script/Engine.Default__SubsystemBlueprintLibrary')
            if H.valid(library) then subsystem=call(library,'GetWorldSubsystem',skill,subsystemClass) end
        end
        local parameters=H.valid(subsystem) and read(subsystem,'Possess')
        H.log('POSS1 '..phase..' side='..(H.authority(owner) and 'host' or 'owning-client')
            ..' local='..tostring(call(owner,'IsLocallyControlled'))..' world='..label(call(owner,'GetWorld'))
            ..' reason='..tostring(reason)..'/'..(reasons[reason] or 'unknown')
            ..' CurrentNotWorkingReason='..tostring(read(skill,'CurrentNotWorkingReason'))
            ..' SkillIsListed='..tostring(read(skill,'SkillIsListed'))
            ..' CanActivate(post)='..tostring(call(skill,'CanActivate'))
            ..' cooldown='..tostring(read(skill,'currentCooldown'))
            ..' manaCost='..tostring(read(skill,'ActivationManaCost'))
            ..' mana(post)='..tostring(read(mana,'CurrentMana'))..' range='..tostring(read(parameters,'Range'))
            ..' dispel='..tostring(read(owner,'DispelDebuff'))..' trap='..tostring(read(owner,'ManaDrainDebuff'))
            ..' state='..tostring(read(gs,'State'))
            ..' target='..label(target)..' '..flags(target)
            ..' current='..label(current)..' aimed(controller.TargetProp)='..label(aimed)..' '..flags(aimed)
            ..' aimedDistance='..tostring(H.valid(aimed) and call(owner,'GetDistanceTo',aimed)))
        return id
    end
    -- Input evidence still exists when native InitUtilitySkill never granted a
    -- Possess component. Selection in the customization UI alone is insufficient.
    for _,name in ipairs({'B_Witch','B_PropPawnPhysics'}) do
        H.hook('/Game/Blueprints/Player/Pawns/'..name..'.'..name..'_C:ActivateUtilitySkillPressed',function(self)
            local owner=self:get(); if not objective(owner) then return end
            local skill=read(owner,'SpecialUtilitySkill')
            if H.class(skill,'B_PossessSkill_C') then
                report(skill,'utility-input',read(skill,'CurrentNotWorkingReason'),read(skill,'CurrentTargetProp'))
            else
                local id=L.key(owner); if not id or seen[id..':utility-input'] then return end
                seen[id..':utility-input']=true
                H.log('POSS1 utility-input side='..(H.authority(owner) and 'host' or 'owning-client')
                    ..' owner='..label(owner)..' component='..label(skill)
                    ..' selected='..label(call(read(owner,'PlayerState'),'GetWitchUtilitySkill')))
            end
        end)
    end
    H.hook(SKILL..':ShowPossessNotWorkingHelp',function(self,reason)
        local skill=self:get()
        local id=report(skill,'help-refused',reason:get(),read(skill,'CurrentTargetProp'))
        if id then armed={id=id} end
    end)
    -- No InitializeRules diagnostic: spawning each skill used to perform the
    -- entire reflective report inside round-start traffic. Input/refusal events
    -- already provide the relevant one-shot evidence.
    H.hook(SKILL..':Press',function(self)
        local skill=self:get(); if not context(skill) then return end
        local current=read(skill,'CurrentTargetProp')
        -- A successful listen-host press has already spent mana/set cooldown.
        -- Its POST CanActivate=false cannot establish that this press failed.
        local refused=not H.valid(current)
        local id=report(skill,refused and 'press-no-target' or 'press-observed',
            read(skill,'CurrentNotWorkingReason'),current)
        if id and refused then armed={id=id} end
    end)
    -- No PossessTrace hook: the client calls it ~330x/s (0.24 ms per hooked call in
    -- game = ~8% of a frame) and UE4SS cannot read its OUT prop anyway.
    H.hook(SKILL..':SwitchPropServerFunction',function(self,prop)
        local skill=self:get(); local owner=context(skill)
        if not owner or not H.authority(owner) then return end
        local p=prop and prop:get(); local body=read(skill,'PropPawnPhysics')
        local controlled=H.valid(body) and read(body,'PossessedProp')
        local accepted=H.valid(p) and H.valid(controlled) and L.key(p)==L.key(controlled)
        report(skill,accepted and 'server-accepted' or 'server-refused',read(skill,'CurrentNotWorkingReason'),p)
    end)
    L.onReset(function() seen={}; armed=nil end)
    return M
end
return M
