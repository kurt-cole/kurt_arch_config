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

-- checklist TUI lives on the todo special workspace (SUPER + R)
hl.window_rule({ match = { class = "checklist" }, workspace = "special:todo" })

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
hl.window_rule({
    match  = { class = "ap-launcher" },
    float  = true,
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
    size   = "(monitor_w*0.6) (monitor_h*0.6)",
    center = true,
})

-- Screensaver. The caelestia shell owns the idle timer (general.idle.timeouts
-- in shell.json calls screensaver.py start/stop); these binds are for trying it
-- on demand. SUPER + SHIFT + Z behaves exactly like the idle trigger and so
-- vanishes the moment you touch anything -- SUPER + SHIFT + ALT + Z is the one
-- to use for actually looking at a saver, since it ignores input and toggles
-- off on a second press (Escape or q close it too).
hl.bind("SUPER + SHIFT + Z", hl.dsp.exec_cmd(scripts .. "/screensaver.py start"))
hl.bind("SUPER + SHIFT + ALT + Z", hl.dsp.exec_cmd(scripts .. "/screensaver.py toggle --stay"))

-- The saver windows are fullscreened onto every monitor by the script itself,
-- so this rule only has to keep them from being animated or dimmed on the way.
hl.window_rule({
    match   = { class = "caelestia-screensaver" },
    no_anim = true,
    no_blur = true,
    opaque  = true,
})

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
