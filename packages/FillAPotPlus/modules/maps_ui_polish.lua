-- Creative preview orb uses the vanilla placement; the real Objective HUD orb is
-- never moved (user: it belongs at its native position, low beside the mana bar).
local M={ORB_X=-140,ORB_BOTTOM=-175,ORB_SIZE=96}
function M.init(X)
    local api={}
    function X.placeOrb(slot)
        local offsets=slot.LayoutData.Offsets
        offsets.Left=M.ORB_X; offsets.Top=M.ORB_BOTTOM
        offsets.Right=M.ORB_SIZE; offsets.Bottom=M.ORB_SIZE
        slot:SetOffsets(offsets) -- native FMargin, never a getter-produced Lua table
    end
    function api.orb(w)
        if not X.live(w) then return end
        local gs=X.gameplay():GetGameState(w)
        if not X.live(gs) or not X.H.class(gs,'B_ObjectiveGameState_C')
            or X.Lifetime.worldKey(w)~=X.Lifetime.worldKey(gs) then return end
        local orb=X.read(w,'WB_DivineOrb')
        if X.H.valid(orb) then X.placeOrb(orb.Slot) end
    end
    function api.poll() end
    function api.reset() end
    return api
end
return M
