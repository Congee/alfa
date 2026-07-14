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

- [ ] `SonyBLE.CameraCentral` actor: scan (filtered by Sony company ID `0x012D`), discover, bond (via notify-subscribe
      pairing trick), retrieve already-connected peripherals, connect/disconnect lifecycle, event stream.
- [ ] Firmware-gated location handshake: probe for `DD30`/`DD31`, write `0x01` before location writes, `0x00` before
      disconnect (skip cleanly on older firmware).
- [ ] `AlfaGeotag.GeotagCoordinator`: CoreLocation significant-change + on-demand precise fixes; "Balanced" policy
      state machine (connected-while-on, backed-off-in-standby).
- [ ] Time + time-zone sync on connect.
- [ ] Background operation: `bluetooth-central` + Location "Always", CoreBluetooth state restoration.
- [ ] SwiftUI UI: camera list, per-camera status (connected/standby, last fix, update count, battery if reported),
      enable/disable, pairing flow, permissions onboarding.
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
