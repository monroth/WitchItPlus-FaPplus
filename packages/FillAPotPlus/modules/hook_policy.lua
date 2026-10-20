local M={}
M.outputs={
    IsPlayerTeamSelectionBalanced={3}, AreAllPlayersReadyWithTeamSelection={2},
    CheckWitchesAlive={2}, GetTotalWitchesLives={2}, CanTeamSurrender={4},
    GetObjectiveMatchPlayerState={3}, IsPlayerInMatch={3}, GetPlayerPlayTime={3},
    CanJoinAsMidgameHunter={2}, CheckIfAllPlayersAreReady={2}, StartNewGameOverride={3},
    IsMatchDead={3}, IsMatchIntact={3}, GetHuntersCount={2}, GetRoundEndTimerUntilRestart={2},
    GetSpecificMapFromLevelName={3},
    GetQuantityVisibility={2}, GetQuantityText={2}, GetMapFileName={2,3},
    GetWinnerTeam={3,4}, GetInitialFocusWidget={2}, GetStructureTileViewDatas={2,3},
    GetItemName={3}, Compare={3}, GetPrefabInfo={8},
    StoreStatics={6}, GetIndividualItemDataAndFocus={4,5}, AreAllPlayersReady={2},
    HandleShouldGameStart={2}, ParseChatCommand={3},
}
-- Gameplay decisions cannot wait behind prop/UI discovery. Declared at package
-- start, subscribed at destination world/class birth before native Blueprint use.
M.decisions={Initialize=true,GetSpecificMapFromLevelName=true,CheckIfAllPlayersAreReady=true,AreAllPlayersReadyWithTeamSelection=true,
    IsPlayerTeamSelectionBalanced=true,HandleShouldGameStart=true,
    SwitchPropMulti=true,SwitchPropServerFunction=true,OnRep_ControllingProp=true,
    SpawnProp=true,SpawnReviveTotem=true,AddRoundState=true,ShowObjectiveResult=true,ShowResult=true,ShowRewards=true,
    EnsureInitialize=true,InitializeOverride=true,ReceiveBeginPlay=true,
    HandleStartMatchOverride=true,HandleEndMatchOverride=true,StartNewGameOverride=true,
    SetTeamByRoundAndObjectiveTeam=true,InitializeFromMatchPlayerState=true,
    CheckWitchesAlive=true,GetTotalWitchesLives=true,CanTeamSurrender=true,
    IsMatchDead=true,IsMatchIntact=true,GetHuntersCount=true,GetWinnerTeam=true,
    GetObjectiveMatchPlayerState=true,IsPlayerInMatch=true,GetPlayerPlayTime=true,
    CanJoinAsMidgameHunter=true,GetRoundEndTimerUntilRestart=true,RefreshCauldronBlock=true,ShowHUD=true,
    OnGameStartedMulti=true,OnMatchStartedMulti=true,LoadPropsAndCauldrons=true,
    ShowTeamSelectionObjective=true,ReceivePossessed=true,HandleClientProcessed=true,TimerFinished=true}
M.replacements={GetPlayernumberText=true}
return M
