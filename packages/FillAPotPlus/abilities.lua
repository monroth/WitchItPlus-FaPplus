return function(S)
    local R,C=S.R,S.C
    local lists={
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
    local trainPath=lists.AllowedHunterSkills[7]
    local catalogue,added
    local function clearCatalogue()
        local gi=R.valid(catalogue)
        if gi then
            local train=S.asset(trainPath)
            for key in pairs(added) do
                local keep={}
                for _,skill in ipairs(S.values(gi[key])) do if skill:GetAddress()~=train:GetAddress() then keep[#keep+1]=skill end end
                gi[key]:Empty();for i,skill in ipairs(keep) do gi[key][i]=skill end
            end
        end
        catalogue,added=nil,nil
    end
    -- Reconciles the skill catalogue with the mode: adds the train in Plus, removes it elsewhere.
    local function addTrain()
        if not S.active() then clearCatalogue();return end
        local gi=R.valid(C.session().gi)
        if not gi then return end
        if not catalogue or catalogue:GetAddress()~=gi:GetAddress() then clearCatalogue();catalogue,added=gi,{} end
        local train=R.valid(S.asset(trainPath))
        if not train then return end
        for _,key in ipairs({'HunterSkills','AllSkills'}) do
            local rows=S.values(gi[key]);local found=false
            for _,skill in ipairs(rows) do if skill:GetAddress()==train:GetAddress() then found=true end end
            if not found then gi[key][#rows+1]=train;added[key]=true end
        end
    end
    R.post(S.path(S.CORE,'B_GameInstance','InitializeSkills'),addTrain)
    R.on('world_end',clearCatalogue)
    C.on_session(addTrain)
    function S.allowSkills()
        local session=C.session()
        addTrain()
        for key,paths in pairs(lists) do
            local target=key:find('Pickups') and session.gm or session.gs
            target[key]:Empty()
            for i,path in ipairs(paths) do target[key][i]=S.asset(path) end
        end
        session.gs:SkillsUpdated()
    end
    R.native.on_asset(trainPath,function(train,why)
        assert(train,why)
        addTrain()
        if S.inMatch() and S.host() then S.allowSkills() end
        if S.active() then
            for _,popup in ipairs(R.find_all('/Game/UserInterface/Skills/WB_SkillListPopup.WB_SkillListPopup_C')) do
                popup:RefreshSkillList()
            end
        end
    end)
end
