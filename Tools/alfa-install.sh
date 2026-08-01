#!/bin/zsh
# Build a Release Alfa and install it on a connected iPhone.
#
# Usage: Tools/alfa-install.sh [udid] [-- extra xcodebuild args…]
#   Device pick order: [udid] arg → $ALFA_DEVICE_UDID → auto-detect (errors if not exactly one).
#   ALFA_CONFIG=Debug to sideload a debug build instead.
#   ALFA_RENEW_DAYS=N renew the signing profile when it has < N days left (default 3; 99 forces).
#
# Both xcodebuild -destination and devicectl accept the *hardware* UDID
# (00xxxxxx-xxxxxxxxxxxxxxxx), so one identifier drives the whole script — unlike
# `devicectl list devices`, whose Identifier column is a different (CoreDevice) UUID.
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

UDID="${1:-${ALFA_DEVICE_UDID:-}}"
[[ $# -gt 0 ]] && shift
[[ "${1:-}" == "--" ]] && shift

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
        print -r -- "  Tools/alfa-install.sh <udid>    (or set ALFA_DEVICE_UDID)" >&2
        [[ -n "$candidates" ]] && print -r -- "$candidates" >&2
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
    tail -40 "$LOG" >&2
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
