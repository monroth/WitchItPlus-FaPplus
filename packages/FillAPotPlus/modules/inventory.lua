local function path(folder,name) return folder..name..'.'..name..'_C' end
local O='/Game/Blueprints/Gamemodes/ObjectiveMode/'
local CR='/Game/Blueprints/Gamemodes/CreativeMode/'
local UT='/Game/Blueprints/StaticProps/Placeable/Utility/'
local ST='/Game/Blueprints/StaticProps/Placeable/StaticProps/'
local TB=CR..'PlacementAndEditUI/Tabs/'
local specs={}
local function group(folder,names) for _,n in ipairs(names) do specs[#specs+1]=path(folder,n) end end
group('/Game/UserInterface/ObjectiveMode/',{'WB_LifeBlock'})
group(O,{'B_ObjectiveGameMode','B_ObjectiveGameState','B_ObjectivePlayerController','B_ObjectivePlayerState',
    'B_ObjectiveCauldron','B_ObjectiveWitchRespawnPoint','B_ObjectiveKillSpectator','B_ReviveTotem'})
group(CR,{'B_CreativeGameMode','B_CreativeGameState','B_CreativePlayerController'})
group(ST,{'BP_WitchCauldron','BP_WitchRuneStone01'})
group(UT,{'BP_PlaceableLight','BP_WitchPlayerStart','BP_Wardrobe'})
group(TB,{'WB_WorldSettingsTab','WB_TargetActorDisplay'})
group('/Game/Blueprints/Core/',{'B_GameInstance'})
group('/Game/Blueprints/Player/PlayerStarts/',{'B_WitchPlayerStart','B_PlayerStart'})
group('/Game/UserInterface/Play/',{'WB_Custommatch'})
group('/Game/UserInterface/Play/GameRules/',{'WB_GameRulesTabs'})
specs[#specs+1]=path('/Game/Blueprints/Props/Bases/','B_StaticMeshProp')
specs[#specs+1]='/Script/Engine.StaticMeshActor'
specs[#specs+1]='/Script/Niagara.NiagaraActor'
specs[#specs+1]='/Script/Engine.DecalActor' -- scorch marks etc.; hideable scenery

local paths={}
for _,entry in ipairs(specs) do paths[entry:match('%.(.+)$')]=entry end
return paths
