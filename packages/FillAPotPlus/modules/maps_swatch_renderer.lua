-- Final swatch resource owner. Native setup/async completion are observations,
-- never a reason to re-run setup or schedule a background repair.
local M={}
local DEFAULT_IMAGE='/Script/UMG.Default__Image'
local BASE='/Game/UserInterface/UIElements/MenuTileView/'
local UI='/Game/UserInterface/UIElements/'
function M.init(X)
    local api={};local tiles,grids={},{}
    local H,L=X.H,X.Lifetime
    local function enabled() return X.C.CreativeMaps and not L.transition end
    local function scalar(v) return type(v)=='number' and v==v and math.abs(v)~=math.huge end
    local function colour(c)
        if not c or not scalar(c.R) or not scalar(c.G) or not scalar(c.B) then return end
        return {R=c.R,G=c.G,B=c.B,A=1}
    end
    -- No borrowed UObject or native struct is retained in an ownership record.
    -- Resolve fresh native objects by their existing path on each event.
    local function identity(o)
        if not X.live(o) then return end
        local address,name=o:GetAddress(),o:GetFullName()
        if not scalar(address) or address==0 or type(name)~='string' then return end
        local path=name:match('^%S+ (.+)$');if not path then return end
        return {address=address,name=name,path=path,epoch=L.epoch}
    end
    local function matches(o,d)
        if not d or d.epoch~=L.epoch or not X.live(o) then return false end
        return o:GetAddress()==d.address and o:GetFullName()==d.name
    end
    local function find(d)
        if not d or d.epoch~=L.epoch then return end
        local o=StaticFindObject(d.path)
        if matches(o,d) then return o end
    end
    local function drop(r)
        if tiles[r.tile.address]==r then tiles[r.tile.address]=nil end
        if grids[r.grid.address]==r then grids[r.grid.address]=nil end
    end
    local function current(r)
        return enabled() and r.epoch==L.epoch
            and tiles[r.tile.address]==r and grids[r.grid.address]==r
    end
    local function resolve(r,tile,grid)
        if not current(r) then return end
        local panel=find(r.panel);tile=tile or find(r.tile)
        if not panel or not matches(tile,r.tile) then return end
        local data=X.read(tile,'ItemData')
        if not matches(data,r.data) or not matches(X.read(tile,'ParentWidget'),r.panel)
            or not matches(X.read(data,'Parent'),r.panel) then return end
        local actual=X.read(tile,'GridButton')
        if not matches(actual,r.grid) or grid and not matches(grid,r.grid) then return end
        local icon,button=X.read(actual,'Icon'),X.read(actual,'Button')
        if not matches(icon,r.icon) or not matches(button,r.button) then return end
        return tile,actual,icon,button
    end
    local function record(tile)
        if not enabled() then return end
        local d=identity(tile);local r=d and tiles[d.address]
        if r and matches(tile,r.tile) then return r end
    end
    function api.own(panel,tile,data,c)
        if not enabled() then return false,'inactive' end
        local desired=colour(c);if not desired then return false,'invalid RGB' end
        if not H.class(tile,'WB_LightColorButton_C')
            or not H.class(data,'B_LightColorButtonData_C') then return false,'not a colour swatch' end
        local grid=X.read(tile,'GridButton')
        local r={epoch=L.epoch,panel=identity(panel),tile=identity(tile),data=identity(data),
            grid=identity(grid),icon=identity(X.read(grid,'Icon')),button=identity(X.read(grid,'Button')),
            colour=desired}
        local size=r.icon and X.read(X.read(X.read(grid,'Icon'),'Brush'),'ImageSize')
        r.sizeX,r.sizeY=size and X.read(size,'X'),size and X.read(size,'Y')
        if not scalar(r.sizeX) or not scalar(r.sizeY) then return false,'native Icon size unavailable' end
        for _,field in ipairs({'panel','tile','data','grid','icon','button'}) do
            if not r[field] then return false,'missing live '..field end
        end
        if not matches(X.read(tile,'ItemData'),r.data)
            or not matches(X.read(tile,'ParentWidget'),r.panel)
            or not matches(X.read(data,'Parent'),r.panel) then return false,'owner relationship changed' end
        local prior=tiles[r.tile.address];if prior then drop(prior) end
        prior=grids[r.grid.address];if prior then drop(prior) end
        tiles[r.tile.address]=r;grids[r.grid.address]=r
        return true
    end
    function api.colour(tile,c)
        local r=record(tile);local desired=colour(c)
        if not r or not desired then return false end
        if not resolve(r,tile) then drop(r);return false end
        r.colour=desired
        return true -- caller performs its native setup, then paint
    end
    local function paint(r,tile,grid)
        if r.painting then return false,'reentrant' end
        local liveTile,liveGrid,icon,button=resolve(r,tile,grid)
        if not liveTile then drop(r);return false,'ownership changed' end
        -- The shipped Light material has no cooked Slate shader permutations.
        -- Use the stock resource-less Image brush, preserving this Icon's sizing.
        -- Native struct assignments/SetBrush copy by value; never alter the CDO.
        local defaults=X.read(X.asset(DEFAULT_IMAGE),'Brush')
        local brush=X.read(icon,'Brush')
        local tint=defaults and X.read(defaults,'TintColor')
        local white=tint and X.read(tint,'SpecifiedColor')
        local draw=defaults and X.read(defaults,'DrawAs')
        if type(brush)~='userdata' or type(defaults)~='userdata'
            or type(tint)~='userdata' or X.read(tint,'ColorUseRule')~=0 or not white
            or white.R~=1 or white.G~=1 or white.B~=1 or white.A~=1
            or not scalar(draw) or draw==0 or X.live(X.read(defaults,'ResourceObject')) then
            return false,'native flat Image brush unavailable'
        end
        for _,object in ipairs({liveTile,liveGrid,button,icon}) do
            if type(X.read(object,'ColorAndOpacity'))~='userdata' then
                return false,'native widget colour unavailable'
            end
        end
        r.painting=true
        local ok,painted,reason=pcall(function()
            -- Copy the empty default brush, including its empty rendering handle.
            -- Mutating only ResourceObject on the old material brush can retain
            -- that brush's material handle or bypass native brush invalidation.
            icon:SetBrush(defaults)
            local _,_,freshIcon=resolve(r,liveTile)
            if not freshIcon then return false,'revoked during paint' end
            -- Brush.ImageSize uses DeprecateSlateVector2D in this build;
            -- SetDesiredSizeOverride declares Vector2D. Pass plain scalar math
            -- fields so UE4SS constructs the exact declared parameter struct.
            local size=X.read(X.read(freshIcon,'Brush'),'ImageSize')
            if type(size)~='userdata' then return false,'native Icon size unavailable' end
            size.X=r.sizeX;size.Y=r.sizeY
            local _,_,sizeOwner=resolve(r,liveTile)
            if not sizeOwner then return false,'revoked during paint' end
            sizeOwner:SetDesiredSizeOverride({X=r.sizeX,Y=r.sizeY})
            -- Slate multiplies the Icon, Button and UserWidget tints. Normalize
            -- only these owned ancestors so RGB is applied once, at the Icon.
            for index=1,4 do
                local freshTile,freshGrid,freshIcon,freshButton=resolve(r,liveTile)
                if not freshTile then return false,'revoked during paint' end
                local object=({freshTile,freshGrid,freshButton,freshIcon})[index]
                local native=X.read(object,'ColorAndOpacity')
                if type(native)~='userdata' then return false,'native widget colour unavailable' end
                native.R=index==4 and r.colour.R or 1
                native.G=index==4 and r.colour.G or 1
                native.B=index==4 and r.colour.B or 1
                native.A=1
                object:SetColorAndOpacity(native)
            end
            return true
        end)
        r.painting=nil
        if not ok then return false,type(painted)=='string' and painted or 'native paint failed' end
        return painted,reason
    end
    function api.paint(tile)
        local r=record(tile);if not r then return false,'not owned' end
        return paint(r,tile)
    end
    function api.release(panel)
        local d=identity(panel);if not d then return 0 end
        local release={}
        for _,r in pairs(tiles) do
            if r.panel.address==d.address and r.panel.name==d.name and r.panel.epoch==d.epoch then
                release[#release+1]=r
            end
        end
        for _,r in ipairs(release) do drop(r) end
        return #release
    end
    function api.reset() tiles={};grids={} end
    L.onReset(api.reset)
    local function failure(r,ok,why)
        if not ok and why~='reentrant' and why~='ownership changed' and why~='revoked during paint' then
            X.once('swatch-renderer:'..r.tile.name..':'..why,'SwatchRenderer','paint unavailable: '..why)
        end
    end
    X.hook('SwatchRenderer',BASE,'WB_TileViewButton','SetButtonParameters',function(self)
        local tile=X.get(self);local r=record(tile);if not r then return end
        failure(r,paint(r,tile))
    end,function() return enabled() and next(tiles)~=nil end)
    X.hook('SwatchRenderer',UI,'WB_GridButton','SetIconImage',function(self)
        local grid=X.get(self);local d=identity(grid);local r=d and grids[d.address]
        if not r or not matches(grid,r.grid) then return end
        failure(r,paint(r,nil,grid))
    end,function() return enabled() and next(grids)~=nil end)
    return api
end
return M
