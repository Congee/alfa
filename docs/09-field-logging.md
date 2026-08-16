# 09 — Field logging & export

**Status: planned, not started.** Blocked on build capacity (2026-08-16). Nothing in this document is implemented.

Written for a specific job: a **multi-day outdoor shoot** whose logs come back here for review. That trial is the
cheapest way to close most of what still holds Phase 1 open — **IT-10** (battery drain, the release-blocking
north-star), IT-9 (GPS accuracy), IT-3, IT-12a, and the multi-hour keep-alive soak — plus the only realistic way to
exercise the finding-13 stale-link rebuild (`docs/review-2026-08-16.md`).

The problem is that the app currently has no way to produce field data that survives the trip.

## Why the unified log is not enough

Today the only observability channel is `os.Logger` — 39 `.notice` call sites under subsystem `me.congee.alfa`,
categories `ble` and `coordinator` (`docs/08` "Observability"). `.notice` reaches the *persistent* store, so it
survives backgrounding, relaunch and reboot. What it does not survive is **eviction**.

The iOS log store is bounded by size, not time. Days of outdoor use — GPS, BLE, the camera app — is the high-volume
case, and Alfa is itself a heavy contributor: at the 46 s keep-alive, `location push` + `location write acked` is
roughly **3,800 notice-level lines per day** from Alfa alone. Day 1 can be gone before the device is next plugged in.

Two further frictions, both field-relevant:

- `log collect --device-udid` needs **USB** (localNetwork fails with "Device not configured (6)") **and** `sudo`. Log
  capture therefore only happens at the Mac, never in the field.
- The free-account sideload signs for **7 days**. A multi-day trial has to finish inside that window or the app dies
  in the bag; re-signing also requires the Mac.

## Constraints that shape the design

| Constraint | Source | Consequence |
|---|---|---|
| Free-account personal sideload | `docs/00:40` | No iCloud, Push, or App Groups — those need a paid membership |
| Battery efficiency is the product thesis | `docs/05`, IT-10 | The logging channel must not wake the radio |
| Zero / minimal third-party | D6, `docs/01:14` | No analytics SDK; Apple frameworks only |
| No coordinates are logged today | verified 2026-08-16 | Preserve it — the export then carries no location data |

That last row is a property worth defending explicitly. Every current log line is coordinate-free (`location push →
camera (95 B)` reports a byte count, not a position). Keeping it that way means the exported file is safe to hand to
anyone, including into a chat like this one, with no redaction step.

## Options considered

**iCloud Drive / CloudKit container — rejected (blocked).** The nicest design: the ring file syncs itself and simply
appears on the Mac. Requires the iCloud capability, which requires a paid Developer Program membership. Revisit only
if the account is upgraded — see "If the account ever goes paid".

**Network telemetry (POST to a self-hosted endpoint) — rejected (self-defeating).** Plain outbound HTTP needs no
entitlement, so this *would* work on a free account. Against it:

1. It contaminates the measurement. IT-10 is a battery-drain test; scheduling radio wakeups to ship logs makes the
   instrument a participant in the experiment.
2. Outdoors there is frequently no signal, so it buffers locally regardless — meaning the local ring is still
   required. Telemetry does not replace this work, it sits on top of it.
3. It moves data off-device from an app that currently sends nothing anywhere.

**Third-party analytics SDK — rejected.** Breaks D6, and inherits every objection above.

**Bounded local ring + zero-cost export — chosen.** Delivers telemetry's actual benefit (data reliably reaches the
Mac) with no backend, no entitlement, no radio, and no polluted drain test.

## Design

### 1. `AlfaLog` — a new AlfaKit target

Current graph is `SonyProtocol ← SonyBLE ← AlfaGeotag`. Both `SonyBLE` and `AlfaGeotag` log, so the ring needs to sit
below both. It does **not** belong in `SonyProtocol`, whose contract is "PURE: Foundation only" — file I/O would break
that. Add a fourth target:

```
.target(name: "AlfaLog"),                                   // Foundation + os.log
.target(name: "SonyBLE", dependencies: ["SonyProtocol", "AlfaLog"]),
```

`AlfaGeotag` picks it up transitively.

### 2. Fan-out, not replacement

`AlfaLog.notice(_:category:)` writes to **both** `os.Logger` (so Console.app and `Tools/alfa-logs.sh` keep working
unchanged) and the ring file. Migrating the 39 existing `log.notice` sites is mechanical and should be one commit,
separate from the ring implementation.

### 3. Pure decision, thin shell

Match the codebase's existing reducer pattern: a pure function decides *whether to rotate* given
(current size, incoming line length, limits), and a thin I/O shell performs it. The decision is host-testable with no
filesystem; only the shell touches disk.

### 4. Rotation and sizing

Two files, `field.log` + `field.1.log`, rotating at 2 MB each for a 4 MB ceiling.

Sanity check against the trial: ~3,800 lines/day × 7 days ≈ 27k lines, at roughly 80 bytes/line ≈ **2.2 MB**. A full
7-day trial fits inside one rotation with room to spare, so nothing is lost even if the device is never plugged in.

### 5. Write path

Serial `DispatchQueue`, buffered appends, flushed on a timer and on `didEnterBackground`. Never block a delegate
callback — `CameraLink` runs its own queue and the write must not become a new source of latency in the BLE path.

### 6. Export

- **`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`** in `App/Info.plist`, and write the ring to
  `Documents/`. Two keys, zero code: the log becomes visible in the Files app and AirDrop-able from the field with no
  Mac involved. Neither key is currently present.
- **Share-sheet button in Settings** for one-tap send.
- **Mac-side pull** (`xcrun devicectl device copy from`, or Xcode → Devices → Download Container), folded into the
  evening plug-in that already has to re-sign the app. This is the "automatic" path that matters.

## Build order

1. `AlfaLog` target: pure rotation decision + host tests.
2. I/O shell: ring file, buffered writer, flush-on-background.
3. Migrate the 39 `log.notice` sites to the fan-out.
4. `Info.plist` keys + write to `Documents/`.
5. Settings share button.
6. `Tools/` script for the plug-in pull.

Steps 1–4 are the minimum that makes the trial worth running. 5 and 6 are convenience.

## Pre-trip checklist

- [ ] Use the **iPhone**, not the iPad. The iPad mini 6 is Wi-Fi-only with no GNSS (`docs/08:16`); outdoors its
      location is coarse or absent. Rig B (iPhone + GNSS) is the designated rig for IT-9 and IT-10.
- [ ] Install and re-sign before departure; profile currently lapses **2026-08-23**.
- [ ] Confirm the ring file is being written before leaving (Files app).
- [ ] Note the camera's `Cnct. while Power OFF` setting — it changes what the drain test is measuring (`docs/05`).
- [ ] Record start-of-trial `ConnectionStats` (Home) for comparison; those persist independently of the log.
- [ ] Ground truth is the **EXIF on the frames themselves** — whether each shot carries fresh, accurate coordinates
      is a stronger signal than any log line.

## If the account ever goes paid

A paid membership resolves two separate problems at once: iCloud sync for the ring (no plug-in ritual at all), and a
**1-year** provisioning profile instead of the 7-day one. Before a multi-day field trial is the moment that pays off.

## Open questions

- **OQ-A** — Should the ring capture more than the current 39 sites? A field trial may want per-fix detail
  (accuracy, staleness) that today's markers omit. Any addition must keep the coordinate-free property.
- **OQ-B** — Is 46 s of push logging worth its volume over days, or should the keep-alive log at a reduced rate in the
  ring while staying verbose in `os.Logger`?
