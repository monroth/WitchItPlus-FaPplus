return function(S)
    local R,C=S.R,S.C
    local F=S.F
    local ballot,offers,screen,grid
    local cards={}
    local placeholder='/Game/UserInterface/Maps/T_MapPicPlaceholder.T_MapPicPlaceholder'
    -- The host's options decide whether this match ends with the Plus ballot.
    local function enabled()
        local s=C.session()
        local opts=s.gi.NextMatchOptions
        local cycle=s.gi.MapManager.CustomMapCycle
        return S.selected(opts) and not opts.CustomMapSelected and S.text(opts.MapData[F.file])=='RandomMapCycle'
            and (not R.valid(cycle) or #S.values(cycle.FileNames)==0)
            and not opts.IsTournamentMode and not opts.IsRecordingMode
    end
    local function counts()
        local result={}
        for i=1,#offers do result[i]=0 end
        for _,ps in ipairs(S.players()) do
            if not ps.IsPendingDisconnect then
                local index=ps.VotedMapIndex+1
                if result[index] then result[index]=result[index]+1 end
            end
        end
        return result
    end
    local function refresh(w)
        if not ballot then return end
        local node=w.WB_MapVoteBar.Map1
        local box
        for _=1,8 do
            if not R.valid(node) then break end
            if S.text(node:GetFName())=='MapBox' then box=node;break end
            node=node:GetParent()
        end
        assert(box,'native map vote container missing')
        if not R.valid(grid) or grid:GetParent():GetAddress()~=box:GetAddress() then
            for _,child in ipairs(S.values(box:GetAllChildren())) do child:SetVisibility(1) end
            grid=S.new('/Script/UMG.UniformGridPanel',w);box:AddChild(grid);cards={}
        end
        for i,row in ipairs(ballot.rows) do
            local card=cards[i]
            if not card then
                local frame=S.new('/Script/UMG.SizeBox',w)
                frame:SetWidthOverride(220);frame:SetClipping(1)
                grid:AddChildToUniformGrid(frame,math.floor((i-1)/5),(i-1)%5)
                card=StaticFindObject('/Script/UMG.Default__WidgetBlueprintLibrary'):Create(w,
                    S.asset('/Game/UserInterface/Maps/WB_MapVote.WB_MapVote_C'),w:GetOwningPlayer())
                frame:AddChild(card);cards[i]=card
                frame:SetHeightOverride(card.MapVotePanel:GetChildAt(0).Slot:GetOffsets().Bottom)
                local title=card.MapName;local parent=title:GetParent()
                parent:SetStretch(0)
                title:RemoveFromParent()
                local bounds=S.new('/Script/UMG.SizeBox',w);parent:AddChild(bounds)
                bounds:SetWidthOverride(220);bounds:SetHeightOverride(30);bounds:SetClipping(1)
                bounds:AddChild(title)
                title:SetJustification(1);title:SetAutoWrapText(false);title.WrapTextAt=0
                local font=title.Font;font.Size=22;title:SetFont(font)
            end
            card.MapToVoteIndex=i-1;card:SetVisibility(0);card:SetIsEnabled(ballot.open)
            -- No author line on any card, so official and custom cards keep one height.
            card.MapAuthor:SetVisibility(1)
            card:UpdateMapData()
            local display=card.MapEntry.MapData
            display[F.file]=FName(row.file);display[F.name]=FText(row.name)
            display[F.objective]=true
            -- Bundled maps ship their picture; a custom layout's screenshot exists on the host only.
            local path=row.previewFile and S.dir..'bundled-maps/'..row.previewFile or row.previewPath
            local image=path and StaticFindObject('/Script/PropWitchHuntModule.Default__ImageLoader'):LoadImageFromDisk(w,path)
            display[F.preview]=R.valid(image) or S.asset(row.preview)
            card.MapEntry:SetButtonParameters()
            card.MapName:SetText(FText(row.name))
            card.MapType:SetText(FText(row.custom and 'Custom with cauldrons' or 'Official Map'))
            card.MapName:SetToolTipText(FText(row.name))
            local quantity=row.quantity or ''
            card.MapEntry.GridButton.Quantity=FText(quantity);card.MapEntry.GridButton.bShowQuantity=quantity~=''
            card.MapVotePanel:SetVisibility(4)
            local n=ballot.tally[i] or 0
            card.Votes:SetText(FText(tostring(n)..(n==1 and ' Vote' or ' Votes')))
        end
        for i=#ballot.rows+1,#cards do cards[i]:SetVisibility(1) end
        for i,card in ipairs(cards) do
            if i<=#ballot.rows then
                for _,move in ipairs({{0,i-1},{1,i+1},{2,i-5},{3,i+5}}) do
                    if move[2]>=1 and move[2]<=#ballot.rows then
                        card.MapEntry:SetNavigationRuleExplicit(move[1],cards[move[2]].MapEntry)
                    end
                end
            end
        end
    end
    local function publish()
        ballot.tally=counts();C.net.publish('fap.ballot',ballot)
        if R.valid(screen) then refresh(screen) end
    end
    local function create()
        if ballot or not enabled() or not S.manager().IsMatchOver then return end
        local s=C.session()
        -- The catalogue registers the bundled maps, which the current map is looked up in.
        local pools=S.catalogue()
        offers=S.calc.selectOffers(S.currentMap(),pools)
        if #offers==0 then return end
        local rows={}
        local holder=S.new('/Game/UserInterface/Maps/B_MapButtonData.B_MapButtonData_C',s.gi)
        s.gs:FlushNetDormancy()
        s.gs.MapsToVote:Empty()
        for i,row in ipairs(offers) do
            if row.kind=='stock' then holder.MapData=S.pinStock(row)
            else holder.MapData=S.baseMap(row.world or S.text(S.layoutData(row)[S.L.map])) end
            local texture=holder.MapData[F.preview]
            local preview=row.kind=='stock' and R.valid(texture) and S.classpath(texture) or placeholder
            local token='FAPV:'..i
            holder.MapData[F.file]=FName(token);holder.MapData[F.name]=FText(row.name)
            holder.MapData[F.preview]=S.asset(placeholder);holder.MapData[F.objective]=true
            s.gs.MapsToVote[i]=holder.MapData
            rows[i]={file=token,name=row.name,quantity=row.info and S.calc.quantity(row.info),
                custom=row.kind=='custom',preview=preview,previewFile=row.kind=='bundle' and row.info.preview or nil,
                previewPath=row.kind=='custom' and S.text(S.layoutData(row)[S.L.screenshot]) or nil}
        end
        S.dirty(s.gs,'MapsToVote',36)
        for _,ps in ipairs(S.players()) do S.write(ps,'VotedMapIndex',-1,37) end
        s.gm.MapsToVoteUpdateNeeded=false
        ballot={rows=rows,open=true,tally={}}
        publish()
    end
    S.onMatchHost.pre(S.path(S.CORE,'B_GameMode','DetermineNewMapsForVote'),function(gm)
        if not enabled() then return end
        create();return true
    end)
    S.onMatchHost.post(S.path(S.O,'B_ObjectiveGameMode','HandleEndMatchOverride'),function(gm)
        create()
    end)
    S.onMatchHost.post(S.path(S.O,'B_ObjectiveGameMode','GetRoundEndTimerUntilRestart'),function(gm,out)
        if not enabled() then return end
        create()
        if ballot then out:set(math.max(30,out:get())) end
    end)
    S.onMatchHost.pre('/Game/Blueprints/Player/B_PlayerController.B_PlayerController_C:VoteMap',function(pc,index)
        if not ballot then return end
        if not ballot.open or index%1~=0 or index<0 or index>=#offers then return true end
    end)
    S.onMatchHost.post('/Game/Blueprints/Player/B_PlayerController.B_PlayerController_C:VoteMap',function(pc)
        if ballot and ballot.open then publish() end
    end)
    S.onMatchHost.on('player_left',function() if ballot then publish() end end)
    S.onMatchHost.post(S.path(S.O,'B_ObjectiveGameMode','K2_OnLogout'),function(gm)
        create()
        if ballot then publish() end
    end)
    local uiPath='/Game/Blueprints/UserInterface/B_IngameUIManager.B_IngameUIManager_C:'
    S.onMatch.post(uiPath..'ShowRewards',function(ui)
        if C.session().gs.CurrentRound==2 and ballot then ui.RewardsWidget.NextScreenTime=0 end
    end)
    local preserveRandom=false
    S.onMatchHost.pre(S.path(S.CORE,'B_GameMode','DetermineNextMapFromVotes'),function(gm)
        if not ballot then return end
        if not ballot.open then return true end
        local index=S.calc.winner(counts(),#offers)
        local s=C.session();local row=offers[index]
        if row.kind=='stock' then
            s.gi.UsedMatchOptions.MapData=s.gs.MapsToVote[index]
            s.gi.UsedMatchOptions.MapData[F.file]=FName(row.file)
            s.gi.UsedMatchOptions.CustomMapSelected=false
            s.gi.UsedMatchOptions.SelectedLayout=-1;s.gi.UsedMatchOptions.UseCustomLayouts=false
        else S.selectMap(s.gi.UsedMatchOptions,row) end
        s.gi.CurrentOpenedMap=s.gi.UsedMatchOptions.MapData
        s.gi.NextMapToOpen=s.gi.UsedMatchOptions.MapData[F.file]
        preserveRandom=true;ballot.open=false;ballot.winner=index-1;publish()
        S.trace('ballot winner %s used %s',row.id or row.file,S.options(s.gi.UsedMatchOptions))
        return true
    end)
    local copyingRandom=false
    -- After a Plus ballot the next match keeps "random map" instead of the voted map.
    S.onMatchHost.pre(S.path(S.MATCH,'B_MatchOptions','CopyMatchOptions'),function(options,source)
        local gi=C.session().gi
        copyingRandom=R.valid(source) and preserveRandom and options==gi.NextMatchOptions
            and source==gi.UsedMatchOptions and S.text(options.MapData[F.file])=='RandomMapCycle'
    end)
    S.onMatchHost.post(S.path(S.MATCH,'B_MatchOptions','CopyMatchOptions'),function(options,source)
        local gi=C.session().gi
        if R.valid(source) and copyingRandom and options==gi.NextMatchOptions and source==gi.UsedMatchOptions then
            options.MapData=gi.MapManager.RandomMapCycle;options.CustomMapSelected=false
            preserveRandom,copyingRandom=false,false
            S.trace('ballot keeps random next %s',S.options(options))
        end
    end)
    C.net.watch('fap.ballot',function(value)
        if S.host() then return end
        ballot=value
        if R.valid(screen) then refresh(screen) end
    end)
    S.onMatch.post('/Game/UserInterface/MatchResult/MapVote/WB_MapVoteScreen.WB_MapVoteScreen_C:Construct',function(w)
        screen=w;refresh(w)
    end)
    S.onMatch.post('/Game/Blueprints/UserInterface/B_IngameUIManager.B_IngameUIManager_C:ShowMapVote',function(ui)
        local w=ui.MapVoteWidget
        if R.valid(w) then
            screen=w;refresh(w)
            if cards[1] then cards[1].MapEntry:SetUserFocus(w:GetOwningPlayer());cards[1].MapEntry:SetKeyboardFocus() end
        end
    end)
    S.onMatch.post('/Game/UserInterface/MatchResult/MapVote/WB_MapVoteScreen.WB_MapVoteScreen_C:GetInitialFocusWidget',function(w,out)
        if ballot and cards[1] then out:set(cards[1].MapEntry) end
    end)
    R.on('world_end',function() ballot=nil;offers=nil;screen=nil;grid=nil;cards={} end)
    -- A ballot's random cycle carries only into the next match; back in the main menu the
    -- player's own pick decides (user, 11-04: a custom layout opened a random map).
    R.on('world_begin',function(world)
        local gi=StaticFindObject('/Script/Engine.Default__GameplayStatics'):GetGameInstance(world)
        if R.valid(gi) and not gi.IsCurrentlyInMatch then preserveRandom,copyingRandom=false,false end
    end)
end
