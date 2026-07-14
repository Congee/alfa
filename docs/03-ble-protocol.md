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

### Status notifications (`FF02`) 🟡

| Bytes | Meaning |
|-------|---------|
| `02 3F 00` | focus lost / ready |
| `02 3F 20` | focus acquired |
| `02 3F 40` | focus busy (single-source) |
| `02 A0 00` | shutter ready / back from picture |
| `02 A0 20` | picture being taken |
| `02 D5 00` | recording stopped |
| `02 D5 20` | recording started |
| `02 C3 00` | remote feature inactive on camera (single-source) |

To detect the user enabling "Bluetooth Rmt Ctrl" at runtime, alpha-gps sends a harmless half-shutter-release (`01 06`)
every ~3 s while the feature reads inactive. Remote-service protocol errors return GATT status `0x0185`. 🟡

## Camera Control service `8000CC00` 🟡

| Char | Role |
|------|------|
| `CC01`/`CC02` | control notify / command |
| `CC05` | power/Wi-Fi state — alpha-gps: `04 00 00 00 00` when on, `04 00 00 02 04` when off |
| `CC06`/`CC07` | Wi-Fi SSID / password (BLE→Wi-Fi handoff) |
| `CC13` | time-sync packet on some newer bodies (13 bytes): `[12,0,0, yearHi,yearLo, month,day,hour,min,sec, dstFlag, signedOffsetHour, offsetMin]` (single-source, alpha-gps RE) |

Not required for Phase 1's core, but `CC05` power-state observation is useful for the "camera is on/off" signal that
drives the Balanced battery policy.

**`CC13` — implemented (beta, 🟡).** `SonyTimePacket` (`SonyProtocol/TimePacket.swift`) encodes this layout and the
BLE layer writes it best-effort on connect when the "Time Correction" setting is on and the characteristic is present
(clean no-op otherwise). **Unverified assumption:** the date/time fields are treated as **local wall-clock** and the
offset fields as the **base** UTC offset (`total − dst`), with DST reported separately. If on-device testing shows the
camera expects UTC-based fields, switch the derivation in `SonyTimePacket.init(date:timeZone:)` to a UTC calendar —
an isolated change. (Time-zone sync itself does not depend on CC13: it rides the DD11 tz/dst block, gated by the
"Time Area Correction" setting.)

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
  discoverable now." These are different states. If Alfa uses adverts to distinguish *standby-reconnect* from *active-
  pairing* (relevant to battery logic), **capture the A7R V's adverts in both states and confirm.**
- Note: alpha-gps / AlphaSync / swremote don't parse these bits at all — they filter only on company ID and let the OS
  handle bonding. That's the safe default for Phase 1.

## iOS pairing/bonding trick ✅

CoreBluetooth has no explicit `pair()`. To force the OS bonding dialog, **subscribe to a notify characteristic**; this
triggers bonding. Retry on ATT errors `5` (Insufficient Authentication) and `15` (Insufficient Encryption), up to ~3×
at ~3 s intervals; drop the gate subscription once bonded. (From alpha-gps `IosBleTransport`.)

## Things to verify on the A7R V before relying on them

1. 🔴 Zoom vs. manual-focus opcode groups and step byte.
2. 🔴 Advertisement tag `0x22` bit `0x40` (paired vs. pairing-enabled).
3. 🟡 `DD21` tz/dst-required bit.
4. 🟡 `EE01` pairing payload (if used at all).
5. 🟡 `CC13` time-sync applicability on the A7R V (vs. the location-packet's embedded time).
