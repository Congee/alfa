# Alfa

**Battery-efficient Bluetooth control for Sony Alpha cameras, on iOS.** Open source, native Swift, no Wi-Fi required.

> `Alfa` is a working name. The project is a clean-room, open-source reimplementation of the ideas behind
> [Geotag Alpha](https://geotagalpha.app/) and [Alpha Remote Controller](https://www.belohradsky.cz/alpharemote/manual.html),
> built to solve the **standby battery-drain problem** that these apps (and Sony's own Creators' App) can cause when
> paired to a camera over Bluetooth Low Energy.

## Why this exists

When a Sony camera is BLE-paired to an iPhone and left in standby (powered off, with "Connect while Power OFF"
enabled), it can constantly connect and disconnect over Bluetooth, slowly draining the camera battery. Running
multiple remote/geotag apps at once makes it dramatically worse.

The root cause is **not** Sony encryption — it is how iOS CoreBluetooth `connect()` works (an indefinite standing
intent held by the system) combined with the camera's re-advertise/auto-drop standby loop and the single shared BLE
link a Sony camera allows. See [`docs/05-battery-strategy.md`](docs/05-battery-strategy.md) for the full analysis.
Alfa's core is a **"good BLE citizen" connection engine** designed to keep the camera asleep until there is real work
to do.

## Status

Early scaffold. **Phase 1** (battery-efficient GPS + time geotagging) is under construction. See
[`docs/02-roadmap.md`](docs/02-roadmap.md).

| Area | State |
|------|-------|
| Sony BLE protocol model (`SonyProtocol`) | GPS/time packet encoder implemented + unit-tested; command & advertisement models defined |
| BLE connection engine (`SonyBLE`) | Architecture defined, implementation stubbed |
| Geotag coordinator (`AlfaGeotag`) | Architecture defined, implementation stubbed |
| iOS app shell (`App`) | Boilerplate SwiftUI app |

## Documentation

All design and reverse-engineering knowledge lives in [`docs/`](docs/):

- [`00-overview.md`](docs/00-overview.md) — vision, scope, non-goals
- [`01-requirements.md`](docs/01-requirements.md) — locked product decisions
- [`02-roadmap.md`](docs/02-roadmap.md) — phased delivery plan
- [`03-ble-protocol.md`](docs/03-ble-protocol.md) — the reverse-engineered Sony BLE GATT reference
- [`04-architecture.md`](docs/04-architecture.md) — module layout, concurrency model
- [`05-battery-strategy.md`](docs/05-battery-strategy.md) — the drain root cause and Alfa's fix
- [`06-code-quality.md`](docs/06-code-quality.md) — standards and tooling
- [`07-references.md`](docs/07-references.md) — prior art and sources

## Building

Requires **Xcode 26+** and **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**. The Xcode project is generated from
[`project.yml`](project.yml) and is not committed.

```sh
# Generate Alfa.xcodeproj (via Nix; or `brew install xcodegen`)
nix run nixpkgs#xcodegen

# Run the pure protocol unit tests on the host (no device needed)
cd AlfaKit && swift test

# Open and run on your device
open Alfa.xcodeproj
```

Distribution target is **personal sideload with a free Apple ID** (7-day re-sign). Set your own
`DEVELOPMENT_TEAM` and a unique `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` before building to a device.

## Legal / ethics

Alfa talks to hardware **you own** using a publicly reverse-engineered, documented protocol. It uses no Sony
trademarks or code, ships no Sony firmware, and requires no firmware modification. Sony's "Access Authentication"
(a Wi-Fi/SSH feature) is **not** involved. This is interoperability work.

## License

[MIT](LICENSE). Set your name as the copyright holder before publishing.
