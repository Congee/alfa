# 01 — Requirements & Locked Decisions

These are settled product decisions. Change them only deliberately, and update this file when you do.

## Confirmed decisions (2026-07)

| # | Decision | Value | Rationale |
|---|----------|-------|-----------|
| D1 | **Phase 1 scope** | Battery-efficient **geotag core** (GPS + time push) | Directly targets the #1 pain (standby drain) and establishes the connection architecture everything else builds on. |
| D2 | **Distribution** | **Free Apple ID, personal sideload** | No paid Developer Program membership. App runs on the owner's own devices via Xcode free provisioning (7-day re-sign). Others build from source. Background BLE + Location "Always" still work with free provisioning. |
| D3 | **Platform surface (now)** | **iPhone only** | Apple Watch, widgets, App Intents, iPad are deferred — but the architecture keeps the core in a shared Swift package so they can be added without a rewrite. |
| D4 | **Battery policy** | **Balanced** | Stay connected while the camera is ON for fresh per-shot geotags; **fully back off in standby** (no standing connect, no aggressive reconnect). See `05-battery-strategy.md`. |
| D5 | **Language / concurrency** | Swift 6, strict concurrency `complete` | Compile-time data-race safety across all CoreBluetooth/CoreLocation delegate boundaries. |
| D6 | **Dependencies** | Zero / minimal third-party | Only Apple frameworks for the core. Dev-only tooling (SwiftLint/SwiftFormat) is allowed. |
| D7 | **License** | MIT | Publish on GitHub. Copyright holder name still to be set. |
| D8 | **Project name** | `Alfa` (provisional) | Name is crowded on GitHub; may be renamed before public release (candidates: AlphaLink, TetherAlpha, SonyLeash). |

## Open questions (revisit before the relevant phase)

- **OQ1 — Name.** Finalize before first public release / GitHub remote.
- **OQ2 — Minimum iOS version.** Currently **iOS 18.0** (gives Observation, Swift 6 concurrency, modern CoreBluetooth
  auto-reconnect, AccessorySetupKit, latest App Intents). Lower only if a target device needs it.
- **OQ3 — AccessorySetupKit vs. classic CoreBluetooth pairing.** ASK (iOS 18+) is Apple's power/privacy-friendly
  direction for accessories; classic `CBCentralManager` + bonding is what all prior art uses. Decide in Phase 1 after
  on-device testing. See `05-battery-strategy.md`.
- **OQ4 — Multi-camera.** Owner has one A7R V. Geotag Alpha gates multi-camera behind a paid tier. Design the model to
  support N cameras, but Phase 1 UI can assume one.

## Success criteria for Phase 1

1. With Alfa as the **only** BLE app running, a standby camera does **not** exhibit constant connect/disconnect churn
   attributable to Alfa. (Measure with camera battery over a fixed standby window and/or a BLE sniffer.)
2. When the camera is powered on and moving, photos are geotagged with a location fresh to within the configured
   threshold.
3. Time (and time zone where supported) is synced on connect.
4. Works on the A7R V (fw 4.0) with "Access Authen." either ON or OFF (it is irrelevant to BLE).
5. Survives app backgrounding, screen lock, and (ideally) app termination via CoreBluetooth state restoration.
