# 03 — Sony Alpha BLE Protocol Reference

Reverse-engineered, cross-validated across `whc2001/ILCE7M3ExternalGps`,
`anoulis/sony_camera_bluetooth_external_gps`, `coral/freemote`, `sonictruth/swremote`, `mlapaglia/AlphaSync`,
`Saschl/alpha-gps`, and the write-ups at gethypoxic.com and gregleeds.com. See `07-references.md` for links.

> ⚠️ `Saschl/alpha-gps` is **new, buggy, and itself exhibits the standby battery drain we are fixing.** Trust its
> byte-level facts only where another repo corroborates them; never adopt its connection/reconnect lifecycle.

**Confidence legend:** ✅ high (multiple independent sources agree) · 🟡 medium (single-source or inferred) · 🔴 low
(sources disagree — must sniff the A7R V to confirm).

There is **no BLE encryption** to defeat. BLE is secured by standard pairing/bonding only. "Access Authentication" is a
Wi-Fi/SSH feature and never appears in the Bluetooth menu.

## GATT services ✅

Vendor services use the pattern `8000XX00-XX00-FFFF-FFFF-FFFFFFFFFFFF`.

| Service | 128-bit UUID | Purpose |
|---------|--------------|---------|
| Location / GPS | `8000DD00-DD00-FFFF-FFFF-FFFFFFFFFFFF` | Push GPS + date/time (Geotag Alpha path) |
| Remote Control | `8000FF00-FF00-FFFF-FFFF-FFFFFFFFFFFF` | Shutter / AF / zoom / record (Remote path) |
| Camera Control | `8000CC00-CC00-FFFF-FFFF-FFFFFFFFFFFF` | BLE→Wi-Fi handoff, FTP, some time-sync |
| Pairing | `8000EE00-EE00-FFFF-FFFF-FFFFFFFFFFFF` | App-layer pairing / power-off (most projects rely on OS bonding instead) |

Characteristics are **16-bit short IDs** under the standard Bluetooth base UUID, e.g. `DD11` ⇒
`0000DD11-0000-1000-8000-00805F9B34FB`. CCCD descriptor for notifications = `2902`.

## Location service `8000DD00` ✅

| Char | Role |
|------|------|
| `DD11` | **Write** the location+time packet here |
| `DD21` | **Read** config/flags (determines whether tz/dst fields are required) |
| `DD30` | fw ≥3.02 only: write `0x01` to **unlock/enable** the location endpoint |
| `DD31` | fw ≥3.02 only: write `0x01` to **enable** location updates |
| `DD01` | **Notify**: "location enabled in camera" flag |

### GPS + date/time packet (write to `DD11`) ✅

Big-endian throughout. **95 bytes** with timezone/DST, **91 bytes** without.

| Offset | Field | Encoding |
|--------|-------|----------|
| 0–1 | Payload length (excludes these 2 bytes) | `0x005D` (=93, with tz+dst) or `0x0059` (=89, without) |
| 2–4 | Fixed | `08 02 FC` |
| 5 | tz/dst-present flag | `0x03` = send tz+dst, `0x00` = omit |
| 6–10 | Fixed | `00 00 10 10 10` |
| 11–14 | Latitude | int32 BE, **degrees × 10⁷** |
| 15–18 | Longitude | int32 BE, **degrees × 10⁷** |
| 19–20 | UTC year | uint16 BE |
| 21 | UTC month | 1 byte |
| 22 | UTC day | 1 byte |
| 23 | UTC hour | 1 byte |
| 24 | UTC minute | 1 byte |
| 25 | UTC second | 1 byte |
| 26–90 | Zero padding | 65 × `0x00` |
| 91–92* | UTC→local offset (minutes) | int16 BE — only if flag `0x03` |
| 93–94* | DST offset (minutes) | int16 BE — only if flag `0x03` |

**Worked example:** latitude `20.077731°` → `20.077731 × 10⁷ = 200_777_310 = 0x0BF79E5E`. Offset UTC+8 → `480` min =
`0x01E0`. (Implemented and asserted in `AlfaKit/Tests/SonyProtocolTests/LocationPacketTests.swift`.)

`DD21` read: bit `0x02` of the relevant byte indicates the tz/dst variant is required. 🟡

### Firmware-gated handshake (fw ≥3.02 / advertised protocol version ≥ 65) ✅

Before writing coordinates: write `0x01` to `DD30`, then `0x01` to `DD31`. Write `0x00` before disconnecting. Older
firmware **lacks these characteristics entirely** — probe with "does this characteristic exist?" and skip each step if
absent. This is two extra **plaintext** writes, not cryptography. Apps unaware of it pair fine but silently fail to tag.

## Remote Control service `8000FF00`

| Char | Role |
|------|------|
| `FF01` | **Write** command bytes |
| `FF02` | **Notify** camera status |

### Command bytes (write to `FF01`) ✅

Each button is a **state pair**: a distinct press (down) and release (up), not a one-shot.

| Function | Down (press) | Up (release) |
|----------|--------------|--------------|
| Half-shutter / AF (S1) | `01 07` | `01 06` |
| Full shutter (S2) | `01 09` | `01 08` |
| AF-ON | `01 15` | `01 14` |
| C1 custom | `01 21` | `01 20` |
| Record | `01 0F` | `01 0E` (toggle; some sources send only `01 0E`) |

**Capture rule ✅:** a bare full-press is ignored ~2/3 of the time. Always: half-press → wait for focus-ack on `FF02` →
full-press → wait for shutter-active → release. Wrong ordering can lock the camera.

### Zoom / manual-focus step commands 🔴

3-byte writes `[0x02, opcode, step]` with opcodes in the `44/45/46/47` and `6A/6B/6C/6D` groups, step `0x10` or `0x20`.
**Sources disagree** on which group is zoom vs. focus and on the step byte. **Do not trust — sniff the A7R V in Phase 2.**

### Status notifications (`FF02`) ✅ (cross-referenced 2026-07-15)

All payloads are 3 bytes `[0x02, category, value]`. Corroboration re-verified across the OSS ecosystem (freemote,
alpha-gps, camera-gps-link, swremote, CameraSync docs):

| Bytes | Meaning | Agreement |
|-------|---------|-----------|
| `02 3F 00` | focus lost / ready | 4 projects **+ ✅ observed on A7R V fw 4.0 (2026-07-15)** |
| `02 3F 20` | focus acquired | **5 projects + ✅ observed on A7R V fw 4.0 (2026-07-15)** |
| `02 3F 40` | focus busy | 1 (swremote only) 🟡 |
| `02 A0 00` | shutter ready / back from picture | 5 projects **+ ✅ observed on A7R V fw 4.0 (2026-07-15)** |
| `02 A0 20` | picture being taken | 5 projects **+ ✅ observed on A7R V fw 4.0 (2026-07-15)** |
| `02 D5 00` | recording stopped | 4 projects |
| `02 D5 20` | recording started | 3 projects |
| `02 C3 00` | remote feature inactive on camera | 2 implementations + 1 doc |

**Implemented (Phase 1, listen-only):** `CameraLink` subscribes to `FF02`, and `02 3F 20` (focus acquired) **or**
`02 A0 20` (shutter fired) triggers an immediate fresh-position push — "update location on focus"
(`GeotagInput.captureActivity`, throttled). Both triggers are first-party-verified on the A7R V (device logs
2026-07-15, docs/08 IT-13): a photo taken with **back-button focus** and no AF activation emitted only
`02 A0 20` → `02 A0 00` (hence the shutter trigger — such a shot produces no `3F` event at all), and a genuine AF-ON
acquisition emitted `02 3F 20` → immediate acked push, with the shutter event 1.7 s later correctly swallowed by the
2 s capture throttle. Nothing is ever written to `FF01` in Phase 1; subscribing is safe
whatever the camera-side remote setting (off ⇒ silence or `02 C3 00`). DD (location) + FF (remote status)
demonstrably coexist on one link (alpha-gps and camera-gps-link both do it, and the same A7R V log shows DD11 writes
acked alongside FF02 notifies).

To detect the user enabling "Bluetooth Rmt Ctrl" at runtime, alpha-gps and camera-gps-link both send a harmless
half-shutter-release (`01 06`) as a probe (~3 s / 250 ms cadences) while the feature reads inactive — any `FF02`
payload other than `02 C3 00` means active. Alfa deliberately does not probe (listen-only). Remote-service protocol
errors return GATT status `0x0185`. 🟡

## Camera Control service `8000CC00` 🟡

| Char | Role |
|------|------|
| `CC01`/`CC02` | control notify / command |
| `CC05` | power/Wi-Fi state — alpha-gps: `04 00 00 00 00` when on, `04 00 00 02 04` when off |
| `CC06`/`CC07` | Wi-Fi SSID / password (BLE→Wi-Fi handoff) |
| `CC13` | time-sync packet on some newer bodies (13 bytes): `[12,0,0, yearHi,yearLo, month,day,hour,min,sec, dstFlag, signedOffsetHour, offsetMin]` (single-source, alpha-gps RE) |

Not required for Phase 1's core, but `CC05` power-state observation is useful for the "camera is on/off" signal that
drives the Balanced battery policy.

**Camera battery over BLE: 🔴 effectively unknown (surveyed 2026-07-15).** No working OSS project reads it — the
standard Battery Service `0x180F`/`0x2A19` appears nowhere across the ecosystem, and the sole lead is `CC10`
("Battery Information", Read+Notify, with a detailed byte layout) documented **only** in CameraSync's docs folder,
backed by zero code there and absent from the primary RE blogs it cites — treat as unverified and possibly
synthesized. Sony's own apps likely read battery over the Wi-Fi/PTP-IP handoff instead. **Probe armed (2026-07-15,
debug builds only):** every connect discovers `CC10` alongside `CC05`/`CC13` and, if present, subscribes + reads it,
logging presence/absence, properties, raw bytes, and read errors (`subsystem:me.congee.alfa`, lines prefixed
`CC10 battery probe:`). The next real-A7R V connect settles the question (`docs/08` IT-14); nothing is built on it
until it returns plausible data.

**`CC13` — implemented and ✅ verified on the A7R V (fw 4.0).** `SonyTimePacket` (`SonyProtocol/TimePacket.swift`)
encodes this layout and the BLE layer writes it best-effort on connect when the "Time Correction" setting is on and
the characteristic is present (clean no-op otherwise). **Confirmed** (`docs/08` IT-4, 2026-07-14): with a wrong camera
clock and the toggle on, the clock lands correct — so the interpretation is right: date/time fields are **local
wall-clock** and the offset fields are the **base** UTC offset (`total − dst`), with DST reported separately. (The
13-byte layout still traces to a single RE source for its *structure*; behaviour is now A7R V-confirmed. Time-zone
sync itself does not depend on CC13: it rides the DD11 tz/dst block, gated by the "Time Area Correction" setting —
the tz-change sub-test is IT-4 step 1, not yet run.)

## Pairing service `8000EE00` 🟡

`EE01`: write `06 08 01 00 00 00` to finalize app-level pairing after OS bonding; also carries a power-off command.
Most prior art skips this and relies on OS bonding. Confirm the payload length on the A7R V if used.

## Advertisement / device detection ✅ (bit meanings 🟡/🔴)

- Sony company ID = **`0x012D`** (301). On the wire, little-endian `2D 01`. CoreBluetooth's
  `CBAdvertisementDataManufacturerDataKey` includes this 2-byte prefix.
- Structure (example `2d01 0300 6400 4531 22eb00 214000`):

| Offset | Field | Notes |
|--------|-------|-------|
| 0–1 | `012D` Sony | LE on wire |
| 2–3 | device type (`0003` = camera) | |
| 4–5 | BLE protocol version | `0x64`=100; `0x41`=65 is the fw ≥3.02 gate |
| 6–7 | ASCII model code | e-mount = `"E1"` (`45 31`) |
| 8–10 | status tag `0x22` group | byte 9 = flags |
| 11–13 | status tag `0x21` group | byte 12 = flags |

- Tag `0x22` flag bits (gethypoxic): PairingSupported `0x80`, PairingEnabled/Paired `0x40`, LocationSupported `0x20`,
  LocationEnabled `0x10`, RemoteFunctionEnabled `0x02`. 🟡
- 🔴 **Ambiguity:** whc2001 reads bit `0x40` as "Paired/bonded"; gethypoxic/freemote read it as "PairingEnabled/
  discoverable now." These are different states.
- Note: alpha-gps / AlphaSync / swremote don't parse these bits at all — they filter only on company ID and let the OS
  handle bonding. That's the safe default for Phase 1.

### Tag `0x21` power/connectivity group ✅ (verified A7R V fw 4.0, 2026-07-14)

**This is Alfa's power on/off discriminator** (`docs/05` rule 8), since `CC05` is silent on this body and no GATT
characteristic signals power-off. Flag bits (gethypoxic + whc2001; used operationally by `ekutner/camera-gps-link`):
WirelessPowerOnEnabled `0x80` ("Cnct. while Power OFF"), **CameraOn `0x40`**, WifiHandoverSupported `0x20`,
WifiHandoverEnabled `0x10`.

Real A7R V captures ("Cnct. while Power OFF" enabled throughout, so `0x80` stays set; the model code reads `"U1"` here,
not `"E1"`). The status area is a run of **fixed 3-byte TLV groups from offset 8**, and the groups present/shift with
power state — so parse by **walking the groups**, not a fixed index:

| Lever | Manufacturer data | `0x21` flags | `CameraOn` (`0x40`) |
|-------|-------------------|--------------|---------------------|
| **On** | `2D01 030065 00 5531 22BA00 2396AC 21F000` | `0xF0` | **set** |
| **Off** | `2D01 030065 00 5531 21B002 23B7AC` | `0xB0` | **clear** |

Powered-on advertises a `0x22` group *before* `0x21`; powered-off drops the `0x22` group entirely and leads with
`0x21`. `SonyAdvertisement` decodes this (`isCameraOn`, `connectsWhilePoweredOff`) with host tests pinning both frames.
**Note:** iOS delivers `CBAdvertisementDataManufacturerDataKey` only to **foreground** scans — background scans can't
read these bits, which is why the reconnect gate is a foreground behaviour (`docs/05` rule 8).

## iOS pairing/bonding trick ✅

CoreBluetooth has no explicit `pair()`. To force the OS bonding dialog, **subscribe to a notify characteristic**; this
triggers bonding. Retry on ATT errors `5` (Insufficient Authentication) and `15` (Insufficient Encryption), up to ~3×
at ~3 s intervals; drop the gate subscription once bonded. (From alpha-gps `IosBleTransport`.)

## Things to verify on the A7R V before relying on them

1. 🔴 Zoom vs. manual-focus opcode groups and step byte.
2. 🔴 Advertisement tag `0x22` bit `0x40` (paired vs. pairing-enabled). *(Tag `0x21` power bits are ✅ verified — see
   "Tag `0x21` power/connectivity group" above.)*
3. 🟡 `DD21` tz/dst-required bit.
4. 🟡 `EE01` pairing payload (if used at all).
5. ✅ `CC13` time-sync on the A7R V — **verified** (fw 4.0, `docs/08` IT-4): the clock syncs correctly with the
   local-wall-clock interpretation.
