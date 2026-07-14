# 04 — Architecture

## Principles

- **Separation of pure logic from I/O.** All byte-level protocol logic is pure, `Sendable`, and unit-tested on the host
  with no CoreBluetooth. I/O (BLE, CoreLocation) lives in thin, well-audited layers.
- **Concurrency by construction.** Swift 6 strict concurrency (`complete`). Mutable BLE/coordination state lives inside
  `actor`s. Cross-boundary values are `Sendable`. No locks, no `@unchecked Sendable` without written justification.
- **Events over shared mutable delegates.** The BLE engine exposes an `AsyncStream` of `Sendable` events; UI observes
  via the Observation framework. CoreBluetooth's callback delegate is confined to the engine actor's executor.
- **Testability first.** If it can be a pure function over bytes, it is.

## Module layout

```
Alfa/
├── App/                      # iOS app target (SwiftUI). Thin. No protocol logic.
│   ├── AlfaApp.swift
│   ├── ContentView.swift
│   └── Assets.xcassets
└── AlfaKit/                  # Swift package — all reusable logic (also feeds future Watch/widget targets)
    ├── Sources/
    │   ├── SonyProtocol/     # PURE. Foundation only. No CoreBluetooth/CoreLocation. Fully unit-tested.
    │   │   ├── GATT.swift             # service/characteristic UUID strings, company ID
    │   │   ├── LocationPacket.swift   # GPS+time encoder (95/91-byte), tz/dst
    │   │   ├── RemoteCommand.swift    # button press/release codes, FF02 status parsing
    │   │   └── Advertisement.swift    # Sony manufacturer-data parser
    │   ├── SonyBLE/          # CoreBluetooth engine. Depends on SonyProtocol.
    │   │   └── CameraCentral.swift    # actor: scan/bond/connect/write lifecycle + event stream (Phase 1 impl)
    │   └── AlfaGeotag/       # CoreLocation + geotag orchestration. Depends on SonyBLE.
    │       └── GeotagCoordinator.swift# Balanced-policy state machine (Phase 1 impl)
    └── Tests/
        └── SonyProtocolTests/         # Swift Testing, pure, host-runnable
```

Why a package rather than app-only groups: the pure and BLE logic must be shareable with the future Watch app,
widgets, and App Intents extensions (D3) without duplication, and `swift test` on the package gives a fast, device-free
test loop.

## Dependency direction

`App` → `AlfaGeotag` → `SonyBLE` → `SonyProtocol`. Never the reverse. `SonyProtocol` depends on nothing but Foundation.

## Concurrency model

| Type | Isolation | Notes |
|------|-----------|-------|
| `SonyLocationPacket`, `SonyRemoteCommand`, `SonyAdvertisement` | `Sendable` value types | pure, immutable |
| `CameraCentral` | `actor` | owns `CBCentralManager`; the `CBCentralManagerDelegate`/`CBPeripheralDelegate` callbacks hop onto the actor. Emits `AsyncStream<CameraEvent>` (events are `Sendable`). |
| `GeotagCoordinator` | `actor` (or `@MainActor` observable façade over an actor) | owns the Balanced-policy state machine and `CLLocationManager`. |
| View models / UI | `@MainActor`, `@Observable` | subscribe to engine events; never touch CoreBluetooth directly. |

CoreBluetooth requires a consistent dispatch queue; the engine actor provides a serial executor / dedicated queue and
keeps all `CB*` objects confined to it. `CBPeripheral`/`CBCentralManager` are **not** `Sendable`, so they never cross
the actor boundary — only extracted `Sendable` snapshots do.

## Key runtime flows (Phase 1)

1. **Discover:** scan filtered by company ID `0x012D` (and/or the location service UUID once bonded). Prefer
   `retrieveConnectedPeripherals`/`retrievePeripherals(withIdentifiers:)` over rescanning.
2. **Bond:** subscribe-to-notify pairing trick; handle ATT 5/15 retries.
3. **Capability probe:** read the GATT tree; detect `DD30`/`DD31` presence for the fw-gated handshake.
4. **Geotag session (Balanced policy):** while the camera is ON, keep the link and push location on movement / on
   half-press; sync time on connect. When the camera goes to standby, tear down and back off (see
   `05-battery-strategy.md`).
5. **Background:** `bluetooth-central` + Location "Always"; opt into CoreBluetooth state restoration deliberately.

## Error handling

- Model BLE/GATT errors as typed Swift errors; surface actionable states to the UI (e.g. "enable Location Info Link on
  camera", "remote feature is off").
- Never crash on malformed advertisement or GATT data — parsers return optionals/throws, never force-unwrap external
  bytes.
