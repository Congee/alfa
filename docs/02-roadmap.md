# 02 — Roadmap

Gradual delivery. Each phase should end in a buildable, testable, dogfoodable state. Do not start a phase before the
previous phase's success criteria are met on real hardware.

## Phase 0 — Scaffold (current)

- [x] Repo, MIT license, `.gitignore`, docs structure.
- [x] XcodeGen `project.yml`, SwiftUI app boilerplate, `AlfaKit` Swift package with three targets.
- [x] `SonyProtocol`: GPS/time packet encoder (implemented + unit-tested), GATT map, command & advertisement models.
- [ ] CI: GitHub Actions running `swift test` (host) + `xcodebuild build` (simulator). *(deferred to Phase 1)*

## Phase 1 — Battery-efficient geotagging (active)

The core of the project. Deliver GPS + time sync **and** the "good BLE citizen" connection engine.

- [x] Pure `GeotagPolicyEngine` reducer encoding the Balanced policy + anti-churn invariants; host-unit-tested
      (`SonyBLETests`: disconnect/connect-fail/standby-location never issue a new connect or scan).
- [x] `SonyBLE.CameraCentral` actor + `CameraLink`: scan (company-ID `0x012D` filter in `didDiscover`), discover, bond
      (notify-subscribe trick with ATT 5/15 retries), `retrieveConnectedPeripherals`, bounded-scan connect/disconnect
      lifecycle, `Sendable` event stream. *(implemented + builds; pending A7R V validation)*
- [x] Firmware-gated location handshake: probe for `DD30`/`DD31`, write `0x01` before location writes, `0x00` before
      disconnect (skips cleanly when the characteristics are absent).
- [x] `AlfaGeotag.GeotagCoordinator` + `LocationProvider`: CoreLocation updates (distance-filtered); "Balanced" policy
      state machine (connected-while-on, backed-off-in-standby) driven by the pure reducer.
- [x] Time + time-zone sync on connect (rides the location packet's UTC + tz/dst block).
- [x] Persist the bonded peripheral UUID across launches (`BondedCameraStore`, `UserDefaults`-backed): saved on a
      successful bond (`ready`), loaded at `start()` so discovery uses `retrievePeripherals(withIdentifiers:)` before
      scanning; a "Forget camera" action clears it.
- [x] Observe `CC05` power-state (Camera Control service `8000CC00`) to feed the policy's `cameraPoweredOff` input:
      conservative pure parser (`CameraPowerState`, host-tested), subscribed + read on connect, best-effort (falls back
      to disconnect-inferred standby when the characteristic is absent).
- [~] Background operation: `bluetooth-central` + Location "Always" background modes wired; `CBCentralManager` restore
      identifier + `willRestoreState` handled; bonded UUID persisted/retrieved. *TODO: full background-relaunch /
      state-restoration flow (re-drive the policy from `willRestoreState`).*
- [~] SwiftUI UI: status (connection, auth, fixes pushed, last fix, errors), enable/disable, "Sync now", "Forget
      camera". *TODO: camera list / multi-camera, pairing flow, permissions onboarding, camera battery if reported.*
- [ ] On-device validation on A7R V fw 4.0, including the standby-drain success criterion.

## Phase 2 — Remote control (foreground)

Mirror Alpha Remote Controller's core over the Remote Control service (`8000FF00`).

- [ ] `SonyBLE` remote command path: shutter (half → full → release), AF-ON, C1, record; `FF02` status notifications.
- [ ] Reliable capture sequence (half-press → focus-ack → full-press → release).
- [ ] **Sniff/verify** the low-confidence zoom vs. manual-focus opcodes on the A7R V (see `03-ble-protocol.md`).
- [ ] Remote UI (foreground), signal strength, camera state indicators.

## Phase 3 — Advanced capture

- [ ] Bulb / long-exposure timing.
- [ ] Intervalometer / timelapse.
- [ ] Exposure bracketing sequences.
- [ ] Focus stacking (timed focus-step holds).
- [ ] Self-timer.

## Phase 4 — Platform surfaces

- [ ] Apple Watch app (wrist remote + signal).
- [ ] Widgets / Lock Screen / Control Center / Action Button.
- [ ] Siri Shortcuts / App Intents automation.
- [ ] iPad layout.

## Phase 5 — Polish & release

- [ ] Multi-camera UX.
- [ ] Localization.
- [ ] Finalize name (OQ1), copyright holder, GitHub release, screenshots, docs site.

## Optional research side-track (not on the critical path)

- [ ] Firmware decryption of `BODYDATA.DAT` (encrypted `.UFU`/`FDAT` container, block-cipher/ECB signature) for
      protocol *authenticity* only. Nothing in the shipping app depends on this.
