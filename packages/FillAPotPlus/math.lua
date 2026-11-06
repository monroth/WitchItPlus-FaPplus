local M={}
-- Authored saves are distinct maps; stock layout variants share a world identity.
-- Never shuffle caller arrays or retry random picks from an exhausted pool.
local function identity(row)
    local key=row and row.file
    return key and key:gsub('\\','/'):lower()
end
function M.selectOffers(current,pools,random)
    local offers,seen={},{}; random=random or math.random
    local function take(pool)
        local candidates,unique={},{}
        for _,row in ipairs(pool or {})do
            local key=identity(row)
            if key and not seen[key] and not unique[key]then candidates[#candidates+1]=row;unique[key]=true end
        end
        if #candidates==0 then return false end
        local row=candidates[random(#candidates)];offers[#offers+1]=row;seen[identity(row)]=true;return true
    end
    local official,all={},{}
    for _,pool in ipairs({pools.vanilla,pools.official,pools.featured or {}})do
        for _,row in ipairs(pool)do official[#official+1]=row end
    end
    for _,row in ipairs(official)do all[#all+1]=row end
    for _,row in ipairs(pools.custom or {})do all[#all+1]=row end
    if current then take({current});all[#all+1]=current end
    local featured=#(pools.featured or {})>0 and pools.featured or pools.official
    local slots={pools.vanilla,pools.official,featured,all}
    if not current then table.insert(slots,1,all)end
    for _,pool in ipairs(slots)do if not take(pool)and not take(official)then take(all)end end
    return offers
end
-- Mirrors native highest-vote, random-tie behaviour.
function M.winner(counts,count,random)
    random=random or math.random
    local highest,ties=-1,{}
    for i=1,count do local votes=counts[i]
        if votes~=nil then
            if votes>highest then highest=votes;ties={i}elseif votes==highest then ties[#ties+1]=i end
        end
    end
    if #ties>0 then return ties[random(#ties)],highest end
end
function M.hsvColour(h,s,v)
    local sector=(h%360)/60; local c=v*s; local x=c*(1-math.abs(sector%2-1)); local m=v-c
    local rgb=({{c,x,0},{x,c,0},{0,c,x},{0,x,c},{x,0,c},{c,0,x}})[math.floor(sector)+1]
    return {R=rgb[1]+m,G=rgb[2]+m,B=rgb[3]+m,A=1}
end
function M.colourHSV(c,previous)
    local hi,lo=math.max(c.R,c.G,c.B),math.min(c.R,c.G,c.B); local delta=hi-lo
    local h=previous and previous.H or 0
    if delta>1e-8 then
        if hi==c.R then h=60*((c.G-c.B)/delta%6)
        elseif hi==c.G then h=60*((c.B-c.R)/delta+2)
        else h=60*((c.R-c.G)/delta+4) end
    end
    return {H=h,S=hi>1e-8 and delta/hi or (previous and previous.S or 0),V=hi}
end
-- Name the displayed swatch. Slate displays these linear channels as sRGB;
-- this conversion is for words only, never for the stored colour or HSV axes.
function M.colourName(c)
    local function display(v)
        v=math.max(0,math.min(1,v))
        return v<=.0031308 and 12.92*v or 1.055*v^(1/2.4)-.055
    end
    local hsv=M.colourHSV({R=display(c.R),G=display(c.G),B=display(c.B)})
    local h,s,v=hsv.H,hsv.S,hsv.V
    if v<=.12 then return 'Black' end
    if s<=.10 then return v>=.90 and 'White' or 'Grey' end
    if h>=15 and h<50 and v<.88 then return 'Brown' end
    if h<15 or h>=345 then
        return s<=.65 and v>=.75 and 'Pink' or 'Red'
    end
    if h<45 then return 'Orange' end
    if h<70 then return 'Yellow' end
    if h<165 then return 'Green' end
    if h<200 then return 'Cyan' end
    if h<255 then return 'Blue' end
    if h<290 then return 'Purple' end
    if h<330 then return 'Magenta' end
    return 'Pink'
end
function M.closePercent(distanceSq,maxDistanceSq)
    return 1-math.sqrt(math.min(distanceSq or maxDistanceSq,maxDistanceSq))/math.sqrt(maxDistanceSq)
end
function M.quantity(info)
 return tostring(math.max(1,math.min(info.pots,255,info.target or 3)))..'/'..tostring(info.pots)
end
return M
