#!/bin/zsh
# End-to-end on-device BLE integration test driver.
#
# Two-radio setup: AlfaCameraSim (mock Sony camera) runs on THIS Mac; the real Alfa app / CameraCentral runs on the
# paired iPhone/iPad under `xcodebuild test`. No physical camera, no sudo. A single Mac cannot do this (its central
# won't discover its own peripheral's advertisement) — two radios are required. See README.md.
#
# For each scenario it starts AlfaCameraSim in the matching ALFA_SIM_SCRIPT mode and runs the on-device XCTest that
# asserts the corresponding real-radio path:
#
#   connect  -> testConnectsHandshakesAndPushesLocation  (sim: none)     discover / bond / handshake / DD11 push
#   standby  -> testBacksOffOnCameraStandby              (sim: standby)  CC05 off -> engine backs off (no churn)
#   focus    -> testFocusTriggersImmediatePush           (sim: focus)    FF02 focus-acquired -> immediate DD11 push
#
# Usage:  Tools/ble-integration/on-device-it.sh
# Env:    ALFA_DEVICE_UDID (default the paired iPad), ALFA_SIM_EXPIRY_SECONDS.
set -uo pipefail
ROOT="/Users/cwu/dev/Alfa"
DEVICE="${ALFA_DEVICE_UDID:-00008110-00043032360A801E}"
DD="$ROOT/.build/xcode-it"                    # gitignored (.build/) — predictable xctestrun path
SIMBIN="$ROOT/AlfaKit/.build/debug/AlfaCameraSim"
export ALFA_SIM_EXPIRY_SECONDS="${ALFA_SIM_EXPIRY_SECONDS:-300}"

cleanup() { pkill -f 'AlfaCameraSim' 2>/dev/null || true; }
trap cleanup EXIT

echo "== building sim (host) =="
swift build --package-path "$ROOT/AlfaKit" || { echo "sim build FAILED"; exit 1; }

echo "== building on-device test bundle =="
xcodebuild build-for-testing -scheme Alfa -project "$ROOT/Alfa.xcodeproj" \
  -destination "platform=iOS,id=$DEVICE" -allowProvisioningUpdates -derivedDataPath "$DD" \
  > "$DD.build.log" 2>&1 || { echo "build-for-testing FAILED (see $DD.build.log)"; exit 1; }

XCTESTRUN=$(ls "$DD"/Build/Products/*.xctestrun 2>/dev/null | head -1)
[[ -n "$XCTESTRUN" ]] || { echo "no .xctestrun under $DD/Build/Products"; exit 1; }

# Inject the opt-in + accept-sim env into the test process (ALFA_RUN_BLE_IT flips the XCTSkipUnless guards off;
# ALFA_TEST_ACCEPT_SIM lets CameraLink accept the sim's location-service advertisement in place of a real camera).
for kv in ALFA_RUN_BLE_IT ALFA_TEST_ACCEPT_SIM; do
  /usr/libexec/PlistBuddy -c "Add :AlfaIntegrationTests:EnvironmentVariables:$kv string 1" "$XCTESTRUN" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :AlfaIntegrationTests:EnvironmentVariables:$kv 1" "$XCTESTRUN"
done

run_scenario() {  # <sim-mode> <test-method>
  local mode="$1" test="$2"
  echo "== scenario: $test  (sim mode: $mode) =="
  cleanup
  ALFA_SIM_SCRIPT="$mode" "$SIMBIN" > "$DD.sim.$mode.log" 2>&1 &
  sleep 2   # let the sim reach poweredOn + advertise before the device scans
  xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "platform=iOS,id=$DEVICE" \
    -only-testing:"AlfaIntegrationTests/BLEIntegrationTests/$test" 2>&1 \
    | grep -E '\[IT\]|Test Case|passed|failed|TEST EXECUTE'
  local rc=${pipestatus[1]}   # NB: not `status` — that's a read-only zsh special ($?)
  cleanup
  return $rc
}

fail=0
run_scenario none    testConnectsHandshakesAndPushesLocation || fail=1
run_scenario standby testBacksOffOnCameraStandby             || fail=1
run_scenario focus   testFocusTriggersImmediatePush          || fail=1
run_scenario none    testShutterTapRunsCaptureSequence       || fail=1
echo "==========================================="
[[ $fail -eq 0 ]] && echo "ALL ON-DEVICE INTEGRATION TESTS PASSED" || echo "SOME ON-DEVICE INTEGRATION TESTS FAILED"
exit $fail
