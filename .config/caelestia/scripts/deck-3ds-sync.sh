#!/usr/bin/env bash
# Ask the Steam Deck to run its 3DS save sync (~/.local/bin/3ds-save-sync on the
# Deck, which does the merge and rsyncs back to this PC through a key locked to
# rrsync on ~/.local/share/azahar-emu/sdmc). Called by the Azahar launchers
# before and after a PC session so the Deck and PC hand saves back and forth.
#
# A sleeping or absent Deck is normal: the connect times out quickly and the
# launch goes ahead. Conflicts are never resolved from here (--no-prompt); they
# are left for the Deck to ask about on its next launch, and flagged with a
# notification.
set -uo pipefail
DECK="deck@100.90.178.35"   # barret-deck's Tailscale IP
LOG="${XDG_CACHE_HOME:-$HOME/.cache}/deck-3ds-sync.log"

out=$(timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=4 \
      -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "$DECK" \
      '~/.local/bin/3ds-save-sync sync --when=pc --no-prompt' 2>&1)
rc=$?
{ echo "--- $(date '+%F %T') ${1:-manual} rc=$rc"; echo "$out"; } >> "$LOG"
case $rc in
    0)   ;;
    3)   notify-send -a "3DS saves" "Save conflict with the Deck" \
             "Both sides changed. Launch the game on the Deck to choose which to keep." ;;
    255|124) ;;  # Deck asleep / unreachable
    *)   notify-send -a "3DS saves" "Deck sync failed" "See $LOG" ;;
esac
exit 0
