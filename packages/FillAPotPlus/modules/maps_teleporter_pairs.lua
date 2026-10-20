-- Pure pairing policy, shared by placement, checks and native-zone presentation.
local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
local Colours=dofile(dir..'maps_colour.lua')
local M={}
function M.key(c)return string.pack('<fff',c.R,c.G,c.B)end
function M.label(c)
 for _,v in ipairs(Colours.SWATCHES)do if M.key(c)==M.key(v)then return v.name end end
 return string.format('RGB %.3f/%.3f/%.3f',c.R,c.G,c.B)
end
function M.groups(entrances,exits,exclude)
 local groups,order={},{}
 for kind,list in pairs({[3]=entrances,[4]=exits})do for _,p in ipairs(list)do
  if not exclude or p.id~=exclude:GetAddress()then
   local c=p.info.colour;local key=M.key(c);local g=groups[key]
   if not g then g={colour=c,key=key,entrances={},exits={}};groups[key]=g;order[#order+1]=g end
   local rows=kind==3 and g.entrances or g.exits;rows[#rows+1]=p
  end
 end end
 table.sort(order,function(a,b)return a.key<b.key end)
 local pairs_,problems={},{}
 for _,g in ipairs(order)do
  if #g.entrances==1 and #g.exits==1 then pairs_[#pairs_+1]=g
  else problems[#problems+1]='Teleporter '..M.label(g.colour)..': '..#g.entrances..' entrance(s), '..#g.exits..' exit(s); needs exactly one of each' end
 end
 return pairs_,problems,order
end
function M.nextColour(entrances,exits,kind,exclude)
 assert(kind==3 or kind==4,'invalid teleporter endpoint kind')
 local _,_,groups=M.groups(entrances,exits,exclude);local used,incomplete={},{}
 for _,g in ipairs(groups)do
  local own=kind==3 and g.entrances or g.exits;local other=kind==3 and g.exits or g.entrances
  if #own==0 and #other==1 then incomplete[g.key]=g.colour end
  used[g.key]=true
 end
 for _,c in ipairs(Colours.SWATCHES)do if incomplete[M.key(c)]then return c end end
 for _,g in ipairs(groups)do if incomplete[g.key]then return g.colour end end
 for _,c in ipairs(Colours.SWATCHES)do if not used[M.key(c)]then return c end end
 for i=1,360 do local c=Colours.hsvColour(i*137.508,.8,1);if not used[M.key(c)]then return c end end
 error('no free teleporter pair colour')
end
return M
