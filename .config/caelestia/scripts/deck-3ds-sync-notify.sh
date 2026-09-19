#!/usr/bin/env bash
# Desktop notification for a 3DS save sync done by the Steam Deck. The Deck's
# 3ds-save-sync rsyncs one JSON file per event ({"id", "lines"}) into
# .deck-3ds-sync/events/ in Azahar's sdmc here -- its key can only write inside
# that directory, and can't overwrite a file, hence one file each.
# deck-3ds-sync-notify.path runs this while the directory is non-empty; each
# event is shown once and deleted.
set -uo pipefail
DIR="$HOME/.local/share/azahar-emu/sdmc/.deck-3ds-sync/events"
shopt -s nullglob
for ev in "$DIR"/*.json; do
    python3 - "$ev" <<'PY'
import json, subprocess, sys
try:
    e = json.load(open(sys.argv[1]))
except ValueError:
    sys.exit(0)
subprocess.run(["notify-send", "-a", "3DS saves", "-i", "input-gaming",
                "3DS saves synced with the Deck", "\n".join(e["lines"])])
PY
    rm -f "$ev"
done
