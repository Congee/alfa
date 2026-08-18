# 08 — Integration Testing (on-device)

The host test suite (`swift test`, 101 tests in 10 suites) locks the **pure** logic — packet layouts and the Balanced-policy
reducer's anti-churn invariants (including the keep-alive heartbeat's guard rails and foreground-aware reconnect). It cannot exercise CoreBluetooth,
CoreLocation, bonding, background relaunch, or the real A7R V. This document is the on-device plan that closes that gap
and validates the three open 🟡 assumptions (`CC13` clock, `CC05` standby value, `DD21` tz bit), the **background
relaunch / state restoration** flow, and the **location-staleness timeout + keep-alive** (IT-11) — the one camera
behavior with *no published value*, so it must be measured on the rig.

Run each suite in order; later suites assume a bonded camera from IT-2.

## Method & rigs

| Rig | Devices | Validates | Cannot validate |
|-----|---------|-----------|-----------------|
| **A — now** | iPad mini 6 (iPad14,1, **Wi-Fi-only → coarse location, no GNSS**) + A7R V (fw 4.0) | Everything below **except** the two GPS/battery items: pairing, geotag writes are *accepted*, time/tz sync, CC05 standby, anti-churn, **state restoration**, forget/re-pair | GPS **accuracy** (location is coarse Wi-Fi); multi-hour battery-drain truth |
| **B — later** | iPhone 17 Pro "Monad" (has GNSS) + A7R V | GPS accuracy (IT-9); the north-star **battery-drain field test** (IT-10) | — |

> Rig B's iPhone ("Monad") is paired to the Mac as of 2026-07-15 — IT-9 and IT-10 are unblocked hardware-wise and are
> the next validations owed. Everything else runs on Rig A.

Bluetooth here means BLE to the **camera**; the iPad's coarse location still produces valid `LocationFix`es, so the
camera will receive and accept `DD11` writes and show a location tag — enough to prove the write path end to end. Only
the *accuracy* of the tag is untrustworthy on Rig A.

## Observability

All connection-lifecycle seams emit `os.Logger` markers under subsystem **`me.congee.alfa`** (added specifically so a
system-triggered *background* relaunch — where no debugger can attach — is still observable).

**Stream (primary):** Console.app → select the device in the sidebar → search field: `subsystem:me.congee.alfa`.
Keep it open across backgrounding and relaunch.

**Capture (CLI):** `Tools/alfa-logs.sh [minutes] [udid]` collects the last N minutes from the device and prints the
filtered markers (keeps the archive in `$TMPDIR` for re-querying). Device pick order: the `udid` argument →
`$ALFA_DEVICE_UDID` → auto-detect, which errors unless **exactly one** device is connected — so with two devices
paired, pass the UDID. Collection needs **USB**: over Wi-Fi/localNetwork `log collect` fails with "Device not
configured (6)". Equivalent raw commands:
```
sudo log collect --device-udid <hardware-udid> --last 10m --output alfa.logarchive
log show alfa.logarchive --predicate 'subsystem == "me.congee.alfa"' --info --style compact
```
> ⚠️ `log collect --device-udid` takes the **hardware** UDID (`00xxxxxx-…`, from `xcrun xctrace list devices`), never
> the CoreDevice UUID (that fails with "unable to obtain a connection"). It also needs `sudo`. `devicectl` is the
> lenient one — it accepts the hardware UDID for `--device` too (verified 2026-08-16), so the hardware UDID is the
> single identifier that works everywhere; prefer it.

**Install / launch:** `Tools/alfa-install.sh [device-name]` builds Release, installs, and reports how long the
free-account signing lasts (7 days; re-signing before it lapses is left to a launch agent outside this repo, and
only works while the device is reachable from the Mac). It prints the matching launch command:
```
Tools/alfa-install.sh "<device name>"
xcrun devicectl device process launch --device <hardware-udid> me.congee.alfa
```
`alfa-install.sh` resolves the device by name, so neither identifier has to be typed. (The "No provider was found"
line during install/launch is a benign devicectl warning; success is the line after it.)

**Optional BLE sniff:** PacketLogger (Xcode → *Additional Tools for Xcode* → *Hardware*) captures the actual ATT
writes/notifications — the ground truth for IT-4's byte-level verification.

### Log marker reference

| Marker (category) | Meaning |
|-------------------|---------|
| `resuming geotag after relaunch (state restoration)` *(coordinator)* | `resumeIfPreviouslyEnabled()` fired on launch |
| `restore: willRestoreState — N peripheral(s), first state=S` *(ble)* | iOS handed back BLE state; `state=2` is `.connected`, `0` is `.disconnected` |
| `restore: link survived — re-discovering services to resume` *(ble)* | Restored link was live → resuming |
| `restore: link dropped — cancelling intent and backing off (no reconnect)` *(ble)* | Restored link dead → anti-churn back-off |
| `connected — discovering services` *(ble)* | `didConnect` |
| `ready — services + handshake acknowledged` *(ble)* | Bonded, GATT mapped, fw handshake done |
| `disconnected: …` / `connect failed: …` *(ble)* | Link lifecycle ends |
| `backing off — cancelling pending connect intent` *(ble)* | A standing `connect()` was cancelled |
| `write FAILED on <char>: <reason> [<domain> <code>]` *(ble)* | A write was rejected. The bracketed domain/code is the part that discriminates: `CBATTErrorDomain 5`/`15` is an unusable link (needs re-encryption), where `localizedDescription` alone renders everything as "Unknown ATT error" |
| `standby probes exhausted on a camera that is serving its GATT — link is stale, dropping to rebuild` *(ble)* | Three standby probes rejected by a camera that *is* serving its Sony GATT → the link is dropped so the policy rebuilds it. Never fires for a reduced-GATT (genuinely off) body |

## Camera-side preconditions (A7R V, fw 4.0)

- `MENU → Network → Bluetooth → Bluetooth Function: On`
- `MENU → Network → Cnct./PC Remote → Cnct. while Power OFF: Off` for most suites (turn **On** only for the standby/
  restoration suites IT-5/IT-7 that need BLE alive while the camera sleeps).
- **No camera-side "location link" toggle is required.** IT-3 confirmed Alfa enables location itself via the fw-gated
  `DD30`/`DD31` handshake after OS bonding — a fresh pair is sufficient. *(The exact A7R V menu wording for the
  remaining items is intentionally left to Sony's Help Guide rather than guessed; earlier drafts here invented
  "Bluetooth Rmt Ctrl" / "Loc. Info Link Set." paths that do not exist on this body.)*
- **Only Alfa** connected — remove the A7R V from Creators' App / Imaging Edge / Alpha Remote first (the multi-suitor
  churn in `05` will otherwise pollute results).

## Reset between runs

Deleting the app from the iPad clears all `UserDefaults` (onboarding flag, enabled flag, remembered camera, settings).
To also drop the OS bond: iPhone/iPad **Settings → Bluetooth → (i) next to the camera → Forget This Device**, and on
the camera `MENU → Network → Bluetooth → (delete the paired device)`. A clean re-pair test (IT-8) needs both sides
forgotten.

---

## IT-1 — Onboarding & permissions

**Pre:** fresh install (or reset). **Steps:** launch → walk the onboarding cover.

**Expect:**
1. Onboarding appears on first launch (full-screen cover).
2. Bluetooth step surfaces the system BT prompt exactly once; after Allow, the step shows "On".
3. Location step requests **While Using** first (not Always); "Always" is only offered/escalated *after* pairing.
4. Camera-prep checklist shows the exact A7R V paths above.
5. Finishing sets the completed flag — **quit and relaunch: onboarding does not reappear.**

**Pass:** prompts fire in the BT → While-Using → (pair) → Always order; no "Always" prompt before a pairing attempt.

## IT-2 — Pairing / bonding

**Pre:** IT-1 done, camera in preconditions, camera **On**. **Steps:** Home → Enable (or the onboarding Pair step).

**Expect:** `connected — discovering services` → OS pairing dialog (from the DD01 notify-subscribe trick) → accept →
`ready — services + handshake acknowledged`. UI: Connection "Connected", Camera row shows the model name. If ATT 5/15
appears, it retries ~3× at 3 s (watch for a repeated notify attempt) then bonds.

**Pass:** reaches `ready`, camera name shown, remembered across a cold launch (Camera row visible before Enable).

**✅ Result (2026-07-14, Rig A):** connected — Home showed Connected + camera name.

## IT-3 — Geotag session (connect / distance / interval)

**Pre:** bonded, camera On, Enable active.
1. **On-connect sync:** on connect, exactly one push fires (`Fixes pushed` = 1) — this doubles as the time sync.
2. **Distance gate:** with Settings → Update distance = 25 m, stay put → no new pushes; move > 25 m → one push.
   (On Rig A, "move" via coarse Wi-Fi jumps is imprecise; verify the *gate behavior*, not the distance value —
   accuracy is IT-9.)
3. **Interval gate:** set Minimum interval = 30 s; move far but < 30 s since last push → **no** push; after 30 s and
   still moved → push. (Both gates must clear — mirrors the host tests `intervalThrottle*`.)

**Pass:** push count increments only when **both** gates clear; the camera's playback shows a location tag on a frame
shot after a push.

## IT-4 — Time sync verification (resolves the `CC13` 🟡 assumption)

The single most valuable Rig-A test — it decides whether `SonyTimePacket`'s local-wall-clock assumption is correct.

**Pre:** bonded. On the camera, note `MENU → Setup → Area/Date/Time` before each sub-test.

1. **Time Area Correction (DD11 tz):** Settings → Time Area Correction **On**. Set the iPad to a **non-default time
   zone** (Settings → General → Date & Time → off "Set Automatically" → pick e.g. UTC+5:30). Enable/Sync → the
   camera's Area/time zone should follow. Turn the toggle **Off**, change zones, Sync → camera zone should **not**
   change (91-byte packet, no tz block). *(Also confirms the `DD21` tz-required bit path works on this body.)*
2. **Time Correction (CC13 clock):** Settings → Time Correction **On**. Deliberately set the **camera** clock wrong
   (e.g. +7 min). Enable/Sync. Read the camera clock:
   - **Correct** → the assumption holds; leave `SonyTimePacket` as is.
   - **Off by exactly the UTC offset** (or DST) → the camera wants **UTC** fields; flip the derivation in
     `SonyTimePacket.init(date:timeZone:)` to a UTC calendar (isolated change) and re-run.
   - **No change at all** → the A7R V ignores `CC13`; the clock rides `DD11`'s mandatory UTC datetime instead.
     Record this and downgrade the toggle's promise in Settings/Help.
3. Sniff `DD11`/`CC13` with PacketLogger and diff the bytes against `docs/03` (offsets 5, 19–25, 91–94; the 13-byte
   CC13 layout).

**Pass:** camera clock and zone land correctly with the toggles on and are untouched with them off. **Record the CC13
outcome in `docs/03` and `alfa-project.md` regardless.**

**✅ Result (2026-07-14, Rig A):** clock sub-test (step 2) passed — camera clock set +7 min wrong, synced with Time
Correction on, landed **correct**. Confirms the local-wall-clock + base-offset interpretation in `SonyTimePacket`;
`docs/03` + `TimePacket.swift` updated from 🟡 to verified. *Still to run:* the tz-change sub-test (step 1) and the
PacketLogger byte diff (step 3).

## IT-5 — CC05 standby detection → back-off

**Pre:** bonded + connected; camera **Cnct. while Power OFF: On** (so BLE survives standby).
**Steps:** let the camera enter standby (or power switch to standby) while Alfa is connected & foregrounded.

**Expect:** `CC05` notify → the pure reducer's `cameraPoweredOff` → `backing off — cancelling pending connect intent`;
UI → "Standby (backed off)". This is the **deliberate-standby** path (camera still BLE-reachable via *Cnct while Power
OFF On*): waking it does **not** auto-reconnect — the standby bail suppresses the follow-on disconnect from re-arming
a connect (that would be the wake-magnet loop). **Sync now** (or backgrounding + returning to the foreground)
reconnects. *(Contrast IT-12, where a link that fully **drops** in the foreground does auto-reconnect.)*

**Pass:** back-off is driven by CC05 *before* any disconnect; no auto-reconnect on wake from a CC05-standby bail. (If
CC05's standby value differs from `04 00 00 02 04`, the fallback is disconnect-inferred standby — note the real bytes.)

## IT-6 — Anti-churn / good BLE citizen

**Pre:** bonded. **Steps:** enable; connect; camera to standby; observe over ~10 min with the app **backgrounded**.

**Expect:** no connect/disconnect oscillation attributable to Alfa. In the log: after back-off there are **no**
repeating `connected`/`disconnected` pairs. Optionally sniff to confirm no standing `connect()` re-fires against the
standby camera.

**Pass:** at most the single expected teardown; zero churn loop. (This is the qualitative form of IT-10.)

## IT-7 — Background relaunch / state restoration (the new flow)

Validates that after the app is **terminated** (not user-force-quit) while geotagging, iOS relaunches it for a BLE
event and Alfa resumes-or-backs-off correctly.

> ⚠️ **Force-quit disables restoration.** Swiping the app up in the App Switcher tells iOS *not* to relaunch it for
> BLE (or background location). To simulate a *system* kill, terminate via **Xcode Stop (■)** while the app is
> backgrounded (SIGKILL — restoration stays armed), or let jetsam reclaim it. Never swipe-kill during this suite.

**Common setup:** bonded; **Cnct. while Power OFF: On**; run the app (from Xcode is fine), Enable, reach `ready` +
≥1 push; press **Home** to background (do **not** swipe-kill); Console.app streaming `subsystem:me.congee.alfa`.

### IT-7a — Dropped-link variant (primary; the battery-critical path)
1. With the app backgrounded, **Xcode Stop (■)** to SIGKILL it (or wait for jetsam).
2. Put the camera into **standby / power off** so the link drops.
3. iOS relaunches Alfa in the background.

**Expect (in order):** `resuming geotag after relaunch (state restoration)` → `restore: willRestoreState — 1
peripheral(s), first state=0` → `restore: link dropped — cancelling intent and backing off (no reconnect)`. **No**
`connected`, **no** standing `connect()`. Foreground the app later → "Standby (backed off)".

**Pass:** the dropped link is **not** reconnected; the pending intent is cancelled; policy is backed off.

### IT-7b — Survived-link variant (opportunistic / harder to force)
Trigger: while the link is still alive after the SIGKILL, cause a **subscribed** notification — a `CC05` power-state
transition (camera → standby with *Cnct while Power OFF On* keeps BLE up) is the practical trigger.

**Expect:** `restore: willRestoreState — 1 peripheral(s), first state=2` → `restore: link survived — re-discovering
services to resume` → `ready — services + handshake acknowledged` (chars re-populated, notify re-subscribed, CC13 re-sync
if enabled). Then, if the CC05 that woke us reads *off*, it immediately backs off (IT-5 path) — expected and correct.

**Pass:** the live link is resumed (re-discovered + re-subscribed) rather than dropped; subsequent standby still backs
off cleanly.

### IT-7c — Foreground cold-launch resume
Reset nothing. Enable, then fully quit via Xcode Stop, then tap the app icon (normal launch).

**Expect:** `resuming geotag after relaunch …`; geotagging is on without re-prompting for permissions; the remembered
camera is shown. **Pass:** state persists across a normal relaunch; no permission prompts on resume.

## IT-11 — Location-staleness timeout & keep-alive heartbeat

**Why this exists:** no Sony doc, forum, or RE repo publishes *how long* the camera keeps a location fix before the
overlay flips "Obtaining location information" → "Location information cannot be obtained." And the camera announces
that expiry over **no BLE characteristic** — `DD01` only reports the location-link feature toggle, not fix staleness —
so Alfa can't react to it; it can only *prevent* it with a periodic re-push. This suite measures the timeout and
proves the keep-alive works. (Field-observed bug: leaving the camera powered-on but idle stopped geotagging even
though Alfa stayed "Connected" — the fix expired because Alfa only pushed on movement.)

**The oracle = EXIF GPS in captured frames.** It's the only machine-readable signal (the overlay is visual-only). A
frame captured while the fix is valid carries `GPSLatitude`/`GPSLongitude`; once expired, it doesn't. Bracketing the
last-tagged and first-untagged frame across a timed sequence gives the timeout — no SDK, no Wi-Fi, no PC-Remote↔BLE
coexistence risk.

**Method (both sub-tests):** camera **On**, on a tripod, stationary. Use the camera's built-in intervalometer
(`MENU → Shooting → Drive Mode / Interval Shooting`) at a **10 s** interval. Alfa bonded + Enabled, ≥1 push confirmed
(overlay shows the location icon). The debug **Freeze location pushes** toggle (`Settings → Diagnostics`, DEBUG builds
only) stops **all** outgoing writes — real pushes *and* keep-alives — while Alfa keeps receiving fixes locally, so the
camera is proven to be the thing timing out, not the phone. Afterward pull the card and:
```
exiftool -T -DateTimeOriginal -GPSLatitude -GPSLongitude *.ARW
```

### IT-11a (T1) — Measure the timeout
1. Bonded, Enabled, overlay shows location obtained. Start interval shooting.
2. After the first frame or two are tagged, flip **Freeze location pushes = On**.
3. Let it run ≥5 min, then stop and read EXIF.

**Result to record:** the gap between the last GPS-tagged frame and the first untagged one brackets the timeout to
±10 s (shorten the interval to tighten). **This number sets the safety margin for the keep-alive** —
`ConnectionPolicy.keepAliveSeconds` (currently **45 s**, chosen against the user-observed ~60 s tolerance; the
coordinator's `heartbeatInterval` derives from it) must stay well under it. If the measured timeout is < ~55 s, lower
`keepAliveSeconds` accordingly.

### IT-11b (T2) — Prove the heartbeat prevents expiry, and recovers
1. Same rig, **Freeze = Off**. Do **not** move. Start interval shooting; run ≥ (2× the T1 timeout).
   **Expect:** every frame stays GPS-tagged — the 45 s keep-alive re-push holds the fix despite zero movement.
   *(UI corroboration: `Fixes pushed` increments ~every 45 s while stationary.)*
2. Now flip **Freeze = On**, let the overlay expire (per T1), then flip **Freeze = Off**.
   **Expect:** the overlay returns to "obtained" and frames re-tag **without a reconnect** — the resume-push (fired
   immediately on un-freeze) re-arms the fix. If instead it only recovers after a full disconnect/reconnect, record
   that: it means the camera needs more than a fresh `DD11` write to clear the expired state.

**Pass:** T1 yields a concrete timeout; T2 shows the stationary keep-alive prevents expiry and un-freezing recovers
the fix in place. **Fixes the "camera idle while powered on" field bug (matrix combos 1 & 3).**

> **Scope:** this validates the *foreground* keep-alive. A suspended app can't run the timer, so a **stationary,
> backgrounded** phone (combos 2 & 5) can still let the fix expire — a known iOS limitation, tracked with the
> reconnect-policy work, not this suite.

## IT-12 — Power-cycle reconnect (foreground **and** background)

Validates the field bug: power the camera off then on (lever) and geotagging should resume **without** tapping "Sync
now" — whether the app is foreground or background.

**Pre:** bonded + connected + geotagging, camera **Cnct. while Power OFF: Off** (so a lever-off fully drops BLE — the
scenario the user hit). Console streaming `subsystem:me.congee.alfa`.

**IT-12a — foreground.** App open. Flip the lever **off** (link drops: camera overlay → "Bluetooth connection
unavailable"; iOS Bluetooth shows disconnected) → flip **on**. **Expect:** because the link was genuinely `.connected`,
the engine re-arms a standing connect (`beginDiscovery`) instead of backing off; iOS services it on power-on →
`connected — discovering services` → `ready — services + handshake acknowledged`; UI "Connected" and the camera overlay
returns to "Obtaining location information" **on its own**.

**IT-12b — background.** Same, but press **Home** to background the app first (do **not** swipe-kill), then flip the
lever off → on. **Expect:** the standing connect is **kept** across backgrounding (not cancelled); on power-on iOS
re-links — relaunching the app via state restoration if it was suspended (`resuming geotag after relaunch …` →
`restore: link survived …` or a fresh `connected …`). Geotagging resumes with the app still in the background.

> **Boot-window note (the 2026-07-14 field failure):** iOS may service the standing connect within ~1 s of lever-on,
> **before** the camera's Sony GATT exists — discovery then returns a reduced GATT and the log shows
> `connected — discovering services` → `no location service in GATT … holding link in standby`. Recovery is the
> bonded **Service Changed** indication once the full GATT is restored: `services modified … — re-discovering` →
> `ready — services + handshake acknowledged` (backstopped by the 15 s discovery-stall watchdog and the 60 s standby
> probe). Eternal silence after `connected — discovering services` is the pre-fix zombie fingerprint — it must not
> appear.

**Pass:** power-cycle auto-recovers with no user action, foreground and background.
**Status:** IT-12b ✅ pass (2026-07-15): app backgrounded, lever off → on, BLE re-linked and geotagging resumed
without user action (user-confirmed, `Cnct. while Power OFF: Off`). IT-12a foreground still owed a dedicated run.

> ⚠️ **Ordering known, but it exposes a drain (on-device 2026-07-14, `subsystem:me.congee.alfa`).** A real A7R V
> lever-off produces a **plain** `disconnected: The specified device has disconnected from us.` with **no** preceding
> `CC05` back-off line (contrast the standby-bail fingerprint `backing off — cancelling pending connect intent` →
> `disconnected: clean`, which appears only on a CC05 `off`). So the A7R V does *not* emit CC05-off on a lever-off — the
> `.connected`→drop path fires and the link auto-reconnects ~9 s later (verified, incl. through a state-restoration
> relaunch). **The problem:** with no CC05-off, the standby **bail never fires either**, so Alfa re-links to a
> lever-off "Cnct while Power OFF" camera. **Addressed (2026-07-15, `a5ac612`):** a re-link to a camera that isn't
> serving/accepting the Sony GATT now converges to a **dormant `.standby` hold** — no writes, a 60 s probe, ack-gated
> `.ready` — so Alfa adds no traffic of its own to the held link. *(Refined 2026-08-16: three rejected probes from a
> camera that **is** serving its GATT now drop the link so it can be rebuilt — a stale link never recovers in place.
> A reduced-GATT body, the genuinely-off case this paragraph is about, is still held indefinitely and never rebuilt.)*
> Whether the *held link alone* still keeps the body
> awake (the access lamp was observed staying on under the old, actively-held link; the dormant hold is unmeasured)
> is exactly what IT-10 condition (b) answers. If it drains, the fallback design is the Sony **advertisement
> power/status byte** as a pre-connect discriminator (bounded scan reconnects only to a genuinely-powered-on camera —
> `docs/03` advertisement parsing). The proven, recommended configuration sidesteps all of this: **Cnct. while Power
> OFF: Off**, where a lever-off camera goes BLE-silent and the wait costs nothing by construction.

## Automated integration harness (mock camera peripheral)

Because connect / handshake / standby can't be automated against the physical camera (no programmatic lever) and device
logs need root, they are exercised by a **mock Sony camera BLE peripheral** running on the Mac, with the **real** app
under `xcodebuild test` on the device. This is a genuine two-radio setup (a single Mac can't discover its own
advertisement — see `Tools/ble-integration/README.md`):

- **`AlfaCameraSim`** (Mac, `CBPeripheralManager`) — advertises the Sony location service (the app accepts it in DEBUG
  only when `ALFA_TEST_ACCEPT_SIM=1`, and then *only* the sim, so a real A7R V nearby can't win the race), serves the
  DD11/DD30/DD31/DD01/CC05/CC13/FF02 GATT, and drives `ALFA_SIM_SCRIPT` scenarios (`none`, `standby`, `focus`).
- **`Tests/AlfaIntegrationTests`** (device, hosted by the Alfa app) — drives the real `CameraCentral` over the real
  radio and asserts. `Tools/ble-integration/on-device-it.sh` runs it all with one command.

**Verified PASS on-device (iPad mini 6):**

| Scenario  | Real-radio path asserted                                                       | Status |
|-----------|--------------------------------------------------------------------------------|--------|
| `connect` | discover → bond (notify-subscribe) → fw handshake (DD30/DD31) → DD11 push       | ✅ PASS |
| `standby` | `CC05` off notification → engine backs off (no standing connect, no reconnect)  | ✅ PASS |
| `focus`   | `FF02` focus-acquired *and* shutter-fired → immediate DD11 pushes while stationary | ✅ PASS (2026-07-15) |

**Not covered by the harness (by design):** the **power-cycle reconnect** (IT-12) and **fix-expiry** (IT-11) paths need
the peripheral's *radio* to vanish, which a macOS `CBPeripheralManager` cannot do — releasing the manager or exiting the
sim process leaves `bluetoothd` holding the link alive (verified on-device). Those remain covered by the pure-reducer
host tests (`SonyBLETests`: a dropped `.connected` link re-arms discovery fg+bg; a CC05 bail does not) and, for the real
camera's actual CC05-vs-disconnect ordering, by the on-device log capture below — which no simulator can substitute for.

## IT-8 — Forget camera / re-pair

**Steps:** Home → Forget camera → confirm. **Expect:** immediate Camera-row clear + `disconnected`; remembered camera
gone across relaunch. Then forget on both OS + camera side (reset procedure) and re-run IT-2.
**Pass:** clean forget; a subsequent pair behaves like first-time.

## IT-13 — Update location on focus *(real camera)*

**Pre:** bonded + connected + geotagging; enable the camera's Bluetooth remote-control setting (pin its exact A7R V
menu path here when running this — do not guess it). Console streaming `subsystem:me.congee.alfa`.
**Steps:** stand still (so the distance gate stays closed), activate AF (half-press, or AF-ON for back-button focus)
until focus locks; separately, take a photo.
**Expect:** `notify FF02 = 02 3F 20` (AF) and `02 A0 20` (shutter) in the log, each followed immediately by
`location write acked`; the camera's location overlay refreshes. Rapid AF re-acquisitions or burst frames within
~2 s must **not** produce extra writes (capture-push throttle). With the camera's remote setting **off**: no FF02
events arrive (or `02 C3 00`), and geotagging is unaffected.
**Pass:** AF/shutter → immediate push, throttled; no writes and no errors with the setting off.

**✅ PASS — both halves field-verified 2026-07-15 (A7R V fw 4.0, back-button-focus shooter):**
- *Shutter:* a photo with **no AF-button press** produced only `02 A0 20` → `02 A0 00` — no `3F` event, as expected
  with no shot-coupled AF activation. This observation is why the shutter codes became a push trigger alongside
  focus (a back-button-focus shooter may never emit a shot-coupled focus event).
- *Focus:* a genuine **AF-ON acquisition** produced `notify FF02 = 02 3F 20` → `location push` → `location write
  acked` 65 ms later, then `02 3F 00` on release.
- *Throttle:* the shot fired 1.7 s after the focus push and its `02 A0 20` correctly produced **no** second write
  (inside the 2 s capture throttle) — the exposure carried the fresh focus-push fix.
- Same session: lever-on relaunched the app in the background (state restoration), boot-window re-discovery →
  ready → first push ~2 s after power-on; lever-off re-armed the standing connect.
*(The FF02 → push mechanics for both triggers are also covered on every harness run by the `focus` scenario below;
this test pinned the real body's behavior and the camera-side setting.)*

## IT-14 — CC10 battery probe *(real camera, passive — no steps beyond connecting)*

Settles whether the doc-only `CC10` "Battery Information" lead exists on the A7R V (`docs/03` — zero working code
behind it anywhere; possibly synthesized). Debug builds probe it automatically on **every** connect: discover, and if
present subscribe + read, logging everything under `CC10 battery probe:` (`subsystem:me.congee.alfa`).
**Steps:** none — just connect to the real camera as usual, then pull the log (`Tools/alfa-logs.sh`).

**✅ Part 1 answered 2026-07-15 — `CC10` EXISTS on the A7R V fw 4.0.** The camera came on near the iPad and the
probe hit it three times: `present, properties 0x12` (Read + Notify), payload stable across all three reads:
`12 00 00 02 03 00 01 00 0A 00 00 00 00 64 00 00 00 00 02` (19 B). Byte 13 = `0x64` = 100, with the camera fully
charged — battery % is the working hypothesis (docs/03).

**Part 2 owed — pin the decode:** re-read at a visibly different charge level (e.g. ~60 %, ~20 %) and compare
byte 13 against the camera's own battery display; note whether a *notify* arrives when the level drops while
connected; if convenient, once with a charger attached. Only after byte 13 tracks the display does a battery UI
(GA-parity item) get built.

## IT-15 — Remote control on the real body *(real camera, foreground)*

The harness `capture` scenario proves the sequencing against the sim; this pins the real A7R V's behavior.
**Pre:** connected + geotagging; camera's Bluetooth remote-control setting on (pin its exact menu path here when
running this — do not guess it); Remote tab open.
**Steps & expect:**
1. *Tap shutter (tap mode):* a photo fires; log shows `remote command → camera (01 07)` → `notify FF02 = 02 3F 20`
   → `(01 09)` → `02 A0 20` → releases `(01 08)(01 06)`; banner flashes FOCUSING → EXPOSING. With an MF lens (or AF
   defeated): the focus wait times out after 3 s, the full-press still goes out, and release priority decides.
2. *Hold shutter:* ≥350 ms hold sustains a half-press (camera AF engages, no shot) until lift.
3. *Two-stage mode:* ring holds S1; center fires S2 — in BULB, holding the center times the exposure and the EXP
   counter runs until release; the estimated NR countdown then appears (long exposures).
4. *AF-ON / C1:* press = camera AF-ON / C1 action while held; 800 ms long-press latches (lock glyph), tap unlocks.
5. *Record:* tap REC → `02 D5 20` in the log + red RECORDING banner + elapsed; tap again → `02 D5 00`.
   **This is the first-party verification of the `02 D5` codes** — record the result in docs/03.
6. *Remote setting off:* flip the camera's remote setting off → any press surfaces the "remote-control setting is
   off" hint (or the camera goes silent — note which).
7. *Coexistence:* while using the remote, geotagging keeps pushing (map marker fresh) — DD11 and FF01/FF02 share
   the one link.
8. *Opcode probe (DEBUG):* with a power-zoom lens mounted, fire `02 44/45 10/20` candidates from the probe panel,
   then the `6A–6D` group; note which group zooms vs racks focus and which step byte is which direction — update
   docs/03's 🔴 section with first-party values.
**Pass:** 1–5 & 7 behave as described with no write errors; 8 resolves the zoom/MF dispute.

## IT-9 — GPS accuracy *(Rig B — iPhone)*

On the iPhone (GNSS), verify pushed coordinates match ground truth (spot-check a frame's embedded GPS against a known
location) and that the distance gate triggers at the real configured distance. **Pass:** tag within GNSS accuracy of
truth; gate fires at ~configured meters.

## IT-10 — Battery-drain field test *(Rig B — the north-star success criterion)*

Per `docs/05`: measure camera battery % drop over a fixed standby window (e.g. overnight, *Cnct while Power OFF On*)
in three conditions — **(a) no app**, **(b) Alfa only**, **(c) Alfa + Creators'/Alpha Remote**.
**Pass:** (b) is indistinguishable from (a); (c) reproduces the drain (confirming the multi-suitor root cause, not an
Alfa regression). Document the procedure so it can be repeated after any connection-engine change.

### Runbook (one condition per night; keep everything else identical)

**Held constant across nights:** same battery (note its age/health), charged to a known starting % (100 %, or read the
exact % off the monitor's battery indicator); same room / temperature; camera **lever off** for the whole window;
window ≥ 8 h and the *same length* every night (set an alarm — Δ% only compares across equal windows); camera
Bluetooth **On**; phone on its usual overnight charger within BLE range.

| Night | Condition | Camera `Cnct. while Power OFF` | Phone side |
|-------|-----------|--------------------------------|------------|
| (a) | baseline, no suitor | **On** | Alfa geotag **disabled** (or app deleted); no Creators' App running |
| (b) | Alfa only — prices the **dormant standby hold** | **On** | Alfa enabled, backgrounded (do **not** swipe-kill) |
| (b′) | Alfa only — the **recommended shipping config** | **Off** | Alfa enabled, backgrounded |
| (c) | churn repro — the drain Alfa exists to avoid | **On** | Creators' App (or Alpha Remote) installed + linked, Alfa enabled too |

**Per night:** ① note start % and wall-clock time just before lever-off; ② hands off for the window; ③ at the end,
*before* powering the camera on, run `Tools/alfa-logs.sh <window-minutes>` on the Mac — the overnight marker stream is
the churn evidence (count `connected`/`disconnected`/`standby` cycles; condition (b) should show the initial link
settling into `standby` and then near-silence — the 60 s probe runs only while iOS keeps the app awake, a suspended
app writes nothing — and never a connect/disconnect loop); ④ lever on, note end %.

**Read:** Δ(b) ≈ Δ(a) within the camera's 1 % display resolution ⇒ the dormant hold is free — pass. Δ(b) > Δ(a) but
log shows no Alfa churn ⇒ the *held link itself* costs the camera power ⇒ implement the advertisement-byte pre-connect
discriminator (IT-12's ⚠️ fallback) and re-run. Δ(b′) ≈ Δ(a) is expected by construction (camera radio-silent);
a failure there means the standing connect is somehow waking the body — investigate before shipping. (c) is the
control: it *should* drain visibly, proving the measurement can detect the disease at all.

**Results (fill in):**

| Date | Condition | Window (h) | Start % | End % | Δ% | Churn in log? | Notes |
|------|-----------|------------|---------|-------|----|---------------|-------|
| | | | | | | | |

---

## Pass/fail summary

| ID | Area | Rig | Blocks release if failing | Status |
|----|------|-----|---------------------------|--------|
| IT-1 | Onboarding/permissions | A | yes | |
| IT-2 | Pairing/bonding | A | yes | ✅ pass (2026-07-14) |
| IT-3 | Geotag session + gates | A | yes | |
| IT-4 | Time/tz sync (CC13/DD11) | A | no (beta) | ✅ CC13 clock verified (2026-07-14); tz sub-test pending |
| IT-5 | CC05 standby → back-off | A | yes | |
| IT-6 | Anti-churn | A | yes | |
| IT-7 | State restoration | A | yes (7a); 7b opportunistic | |
| IT-11 | Staleness timeout + keep-alive | A | yes (idle-drop bug) | |
| IT-12 | Power-cycle reconnect (fg + bg) | A | yes (reconnect bug) | ✅ 12b bg pass (2026-07-15); 12a fg pending |
| IT-8 | Forget / re-pair | A | yes | |
| IT-9 | GPS accuracy | B | yes (before GPS claims) | |
| IT-10 | Battery-drain field test | B | **yes — the reason the project exists** | |

## Defect log template

```
[IT-#] <title>
Rig / fw:        A (iPad mini 6) / A7R V fw 4.0
Steps:           …
Expected:        <UI + log markers + camera behavior>
Actual:          <what happened + relevant subsystem:me.congee.alfa log lines>
Sniff (if any):  <PacketLogger byte diff vs docs/03>
Assumption hit:  <CC13 / CC05 value / DD21 bit>  →  <doc/code change made>
```
