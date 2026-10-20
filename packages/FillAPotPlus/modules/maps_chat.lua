-- Local replies only. Blueprint ParseChatCommand is POST; slash commands already
-- set IsChatCommand=true before HandleChatCommand can reach SendChatMessageServer.
local M={}
function M.parse(text)
    if type(text)~='string' then return end
    local words={}; for word in text:gmatch('%S+') do words[#words+1]=word end
    local root=(words[1] or ''):lower()
    if root~='/hide' and root~='/faphide' and root~='/fapmaps' and root~='/fapmodstatus' and root~='/fappreview' then return end
    table.remove(words,1)
    return root,words
end
function M.init(X)
    local baseOwner=dofile(assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))..'baseworld_owner.lua')
    local api,queued={},{}
    local rawLog=X.log
    local capture=0
    local function widget()
        for _,gi in ipairs(X.findAll('B_GameInstance_C')) do
            if X.live(gi) then
                local manager=X.read(gi,'IngameUIManager')
                if X.H.valid(manager) then
                    local chat=X.read(manager,'ChatWidget')
                    if X.H.valid(chat) then return chat end
                end
            end
        end
    end
    local function deliver(message)
        if X.Lifetime.transition then return end
        local ok,chat=pcall(widget)
        if not ok or not chat then return end -- rawLog is always the fallback
        -- Sender name colour (WB_ChatEntry tints ChatName/ChatTime only; alpha 0 hid "FAP").
        local colourOK,colour=pcall(X.native,{R=1,G=0.8,B=0.2,A=1})
        if not colourOK then return end
        for line in (tostring(message)..'\n'):gmatch('(.-)\n') do
            if line~='' then
                local sent,err=pcall(function() chat:AddChatMessage(FText('FAP'),FText(line),0,0,colour) end)
                if not sent then rawLog('Chat','local reply unavailable: '..tostring(err)); return end
            end
        end
    end
    -- The chat widget accepts our lines but players reported seeing nothing; command
    -- results therefore also open the native message dialog (FString Title/Text, as
    -- B_PlayerController uses in matches), one dialog per poll batch.
    local function dialog(lines)
        if X.Lifetime.transition or #lines==0 then return end
        for _,gi in ipairs(X.findAll('B_GameInstance_C')) do
            local manager=X.live(gi) and X.read(gi,'MenuUIManager')
            if X.H.valid(manager) then
                local ok,err=pcall(function() manager:ShowMessageDialog('Fill a Pot+',table.concat(lines,'\n')) end)
                if not ok then rawLog('Chat','message dialog unavailable: '..tostring(err)) end
                return
            end
        end
    end
    -- Short status lines (aim target, aim on/off): chat only, never a modal dialog.
    -- Log only: every chat line creates widgets, which bumps the object registry and
    -- wakes full map maintenance (~67 ms in Creative). The aim target blinks instead.
    function X.notice(stage,message) rawLog(stage,message) end
    function X.reply(stage,message) X.queueReply(stage,message) end
    function X.queueReply(stage,message)
        rawLog(stage,message)
        if #queued<512 then queued[#queued+1]=message end
    end
    function X.log(stage,message)
        if capture>0 then X.queueReply(stage,message) else rawLog(stage,message) end
    end
    -- Capturing logs also works in borrowed console callbacks: widget access is
    -- deferred until the game-thread poll, and errors get the same local reply.
    function X.command(fn,...)
        local previous=capture
        capture=previous+1
        local result=table.pack(pcall(fn,...))
        capture=previous -- a synchronous travel/reset may run inside the command
        if not result[1] then rawLog('Command','Refused: '..tostring(result[2]));X.queueReply('Command',FAPP_SERVICES.runtime.player_error(result[2])) end
        return table.unpack(result,1,result.n)
    end
    function api.poll()
        local work=queued; queued={}
        for _,line in ipairs(work) do deliver(line) end
        dialog(work)
    end
    function api.pending() return #queued>0 end
    function api.reset() queued={}; capture=0 end
    X.hook('Chat','/Game/Blueprints/UserInterface/','B_IngameUIManager','ParseChatCommand',function(_,text,isCommand)
        local root,args=M.parse(X.text(X.get(text)))
        if not root or (baseOwner.enabled and (root=='/hide' or root=='/faphide')) then return end
        -- Defensive OUT override; the dump already sets this for EVERY slash root.
        if isCommand~=nil then pcall(function() isCommand:set(true) end) end
        if root=='/hide' or root=='/faphide' then
            if X.Suppression then X.Suppression.enqueue(args,true) else X.queueReply('Chat','Hide tools unavailable') end
        elseif root=='/fapmaps' then
            if X.Selection then X.command(X.Selection.command,args) end
        elseif root=='/fapmodstatus' then
            if X.ModSync then X.ModSync.status() end
        elseif root=='/fappreview' then
            if X.Preview then X.command(X.Preview.command,args) end
        end
    end)
    X.Chat=api
    return api
end
return M
