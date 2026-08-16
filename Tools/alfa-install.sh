#!/bin/zsh
# Build a Release Alfa and install it on a connected iPhone.
#
# Usage: Tools/alfa-install.sh [name|udid] [-- extra xcodebuild args…]
#   Device pick order: [name|udid] arg → $ALFA_DEVICE → $ALFA_DEVICE_UDID → the only iOS device
#   (errors if not exactly one). A device name is resolved to its UDID, so `ALFA_DEVICE=Monad`
#   in your shell profile is enough to make this a no-argument command. USB or Wi-Fi both work;
#   the script never requires a particular transport.
#   ALFA_CONFIG=Debug to sideload a debug build instead.
#   ALFA_RENEW_DAYS=N renew the signing profile when it has < N days left (default 3; 99 forces).
#
# Both xcodebuild -destination and devicectl accept the *hardware* UDID
# (00xxxxxx-xxxxxxxxxxxxxxxx), so one identifier drives the whole script — unlike
# `devicectl list devices`, whose default Identifier column is a different (CoreDevice)
# UUID — hence the explicit --columns udid below.
# Signing is Automatic against Config/Local.xcconfig's DEVELOPMENT_TEAM; -allowProvisioningUpdates
# lets Xcode mint/refresh the profile without opening the IDE.
#
# Free (personal team) profiles carry TimeToLive=7, and the app stops launching once the embedded
# one expires. Xcode reuses a cached profile until it actually expires rather than topping up its
# TTL, so renewing means deleting the cache entry — automatic signing then mints a fresh 7-day
# profile on the next build. Renewal needs a live Apple ID session in Xcode; if it has lapsed
# (2FA), xcodebuild fails and Xcode must be opened once by hand.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${ALFA_CONFIG:-Release}"
DERIVED="${TMPDIR:-/tmp}/alfa-install-dd"
BUNDLE_ID="me.congee.alfa"
RENEW_DAYS="${ALFA_RENEW_DAYS:-3}"
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
# Pre-Xcode 16 cache location; still honoured if present.
LEGACY_PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"

UDID_RE='^00[0-9A-Fa-f]{6}-[0-9A-Fa-f]{16}$'
DEVICE_JSON="${TMPDIR:-/tmp}/alfa-devices.json"
PAIRED_IOS="hardwareProperties.platform == 'iOS' AND connectionProperties.pairingState == 'paired'"
# Transport is never a requirement here — USB or Wi-Fi, whatever CoreDevice can reach is fine.
# It is only ever used to break a tie when several devices are paired, and even then a null
# reading falls back rather than failing: transportType reads null for a merely-remembered
# device, but also transiently between connections. Matching 'wired' would be plain wrong —
# devicectl reports 'localNetwork' for a cabled phone.
REACHABLE="connectionProperties.transportType != nil"

# devicectl exits 0 when nothing matches, and Apple documents --json-output as the only
# supported interface for scripts — so matches get counted out of the JSON, not the table.
device_udids() {
    xcrun devicectl list devices --filter "$1" --json-output "$DEVICE_JSON" >/dev/null 2>&1 || true
    grep -oE '"udid" *: *"00[0-9A-Fa-f]{6}-[0-9A-Fa-f]{16}"' "$DEVICE_JSON" 2>/dev/null \
        | grep -oE '00[0-9A-Fa-f]{6}-[0-9A-Fa-f]{16}' || true
}

# Human-readable listing for error messages only.
device_table() {
    xcrun devicectl list devices --hide-default-columns --hide-headers \
        --columns name --columns udid --filter "$1" 2>/dev/null | grep -E '[^[:space:]]' || true
}

SELECTOR="${1:-${ALFA_DEVICE:-${ALFA_DEVICE_UDID:-}}}"
[[ $# -gt 0 ]] && shift
[[ "${1:-}" == "--" ]] && shift

if [[ "$SELECTOR" =~ $UDID_RE ]]; then
    UDID="$SELECTOR"
elif [[ -n "$SELECTOR" ]]; then
    # A name is already unambiguous, so no transport condition at all; an unreachable device is
    # caught later, at the build, where it gets its own message.
    # Predicate literal is double-quoted so names with apostrophes work ("Changsheng's iPad");
    # any double quote in the name is escaped for the same reason.
    filter="$PAIRED_IOS AND deviceProperties.name == \"${SELECTOR//\"/\\\"}\""
    matches=(${(f)"$(device_udids "$filter")"}); matches=(${matches:#})
    if (( ${#matches} == 1 )); then
        UDID="${matches[1]}"
        print -r -- "Device: $SELECTOR ($UDID)"
    else
        print -r -- "Expected one paired iOS device named \"$SELECTOR\", found ${#matches}." >&2
        print -r -- "Paired devices:" >&2
        print -r -- "$(device_table "$PAIRED_IOS")" >&2
        exit 1
    fi
else
    # No name given, so a tie has to be broken somehow: prefer devices reporting a transport,
    # but fall back to every paired device rather than refusing on a null reading.
    matches=(${(f)"$(device_udids "$PAIRED_IOS AND $REACHABLE")"}); matches=(${matches:#})
    (( ${#matches} )) || { matches=(${(f)"$(device_udids "$PAIRED_IOS")"}); matches=(${matches:#}) }
    if (( ${#matches} == 1 )); then
        UDID="${matches[1]}"
        print -r -- "Device: $(device_table "hardwareProperties.udid == '$UDID'")"
    else
        print -r -- "Expected exactly one iOS device, found ${#matches} — name the one you want:" >&2
        print -r -- "  Tools/alfa-install.sh <name|udid>    (or set ALFA_DEVICE)" >&2
        print -r -- "$(device_table "$PAIRED_IOS")" >&2
        exit 1
    fi
fi

if [[ ! -f Config/Local.xcconfig ]]; then
    print -r -- "Config/Local.xcconfig missing — copy Config/Local.xcconfig.example and set DEVELOPMENT_TEAM." >&2
    exit 1
fi

# Drop any Xcode-managed profile for this bundle ID that is within RENEW_DAYS of expiry, so the
# build below mints a replacement. Only ever touches IsXcodeManaged profiles — a hand-installed
# enterprise/ad-hoc profile is left alone.
renew_profiles() {
    local dir="$1" f appid expires epoch now days
    [[ -d "$dir" ]] || return 0
    now=$(date +%s)
    for f in "$dir"/*.mobileprovision(N); do
        local plist
        plist=$(security cms -D -i "$f" 2>/dev/null) || continue
        [[ "$(print -r -- "$plist" | plutil -extract IsXcodeManaged raw -o - - 2>/dev/null)" == "true" ]] || continue
        appid=$(print -r -- "$plist" | plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null) || continue
        [[ "$appid" == *".$BUNDLE_ID" ]] || continue

        expires=$(print -r -- "$plist" | plutil -extract ExpirationDate raw -o - - 2>/dev/null) || continue
        epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$expires" +%s 2>/dev/null) || continue
        days=$(( (epoch - now) / 86400 ))

        if (( days < RENEW_DAYS )); then
            echo "Signing profile expires in ${days}d (${expires}) — renewing."
            rm -f "$f"
        else
            echo "Signing profile valid for ${days}d (${expires})."
        fi
    done
}

renew_profiles "$PROFILE_DIR"
renew_profiles "$LEGACY_PROFILE_DIR"

APP="$DERIVED/Build/Products/$CONFIG-iphoneos/Alfa.app"
LOG="${TMPDIR:-/tmp}/alfa-install.log"

echo "Building $CONFIG for $UDID…"
if ! xcodebuild \
    -project Alfa.xcodeproj \
    -scheme Alfa \
    -configuration "$CONFIG" \
    -destination "id=$UDID" \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    "$@" \
    build >"$LOG" 2>&1
then
    # The one failure a human has to clear: renewal needs a live Apple ID session, and 2FA
    # cannot be scripted. Say so plainly instead of burying it in 40 lines of log.
    if grep -q 'error: No Accounts' "$LOG"; then
        print -r -- "Xcode has no signed-in Apple ID, so automatic signing cannot mint a profile." >&2
        print -r -- "Open Xcode ▸ Settings ▸ Accounts, sign in, then re-run this script." >&2
    elif grep -q 'Unable to find a destination matching' "$LOG"; then
        print -r -- "$UDID is paired but not reachable — plug it in or put it on the same Wi-Fi." >&2
    else
        tail -40 "$LOG" >&2
    fi
    print -r -- "Build failed — full log: $LOG" >&2
    exit 1
fi

echo "Installing $APP…"
xcrun devicectl device install app --device "$UDID" "$APP"

embedded=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
    | plutil -extract ExpirationDate raw -o - - 2>/dev/null) || embedded=""
[[ -n "$embedded" ]] && echo "Installed — signing valid until $embedded."
echo "Launch with:"
echo "  xcrun devicectl device process launch --device $UDID $BUNDLE_ID"
