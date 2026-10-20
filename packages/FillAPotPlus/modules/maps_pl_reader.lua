-- Offline v9 .pl reader. Only Lua 5.4 primitives; no UObject calls or C modules.
-- RFC1950 streams inside UE FCompressedChunk (compression discriminator 3).
local M={}
local byte,char,unpack=string.byte,string.char,string.unpack
local MAX=256*1024*1024
local function requireValid(ok,why) if not ok then error(why,0) end end
local function reader(data)
    local r={data=data,pos=1}
    function r:take(n)
        requireValid(n>=0 and n<=#self.data-self.pos+1,'truncated/invalid layout field')
        local p=self.pos; self.pos=p+n; return self.data:sub(p,p+n-1)
    end
    function r:skip(n)
        requireValid(n>=0 and n<=#self.data-self.pos+1,'truncated/invalid layout field')
        self.pos=self.pos+n
    end
    function r:number(fmt,n)
        requireValid(n<=#self.data-self.pos+1,'truncated layout integer')
        local v; v,self.pos=unpack(fmt,self.data,self.pos); return v
    end
    function r:i32() return self:number('<i4',4) end
    function r:i64() return self:number('<i8',8) end
    function r:count()
        local n=self:i32(); requireValid(n>=0 and n<=#self.data//4,'invalid layout count'); return n
    end
    function r:name()
        local n=self:i32(); if n==0 then return '' end
        local s=self:take(n>0 and n or -n*2)
        requireValid(s:sub(n>0 and -1 or -2)==(n>0 and '\0' or '\0\0'),'FString missing NUL')
        if n>0 then return s:sub(1,-2) end
        -- Asset names are ASCII, but a valid Unicode name may be skipped safely.
        local out={}; for i=1,#s-2,2 do
            local c=unpack('<I2',s,i); out[#out+1]=c<128 and char(c) or '?'
        end
        return table.concat(out)
    end
    return r
end

local function huffman(lengths,allowEmpty,complete)
    local counts,codes={},{}; local max=0
    for _,n in ipairs(lengths) do
        requireValid(n>=0 and n<=15,'invalid Huffman length')
        if n>0 then counts[n]=(counts[n] or 0)+1; max=math.max(max,n) end
    end
    if max==0 then requireValid(allowEmpty,'empty Huffman tree'); return {max=0,fast={},long={}} end
    local left,code=1,0
    for n=1,15 do
        left=left*2-(counts[n] or 0); requireValid(left>=0,'oversubscribed Huffman tree')
        code=(code+(counts[n-1] or 0))*2; codes[n]=code
    end
    requireValid(left==0 or (not complete and max==1 and counts[1]==1),'incomplete Huffman tree')
    local fast,long={},{}
    for symbol=0,#lengths-1 do
        local n=lengths[symbol+1]
        if n>0 then
            local c=codes[n]; codes[n]=c+1; local rev=0
            for _=1,n do rev=(rev<<1)|(c&1); c=c>>1 end
            if n<=9 then
                local value=(symbol<<4)|n
                for k=rev,511,1<<n do fast[k]=value end
            else long[(1<<n)|rev]=symbol end
        end
    end
    return {max=max,fast=fast,long=long}
end
local fixedLit,fixedDist
do
    local l,d={},{}
    for i=0,287 do l[i+1]=i<=143 and 8 or i<=255 and 9 or i<=279 and 7 or 8 end
    for i=1,32 do d[i]=5 end
    fixedLit,fixedDist=huffman(l),huffman(d)
end
local lengthBase={3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
local lengthExtra={0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
local distBase={1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
local distExtra={0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}
local order={16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}
function M.zlib(data,expected)
    requireValid(#data>=6 and expected>=0 and expected<=MAX,'invalid zlib size')
    local cmf,flg=byte(data,1,2)
    requireValid(cmf&15==8 and cmf>>4<=7 and (cmf*256+flg)%31==0 and flg&32==0,'unsupported zlib header/dictionary')
    local pos,last,buf,bits=3,#data-4,0,0
    local function fill(n)
        while bits<n and pos<=last do buf=buf|(byte(data,pos)<<bits); pos=pos+1; bits=bits+8 end
    end
    local function get(n)
        fill(n); requireValid(bits>=n,'truncated deflate bits')
        local v=buf&((1<<n)-1); buf=buf>>n; bits=bits-n; return v
    end
    local function symbol(tree)
        fill(15)
        local v=tree.fast[buf&511]
        if v then
            local n=v&15; requireValid(bits>=n,'truncated Huffman code')
            buf=buf>>n; bits=bits-n; return v>>4
        end
        for n=10,tree.max do
            local s=tree.long[(1<<n)|(buf&((1<<n)-1))]
            if s then requireValid(bits>=n,'truncated Huffman code'); buf=buf>>n; bits=bits-n; return s end
        end
        error('invalid Huffman code',0)
    end
    local out,n={},0
    local final=false
    while not final do
        final=get(1)==1; local typ=get(2)
        if typ==0 then
            get(bits%8)
            local len,inv=get(16),get(16)
            requireValid(len ~ inv==65535 and n+len<=expected,'invalid stored deflate block')
            for _=1,len do n=n+1; out[n]=get(8) end
        else
            requireValid(typ~=3,'reserved deflate block')
            local lit,dist=fixedLit,fixedDist
            if typ==2 then
                local nl,nd,nc=get(5)+257,get(5)+1,get(4)+4
                requireValid(nl<=286,'invalid literal alphabet')
                local cl={}; for i=1,19 do cl[i]=0 end
                for i=1,nc do cl[order[i]+1]=get(3) end
                local ct=huffman(cl,false,true); local lengths={}
                while #lengths<nl+nd do
                    local s=symbol(ct); local value,count=s,1
                    if s==16 then requireValid(#lengths>0,'Huffman repeat without previous'); value=lengths[#lengths]; count=get(2)+3
                    elseif s==17 then value=0; count=get(3)+3
                    elseif s==18 then value=0; count=get(7)+11 end
                    requireValid(#lengths+count<=nl+nd,'Huffman repeat overflow')
                    for _=1,count do lengths[#lengths+1]=value end
                end
                requireValid(lengths[257]>0,'missing deflate end code')
                local dl={}; for i=1,nd do dl[i]=lengths[nl+i] end
                for i=nl+nd,nl+1,-1 do lengths[i]=nil end
                lit,dist=huffman(lengths),huffman(dl,true)
            end
            while true do
                local s=symbol(lit)
                if s==256 then break end
                if s<256 then
                    requireValid(n<expected,'deflate output overflow'); n=n+1; out[n]=s
                else
                    requireValid(s<=285,'reserved deflate length')
                    local idx=s-256; local len=lengthBase[idx]+get(lengthExtra[idx])
                    local d=symbol(dist); requireValid(d<30,'reserved deflate distance')
                    local distance=distBase[d+1]+get(distExtra[d+1])
                    requireValid(distance<=n and distance<=1<<((cmf>>4)+8) and n+len<=expected,'invalid deflate back-reference')
                    for _=1,len do n=n+1; out[n]=out[n-distance] end
                end
            end
        end
    end
    requireValid(n==expected and pos-(bits//8)==last+1,'zlib output size/trailing data mismatch')
    local a,b=1,0; local chunks={}
    for start=1,n,4096 do
        local finish=math.min(n,start+4095)
        for i=start,finish do a=a+out[i]; b=b+a end
        a=a%65521; b=b%65521
        chunks[#chunks+1]=char(table.unpack(out,start,finish))
    end
    requireValid((b<<16)|a==unpack('>I4',data,last+1),'zlib Adler-32 mismatch')
    return table.concat(chunks)
end
function M.inflate(data)
    -- The game's FArchiveSaveCompressedProxy writes a SEQUENCE of independent
    -- SerializeCompressed records (each <= one chunk); read them all.
    local r=reader(data); local chunks={}; local size0
    repeat
        requireValid(r:number('<I4',4)==0x9e2a83c1 and r:number('<I4',4)==0x22222222,'unsupported FCompressedChunk tag')
        local size=r:i64(); requireValid(size>0 and size<=MAX and r:number('B',1)==3,'unsupported compression format/block size')
        requireValid(size0==nil or size==size0,'inconsistent chunk size'); size0=size
        local compressed,total=r:i64(),r:i64()
        requireValid(compressed>0 and compressed<=#data and total>0 and total<=MAX,'invalid compression summary')
        local count=(total+size-1)//size; requireValid(count<=(#data-r.pos+1)//16,'truncated compression table')
        local pairs,cs,us={},0,0
        for i=1,count do
            local c,u=r:i64(),r:i64()
            requireValid(c>0 and c<=#data and u==math.min(size,total-(i-1)*size),'invalid compression block sizes')
            pairs[i]={c,u}; cs=cs+c; us=us+u
        end
        requireValid(cs==compressed and us==total,'compression summary/block mismatch')
        for _,p in ipairs(pairs) do chunks[#chunks+1]=M.zlib(r:take(p[1]),p[2]) end
        requireValid(#chunks<=64,'too many compressed records')
    until r.pos==#data+1
    return table.concat(chunks)
end
function M.parse(raw,X)
    local r=reader(raw)
    requireValid(r:i32()==#raw-4 and r:i32()==9,'unsupported layout size/version')
    local props=r:count()
    for _=1,props do r:name(); r:skip(88) end -- 9 doubles + 4 integers
    requireValid(r:i32()==0,'unsupported nonzero pre-object section')
    local objects=r:count(); local pots,respawns,markers=0,0,{}
    for _=1,objects do
        local name=r:name(); r:skip(80) -- 9 doubles + Activated/Id
        local payload=r:take(r:i32())
        local bytes={}; local first=math.max(1,#payload-(X.MAX_TYPE_PAYLOAD or 39)+1)
        for i=first,#payload do bytes[#bytes+1]=byte(payload,i) end
        local marker=X.decode(bytes)
        if marker and name:gsub('_C$','')==X.CARRIERS[marker.kind]:match('%.(.+)$'):gsub('_C$','') then
            if marker.kind==1 then pots=pots+1; markers[#markers+1]=marker elseif marker.kind==2 then respawns=respawns+1 end
        end
    end
    -- Tail sections do not affect object boundaries. Populated tails (lights,
    -- switches, world properties/prefabs) remain unknown: fail closed for now.
    requireValid(r:i32()==0 and r:i32()==0 and r:i32()==0 and r.pos==#raw+1,'unsupported nonempty/trailing layout sections')
    local target,revision,conflict=X.target(markers)
    return {pots=pots,respawns=respawns,target=target,targetRevision=revision,conflict=conflict,seekCoefficient=X.markerSeekCoefficient(markers),props=props,objects=objects}
end
function M.records(data,X)
    local raw=M.inflate(data); local records={}; local at=1
    while at<=#raw do
        local length=string.unpack('<i4',raw,at)
        requireValid(length>=4 and at+length+3<=#raw,'invalid layout record length')
        local bytes=raw:sub(at,at+length+3)
        local info=M.parse(bytes,X); info.raw=bytes; records[#records+1]=info
        at=at+length+4
        requireValid(#records<=64,'too many layout records')
    end
    return records
end
function M.read(data,X)
    local records=M.records(data,X)
    local r=records[1]; r.raw=nil
    if #records>1 then
        r={records=records,pots=0,target=0,respawns=0,props=0,targetRevision=0}
        for _,record in ipairs(records) do
            record.raw=nil
            r.pots=math.max(r.pots,record.pots); r.target=math.max(r.target,record.target)
            r.respawns=math.max(r.respawns,record.respawns); r.props=math.max(r.props,record.props)
        end
    end
    return r
end
-- Native-compatible stored zlib blocks. Materialized records preserve exact raw
-- bytes and originals; compression level affects size only, never their contents.
function M.pack(raw)
    local chunks={}
    for at=1,#raw,131072 do
        local bytes=raw:sub(at,at+131071); local blocks={string.char(0x78,0x01)}
        for i=1,#bytes,65535 do
            local block=bytes:sub(i,i+65534)
            blocks[#blocks+1]=string.char(i+#block>#bytes and 1 or 0)..string.pack('<I2I2',#block,(~#block)&0xffff)..block
        end
        local a,b=1,0
        for i=1,#bytes do a=(a+bytes:byte(i))%65521; b=(b+a)%65521 end
        blocks[#blocks+1]=string.pack('>I4',(b<<16)|a)
        local compressed=table.concat(blocks)
        chunks[#chunks+1]=string.pack('<I4I4i8Bi8i8i8i8',0x9e2a83c1,0x22222222,131072,3,#compressed,#bytes,#compressed,#bytes)..compressed
    end
    return table.concat(chunks)
end
-- Finite, main-state decoder for the menu index. No additional Lua state or engine calls.
-- Each step consumes <=4096 output bytes / <=128 layout objects, with a 2 ms
-- deadline. Synchronous readers above remain for explicit load/export barriers.
function M.zlibJob(data,expected)
    requireValid(#data>=6 and expected>=0 and expected<=MAX,'invalid zlib size')
    local cmf,flg=byte(data,1,2)
    requireValid(cmf&15==8 and cmf>>4<=7 and (cmf*256+flg)%31==0 and flg&32==0,'unsupported zlib header/dictionary')
    local pos,last,buf,bits=3,#data-4,0,0
    local function get(n)
        while bits<n and pos<=last do buf=buf|(byte(data,pos)<<bits);pos=pos+1;bits=bits+8 end
        requireValid(bits>=n,'truncated deflate bits')
        local v=buf&((1<<n)-1);buf=buf>>n;bits=bits-n;return v
    end
    local function symbol(tree)
        while bits<15 and pos<=last do buf=buf|(byte(data,pos)<<bits);pos=pos+1;bits=bits+8 end
        local v=tree.fast[buf&511]
        if v then local n=v&15;requireValid(bits>=n,'truncated Huffman code');buf=buf>>n;bits=bits-n;return v>>4 end
        for n=10,tree.max do
            local s=tree.long[(1<<n)|(buf&((1<<n)-1))]
            if s then requireValid(bits>=n,'truncated Huffman code');buf=buf>>n;bits=bits-n;return s end
        end
        error('invalid Huffman code',0)
    end
    local out,n={},0;local final,lit,dist,stored=false,nil,nil,nil
    local phase='header';local checksumAt,a,b=1,1,0;local chunks={};local result
    return function()
        if result then return true,result end
        local deadline=os.clock()+.002;local start=n
        repeat
            if phase=='header' then
                final=get(1)==1;local typ=get(2)
                if typ==0 then
                    get(bits%8);local len,inv=get(16),get(16)
                    requireValid(len ~ inv==65535 and n+len<=expected,'invalid stored deflate block')
                    stored=len;phase='stored'
                else
                    requireValid(typ~=3,'reserved deflate block');lit,dist=fixedLit,fixedDist
                    if typ==2 then
                        local nl,nd,nc=get(5)+257,get(5)+1,get(4)+4
                        requireValid(nl<=286,'invalid literal alphabet')
                        local cl={};for i=1,19 do cl[i]=0 end
                        for i=1,nc do cl[order[i]+1]=get(3) end
                        local ct=huffman(cl,false,true);local lengths={}
                        while #lengths<nl+nd do
                            local s=symbol(ct);local value,count=s,1
                            if s==16 then requireValid(#lengths>0,'Huffman repeat without previous');value=lengths[#lengths];count=get(2)+3
                            elseif s==17 then value=0;count=get(3)+3
                            elseif s==18 then value=0;count=get(7)+11 end
                            requireValid(#lengths+count<=nl+nd,'Huffman repeat overflow')
                            for _=1,count do lengths[#lengths+1]=value end
                        end
                        requireValid(lengths[257]>0,'missing deflate end code')
                        local dl={};for i=1,nd do dl[i]=lengths[nl+i] end
                        for i=nl+nd,nl+1,-1 do lengths[i]=nil end
                        lit,dist=huffman(lengths),huffman(dl,true)
                    end
                    phase='symbols'
                end
            elseif phase=='stored' then
                local count=math.min(stored,256)
                for _=1,count do n=n+1;out[n]=get(8) end
                stored=stored-count
                if stored==0 then phase=final and 'checksum' or 'header' end
            elseif phase=='symbols' then
                local s=symbol(lit)
                if s==256 then phase=final and 'checksum' or 'header'
                elseif s<256 then requireValid(n<expected,'deflate output overflow');n=n+1;out[n]=s
                else
                    requireValid(s<=285,'reserved deflate length')
                    local idx=s-256;local len=lengthBase[idx]+get(lengthExtra[idx]);local d=symbol(dist)
                    requireValid(d<30,'reserved deflate distance');local distance=distBase[d+1]+get(distExtra[d+1])
                    requireValid(distance<=n and distance<=1<<((cmf>>4)+8) and n+len<=expected,'invalid deflate back-reference')
                    for _=1,len do n=n+1;out[n]=out[n-distance] end
                end
            elseif phase=='checksum' then
                requireValid(n==expected and pos-(bits//8)==last+1,'zlib output size/trailing data mismatch')
                local finish=math.min(n,checksumAt+4095)
                for i=checksumAt,finish do a=a+out[i];b=b+a end
                a=a%65521;b=b%65521
                if finish>=checksumAt then chunks[#chunks+1]=char(table.unpack(out,checksumAt,finish)) end
                checksumAt=finish+1
                if checksumAt>n then
                    requireValid((b<<16)|a==unpack('>I4',data,last+1),'zlib Adler-32 mismatch')
                    result=table.concat(chunks);return true,result
                end
                return false
            end
        until n-start>=4096 or os.clock()>=deadline
        return false
    end
end
function M.readJob(data,X)
    local r=reader(data);local chunks={};local size0;local blocks,block,decode
    local raw,at,record,phase,remaining,markers,infos=nil,1,nil,'inflate',0,nil,{}
    local pots,respawns,props,objects=0,0,0,0
    return function()
        if phase=='inflate' then
            if decode then
                local done,value=decode();if not done then return false end
                chunks[#chunks+1]=value;decode=nil;block=block+1
                requireValid(#chunks<=64,'too many compressed records');return false
            end
            if blocks and block<=#blocks then
                local p=blocks[block];decode=M.zlibJob(r:take(p[1]),p[2]);return false
            end
            if r.pos==#data+1 then raw=table.concat(chunks);chunks=nil;phase='record';return false end
            requireValid(r:number('<I4',4)==0x9e2a83c1 and r:number('<I4',4)==0x22222222,'unsupported FCompressedChunk tag')
            local size=r:i64();requireValid(size>0 and size<=MAX and r:number('B',1)==3,'unsupported compression format/block size')
            requireValid(size0==nil or size==size0,'inconsistent chunk size');size0=size
            local compressed,total=r:i64(),r:i64()
            requireValid(compressed>0 and compressed<=#data and total>0 and total<=MAX,'invalid compression summary')
            local count=(total+size-1)//size;requireValid(count<=(#data-r.pos+1)//16,'truncated compression table')
            blocks={};local cs,us=0,0
            for i=1,count do
                local c,u=r:i64(),r:i64();requireValid(c>0 and c<=#data and u==math.min(size,total-(i-1)*size),'invalid compression block sizes')
                blocks[i]={c,u};cs=cs+c;us=us+u
            end
            requireValid(cs==compressed and us==total,'compression summary/block mismatch');block=1;return false
        end
        if phase=='record' then
            if at>#raw then
                local info=infos[1];requireValid(info~=nil,'empty layout archive')
                if #infos==1 then info.raw=nil end
                if #infos>1 then
                    info={records=infos,pots=0,target=0,respawns=0,props=0,targetRevision=0}
                    for _,v in ipairs(infos) do
                        info.pots=math.max(info.pots,v.pots);info.target=math.max(info.target,v.target)
                        info.respawns=math.max(info.respawns,v.respawns);info.props=math.max(info.props,v.props)
                    end
                end
                return true,info
            end
            local length=unpack('<i4',raw,at);requireValid(length>=4 and at+length+3<=#raw,'invalid layout record length')
            record=reader(raw:sub(at,at+length+3));at=at+length+4
            requireValid(record:i32()==#record.data-4 and record:i32()==9,'unsupported layout size/version')
            props=record:count();remaining=props;phase='props';pots=0;respawns=0;markers={}
        end
        local deadline=os.clock()+.002;local visited=0
        repeat
            if phase=='props' then
                if remaining>0 then record:name();record:skip(88);remaining=remaining-1;visited=visited+1
                else requireValid(record:i32()==0,'unsupported nonzero pre-object section');objects=record:count();remaining=objects;phase='objects' end
            elseif phase=='objects' then
                if remaining>0 then
                    local name=record:name();record:skip(80);local length=record:i32()
                    record:skip(length);local bytes={}
                    -- Inspect only the marker trailer. An arbitrary materials
                    -- prefix must not introduce a large synchronous string copy.
                    for i=math.max(record.pos-length,record.pos-(X.MAX_TYPE_PAYLOAD or 39)),record.pos-1 do
                        bytes[#bytes+1]=byte(record.data,i)
                    end
                    local marker=X.decode(bytes)
                    if marker and name:gsub('_C$','')==X.CARRIERS[marker.kind]:match('%.(.+)$'):gsub('_C$','') then
                        if marker.kind==1 then pots=pots+1;markers[#markers+1]=marker elseif marker.kind==2 then respawns=respawns+1 end
                    end
                    remaining=remaining-1;visited=visited+1
                else
                    requireValid(record:i32()==0 and record:i32()==0 and record:i32()==0 and record.pos==#record.data+1,'unsupported nonempty/trailing layout sections')
                    local target,revision,conflict=X.target(markers)
                    infos[#infos+1]={raw=record.data,pots=pots,respawns=respawns,target=target,targetRevision=revision,conflict=conflict,seekCoefficient=X.markerSeekCoefficient(markers),props=props,objects=objects}
                    requireValid(#infos<=64,'too many layout records');phase='record';return false
                end
            end
        until visited>=128 or os.clock()>=deadline
        return false
    end
end
function M.packJob(raw)
    local chunks={};local at=1;local current,blocks,a,b,checksumAt
    return function()
        if not current then
            if at>#raw then return true,table.concat(chunks) end
            current=raw:sub(at,at+131071);blocks={char(0x78,0x01)};a,b,checksumAt=1,0,1
            for i=1,#current,65535 do
                local block=current:sub(i,i+65534)
                blocks[#blocks+1]=char(i+#block>#current and 1 or 0)..string.pack('<I2I2',#block,(~#block)&0xffff)..block
            end
            return false
        end
        local finish=math.min(#current,checksumAt+4095)
        for i=checksumAt,finish do a=a+current:byte(i);b=b+a end
        a=a%65521;b=b%65521;checksumAt=finish+1
        if checksumAt<=#current then return false end
        blocks[#blocks+1]=string.pack('>I4',(b<<16)|a)
        local compressed=table.concat(blocks)
        chunks[#chunks+1]=string.pack('<I4I4i8Bi8i8i8i8',0x9e2a83c1,0x22222222,131072,3,#compressed,#current,#compressed,#current)..compressed
        at=at+#current;current=nil;return false
    end
end
return M
