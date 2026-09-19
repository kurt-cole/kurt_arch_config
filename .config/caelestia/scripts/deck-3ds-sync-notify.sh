#!/usr/bin/env bash
# Desktop notification for a 3DS save sync done by the Steam Deck. The Deck's
# 3ds-save-sync rsyncs a one-line JSON event ({"id", "lines"}) into the root of
# Azahar's sdmc here -- its key can only write inside that directory -- and
# deck-3ds-sync-notify.path runs this whenever the file changes.
set -uo pipefail
EV="$HOME/.local/share/azahar-emu/sdmc/.deck-3ds-sync-event"
SEEN="${XDG_CACHE_HOME:-$HOME/.cache}/deck-3ds-sync-last-event"
[ -s "$EV" ] || exit 0
python3 - "$EV" "$SEEN" <<'PY'
import json, subprocess, sys
from pathlib import Path
ev, seen = Path(sys.argv[1]), Path(sys.argv[2])
try:
    e = json.loads(ev.read_text())
except ValueError:
    sys.exit(0)
if seen.exists() and seen.read_text() == e["id"]:
    sys.exit(0)
seen.write_text(e["id"])
subprocess.run(["notify-send", "-a", "3DS saves", "-i", "input-gaming",
                "3DS saves synced with the Deck", "\n".join(e["lines"])])
PY
