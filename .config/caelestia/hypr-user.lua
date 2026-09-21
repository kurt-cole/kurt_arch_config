local fn = require("utils.functions")
hl.bind("SUPER + G", fn.toggle("audio"))
hl.bind("SUPER + S", fn.toggle("steam"))

-- Mouse side buttons -> discord mute (CTRL+SHIFT+M) and deafen (CTRL+SHIFT+D).
--
-- The buttons are labelled F13/F14 but emit keycodes 191/192, which this layout
-- names XF86Tools and XF86Launch5. Hyprland resolves *bind* keys against the
-- keymap, so hl.bind("F13", ...) registers without complaint and then never
-- matches a press -- bind the keysym. ("code:NNN" is rejected as a bind key by
-- this lua API, though send_shortcut does accept it as a `key`.)
--
-- Same keymap trap on the send side: send_shortcut's `key` is looked up in the
-- keymap too, so "F13" there fails with "key not found". Plain letters are fine.
--
-- Why the built-in shortcuts rather than discord's own keybinds: discord's
-- custom keybind capture is X11-only and completely dead under native Wayland
-- (its Record Keybind captures nothing, not even `a`). CTRL+SHIFT+M/D are
-- handled by the renderer instead, so they survive. send_shortcut reaches
-- discord even while it is unfocused or parked on a hidden special workspace.
for key, shortcut in pairs({ XF86Tools = "M", XF86Launch5 = "D" }) do
    hl.bind(key, hl.dsp.send_shortcut({ mods = "CTRL SHIFT", key = shortcut, window = "class:^(discord)$" }),
        { locked = true })
end

-- Both Acer B277U E panels do 48-100Hz (EDID range limits), but "preferred"
-- in caelestia's default monitor conf picks the 59.95Hz DTD.
hl.monitor({ output = "DP-1", mode = "2560x1440@100", position = "0x0",    scale = 1 })
hl.monitor({ output = "DP-2", mode = "2560x1440@100", position = "2560x0", scale = 1 })

-- checklist TUI lives on the todo special workspace (SUPER + R)
hl.window_rule({ match = { class = "checklist" }, workspace = "special:todo" })

-- The Deck's headless output (azahar-deck.sh / deck-controller.sh) must not take
-- a numbered workspace. A new output grabs the first free id, so it stole 4, and
-- SUPER + 4/5 then focused the parked, invisible screen. The scripts also claim
-- name:deck right after creating it, in case the output gets another number.
hl.workspace_rule({ workspace = "name:deck", monitor = "HEADLESS-1", default = true })

-- 2/3 + 1/3 column splits. Focus-independent: the bind names which side gets
-- the 1/3, whatever window happens to live there.
local split = os.getenv("HOME") .. "/.config/caelestia/scripts/hypr-split.py"
hl.bind("SUPER + H", hl.dsp.exec_cmd(split .. " 0.3333")) -- 1/3 left, 2/3 right
hl.bind("SUPER + L", hl.dsp.exec_cmd(split .. " 0.6667")) -- 2/3 left, 1/3 right

-- A 1/3 column, sized to match what the tiled windows get: the caelestia bar
-- reserves 60px on the left and 10px on the other edges, and every window sits
-- inside gaps_out + border = 11px. So the two 11px inner gaps + 22px of outer
-- padding come off the width (104 total with the reserved edges), and 42px off
-- the height.
local col_size  = "((monitor_w-104)/3) (monitor_h-42)"
local col_left  = "71 21"
local col_right = "(monitor_w-21-(monitor_w-104)/3) 21" -- window_w isn't resolved yet at rule time

-- Audio mixer: left 1/3. This overrides caelestia's centred 60%x70% rule, which
-- matches by tag -- and hyprland applies tag-matched rules after class-matched
-- ones no matter what order they were declared in, so this has to match the tag
-- as well to get the last word.
hl.window_rule({
    match = { tag = "float_60_70", class = "org.pulseaudio.pavucontrol" },
    float = true,
    size  = col_size,
    move  = col_left,
})

-- Keybind cheatsheet: right 1/3, on its own special workspace (SUPER + `)
hl.window_rule({
    match     = { class = "cheatsheet" },
    workspace = "special:cheatsheet",
    float     = true,
    size      = col_size,
    move      = col_right,
})
hl.bind("SUPER + grave", fn.toggle("cheatsheet"))

-- Claude Code in the scratchwork project
hl.bind("SUPER + apostrophe", hl.dsp.exec_cmd(
    "foot -a claude -T claude fish -C 'cd ~/Projects/claude-scratchwork; exec claude'"))

-- Archipelago quick launcher (SUPER + ;): a floating 60% centred TUI listing
-- the games flipped on in ~/.config/Archipelago/launcher.toml. Deliberately not
-- a special workspace -- it floats over the current one so whatever it launches
-- lands on the workspace underneath, and it closes itself on launch. The key
-- toggles: pressing it again closes the window instead of stacking a second one.
local scripts = os.getenv("HOME") .. "/.config/caelestia/scripts"
-- Pinned because a plain float on a special workspace is drawn *behind* that
-- workspace's tiled windows whenever the other monitor also has a special
-- workspace up (hyprland 0.56 bug: steam up on DP-1 buried the TUI under
-- discord on DP-2). Pinned windows are drawn above special workspaces. Side
-- effect: a pinned window follows keyboard focus to the other monitor.
hl.window_rule({
    match  = { class = "ap-launcher" },
    float  = true,
    pin    = true,
    size   = "(monitor_w*0.6) (monitor_h*0.6)",
    center = true,
})
hl.bind("SUPER + semicolon", hl.dsp.exec_cmd(
    scripts .. "/tui-toggle.sh ap-launcher,ap-config " ..
    "foot -a ap-launcher -T Archipelago " .. scripts .. "/ap-launcher.py"))

-- The config editor it spawns -- SUPER + ; closes this too, by asking nvim to
-- quit so an unsaved buffer still gets its save prompt. (The debug terminal,
-- class ap-debug, is left alone on purpose: it tiles like any other terminal.)
hl.window_rule({
    match  = { class = "ap-config" },
    float  = true,
    size   = "(monitor_w*0.6) (monitor_h*0.7)",
    center = true,
})

-- Minimize, the only way wayland allows it: park the window on a special
-- workspace named after the one it came from (special:purg-<ws>) and never give
-- that workspace a toggle. SUPER + SHIFT + N is the way back -- a picker listing
-- what this workspace has hidden, which sends the pick home again.
hl.bind("SUPER + N", hl.dsp.exec_cmd(scripts .. "/purgatory.py hide"))
hl.bind("SUPER + SHIFT + N", hl.dsp.exec_cmd(
    scripts .. "/tui-toggle.sh purgatory " ..
    "foot -a purgatory -T Hidden " .. scripts .. "/purgatory.py"))
hl.window_rule({
    match  = { class = "purgatory" },
    float  = true,
    pin    = true,   -- same special-workspace draw-order bug as ap-launcher
    size   = "(monitor_w*0.6) (monitor_h*0.6)",
    center = true,
})

-- ...and the way *out* when something else opens it. misc.lua sets
-- focus_on_activate = true, so an xdg-activation request (opening a PNG while
-- the browser is hidden, a chat notification, a "reuse existing window" launch)
-- focuses the hidden window -- and hyprland shows a focused window by pulling
-- its workspace up. Purgatory then lands on screen with no toggle bound to it,
-- and no way to dismiss it: SUPER + SHIFT + N cannot help either, because the
-- picker scopes itself to the *current* workspace, which is now the purgatory,
-- so it lists nothing.
--
-- An activation request means "look at this window", so treat it as the restore
-- it already is: send the window home and follow it there. Anything still
-- hidden stays hidden, and the purgatory is dismissed if it clung on.
local PURG = "^special:purg%-"

hl.on("window.active", function(win)
    win = win or hl.get_active_window()
    if not win or not win.address then return end

    local ws = win.workspace and win.workspace.name or ""
    if not ws:match(PURG) then return end

    local name = ws:sub(#"special:purg-" + 1)
    local home = name:match("^sp_(.+)$")
    home = home and ("special:" .. home) or name

    -- Dismiss before moving, not after: the activated window is focused, so the
    -- monitor showing the purgatory is the focused one and toggle_special (which
    -- only ever acts on the focused monitor) reaches it. Do it the other way
    -- round and follow = true can carry focus to the *other* monitor -- if home
    -- is itself a special workspace living there -- stranding an empty purgatory
    -- on screen, which is the unrecoverable state this whole hook exists to
    -- prevent.
    local special = hl.get_active_special_workspace()
    if special and special.name == ws then
        hl.dispatch(hl.dsp.workspace.toggle_special(ws:sub(#"special:" + 1)))
    end

    hl.dispatch(hl.dsp.window.move({
        window = "address:" .. win.address, workspace = home, follow = true,
    }))

    -- Belt and braces: if a purgatory is still up anywhere, focus that monitor
    -- to dismiss it and hand focus back to the window we just restored.
    for _, monitor in ipairs(hl.get_monitors() or {}) do
        local shown = monitor.active_special_workspace and monitor.active_special_workspace.name
        if shown == ws then
            hl.dispatch(hl.dsp.focus({ monitor = monitor.name }))
            hl.dispatch(hl.dsp.workspace.toggle_special(ws:sub(#"special:" + 1)))
            hl.dispatch(hl.dsp.focus({ window = "address:" .. win.address }))
        end
    end
end)

-- Never warp the cursor. Hyprland otherwise yanks the pointer into whatever
-- window gains focus, which is jarring on its own and is what makes a Steam
-- notification snap the mouse to the centre of the window underneath it: the
-- XWayland toast takes focus (caelestia sets misc:focus_on_activate), then
-- focus returns and the pointer is dragged along.
hl.config({
    cursor = {
        no_warps = true,
    },
})

-- XWayland popup menus escaping a special workspace.
--
-- Steam's menus ("+ Add a game", the library right-click menus) are X11
-- override-redirect windows (_NET_WM_WINDOW_TYPE_POPUP_MENU), and hyprland
-- handles those on a short-circuit path that never runs window rules -- so no
-- hl.window_rule can touch them. Worse, they *do* map onto the right special
-- workspace and are reassigned to the monitor's regular workspace a moment
-- afterwards, so even this hook sees the correct workspace and there is nothing
-- to fix yet. The menu then sits invisible behind the pulled-up group and dies
-- unnoticed when steam loses focus. Steam's managed windows (Friends List,
-- Settings) are unaffected, which is what makes the failure look random.
--
-- Hence the deferred helper: it watches the new window for two seconds and puts
-- it back whenever it drifts off. Moving one keeps its geometry, and it renders
-- and clicks normally afterwards.
--
-- The "same class already on the pulled-up special workspace" test is
-- deliberately narrow: with no group up (a steam notification toast, say)
-- nothing matches and the window is left exactly where hyprland put it.
hl.on("window.open", function(win)
    if not win or not win.xwayland then return end

    local special = hl.get_active_special_workspace()
    if not special then return end

    for _, other in ipairs(hl.get_windows() or {}) do
        if other.address ~= win.address and other.class == win.class
            and other.workspace and other.workspace.id == special.id then
            hl.dispatch(hl.dsp.exec_cmd(
                scripts .. "/popup-keeper.py " .. win.address .. " " .. special.name))
            return
        end
    end
end)
