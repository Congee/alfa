# BLE integration-test harness

Exercises the **real** `CameraCentral`/`CameraLink` engine over a **real Bluetooth radio**, against a mock Sony camera
— no physical camera, no sudo, no Wi-Fi/SDK.

## Why two radios (a single Mac can't do it)

A lone Mac running both the mock peripheral *and* the central fails: one Bluetooth radio time-shares the central and
peripheral roles and does **not** surface its own advertisement back to its own scan (verified — a raw 30 s scan never
saw the local peripheral while seeing ~20 ambient devices). So the two roles run on **two radios**:

```
┌───────────────── Mac ─────────────────┐      real BLE      ┌────────────── iPhone/iPad ──────────────┐
│  AlfaCameraSim (CBPeripheralManager)   │  ~~~~~~~~~~~~~~~~~  │  real Alfa app: CameraCentral/CameraLink │
│  = mock Sony A7R V camera              │   (two radios)     │  = the real central, under xcodebuild    │
└────────────────────────────────────────┘                    └──────────────────────────────────────────┘
```

`CameraLink` can't be matched by manufacturer data (macOS `CBPeripheralManager` cannot advertise Sony's company ID), so
a **debug-only, env-gated** hook (`ALFA_TEST_ACCEPT_SIM=1`) makes discovery accept the sim's **location-service-UUID**
advertisement instead — and, when set, accept *only* the sim, so a real A7R V in the room can't win the race. The hook
is compiled out of release builds and inert unless the env var is set.

## Pieces

- **`AlfaCameraSim`** (`AlfaKit/Sources/AlfaCameraSim`) — mock A7R V peripheral. Serves the location service
  (`DD11`/`DD30`/`DD31`/`DD01`/`DD21`), camera-control service (`CC05`/`CC13`), and remote-control service (`FF02`
  notify), decodes and logs `DD11` writes, and drives autonomous scenarios via `ALFA_SIM_SCRIPT`:
  - `none` (default) — a plain long-running GATT mock (also takes stdin: `standby` / `wake` / `focus` / `status` /
    `quit`).
  - `standby` — sends a `CC05` power-off notification ~2 s after the first location write.
  - `focus` — sends an `FF02` focus-acquired notification (`02 3F 20`, then the release) ~2 s after the first
    location write, then a shutter-fired pair (`02 A0 20/00`) ~6 s after it — past the engine's 2 s capture throttle,
    so both triggers must each produce a push.

  In every mode the sim also serves a **writable `FF01`** and echoes incoming remote commands as the FF02 statuses a
  real body answers with (half-press → focus-ack; full-press → picture-being-taken → shutter-ready; record press →
  `02 D5` toggle) — Phase 2's capture sequencing is exercised write-driven, no script needed. Unknown opcodes (the
  zoom/MF probe candidates) are acked and logged but never echoed: the sim must not pretend to answer a question
  only the real camera can.
- **`Tests/AlfaIntegrationTests/BLEIntegrationTests.swift`** — on-device XCTest, hosted by the Alfa app (so it inherits
  the app's Bluetooth entitlement, usage strings, and existing permission grant). Drives the real `CameraCentral` and
  asserts. Skipped unless `ALFA_RUN_BLE_IT=1`.
- **`on-device-it.sh`** — one-command driver: builds the sim + test bundle, then runs each scenario with the sim in the
  matching mode and asserts the test passes.

## Running

```sh
Tools/ble-integration/on-device-it.sh          # builds, then runs all scenarios; prints PASS/FAIL
```

The device is the only connected iOS device, or `ALFA_DEVICE_UDID` when more than one is attached. To drive it by
hand, run the sim in one terminal (`swift run --package-path AlfaKit AlfaCameraSim`) and the on-device XCTest with
`test-without-building ... -only-testing:...` in another (see the script for the exact invocation and the
`.xctestrun` env injection).

## What these tests prove (verified on-device: iPad mini 6, A7R V engine)

| Scenario  | Sim mode  | Real-radio path asserted                                                        | Status |
|-----------|-----------|--------------------------------------------------------------------------------|--------|
| `connect` | `none`    | discover → bond (notify-subscribe) → fw handshake (DD30/DD31) → DD11 push       | ✅ PASS |
| `standby` | `standby` | `CC05` off notification → engine backs off (no standing connect, no reconnect)  | ✅ PASS |
| `focus`   | `focus`   | `FF02` focus-acquired *and* shutter-fired → immediate DD11 pushes while stationary | ✅ PASS |
| `capture` | `none`    | `shutterTapped()` → FF01 half → focus-ack → full → exposing → release-through → duration; record toggle via `02 D5` | ✅ PASS |

## Known limitation: a hard power-off (reconnect) can't be emulated from a macOS peripheral

A real camera power-off makes the peripheral's **radio vanish**, and the iPhone central then sees a genuine
`didDisconnectPeripheral` → auto-reconnect. From a macOS peripheral there is **no way to force that**:

- `CBPeripheralManager` has no API to disconnect a connected central.
- Releasing the manager, `removeAllServices`, or **exiting the sim process** does **not** drop the link — `bluetoothd`
  keeps the ACL alive at the system level (verified on-device: the iPad stayed `connected`, only receiving
  `didModifyServices`, seconds after the sim process exited).
- The only thing that drops the link is turning the Mac's Bluetooth **radio** off (`blueutil -p 0/1`), which is
  invasive (it drops every Bluetooth device on the Mac) and could not be built via nix on the dev machine.

So the **reconnect-on-power-on** path is intentionally **not** covered here. It is covered instead by:

1. The pure-reducer host tests (`AlfaKit/Tests/SonyBLETests`, run with `swift test`): a genuinely dropped `.connected`
   link re-arms discovery in foreground *and* background, while a `CC05` standby bail does not (the anti-churn
   invariant) — deterministic, no radio.
2. On-device logs from the **real** A7R V (`docs/08` IT-12): only the real camera can tell us whether it emits `CC05`
   off *before* the disconnect on a lever-off — which no simulator can answer, because the sim would just be replaying
   our own guess.
