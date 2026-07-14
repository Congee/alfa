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
    │   │   ├── Advertisement.swift    # Sony manufacturer-data parser
    │   │   └── CameraPowerState.swift # CC05 power/standby parser (conservative, host-tested)
    │   ├── SonyBLE/          # CoreBluetooth engine. Depends on SonyProtocol.
    │   │   ├── CameraTypes.swift      # CameraConnectionState, CameraEvent, ConnectionPolicy, LocationFix (pure)
    │   │   ├── GeotagPolicy.swift     # PURE Balanced-policy reducer (host-tested, no CoreBluetooth)
    │   │   ├── SonyCBUUID.swift       # CBUUID values derived from the pure SonyGATT strings
    │   │   ├── BondedCameraStore.swift# persists the bonded camera identity (RememberedCamera: id+name, UserDefaults)
    │   │   ├── CameraLink.swift       # CoreBluetooth confinement — queue-confined @unchecked Sendable "hands"
    │   │   └── CameraCentral.swift    # actor "brain": policy state + link + republished event stream
    │   └── AlfaGeotag/       # CoreLocation + geotag orchestration. Depends on SonyBLE.
    │       ├── LocationProvider.swift # CoreLocation → Sendable LocationFix / authorization streams
    │       └── GeotagCoordinator.swift# @MainActor @Observable façade: pipes location in, mirrors events out
    └── Tests/
        ├── SonyProtocolTests/         # Swift Testing, pure, host-runnable
        └── SonyBLETests/              # Balanced-policy reducer invariants (host-runnable)
```

Why a package rather than app-only groups: the pure and BLE logic must be shareable with the future Watch app,
widgets, and App Intents extensions (D3) without duplication, and `swift test` on the package gives a fast, device-free
test loop.

## Dependency direction

`App` → `AlfaGeotag` → `SonyBLE` → `SonyProtocol`. Never the reverse. `SonyProtocol` depends on nothing but Foundation.

## Concurrency model

| Type | Isolation | Notes |
|------|-----------|-------|
| `SonyLocationPacket`, `SonyRemoteCommand`, `SonyAdvertisement`, `LocationFix` | `Sendable` value types | pure, immutable |
| `GeotagPolicyEngine` + `GeotagState` | pure `struct` reducer | the Balanced-policy decision logic; no I/O, host-unit-tested |
| `CameraCentral` | `actor` (the "brain") | owns `GeotagState` + a `CameraLink`; consumes `Sendable` `LinkEvent`s in order, runs the reducer, issues link commands, republishes `AsyncStream<CameraEvent>`. Touches no `CB*` object. |
| `CameraLink` | `final class`, `@unchecked Sendable` (the "hands") | owns `CBCentralManager`/`CBPeripheral`, confined to a private serial `DispatchQueue`; `CBCentralManagerDelegate`/`CBPeripheralDelegate` callbacks arrive on that queue. |
| `BondedCameraStore` / `UserDefaultsBondedCameraStore` | `Sendable` protocol / `@unchecked Sendable` struct | persists the bonded camera identity (`RememberedCamera`: id + name); `UserDefaults` is documented thread-safe (the written justification for `@unchecked`). Injected into `CameraCentral` for host-testability. |
| `LocationProvider` | `final class`, `@unchecked Sendable` | wraps `CLLocationManager` (main-confined); vends `Sendable` `LocationFix`/auth `AsyncStream`s. |
| `GeotagCoordinator` | `@MainActor`, `@Observable` façade | pipes location samples into `CameraCentral`, mirrors its events into observable UI state. |
| View models / UI | `@MainActor`, `@Observable` | subscribe to engine events; never touch CoreBluetooth directly. |

CoreBluetooth requires a consistent dispatch queue. Rather than give the actor a custom executor, the design **splits
brain from hands**: `CameraLink` confines every `CB*` object to one private serial queue (its public commands hop onto
it; every delegate callback arrives on it), and the `CameraCentral` actor never touches a `CB*` object at all. Only
`Sendable` values cross between them — `LinkEvent`s outbound (via a `@Sendable` closure into an `AsyncStream`), command
calls with `Sendable` arguments inbound. That confinement is the written justification for `CameraLink`'s and
`LocationProvider`'s `@unchecked Sendable`. `CBPeripheral`/`CBCentralManager` are **not** `Sendable` and never leave
their queue.

## Key runtime flows (Phase 1)

1. **Discover:** scan filtered by company ID `0x012D` (and/or the location service UUID once bonded). Prefer
   `retrieveConnectedPeripherals`/`retrievePeripherals(withIdentifiers:)` over rescanning; the last bonded camera's
   identity (id + name) is persisted (`BondedCameraStore`) and loaded on launch so a remembered camera is retrieved
   without a scan and shown in the UI while offline.
2. **Bond:** subscribe-to-notify pairing trick; handle ATT 5/15 retries.
3. **Capability probe:** read the GATT tree; detect `DD30`/`DD31` presence for the fw-gated handshake.
4. **Geotag session (Balanced policy):** while the camera is ON, keep the link and push location on movement / on
   half-press; sync time on connect. When the camera goes to standby, tear down and back off (see
   `05-battery-strategy.md`). Standby is detected **proactively** from the `CC05` power-state notification, falling back
   to the CoreBluetooth disconnect when `CC05` is absent — both feed the pure reducer's `cameraPoweredOff`/`disconnected`
   inputs, which never auto-reconnect.
5. **Background:** `bluetooth-central` + Location "Always"; opt into CoreBluetooth state restoration deliberately.

## Error handling

- Model BLE/GATT errors as typed Swift errors; surface actionable states to the UI (e.g. "enable Location Info Link on
  camera", "remote feature is off").
- Never crash on malformed advertisement or GATT data — parsers return optionals/throws, never force-unwrap external
  bytes.
