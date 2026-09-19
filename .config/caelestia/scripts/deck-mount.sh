#!/usr/bin/env bash
# Mount the Steam Deck's home at ~/Deck over sshfs, on demand.
#
#   deck-mount.sh open    mount if needed, then open it in the file manager
#   deck-mount.sh stop    unmount
#   deck-mount.sh status
#
# Deliberately NOT a permanent/automount: the Deck sleeps constantly, and a
# network mount whose host vanishes hangs anything that statfs's it --
# caelestia's shell does that to every mount, which is exactly how the zimaos
# CIFS automount hung hibernate. So the mount runs as a transient user unit
# (deck-mount.service) with a watchdog that lazy-unmounts it as soon as the
# Deck stops answering, and sshfs runs without `reconnect` so a dead link
# fails fast (ENOTCONN) instead of blocking. The PC's own system-sleep hook
# (/usr/lib/systemd/system-sleep/deck-mount) unmounts it before sleeping.
set -uo pipefail
DECK_IP=100.90.178.35       # barret-deck on Tailscale
MNT="$HOME/Deck"
UNIT=deck-mount

mounted() { mountpoint -q "$MNT"; }
reachable() { timeout 3 bash -c "</dev/tcp/$DECK_IP/22" 2>/dev/null; }

case "${1:-open}" in
run)    # the unit's body
    mkdir -p "$MNT"
    sshfs -f "deck@$DECK_IP:/home/deck" "$MNT" \
        -o BatchMode=yes,ConnectTimeout=5,ServerAliveInterval=5,ServerAliveCountMax=2 \
        -o idmap=user,follow_symlinks,dir_cache=yes &
    SSHFS=$!
    trap 'kill $SSHFS 2>/dev/null; fusermount3 -uz "$MNT" 2>/dev/null; exit 0' TERM INT
    while sleep 10; do
        kill -0 $SSHFS 2>/dev/null || break
        reachable || break
    done
    kill $SSHFS 2>/dev/null
    fusermount3 -uz "$MNT" 2>/dev/null
    ;;
open)
    if ! mounted; then
        if ! reachable; then
            notify-send -a "Steam Deck" "Deck not reachable" "Is it awake and on Tailscale?"
            exit 1
        fi
        systemctl --user stop "$UNIT" 2>/dev/null
        systemd-run --user --quiet --collect --unit="$UNIT" "$0" run
        for _ in $(seq 1 40); do mounted && break; sleep 0.25; done
        mounted || { notify-send -a "Steam Deck" "Mount failed" "journalctl --user -u $UNIT"; exit 1; }
    fi
    [ -n "${NO_OPEN:-}" ] || xdg-open "$MNT" >/dev/null 2>&1 &
    ;;
stop)
    systemctl --user stop "$UNIT" 2>/dev/null
    mounted && fusermount3 -uz "$MNT"
    ;;
status)
    mounted && echo "mounted at $MNT" || echo "not mounted"
    ;;
*)  echo "usage: $0 open|stop|status" >&2; exit 2 ;;
esac
