-- Shared mutable settings, validated user overrides, and match-scoped admission/lives.
local M={}
local Winner=dofile(assert(debug.getinfo(1,"S").source:match("^@(.+[\\/])")).."winner_order.lua")
local Context=dofile(assert(debug.getinfo(1,"S").source:match("^@(.+[\\/])")).."match_context.lua")
-- Obsolete user-file keys migrate silently; they no longer affect gameplay or the UI.
local obsolete={RespawnChoices=true,RespawnAtFilledCauldrons=true,HunterDeathPowerups=true,WitchInvisibility=true,HunterTrain=true,WitchPossession=true,ProtectWantedProps=true,PossessedPropRespawnSeconds=true}
M.rows={
    {key="UnequalTeams",label="Unequal teams",kind="bool",group="custom",nextMatch=true},
    {key="StartWhenEveryoneReady",label="Start when everyone is ready",kind="bool",group="custom",nextMatch=true,
        note="Skip the selection countdown once everyone is ready."},
    {key="MaxLives",label="Witch lives",kind="number",min=1,max=255,step=1,group="custom",nextMatch=true},
    {key="RespawnSeconds",label="Witch respawn delay (s)",kind="number",min=0,max=3600,step=.1},
    {key="ReviveTotemsPerDeadWitch",label="Revive totems per dead witch",kind="choice",choices={0,1,2,3,4,5},
        captions={"0 (disabled)","1","2","3","4","5"},nextMatch=true,
        note="One revival uses all totems for that witch. Living witches revive a random dead teammate."},
    {key="ReviveAtFilledCauldrons",label="Revive at filled cauldrons",kind="bool",nextMatch=true,
        note="Stand at a full cauldron to revive a random dead teammate."},
    {key="TotemReviveSeconds",label="Revival time (s)",kind="number",min=.01,max=3600,step=.01},
    {key="LateJoinSpectators",label="Late joiners spectate",kind="bool"},
    {key="reconnect.enabled",label="Allow disconnected players to rejoin",kind="bool"},
    {key="reconnect.max_wait_seconds",label="Reconnect time limit (s)",kind="number",min=0,max=86400,step=1},
    {key="NormalizeInfiniteLifeScore",label="Balance scores with infinite lives",kind="bool"},
    {key="SoftLocks.hostRoundAdvance",label="Recover stuck dead players between rounds",kind="bool"},
    {key="SoftLocks.clientRetrySelection",label="Recover stuck character selection",kind="bool"},
    {key="SoftLocks.clientRebindSkillBlock",label="Recover missing skill controls",kind="bool"},
    {key="SoftLocks.hostWardrobeReenable",label="Recover controls after wardrobe",kind="bool"},
    {key="SoftLocks.clientRepairCustomization",label="Recover stuck customization menus",kind="bool"},
    {key="SoftLocks.hostCancelOldKillSpectators",label="Clear stuck spectator mode between rounds",kind="bool"},
    {key="Diagnostics",label="Detailed logging",kind="bool"},
    {key="CreativeMaps",label="Creative maps in Fill a Pot",kind="bool",
        note="All players need Fill a Pot+ to play these maps."},
    {key="CreativeMapMinPropDistance",label="Minimum prop distance from cauldrons",kind="number",min=0,max=10000,step=1,
        note="0 uses the standard distance. Every copy of a requested prop must be beyond this distance."},
    {key="CreativeMapVotePool",label="Vote pool",kind="choice",choices={"official","custom","both"},
        captions={"Official","Custom with cauldrons","Both"},
        note="Maps offered at the end of a match."},
}
-- Five native choice buttons in the scrollable Fill a Pot+ tab (Match Rules +), not in
-- the Custom Match panel; choosing an occupied criterion swaps the two places.
for i=1,6 do
    M.rows[#M.rows+1]={key="WinnerPriority"..i,label="Winner priority "..i,kind="choice",nextMatch=true,
        choices={"wins","pots","props","lives","kills","time"},
        captions={"Halves won","Full cauldrons","Delivered props","Witch lives remaining","Hunter kills","Time"},
        note="Click each criterion from most to least important. Ties use the next criterion; infinite lives are ignored."}
end
local function parent(C,key)
    local a,b=key:match("^([^.]+)%.(.+)$")
    return a and C[a] or C,b or key
end
function M.init(C,directory,log,runtime)
    runtime=assert(runtime or FAPP_API,"runtime settings API required")
    local store=FAPP_SERVICES.storage.open()
    local firstRun=store.read_json("settings.json")==nil
    local api={revision=0}
    local Identity=assert(FAPP_SERVICES).match_identity
    local function session(mm)
        local gi=Context.instance(mm)
        return assert(Identity.session(gi),'match settings need a live GameInstance'),gi
    end
    if not Winner.parse(C.WinnerOrder) then C.WinnerOrder=Winner.default end
    for key in pairs(obsolete) do C[key]=nil end
    local schema,defaults={},{}
    for _,row in ipairs(M.rows) do
        if not row.key:match('^WinnerPriority') then
            schema[row.key]=row
            local container,key=parent(C,row.key); defaults[row.key]=container[key]
        end
    end
    schema.AllowEmptyTeams={key="AllowEmptyTeams",kind="bool",nextMatch=true}
    defaults.AllowEmptyTeams=C.AllowEmptyTeams
    schema.WinnerOrder={key="WinnerOrder",validate=function(value) return Winner.parse(value)~=nil end,nextMatch=true}
    defaults.WinnerOrder=C.WinnerOrder
    schema.MaxLives={kind='number',min=1,max=255,step=1,nextMatch=true,validate=function(value)
        return value=='infinite' or (type(value)=='number' and value==value and value>=1 and value<=255)
    end}
    schema.FiniteLives={kind='number',min=1,max=255,step=1}
    defaults.FiniteLives=type(C.MaxLives)=='number' and C.MaxLives or 10
    schema._legacyImported={kind='bool'}; defaults._legacyImported=true
    for _,rule in pairs(schema) do if rule.kind=='number' then rule.precision=2 end end
    local owner={config=runtime.config,save_settings=runtime.save_settings,json=runtime.json,log=log}
    local mechanics=FAPP_SERVICES.settings_factory.new(owner,defaults,schema)
    local filename=directory and directory.."settings_user.lua"
    local lastFinite=mechanics.get('FiniteLives')
    local function assign(key,value)
        if not mechanics.set(key,value) then return false end
        value=mechanics.get(key); api.revision=mechanics.revision
        local t,k=parent(C,key); t[k]=value
        if key=="MaxLives" and type(value)=="number" then lastFinite=value end
        return true
    end
    for key in pairs(defaults) do
        if key~='FiniteLives' and key~='_legacyImported' then assign(key,mechanics.get(key)) end
    end
    local function import(values)
        for key,value in pairs(values) do
            if obsolete[key] or key=="_legacyImported" then
            elseif key=="FiniteLives" then
                if mechanics.set(key,value) then lastFinite=mechanics.get(key) end
            elseif type(value)=="table" and (key=="reconnect" or key=="SoftLocks") then
                for child,entry in pairs(value) do
                    if not assign(key.."."..child,entry) then log("ignored invalid setting "..key.."."..child) end
                end
            elseif not assign(key,value) then log("ignored invalid setting "..tostring(key)) end
        end
    end
    if firstRun and filename then
        local file=io.open(filename,"r")
        if file then
            local data=file:read(262145); file:close()
            assert(#data<=262144,"legacy settings too large")
            local chunk,err=load(data,"@"..filename,"t",{})
            local ok,user=false,nil
            if chunk then ok,user=pcall(chunk) end
            if ok and type(user)=="table" then import(user); log("imported legacy user settings (original preserved)")
            else log("legacy user settings ignored: "..tostring(err or user)) end
        end
    end
    import(runtime.config({}))
    function api.get(key)
        local rank=tonumber(key:match("^WinnerPriority([1-6])$"))
        if rank then return Winner.parse(C.WinnerOrder)[rank] end
        if key=="InfiniteLives" then return C.MaxLives=="infinite" end
        if key=="MaxLives" and C.MaxLives=="infinite" then return lastFinite end
        local t,k=parent(C,key); return t[k]
    end
    function api.save()
        mechanics.set('FiniteLives',lastFinite)
        mechanics.set('_legacyImported',true)
        mechanics.save()
        log("saved runtime settings.json")
        return true
    end
    if firstRun then api.save() end
    -- Click semantics: the clicked criterion moves to the bottom. Clicking all five
    -- from most to least important leaves exactly that order.
    function api.winnerSink(rank)
        local order=Winner.parse(C.WinnerOrder); if not order or not order[rank] then return false end
        local v=table.remove(order,rank); order[#order+1]=v
        return api.set("WinnerOrder",table.concat(order,","))
    end
    function api.set(key,value)
        local rank=tonumber(key:match("^WinnerPriority([1-6])$"))
        if rank then
            if not Winner.labels[value] then return false end
            local order=Winner.parse(C.WinnerOrder)
            for i,v in ipairs(order) do if v==value then order[i]=order[rank]; break end end
            order[rank]=value
            return api.set("WinnerOrder",table.concat(order,","))
        end
        local before=key=="MaxLives" and C.MaxLives or api.get(key)
        if before==value then return true end
        local actual=key
        if key=="InfiniteLives" then
            if type(value)~="boolean" then return false end
            actual="MaxLives"; value=value and "infinite" or lastFinite
        end
        if not assign(actual,value) then log("rejected UI setting "..tostring(key)); return false end
        log("setting "..actual.." = "..tostring(value)..(schema[actual].nextMatch and " (next match)" or ""))
        return true
    end
    local matchOwner,matchId,matchRevision
    FAPP_SERVICES.lifetime.onReset(function() matchOwner=nil; matchId=nil end)
    function api.forMatch(mm)
        local id=tostring(mm:GetAddress())..':'..tostring(mm:GetFullName())
        if id~=matchId or not matchOwner or matchRevision~=Identity.revision then
            matchOwner=session(mm); matchId=id; matchRevision=Identity.revision
        end
        local owner=matchOwner
        local match=owner.matchSettings
        if not match or not match.active then
            owner.matchSettings={id=id,active=mm.CurrentRound>0,UnequalTeams=C.UnequalTeams,AllowEmptyTeams=C.AllowEmptyTeams,
                StartWhenEveryoneReady=C.StartWhenEveryoneReady,MaxLives=C.MaxLives,WinnerOrder=C.WinnerOrder,
                ReviveTotemsPerDeadWitch=C.ReviveTotemsPerDeadWitch,ReviveAtFilledCauldrons=C.ReviveAtFilledCauldrons}
        end
        return owner.matchSettings
    end
    function api.resetMatch(mm)
        matchOwner=nil; matchId=nil
        local _,gi=session(mm)
        if mm.CurrentRound~=1 or mm.IsMatchOver==true then Identity.forget(gi) end
    end
    api.rows=M.rows
    return api
end
return M
