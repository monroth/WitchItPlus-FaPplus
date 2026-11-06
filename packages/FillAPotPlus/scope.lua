-- Scope of Fill a Pot+. Gameplay hooks register through these registrars only;
-- plain R hooks are reserved for menus that choose the mode before a match.
return function(S)
    -- One line per map decision, so a wrong map can be traced from the log.
    function S.options(o)
        if not o or not o.MapData then return 'none' end
        local layout=o.CustomMapSelected and S.text(o.LayoutData[S.L.file]) or '-'
        return string.format('%x map=%s custom=%s layout=%s plus=%s',o:GetAddress(),
            S.text(o.MapData[S.F.file]),tostring(o.CustomMapSelected),layout,tostring(S.C.is_plus(o)))
    end
    function S.trace(fmt,...) S.R.log('FAP map',fmt,...) end
    function S.log(fmt,...) S.R.log('FAP',fmt,...) end
    local C=S.C
    local function inMatch(s) return s.mode=='fap+' end
    local function inMode(s) return s.mode=='fap+' or s.mode=='creative' end
    local function editing(s) return s.mode=='creative' and not s.gs.IsPlayTestMode end
    local function host(s) return s.role~='client' end
    function S.inMatch() return inMatch(C.session()) end
    function S.active() return inMode(C.session()) end
    function S.editing() return editing(C.session()) end
    function S.host() return host(C.session()) end
    S.onMatch = C.scoped(inMatch)
    S.onMatchHost = C.scoped(function(s) return inMatch(s) and host(s) end)
    S.onMode = C.scoped(inMode)
    S.onModeHost = C.scoped(function(s) return inMode(s) and host(s) end)
    S.onEditor = C.scoped(editing)
    S.onEditorHost = C.scoped(function(s) return editing(s) and host(s) end)
end
