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

**Phase 1** (battery-efficient GPS + time geotagging) and **Phase 2** (foreground remote control) are implemented and
run against a real A7R V (fw 4.0). This is not a released app: distribution is a personal sideload, and a number of
on-device validation items are still open — including the multi-hour battery-drain field test that is the project's
whole point. See [`docs/02-roadmap.md`](docs/02-roadmap.md) for what is verified versus owed.

| Area | State |
|------|-------|
| Sony BLE protocol model (`SonyProtocol`) | Location/time packet encoders, advertisement + remote-status parsers, `CC05`/`CC13` — pure, no CoreBluetooth, host-tested |
| BLE connection engine (`SonyBLE`) | `CameraCentral` actor + queue-confined `CameraLink`: bond, firmware-gated handshake, keep-alive, standby back-off, background state restoration |
| Geotag coordinator (`AlfaGeotag`) | CoreLocation → policy-gated `DD11` pushes, time/time-zone sync, push-on-focus |
| Remote control (Phase 2) | Pure capture-sequence reducer + gated `FF01` command path + Remote tab (shutter / AF-ON / REC) |
| iOS app (`App`) | Home / Remote / Settings / Help, plus the permissions + pairing onboarding flow |
| Tests | 101 host tests in 10 suites (pure, device-free) + a two-radio on-device integration harness |
| CI | Not set up yet |

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
- [`08-integration-testing.md`](docs/08-integration-testing.md) — the on-device test plan, log markers, and field results
- [`09-field-logging.md`](docs/09-field-logging.md) — design for the bounded on-device log ring *(planned)*

## Building

Requires **Xcode 26+** and **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**. The Xcode project is generated from
[`project.yml`](project.yml) and is not committed.

```sh
# Signing config — gitignored, so it never carries a personal Team ID into the repo
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then set DEVELOPMENT_TEAM

# Generate Alfa.xcodeproj (via Nix; or `brew install xcodegen`)
nix run nixpkgs#xcodegen

# Run the pure unit tests on the host — no device, no camera
cd AlfaKit && swift test

# Open and run on your device
open Alfa.xcodeproj
```

Distribution target is **personal sideload with a free Apple ID** (7-day re-sign); a free personal team is enough.
Change `PRODUCT_BUNDLE_IDENTIFIER` in [`project.yml`](project.yml) to something you own.
`Tools/alfa-install.sh [device-name]` does the Release build, install, and signing-expiry report in one step.

## Legal / ethics

Alfa talks to hardware **you own** using a publicly reverse-engineered, documented protocol. It uses no Sony
trademarks or code, ships no Sony firmware, and requires no firmware modification. Sony's "Access Authentication"
(a Wi-Fi/SSH feature) is **not** involved. This is interoperability work.

## License

[MIT](LICENSE).
