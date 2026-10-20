-- Defaults; runtime settings override UI-exposed values. Infrastructure needs restart.
return {
    Enabled = true,
    CreativeMaps = true,      -- Creative palette / playtest preview / custom Objective adapter / HUD
    CreativeMapVoting = true, -- native final-match vote bridge; false restores vanilla flow (restart required)
    CreativeMapVotePool = "official", -- official / custom / both; explicit map cycles keep their native order
    HudColumnThreshold = 7,   -- more pots than this use the two-column cauldron HUD
    HudColumnLift = 60,       -- 6..threshold pots: lift the single column up by this many px
    CreativeMapMinPropDistance = 0, -- UU; 0 = cauldron CDO (2500), 500 = small-map override, preview + real adapter
    SettingsUI = true,        -- native custom-match controls + Fill a Pot+ rules tab
    UnequalTeams = true,
    AllowEmptyTeams = false, -- true permits 1v0 experiments; normal end checks still apply
    StartWhenEveryoneReady = false, -- opt-in FaP: no countdown, any nonempty team arrangement; everyone explicitly Ready
    WinnerOrder = "wins,pots,props,lives,kills,time", -- FaP only; snapshotted for both halves at match start
    MaxLives = 10,           -- integer 1..255, or "infinite"; UI drag 100 = infinite, typed 100 = finite
    InfiniteLivesReserve = 99, -- replenished synchronously, not a 99-death limit
    HudLivesCap = 5,         -- replicated icon count; above this, icons stay full
    RespawnSeconds = 5.0,    -- 0 means next tick, not a disabled UE timer
    ReviveTotemsPerDeadWitch = 1, -- FaP only; 1 = native, 0 = no point totems, 2..5 = alternatives
    ReviveAtFilledCauldrons = false, -- FaP only; native replicated revive circles beside full pots
    TotemReviveSeconds = 3.0, -- witch-seconds in circle; multiple witches accelerate it
    NormalizeInfiniteLifeScore = true, -- report 0 in round results: no lives tie-break
    LateJoinSpectators = true,
    reconnect = {
        enabled = true,
        max_wait_seconds = 120, -- wall-clock forfeit/surrender grace; 0 disables grace
        pause_timer = false,   -- user preference: gameplay timer continues by default
        preserve_alive_witch_lives = true,
        trace_native_flow = true,
    },
    ManualPauseKey = "F8",     -- UE4SS Key table name; host only, active round only
    PauseNotification = true, -- existing multicast game-message type 10; transient
    Diagnostics = true,
    TraceTransitionDetails = false, -- opt-in full roster/widget walks; use fappdump
    SoftLocks = {
        hostRoundAdvance = true,
        clientRetrySelection = true,
        clientRebindSkillBlock = true,
        hostWardrobeReenable = true,
        clientRepairCustomization = true, -- Objective-only: replace proven stale/duplicate native screen records
        hostCancelOldKillSpectators = true,
    },
    HookRetryMs = 1000,
    MaintenanceMs = 500,
    DiagnosticRepeatSeconds = 30,
    -- Native countdown/equalizer is disabled with UnequalTeams. Everyone must Ready.
    -- This unreachable quota makes EqualizeTeamSizes exit BEFORE it moves players
    -- or invokes OnRep_IsReadyObjectiveTeamSelection (which can start a round).
    BalanceGuardQuota = 1000000,
    UiRequiredPlayersPerTeam = 2, -- cosmetic quota; >1 preserves native lone-player surrender UI
    -- Exact names from bytecode. Override only if runtime reflection proves a rename.
    Properties = {
        TotemReviveSeconds = "WitchInCircleTimeNeeded",
    },
}
