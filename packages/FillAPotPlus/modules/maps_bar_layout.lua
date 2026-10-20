-- Exact port of art_ref/progress_bar/compose_bar.py. Texture columns are [x0,x1).
-- Seam minima are computed offline from the four native 512x64 textures.
local M={}
local back='\\\\'
local LEFT={cap={fixed={0,50},flex={50,150},fill='left'},
    [back]={fixed={175,205},flex={205,300},fill='mid'},
    ['/']={fixed={338,368},flex={368,470},fill='right'}}
local RIGHT={[back]={fixed={145,175},flex={40,145},fill='left'},
    ['/']={fixed={308,338},flex={205,308},fill='mid'},
    cap={fixed={462,512},flex={360,462},fill='right'}}
local SEAMS={cap={cap={125,372},[back]={97,97}},
    [back]={cap={279,386},[back]={213,102},['/']={252,252}},
    ['/']={cap={415,415},['/']={387,278}}}
local function round(x) -- Python round(): ties to even
    local a=math.floor(x); local f=x-a
    return (f>.5 or (f==.5 and a%2==1)) and a+1 or a
end
function M.edges(n)
    local es={}; local k=n-1
    for i=1,k do es[i]=i<=math.floor((k+1)/2) and back or '/' end
    return es
end
function M.seam(le,re)
    local s=assert(SEAMS[le][re],'unsupported seam'); return s[1],s[2]
end
-- Up to 3 pots: native section widths (N=3 is exactly the vanilla 512 px bar).
function M.target_width(n) if n<=3 then return nil end return math.max(46,math.min(170,math.floor(768/n))) end
function M.section_pieces(le,re,width)
    local L,R=LEFT[le],RIGHT[re]; local a,b=M.seam(le,re)
    local fl,fr=L.fixed[2]-L.fixed[1],R.fixed[2]-R.fixed[1]
    local srcL,srcR={L.fixed[2],a},{b,R.fixed[1]}
    local nl,nr=srcL[2]-srcL[1],srcR[2]-srcR[1]
    local nat=nl+nr; local flex=width and math.max(8,width-fl-fr) or nat; local dl,dr
    if flex<=nat then
        local cut=nat-flex; local wl=math.max(4,nl-math.floor(cut/2)); local wr=math.max(4,flex-wl)
        srcL={srcL[1],srcL[1]+wl}; srcR={srcR[2]-wr,srcR[2]}; dl,dr=wl,wr
    else dl=round(nl*(flex/nat)); dr=flex-dl end
    return {{src=L.fixed,w=fl,fill=L.fill},{src=srcL,w=dl,fill=L.fill},
        {src=srcR,w=dr,fill=R.fill},{src=R.fixed,w=fr,fill=R.fill}}
end
function M.layout(n,width)
    assert(type(n)=='number' and n%1==0 and n>=1 and n<=10,'target outside 1..10')
    local es=M.edges(n); local pieces,x={},0
    for i=1,n do
        local le=i==1 and 'cap' or es[i-1]; local re=i==n and 'cap' or es[i]
        local tw=width; if tw==nil then tw=M.target_width(n) end
        for _,p in ipairs(M.section_pieces(le,re,tw)) do
            pieces[#pieces+1]={src={p.src[1],p.src[2]},dst=x,w=p.w,section=i-1,fill=p.fill}; x=x+p.w
        end
    end
    return pieces,x
end
return M
