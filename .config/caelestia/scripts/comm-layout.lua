-- Arrange a workspace as: left = 2/3 column, right = top (70%) over bottom.
-- Called from comm-layout.py via `hyprctl dispatch`. Everything runs in one
-- synchronous call, so the focus hops it needs never reach the screen.
--
-- dwindle's preselect / splitratio act on the focused window only, hence the
-- hops; `splitratio <r> exact` is the absolute form ("exact <r>" is rejected).
return function(ws, left, top, bottom)
    local prev = hl.get_active_window()
    local tmp  = "special:comm-layout-tmp"
    local function addr(a) return "address:" .. a end
    local function d(x) hl.dispatch(x) end

    -- Rebuild the dwindle tree around `top` (discord): it never leaves the
    -- workspace, while the other two are parked and re-inserted beside it with
    -- a preselected direction. Something has to stay behind -- an emptied
    -- special workspace is destroyed and comes back on the *focused* monitor,
    -- closing it wherever it was actually shown.
    d(hl.dsp.window.move({ window = addr(top), workspace = ws, follow = false }))
    for _, a in ipairs({ left, bottom }) do
        d(hl.dsp.window.move({ window = addr(a), workspace = tmp, follow = false }))
    end
    d(hl.dsp.focus({ window = addr(top) }))
    d(hl.dsp.layout("preselect l"))
    d(hl.dsp.window.move({ window = addr(left), workspace = ws, follow = false }))
    d(hl.dsp.focus({ window = addr(top) }))
    d(hl.dsp.layout("preselect d"))
    d(hl.dsp.window.move({ window = addr(bottom), workspace = ws, follow = false }))

    d(hl.dsp.focus({ window = addr(left) }))
    d(hl.dsp.layout("splitratio 1.3333 exact"))
    d(hl.dsp.focus({ window = addr(top) }))
    d(hl.dsp.layout("splitratio 1.4 exact"))

    if prev and prev.address then
        d(hl.dsp.focus({ window = addr(prev.address) }))
    end
end
