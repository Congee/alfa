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
   In the **foreground** this keeps the reconnect safe by never connecting to an off camera. In the **background** the
   power gate can't run (no manufacturer data), so Alfa instead connects and — if the camera turns out to be off —
   holds the link *dormant without writing to it* (the standby hold, below), which is what keeps that path drain-safe.

   > **Why not `CC05`?** The original design bailed on standby via the `CC05` power-state characteristic. On the A7R V
   > (fw 4.0) `CC05` is **silent** — no notification and no read response (verified on-device 2026-07-14, `docs/08`
   > IT-12), and a lever-off produces a plain `disconnected` with no power-off event of any kind. This is universal
   > across the Sony-BLE OSS ecosystem: **no GATT characteristic signals power-off.** The only reliable discriminator is
   > the **advertisement**: `0x21` bit `0x40` reads `0xF0` powered-on and `0xB0` powered-off (verified both directions on
   > the A7R V; independently documented by gethypoxic/whc2001 and used operationally by `ekutner/camera-gps-link`).

   **Foreground vs background.** The gate needs the advertisement's manufacturer data, which iOS delivers only to a
   **foreground** scan. So in the foreground Alfa scans, reads the `0x21` power flags, and connects only to a
   powered-on camera. A background scan can't inspect the advertisement (iOS strips manufacturer data) and can't even
   see a Sony camera reliably (the location service is a 128-bit UUID, not advertised), so the power gate is a
   foreground-only mechanism. Background resume therefore rides a **standing `connect()`**, not a scan.

   **The drain was never the standing connect — it was churning an off camera.** *(Corrected on-device 2026-07-14,
   superseding an earlier "background auto-resume is impossible for a Cnct-ON camera" conclusion.)* A device-log capture
   during a background power-cycle showed the real mechanism: on every reconnect to an off-but-connectable camera Alfa
   ran full service discovery, declared `ready` **before any write was acknowledged**, and pushed location — all of
   which failed (`ready — services + handshake complete` immediately followed by `write FAILED on DD30/DD31/DD11:
   Unknown ATT error`) — then the link dropped and the cycle repeated. That premature-`ready`-then-failed-write **churn**
   was the drain. When the camera was genuinely on, the identical path worked (`location write acked`, steady keep-alives).

   **The fix: acknowledge-gated readiness + a dormant standby hold.** The fw-gated handshake is now **sequential and
   ack-gated**: write `0x01` to DD30 (unlock); only on its acknowledgement write DD31 (enable); only on *its*
   acknowledgement declare `.ready`. A link to a powered-off "Cnct. while Power OFF" camera accepts the connection but
   *rejects* these writes (ATT error), so instead of a false `ready` + failed-push storm the link enters **standby**
   (`CameraLink.enterStandby` → `LinkEvent.standby` → `CameraConnectionState.standby`): it is **held dormant** — no
   writes, no reconnect churn — and re-probes the handshake on a slow timer (`standbyProbeSeconds`, 60 s) and on any
   characteristic notification. The instant the camera powers on, a probe's writes acknowledge (or the camera drops and
   the standing connect re-links to a now-powered-on body) → `.ready` → geotagging resumes. A drop *from* standby
   re-arms the standing connect (`GeotagPolicyEngine` treats `.standby` like `.connected` for reconnect), so power-on
   resume survives even if the dormant link is cycled. Alfa-side churn is eliminated in **any** camera configuration:
   the connection is held quietly rather than being repeatedly re-established and written to. Whether merely *holding*
   a link to a Cnct-ON off camera costs its battery anything is a camera-side property only the IT-10 field
   measurement can settle — with Cnct-OFF the question doesn't arise, because a silent camera has nothing to hold.

   **Field refinement (2026-07-14, second capture): the camera accepts a reconnect before it serves its GATT.** A
   **Cnct-OFF** A7R V goes silent at lever-off, so the standing connect completed only at lever-**on** — but it
   completed in the camera's **boot window**: the radio answered within a second, *before* the Sony services existed,
   and **service discovery returned no Sony service** (a reduced GATT). The link then sat "connected" with nothing to
   handshake against, no error, and nothing to probe: a silent zombie that never became ready and, once the app was
   suspended, could never wake (a dispatch-timer probe doesn't fire in a suspended app). The same reduced-GATT
   behaviour presumably applies to a Cnct-ON off-standby body (unverified). Three mechanisms close this: (1) **every
   connect → ready pipeline is watchdogged** (`discoveryStallSeconds`, 15 s) and a failed / Sony-service-less /
   characteristic-less discovery all converge into the same standby hold; (2) the standby probe **re-runs service
   discovery** when it has no characteristics to handshake with (covers foreground/awake recovery); and (3) — the
   crux for the background — the camera's **Service Changed indication** (`peripheral(_:didModifyServices:)`): once
   booted the camera restores its full GATT, the bonded indication *does* wake a suspended app, and the handler
   re-discovers → handshake acks → `.ready` → geotagging resumes right at the lever-on, not a probe interval later.

   **The "Reconnect in background" toggle (`GeotagSettings.backgroundResume`, default on).** Two kept code paths:
   - **On (default):** on a dropped/dormant link, `CameraLink.beginDiscovery` registers a standing `connect()` to the
     known camera immediately (not via a scan — background scans surface nothing and iOS may suspend us before a scan
     timeout). iOS fulfils it on the camera's next power-on, relaunching Alfa via state restoration; an off camera that
     answers early is held in standby (above) until it powers on.
   - **Off (conservative):** background disconnects back off; resume on foreground / "Sync now" only.

   > **Net for the user:** background auto-resume works functionally with "Cnct. while Power OFF" either on or off.
   > The **proven, Geotag-Alpha-parity configuration is Off**: the camera goes fully silent when the lever is off, so
   > the standing connect waits for free (zero drain *by construction* — there is nothing to hold and nothing to talk
   > to) and iOS completes it the instant the camera powers on. With it **On**, Alfa answers the off camera's link but
   > holds it dormant without a single write, so Alfa adds no churn — but the absolute cost of the held link is a
   > camera-side property pending a field measurement (`docs/08` IT-10). Note Geotag Alpha itself makes no drain-free
   > claim for Cnct-ON (its changelog auto-disables fast reconnect there); do not hold Alfa's Cnct-ON behaviour to a
   > standard no app is known to meet. *(Alfa-side churn eliminated + verified in logs 2026-07-14.)*

### Keep the camera's fix alive while connected (staleness ≠ churn)

Separately from connection churn, the camera **silently expires** a location fix that stops being refreshed (the
"Location information cannot be obtained" overlay) and announces that over no BLE characteristic — so it must be
*prevented*, not reacted to. While connected, Alfa re-pushes the last position on a **45 s** keep-alive
(`ConnectionPolicy.keepAliveSeconds`, the single source of truth for the cadence) whenever nothing else has written for
that long — comfortably inside the camera's ~60 s tolerance (user-confirmed; exact number pinned by `08` IT-11) while
sending ~4–5× fewer writes than Sony's own ~10 s cadence. Driven off the write timeline, so a moving phone that is
already pushing never adds redundant writes. This is orthogonal to the anti-churn rules above: it only ever runs on an
*established* link and never issues a connect.

**The heartbeat needs runtime — so location runs continuously while (and only while) a camera is connected.** iOS's
stationary auto-pause (`pausesLocationUpdatesAutomatically`) suspends the app, freezing the heartbeat timer
mid-session: the 2026-07-14 field log shows a 4-minute background silence that let the camera expire its fix even
though the link was up. `LocationProvider.setContinuous(_:)`, driven by the connection state, disables the auto-pause
(and explicitly restarts updates — a pause never undoes itself) for exactly the lifetime of a `.connected` link, and
restores the battery-smart default in every other state — so the phone-side cost is bounded by the time a camera is
actually on and linked, and an idle background Alfa costs nothing extra. Stale cached fixes CoreLocation replays on a
restart (which can be minutes old and whose embedded timestamp the camera may treat as time correction) are filtered
at the source.

### State restoration is part of the fix, not a loophole in it

Opting into CoreBluetooth state restoration (a restore identifier + `willRestoreState`) is what lets Alfa *decide
about* a standing intent that outlived termination. iOS relaunches the app to service a pending `connect()`; on that
relaunch Alfa re-adopts the peripheral and decides by its actual state and the "Reconnect in background" setting: a
link that **survived** resumes immediately; with background resume **on**, a still-**pending** standing connect is
kept in place (it *is* the auto-resume mechanism — cancelling it would race the very `didConnect` the relaunch may be
delivering) and a **dropped** link re-arms a fresh standing connect; with background resume **off**, the pending
intent is cancelled and the policy backs off. Without restoration, a standing intent held at termination would be
unreachable — neither resumable nor cancellable; with restoration, every relaunch is an opportunity to handle it
deliberately. The enabled state is persisted so the resume is automatic and non-interactive (no permission prompts on
a background launch).

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
