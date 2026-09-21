-- Arrange a workspace as: left = 2/3 column, right = top (70%) over bottom.
-- Called from comm-layout.py via `hyprctl dispatch`. Everything runs in one
-- synchronous call, so the focus hops it needs never reach the screen.
--
-- dwindle's preselect / splitratio act on the focused window only, hence the
-- hops; `splitratio <r> exact` is the absolute form ("exact <r>" is rejected).
return function(ws, monitor, left, top, bottom)
    local prev = hl.get_active_window()
    local tmp  = "special:comm-layout-tmp"
    local function addr(a) return "address:" .. a end
    local function d(x) hl.dispatch(x) end

    -- Focusing a window on a special workspace drags that workspace onto the
    -- *focused* monitor, so every hop below has to happen from its own monitor.
    -- (Otherwise, with the mouse on DP-1, it moved over and vanished from DP-2.)
    -- Focusing also pulls a hidden special workspace up; note whether it was up
    -- so it can be put away again afterwards.
    d(hl.dsp.workspace.move({ workspace = ws, monitor = monitor }))
    local shown = hl.get_active_special_workspace(monitor)
    local was_shown = shown ~= nil and shown.name == ws
    d(hl.dsp.focus({ monitor = monitor }))

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

    if not was_shown then
        local now = hl.get_active_special_workspace(monitor)
        if now and now.name == ws then
            d(hl.dsp.workspace.toggle_special(ws:sub(#"special:" + 1)))
        end
    end

    if prev and prev.address then
        d(hl.dsp.focus({ window = addr(prev.address) }))
    end
end
