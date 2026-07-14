# 07 — References & Prior Art

All protocol facts in `03-ble-protocol.md` trace to these public sources. Clean-room: documentation only, no
decompiled Sony code.

## Reverse-engineered protocol write-ups

- **gethypoxic.com** — "Sony Camera BLE Control Interface." Most complete public GATT service map (CC/DD/EE/FF),
  advertisement tag bitmaps.
- **gregleeds.com/reverse-engineering-sony-camera-bluetooth** — original BLE-sniff write-up; command table;
  "must focus before shutter" behavior.

## Code / repos

> ⚠️ **`Saschl/alpha-gps` caveat — read before trusting it.** It is a **new project with known problems, and it
> itself suffers from the standby battery-drain bug Alfa exists to fix.** Use it only as a *protocol* cross-reference
> for byte-level facts (and even then, corroborate each fact against `whc2001`, `freemote`, or `swremote` before
> relying on it). **Do not** copy its connection/reconnect lifecycle or treat its design as a battery template — that
> is precisely where the bug lives. Its `CC13` time-sync and `02 C3 00` sentinel are single-source and unverified.

| Repo | What it contributes |
|------|---------------------|
| `Saschl/alpha-gps` | Kotlin Multiplatform (Android + iOS interop). GATT constants, 91/95-byte GPS packet builder, shutter commands, subscribe-to-notify pairing trick, ATT 5/15 retry policy, `CC13`, `CC05`. **New & buggy — protocol cross-reference only, not a lifecycle template** (see warning above). |
| `whc2001/ILCE7M3ExternalGps` | `PROTOCOL_EN.md` — most granular byte-offset spec; definitive fw ≥3.02 / `DD30`/`DD31` gating (issue #3). |
| `Staacks/alpharemote` | Kotlin/Android BLE *remote*; ILCE-7RM5 confirmed working; issues #1/#4 document real BLE gotchas (Service Changed race, reconnect-on-power-cycle). |
| `mlapaglia/AlphaSync` | Android app targeting the A7RM5 specifically; GPS packet generator. |
| `anoulis/sony_camera_bluetooth_external_gps` | Python/`bleak` GPS reference; `CC05` power observation. |
| `coral/freemote` | nRF52840; most-cited command-code + `FF02` status-notification table. |
| `sonictruth/swremote` | Android; clean enumerated command/notification constants. |
| `missuo/Koko` | SwiftUI iOS 26 background geotagger using CoreBluetooth State Restoration + Live Activity; multi-brand `CameraDriver` architecture worth studying (Sony driver unvalidated). |
| `narumiruna/sony-geotag` | Python + SwiftUI, verified on A7C II; DD30/DD31/DD11 flow. |
| `wangrunji0408/SonyCameraKit` | Swift; BLE Wi-Fi-wake → PTP-IP; the BLE→Wi-Fi handoff path. |

## The two apps Alfa reimplements

- **Geotag Alpha** — https://geotagalpha.app/ (+ `/faq`, `/pairing`, `/changelog`, `/troubleshooting`, `/compatibility`).
  Best first-party documentation of the single-link-contention drain and its mitigations. Closed source.
- **Alpha Remote Controller** ("Remote Alpha") — https://www.belohradsky.cz/alpharemote/manual.html . Closed source,
  foreground-only, one-time paid.

## "Access Authentication" (Wi-Fi/SSH — NOT BLE)

- Sony help guide (ILCE-7RM5): TP1000954842 / TP1000954843 / TP0002920030 — `Network → Network Option → Access Authen.`
  Encrypts Wi-Fi/Ethernet remote-shooting & transfer (PC Remote / Imaging Edge / Camera Remote SDK). Absent from the
  Bluetooth menu.
- `goudvuur/sonshell` issue #2 — live proof it's the Wi-Fi/PTP-IP path (`CrError_Connect_FailRejected 0x820a`, fixed
  with `--user`/`--pass`; `[AUTH] ... ssh support is on`). Uses Sony's closed SDK. Unsolved by open source, and
  irrelevant to a BLE app.

## Apple / CoreBluetooth

- `CBCentralManager.connect(_:options:)` docs — "attempts to connect... don't time out."
- "Core Bluetooth Best Practices" — single shared link; "disconnect when you have all the data you need; scan only when
  you need to."
- WWDC 2013 #703, 2017 #712 — state restoration relaunch semantics.
- TN3115 (updated 2025-09-15, iOS 26) — background BLE relaunch rules; AccessorySetupKit direction.
- QA1931 — connection interval / latency / supervision-timeout ranges (peripheral-owned).

## Firmware (optional side-track)

- `BODYDATA.DAT` — Sony `.UFU` container (magic `89 55 46 55`), chunks `DATV`/`PROV`/`UDID`/`FDAT`; `FDAT` is
  block-cipher (ECB signature) encrypted. Community Sony-firmware decryption tooling exists (fwtool-style). Nothing in
  the app depends on decrypting this. **Never commit the blob.**

## Confidence caveats to re-verify on the A7R V

Zoom vs. focus opcodes (🔴), advertisement bit `0x40` paired-vs-pairing (🔴), `DD21` tz bit (🟡), `EE01` payload (🟡),
`CC13` applicability (🟡). See `03-ble-protocol.md`.
