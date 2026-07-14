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
6. **Detect on/off, don't guess.** Use the `CC05` power-state characteristic and/or advertisement/notification signals
   to know whether the camera is genuinely on before committing to a persistent link.
7. **Be a single, polite central.** Educate the user that running Alfa alongside Creators'/Imaging Edge/other remote
   apps re-creates the multi-suitor churn — the camera tolerates only one clean active link.

### Consider AccessorySetupKit (OQ3)

iOS 18+ AccessorySetupKit is Apple's power-/privacy-conscious accessory model, and TN3115 (updated for iOS 26) notes
iOS now relaunches non-ASK apps for only a subset of background BLE triggers. Evaluate ASK during Phase 1 on-device
testing; classic `CBCentralManager` + bonding remains the fallback (it is what all prior art uses).

## How we validate the fix

- Baseline: measure camera battery drop (and/or sniff BLE) over a fixed standby window with **no** app.
- With Alfa only: the drop should be indistinguishable from baseline; no Alfa-attributable connect/disconnect churn.
- Regression guard: document the measurement procedure so it can be repeated after connection-engine changes.

## User-facing camera-side hard fixes (document in-app where relevant)

Disabling "Cnct. while Power OFF", turning off "Bluetooth Rmt Ctrl", or Airplane Mode all stop the drain outright, and
**not running competing remote apps simultaneously** is the biggest single win. Alfa should nudge, not fight, these.
