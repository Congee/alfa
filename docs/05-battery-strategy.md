# 05 — Battery Strategy (the reason this project exists)

## The symptom

A Sony camera BLE-paired to an iPhone, left in standby ("Cnct. while Power OFF" enabled), constantly connects and
disconnects, slowly draining the camera battery. Observed severity:

- **Sony Creators' App:** worst.
- **Geotag Alpha alone:** fine.
- **Geotag Alpha + Alpha Remote Controller together:** churns again.

## The root cause (not encryption — CoreBluetooth semantics)

1. **`CBCentralManager.connect(_:options:)` never times out.** It is a *standing intent* held by the system daemon
   (`bluetoothd`), fulfilled the instant the peripheral advertises — even after the app is suspended or terminated
   (and, with state restoration, the app is relaunched to service it).
2. **One physical link per peripheral, shared across all apps.** iOS exposes a single system central; each app holds a
   `CBPeripheral` handle into it. The link's lifetime is the **union** of every app's interest. Canceling your
   connection does not drop the link if another app still wants it.
3. **The camera's standby loop.** "Cnct. while Power OFF" makes the camera re-advertise and auto-drop idle links (Sony
   documents that it "depletes the battery gradually"). Up to 2 devices may connect.

Put together: the camera advertises → `bluetoothd` services whichever app's pending intent it picks → that app does
trivial/no work → the link drops (camera inactivity timeout or app suspended) → camera re-advertises → the *other*
app's still-pending intent gets serviced → repeat. **One app = one suitor, no oscillation. Two uncoordinated apps = a
churn loop.** Creators' App is worst because it also pushes location on a ~7 s poll.

Aggressive "fast reconnect" (reconnect inside `didDisconnectPeripheral`, or `CBConnectPeripheralOptionEnableAutoReconnect`)
against a standby camera is the accelerant. Geotag Alpha's own changelog shows they had to auto-disable fast reconnect
when a camera has "Control while Power OFF" enabled.

> ⚠️ `Saschl/alpha-gps` is a cautionary example, not a model: it is new and **reproduces this exact drain.** Do not
> reuse its connection-lifecycle logic. Alfa's engine is designed from the CoreBluetooth semantics above, not ported
> from any existing app.

## Alfa's policy: "Balanced" (D4)

**While the camera is ON:** maintain the link; push location on movement / on half-press; sync time on connect. This is
cheap and expected — the camera radio is already awake.

**When the camera goes to standby:** tear down cleanly and **back off**. Do **not** hold a standing `connect()`, do
**not** aggressively reconnect. Re-establish only on an explicit, low-frequency trigger.

### Concrete rules for the connection engine

1. **No indefinite `connect()` during standby.** A pending connect is a permanent wake magnet. Only issue `connect()`
   when we intend to do work and expect the camera to be reachable.
2. **Check first, don't pile on.** Call `retrieveConnectedPeripherals(withServices:)` before connecting; if the system
   already has the peripheral (another app owns the link), do not add a redundant standing intent.
3. **Disconnect promptly when done.** "Disconnect when you have all the data you need; scan only when you need to."
4. **Coalesce writes to the camera's needed cadence,** not a fixed fast poll. Push on meaningful location change, not
   every N seconds.
5. **Gate fast-reconnect off in standby.** If auto-reconnect is used at all, disable it whenever the camera is in
   "Control while Power OFF" standby (mirror Geotag Alpha's mitigation).
6. **Detect on/off from the advertisement, don't guess.** Read the camera's power state from the `0x21` advertisement
   group (bit `0x40` = on) *before* committing to a link (rule 8). `CC05` is kept as a best-effort post-connect fallback
   for bodies that report it, but it is **silent on the A7R V** and no Sony GATT characteristic signals power-off, so the
   advertisement is the source of truth.
7. **Be a single, polite central.** Educate the user that running Alfa alongside Creators'/Imaging Edge/other remote
   apps re-creates the multi-suitor churn — the camera tolerates only one clean active link.
8. **Reconnect only to a camera that advertises *powered-on* (the advertisement power gate).** When a genuinely
   established link drops, re-establish it by **scanning and inspecting the advertisement**, not by a blind standing
   `connect()`. Connect only when the advertisement's `0x21` power group reports the camera on (bit `0x40`); an
   advertisement reporting *off* is an off-but-connectable "Cnct. while Power OFF" camera, so Alfa **declines** and
   keeps scanning briefly (bounded, `CameraLink.offWaitSeconds`) to reconnect the instant it powers on, then backs off.
   This is what makes the reconnect safe: Alfa never wakes or holds an off camera, because it never connects to one.

   > **Why not `CC05`?** The original design bailed on standby via the `CC05` power-state characteristic. On the A7R V
   > (fw 4.0) `CC05` is **silent** — no notification and no read response (verified on-device 2026-07-14, `docs/08`
   > IT-12), and a lever-off produces a plain `disconnected` with no power-off event of any kind. This is universal
   > across the Sony-BLE OSS ecosystem: **no GATT characteristic signals power-off.** The only reliable discriminator is
   > the **advertisement**: `0x21` bit `0x40` reads `0xF0` powered-on and `0xB0` powered-off (verified both directions on
   > the A7R V; independently documented by gethypoxic/whc2001 and used operationally by `ekutner/camera-gps-link`).

   **Foreground vs background.** The gate needs the advertisement's manufacturer data, which iOS delivers only to a
   **foreground** scan. So reliable resume-on-power-on is a foreground (or explicit "Sync now") behaviour. A background
   scan can't inspect the advertisement, so Alfa deliberately does **not** blind-connect from the background (that would
   re-link to and drain an off-but-connectable camera); it backs off instead and resumes on the next foreground/Sync.
   The one blind `connect()` still allowed is the foreground fallback when the scan sees **no** advertisement at all
   (camera fully off / out of range, i.e. *not* connectable-while-off) — a harmless standing intent iOS services on real
   power-on, which also survives into the background to give power-on resume for the well-behaved (Cnct-OFF) config.
   Net trade-off: with "Cnct. while Power OFF" **enabled**, background auto-resume is traded away to guarantee zero
   drain — another reason Alfa nudges the user to disable that setting (below), which restores full, safe background
   resume. *(✅ Resolved on-device 2026-07-14 — replaces the abandoned CC05 standby bail.)*

### Keep the camera's fix alive while connected (staleness ≠ churn)

Separately from connection churn, the camera **silently expires** a location fix that stops being refreshed (the
"Location information cannot be obtained" overlay) and announces that over no BLE characteristic — so it must be
*prevented*, not reacted to. While connected, Alfa re-pushes the last position on a ~10 s keep-alive (matching Sony's
own cadence) whenever nothing else has written for that long — driven off the write timeline, so a moving phone that is
already pushing never adds redundant writes. This is orthogonal to the anti-churn rules above: it only ever runs on an
*established* link and never issues a connect. (Timeout measured on-device: `08` IT-11.)

### State restoration is part of the fix, not a loophole in it

Opting into CoreBluetooth state restoration (a restore identifier + `willRestoreState`) is what lets Alfa *cancel* a
standing intent that outlived termination. iOS relaunches the app to service a pending `connect()`; on that relaunch
Alfa re-adopts the peripheral and, **only if the link actually survived**, resumes it. A restored-but-dropped or
still-pending link is deliberately **not** reconnected — the pending `connect()` is cancelled and the policy backs
off. Without restoration, a standing intent held at termination would become a permanent background wake magnet with
no chance to cancel it; with restoration, every relaunch is an opportunity to tear it down cleanly. The enabled state
is persisted so the resume is automatic and non-interactive (no permission prompts on a background launch).

### Consider AccessorySetupKit (OQ3)

iOS 18+ AccessorySetupKit is Apple's power-/privacy-conscious accessory model, and TN3115 (updated for iOS 26) notes
iOS now relaunches non-ASK apps for only a subset of background BLE triggers. Evaluate ASK during Phase 1 on-device
testing; classic `CBCentralManager` + bonding remains the fallback (it is what all prior art uses).

## How we validate the fix

- Baseline: measure camera battery drop (and/or sniff BLE) over a fixed standby window with **no** app.
- With Alfa only: the drop should be indistinguishable from baseline; no Alfa-attributable connect/disconnect churn.
- Regression guard: document the measurement procedure so it can be repeated after connection-engine changes.

## User-facing camera-side hard fixes (document in-app where relevant)

Disabling "Cnct. while Power OFF" (`MENU → Network → Cnct./PC Remote`) or the camera's Airplane Mode both stop the drain
outright, and **not running competing remote apps simultaneously** is the biggest single win. Alfa should nudge, not
fight, these. (No camera-side "location link" toggle exists on the A7R V — Alfa enables location itself via the
`DD30`/`DD31` handshake after bonding, `docs/08` IT-3.)
