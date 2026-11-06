local dir=debug.getinfo(1,'S').source:match('^@(.+[\\/])')
local Layout=dofile(dir..'bar_layout.lua')
return function(S)
    local R,C=S.R,S.C
    local bar
    local function align(parent,child,h,v)
        local slot=parent:AddChild(child)
        slot:SetHorizontalAlignment(h);slot:SetVerticalAlignment(v)
        return slot
    end
    local function clear()
        if not bar then return end
        local b=bar;bar=nil
        if not R.valid(b.widget) then return end
        b.root:RemoveFromParent()
        for _,row in ipairs(b.originals) do
            if row.detached then
                local slot=align(b.parent,row.image,row.h,row.v)
                local padding=slot.Padding
                for key,value in pairs(row.padding) do padding[key]=value end
                slot:SetPadding(padding)
            end
            row.image:SetVisibility(row.visibility)
        end
        local offsets=b.widget.Slot.LayoutData.Offsets
        for key,value in pairs(b.offsets) do offsets[key]=value end
        b.widget.Slot:SetOffsets(offsets)
        for _,row in ipairs(b.clips) do row.widget:SetClipping(row.value) end
    end
    local function build(widget,n)
        widget:ForceLayoutPrepass()
        local parent=widget.Cauldron1:GetParent()
        local textures,originals,frame={},{},nil
        for _,image in ipairs(S.values(parent:GetAllChildren())) do
            local name=image:GetFName():ToString()
            local key=({Back='bg',Galss='frame',Cauldron2='mid',Cauldron3='right'})[name]
            if key then textures[key]=image.Brush.ResourceObject end
            if name=='Galss' then frame=image end
            local slot=image.Slot
            originals[#originals+1]={image=image,detached=name:match('^Cauldron[123]$')~=nil,
                h=slot.HorizontalAlignment,v=slot.VerticalAlignment,visibility=image:GetVisibility(),
                padding={Left=slot.Padding.Left,Top=slot.Padding.Top,Right=slot.Padding.Right,Bottom=slot.Padding.Bottom}}
        end
        local k=frame.Brush.ImageSize.Y/64
        local plan,width=Layout.layout(n)
        local function new(kind)return S.new('/Script/UMG.'..kind,widget.WidgetTree)end
        local root=new('SizeBox');root:SetWidthOverride(width*k);root:SetHeightOverride(64*k);root:SetVisibility(4)
        align(parent,root,2,2)
        local row=new('HorizontalBox');root:AddChild(row)
        local b={widget=widget,address=widget:GetAddress(),parent=parent,root=root,n=n,originals=originals,pieces={},clips={}}
        local offsets=widget.Slot.LayoutData.Offsets
        b.offsets={Left=offsets.Left,Top=offsets.Top,Right=offsets.Right,Bottom=offsets.Bottom}
        for _,p in ipairs(plan) do
            local box=new('SizeBox');box:SetWidthOverride(p.w*k);box:SetHeightOverride(64*k);box:SetClipping(1)
            local slot=align(row,box,0,0);local size=slot.Size;size.SizeRule=0;size.Value=1;slot:SetSize(size)
            local canvas=new('CanvasPanel');box:AddChild(canvas)
            for z,key in ipairs({'bg','fill','frame'}) do
                local image=new('Image')
                local texture=key=='fill' and (p.fill=='left' and textures.right or textures[p.fill]) or textures[key]
                image:SetBrushFromTexture(texture,false)
                local colour=image.ColorAndOpacity;colour.R=1;colour.G=1;colour.B=1;colour.A=1
                image:SetColorAndOpacity(colour)
                if key=='fill' and p.fill=='left' then
                    image:SetRenderTransformPivot({X=.5,Y=.5});image:SetRenderScale({X=-1,Y=1})
                end
                local imageSlot=canvas:AddChild(image)
                local factor=p.w/(p.src[2]-p.src[1])*k
                local imageOffsets=imageSlot.LayoutData.Offsets
                imageOffsets.Left=-p.src[1]*factor;imageOffsets.Top=0;imageOffsets.Right=512*factor;imageOffsets.Bottom=64*k
                imageSlot:SetOffsets(imageOffsets);imageSlot:SetZOrder(z-1)
                image:SetVisibility(key=='fill' and 2 or 4)
                if key=='fill' then b.pieces[#b.pieces+1]={image=image,index=p.section+1} end
            end
        end
        offsets.Right=width*k;widget.Slot:SetOffsets(offsets)
        for _,node in ipairs({parent,parent:GetParent(),widget,widget:GetParent()}) do
            b.clips[#b.clips+1]={widget=node,value=node.Clipping};node:SetClipping(0)
        end
        for _,original in ipairs(originals) do
            original.image:SetVisibility(2)
            if original.detached then original.image:RemoveFromParent() end
        end
        bar=b
    end
    function S.progressBar(widget)
        local gs=C.session().gs
        -- CauldronTarget has no replication callback; a guest repaints when the policy arrives.
        local policy=S.hudPolicy()
        local target=policy and policy.target or gs.CauldronTarget
        local n=math.min(10,math.max(target,policy and policy.ceiling or 0))
        if n<1 then return end
        if bar and (bar.address~=widget:GetAddress() or bar.n~=n) then clear() end
        if not bar then build(widget,n) end
        local colours=S.values(gs.FilledCauldronColors)
        for _,piece in ipairs(bar.pieces) do
            local c=colours[piece.index]
            if piece.index>target then c={R=.2961379885673523,G=.2307399958372116,B=.34670400619506836} end
            if c then
                local value=piece.image.ColorAndOpacity
                value.R=c.R;value.G=c.G;value.B=c.B;value.A=1
                piece.image:SetColorAndOpacity(value)
            end
            piece.image:SetVisibility(c and 4 or 2)
        end
    end
    for _,method in ipairs({'OnCauldronFilledMulti','LoadPropsAndCauldrons'}) do
        S.onMatch.post(S.path(S.O,'B_ObjectiveGameState',method),function() S.refreshHUD() end)
    end
    R.on('world_end',clear)
end
