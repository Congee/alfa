#!/bin/zsh
# Snapshot the last few minutes of a device's unified log, filtered to Alfa's subsystem markers
# (me.congee.alfa) — the primary observability channel for background/relaunch flows where no
# debugger can attach (docs/08 "Observability").
#
# Usage: Tools/alfa-logs.sh [minutes] [udid]     (minutes defaults to 3)
#   Device pick order: [udid] arg → $ALFA_DEVICE_UDID → auto-detect (errors if not exactly one).
#
# `log collect --device-udid` takes the device's *hardware* UDID (00xxxxxx-xxxxxxxxxxxxxxxx, as
# listed by `xcrun xctrace list devices`) — NOT the CoreDevice UUID that `devicectl` uses.
# Collection needs sudo (it may prompt).
set -euo pipefail

MINS="${1:-3}"
UDID="${2:-${ALFA_DEVICE_UDID:-}}"

if [[ -z "$UDID" ]]; then
    candidates=$(xcrun xctrace list devices 2>/dev/null \
        | sed -n '/^== Devices ==/,/^== /p' \
        | grep -E '\(00[0-9A-F]{6}-[0-9A-F]{16}\)$' || true)
    count=$(print -r -- "$candidates" | grep -c . || true)
    if (( count == 1 )); then
        UDID=$(print -r -- "$candidates" | grep -oE '00[0-9A-F]{6}-[0-9A-F]{16}')
        print -r -- "Device: $candidates"
    else
        print -r -- "Expected exactly one connected iOS device, found $count — pass a UDID:" >&2
        print -r -- "  Tools/alfa-logs.sh [minutes] <udid>    (or set ALFA_DEVICE_UDID)" >&2
        [[ -n "$candidates" ]] && print -r -- "$candidates" >&2
        exit 1
    fi
fi

OUT="${TMPDIR:-/tmp}/alfa.logarchive"
rm -rf "$OUT"
echo "Collecting last ${MINS}m from $UDID (sudo may prompt)…"
sudo /usr/bin/log collect --device-udid "$UDID" --last "${MINS}m" --output "$OUT"
echo "===== Alfa markers (subsystem me.congee.alfa) — archive kept at $OUT ====="
/usr/bin/log show "$OUT" --predicate 'subsystem == "me.congee.alfa"' --info --style compact
