-- WIN3 presentation: the host's frozen decision, using native result-line roles.
local M={}
local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
local Winner=dofile(dir..'winner_order.lua')
function M.model(order,result,infinite,fallback)
    if fallback or not result or not result.a or not result.b then return end
    local rows,deciding={},nil
    for _,key in ipairs(Winner.parse(order) or Winner.parse(Winner.default)) do
        if not (key=='lives' and infinite) then
            local x,y=result.a[key],result.b[key]
            if type(x)~='number' or type(y)~='number' then return end
            local a,b=x,y
            if key=='time' then
                if result.a.finished~=result.b.finished then a,b=result.a.finished and 1 or 0,result.b.finished and 1 or 0
                elseif result.a.finished then a,b=-a,-b end
            end
            local team=a==b and 0 or (a>b and 1 or 2)
            -- These native enums are ROLE icons (0 witch, 1 hunter, 2 neutral),
            -- not ObjectiveTeam IDs. Kills are hunter achievements; others witch.
            local winRole=key=='kills' and 1 or 0
            local ar=team==0 and 2 or (team==1 and winRole or 1-winRole)
            local br=team==0 and 2 or (team==2 and winRole or 1-winRole)
            local function score(n)
                if key~='time' then return tostring(n) end
                n=math.max(0,math.floor(n)); return string.format('%d:%02d',n//60,n%60)
            end
            local row={key=key,label=key=='wins' and 'Rounds won' or Winner.labels[key],
                a=score(x),b=score(y),team=team,ar=ar,br=br,deciding=not deciding and team~=0}
            rows[#rows+1]=row
            if row.deciding then deciding=#rows end
        end
    end
    if deciding then
        if result.key~=rows[deciding].key or result.team~=rows[deciding].team then return end
    elseif result.key~='draw' or result.team~=0 then return end
    local model={rows=rows,reveal=deciding or #rows,deciding=deciding,team=result.team,
        summary=result.key=='draw' and 'Draw: all criteria equal' or 'Deciding criterion: '..Winner.labels[result.key]}
    local signature={tostring(model.team),tostring(model.reveal),model.summary}
    for _,row in ipairs(rows) do
        signature[#signature+1]=table.concat({row.key,row.a,row.b,row.ar,row.br},':')
    end
    model.signature=table.concat(signature,'|')
    return model
end
function M.schedule(model)
    local steps={}
    for index=1,model.reveal do
        steps[#steps+1]={ms=index*750,first=index,last=index==model.deciding and #model.rows or index}
    end
    return steps
end
function M.preview(order)
    local a={wins=1,pots=2,props=5,lives=7,kills=3,time=85,finished=false}
    local b={wins=1,pots=1,props=4,lives=6,kills=2,time=80,finished=false}
    local team,key=Winner.compare(order,a,b,false)
    return {team=team,key=key,a=a,b=b}
end
return M
