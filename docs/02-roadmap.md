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
- [x] Persist the bonded camera identity (id + name) across launches (`BondedCameraStore`/`RememberedCamera`,
      `UserDefaults`-backed): saved on a successful bond (`ready`), loaded at `start()` so discovery uses
      `retrievePeripherals(withIdentifiers:)` before scanning, and shown in the UI on a cold launch (as Alpha Remote
      does). "Forget camera" disconnects + clears it.
- [x] Observe `CC05` power-state (Camera Control service `8000CC00`) to feed the policy's `cameraPoweredOff` input:
      conservative pure parser (`CameraPowerState`, host-tested), subscribed + read on connect, best-effort (falls back
      to disconnect-inferred standby when the characteristic is absent).
- [x] Background operation + state restoration: `bluetooth-central` + Location "Always" background modes wired;
      `CBCentralManager` created with a restore identifier; an `AppDelegate` (`didFinishLaunchingWithOptions`)
      re-creates the central on launch so iOS delivers `willRestoreState` on a background relaunch. The restored link
      is resumed **only if it survived** (re-discover services → re-subscribe → re-run handshake → continue); a
      restored **still-pending** standing connect is **kept in place** while background resume is on (cancelling it
      races the camera's power-on — the camera's next lever-on completes it), and cancelled + backed off when
      background resume is off; a restored-but-**dropped** link re-arms the standing connect rather than blindly
      re-issuing one (anti-churn, `docs/05` rule 1). The enabled/disabled state is persisted so a
      relaunch resumes non-interactively (no permission prompts). *Mechanics validated on-device per
      `08-integration-testing.md`.*
- [x] Keep-alive + reconnect: a 45 s keep-alive (single source of truth `ConnectionPolicy.keepAliveSeconds`, safely
      below the camera's ~60 s fix-expiry tolerance) re-pushes the last position while connected so the camera
      never expires its fix (`docs/05`; the camera signals expiry over no BLE characteristic, so it is prevented via a
      write-timeline-driven timer that adds no redundant writes while moving); and a genuinely dropped link is
      re-established automatically **in the foreground *and* background** (standing `connect()` serviced on the
      camera's next power-on, relaunching via state restoration if suspended). A CC05 standby bail never re-arms (no
      wake-magnet loop). A camera that answers the connect **without serving the Sony GATT** — connectable-while-off,
      or inside its power-on **boot window** before the GATT exists — is held in a **dormant standby** (no writes,
      60 s probe, 15 s discovery-stall watchdog), recovering to ready via the bonded **Service Changed** indication
      and the ack-gated handshake. *The connect/handshake/push and CC05-standby-bail paths are covered by a two-radio
      on-device integration harness (`Tools/ble-integration/`: mock camera on the Mac, real central on the device under
      `xcodebuild test`) — both PASS. Power-cycle reconnect (a link-drop a macOS peripheral can't emulate) and fix-expiry
      stay covered by the pure-reducer host tests + on-device logs (`08` IT-11/IT-12).*
- [x] SwiftUI UI: tab shell (Home / Settings / Help); pairing + permissions onboarding flow (Bluetooth →
      Location When-in-use→Always → camera-prep checklist → pair → done); status (connection, camera indicator,
      Bluetooth + location access, fixes pushed, last fix, errors); enable/disable, "Sync now", "Forget camera"
      (confirmation dialog). *TODO: multi-camera list, camera battery if reported.* *2026-07-15: app-wide design
      pass — α-orange accent, silkscreen label voice, Home's camera-chrome status plate (`App/Theme.swift` shares
      the Remote tab's palette; utility screens stay adaptive).*
- [x] Settings + time sync: customisable update distance + interval (persisted, `GeotagSettings`); Time Correction
      (CC13 clock write — ✅ A7R V-verified, IT-4) + Time Area Correction (tz/dst block) toggles; in-app Help/Troubleshooting +
      compatibility. *(feature parity with Geotag Alpha's Phase-1 geotag surface; multi-camera
      remains deferred — see D3/OQ4.)*
- [x] Geotag Alpha parity sweep (2026-07-15, from the GA site + changelog):
      **Update on focus** — `CameraLink` subscribes to the `FF02` remote-status feed (listen-only; `FF01` commands
      stay Phase 2) and a focus acquisition (`02 3F 20`, 5-project corroboration) pushes the freshest position
      immediately, as does a fired shutter (`02 A0 20`, ✅ first-party — a back-button-focus shot emits no focus
      event at all), bypassing the distance/interval gates behind a 2 s throttle (`GeotagInput.captureActivity`,
      host-tested; sim scenario `focus` in the two-radio harness). Requires the camera's Bluetooth remote-control
      setting. **✅ IT-13 field-verified 2026-07-15**: real AF-ON → `02 3F 20` → acked push in 65 ms; the shot 1.7 s
      later correctly throttled.
      **Use GPS time** — optional CC13 clock source from the GNSS fix's timestamp (fresh-fix-gated, deferred write).
      **Connection diagnostics** — persisted reconnect counts (background tallied separately) + time connected, on
      Home.
      **Map view** — Home shows the last position actually acknowledged by the camera (the ack event now carries the
      fix; coordinator exposes it as a plain coordinate) on a MapKit map, cleared on forget. *Camera battery display
      unblocked 2026-07-15: the debug `CC10` probe hit the real body — the characteristic **exists** (Read+Notify,
      19-byte payload, byte 13 = 100 on a full charge). UI waits on the decode being pinned at other charge levels
      (`docs/08` IT-14 part 2).*
- [~] On-device validation on A7R V fw 4.0 (`08-integration-testing.md`): **IT-2 pair ✅**, **IT-4 CC13 clock ✅
      verified** (local-wall-clock interpretation correct — no UTC flip needed), **IT-12b background power-cycle
      reconnect ✅ field-verified (2026-07-15)** — lever off → on with the app backgrounded re-links and resumes
      geotagging with no user action. *Remaining: the standby-drain success criterion (IT-10, Rig B/iPhone — now
      unblocked, the iPhone is paired), IT-12a foreground run, IT-5 CC05 standby, IT-7 state restoration, IT-4 tz
      sub-test, and a multi-hour background keep-alive soak.*

## Phase 2 — Remote control (foreground)

Mirror Alpha Remote Controller's core over the Remote Control service (`8000FF00`).

- [x] `SonyBLE` remote command path (2026-07-15): `CameraLink` discovers + writes `FF01` behind the same
      ack-gated-handshake gate as location writes; typed `LinkEvent`s for FF02/CC05; command acks/failures surfaced.
- [x] Reliable capture sequence: pure `RemoteControlEngine` (sibling of the geotag reducer, 19 host tests) owns
      half → focus-ack/timeout → full → shutter-active → release-through, generation-tagged timeouts,
      `02 C3 00`/write-failure/disconnect aborts; **structurally connection-free** (its action type cannot express
      a connect). Verified end-to-end over the radio (harness `capture` scenario). Focus-ack timeout *escalates*
      (MF-lens support — the camera's release priority stays the authority); record is tap-only (wire toggle).
- [~] **Sniff/verify** the low-confidence zoom vs. manual-focus opcodes on the A7R V: DEBUG probe panel shipped
      (fires the disputed `[02 group step]` candidates through the gated FF01 path; results in the device log) —
      the live verification pass is owed (`docs/08` IT-15).
- [x] Remote UI (foreground): Remote tab as a camera-body control surface — α-ring shutter (tap = auto sequence /
      hold = half; two-stage S1/S2 zones, bulb-capable), AF-ON/C1 press-hold-lock, REC toggle, state banner
      (Ready/Focusing/Exposing/Recording), EXP/REC elapsed + estimated long-exposure-NR countdown, RSSI signal bars
      (polled only while the tab is visible). *Real-camera pass owed: `docs/08` IT-15 (incl. `02 D5` record codes,
      not yet A7R V-verified).*

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
- [ ] Localization. *(Geotag Alpha shipped German/French/Japanese in its v1.7 — a release-polish parity item, not
      part of the Phase-1 geotag feature surface.)*
- [ ] Finalize name (OQ1), copyright holder, GitHub release, screenshots, docs site.

## Optional research side-track (not on the critical path)

- [ ] Firmware decryption of `BODYDATA.DAT` (encrypted `.UFU`/`FDAT` container, block-cipher/ECB signature) for
      protocol *authenticity* only. Nothing in the shipping app depends on this.
