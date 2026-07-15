import CoreBluetooth
import Foundation
import SonyProtocol
import os

/// Low-level events emitted by ``CameraLink`` (all `Sendable`).
enum LinkEvent: Sendable, Equatable {
    case bluetoothAvailability(BluetoothAvailability)
    case discovered(id: UUID, name: String?, rssi: Int, manufacturerData: [UInt8]?)
    /// Services + characteristics discovered and the fw-gated handshake completed. Carries the bonded peripheral's
    /// identifier (remembered for direct retrieval on a later launch) and its advertised name (for the UI indicator).
    case ready(id: UUID, name: String?)
    /// The link is established but the camera is powered off (its handshake writes were rejected): held dormant for
    /// background auto-resume. No location is pushed until the camera powers on and the handshake acknowledges.
    case standby
    case connectFailed
    case disconnected
    case wroteLocation
    case notify(characteristic: String, value: [UInt8])
    case failure(String)
}

/// CoreBluetooth confinement object — the "hands" driven by ``CameraCentral`` (the "brain").
///
/// This is intentionally **not** an actor: CoreBluetooth requires a single serial dispatch queue, and every `CB*`
/// delegate callback arrives on that queue. All mutable state here is confined to `queue`; public command methods hop
/// onto it; only `Sendable` values (`LinkEvent`, byte arrays, UUIDs) ever cross the boundary via `onEvent`. That
/// confinement is the written justification for `@unchecked Sendable` (see `docs/04-architecture.md`).
///
/// The lifecycle is designed from CoreBluetooth semantics, **not** ported from `Saschl/alpha-gps`: reconnects are
/// policy-driven (never issued inside `didDisconnectPeripheral`), foreground scans are bounded, and the only standing
/// `connect()` is the deliberate background auto-resume intent — whose link, if the camera turns out to be off, is
/// held dormant (ack-gated readiness, no writes) instead of being churned.
final class CameraLink: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "me.congee.alfa.ble", qos: .userInitiated)
    private let onEvent: @Sendable (LinkEvent) -> Void
    /// CoreBluetooth state-restoration identifier; `nil` opts out of restoration entirely (used by the on-device
    /// integration tests, whose extra central must not consume — and thereby cancel — the app's preserved intents).
    private let restoreIdentifier: String?
    /// Connection-lifecycle log. Focused on the seams that are otherwise unobservable during a background
    /// state-restoration relaunch (no debugger attaches). Filter in Console.app: `subsystem:me.congee.alfa`.
    private let log = Logger(subsystem: "me.congee.alfa", category: "ble")

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?

    // Location-service characteristics (nil until discovered / absent on older firmware).
    private var writeChar: CBCharacteristic?  // DD11
    private var unlockChar: CBCharacteristic? // DD30
    private var enableChar: CBCharacteristic? // DD31
    private var notifyChar: CBCharacteristic? // DD01

    // Camera Control service characteristics (nil until discovered / absent on some bodies).
    private var powerStateChar: CBCharacteristic? // CC05
    private var timeSyncChar: CBCharacteristic?   // CC13

    // Remote Control service characteristic (nil until discovered / absent on some bodies). Listen-only in Phase 1:
    // FF02 carries focus/shutter status (feeds "update location on focus"); FF01 remote *commands* are Phase 2 and
    // are never written here.
    private var remoteStatusChar: CBCharacteristic? // FF02
    /// Time-sync bytes staged before `CC13` is known (or written the moment it is), so the write survives whichever
    /// order the location- and camera-control services finish discovery in.
    private var pendingTimeSync: [UInt8]?

    private var knownIdentifier: UUID?
    private var handshakeComplete = false
    private var scanTimeout: DispatchWorkItem?
    private var bondRetries = 0
    private var powerNotifyRetries = 0
    private var remoteNotifyRetries = 0
    /// Whether the app is in the foreground. A background scan can't surface manufacturer data (so the power gate can't
    /// run), so the "saw no advertisement → direct connect" fallback is allowed only in the foreground — otherwise a
    /// background reconnect would blindly re-link to an off-but-connectable camera and drain it.
    private var isForeground = true
    /// When true, a dropped established link is re-established by holding a standing `connect()` (fulfilled by iOS on the
    /// camera's next power-on, relaunching us via state restoration if suspended) rather than only the conservative
    /// foreground scan-and-gate. Delivers background auto-resume. A camera that goes silent when off ("Cnct. while
    /// Power OFF" = Off) makes the wait free by construction; one that stays connectable is answered but then held
    /// dormant (`enterStandby`) so Alfa itself writes nothing to it. Mirrors `GeotagSettings.backgroundResume`
    /// (defaults on); re-applied by `CameraCentral.start()`. See `docs/05`.
    private var backgroundResume = false
    /// Set when the current scan has seen the camera advertising *powered-off* (`0x21` bit `0x40` clear): an
    /// off-but-connectable "Cnct. while Power OFF" camera we must decline rather than hold. Reset when a scan starts.
    private var sawCameraOff = false
    /// Bounded "wait for power-on" timer, armed once the camera is seen advertising off so a foreground scan doesn't run
    /// forever against a camera that just sits there off. Fires → stop scanning and back off.
    private var offWaitTimeout: DispatchWorkItem?
    /// Last camera-on state logged during the current scan, so the raw advertisement is logged on change only (an
    /// `allowDuplicates` scan fires many times a second).
    private var lastAdvCameraOn: Bool?
    /// True while the camera is believed bonded: set when the `DD01` notify subscription succeeds, and seeded from
    /// `knownIdentifier` (a camera is only remembered after reaching `.ready`, i.e. after bonding). Lets us tell a
    /// pre-bond write failure (first pairing: retry) from a powered-off camera (enter standby immediately — no point
    /// burning retries against a body that is rejecting every write because it is off).
    private var didBond = false
    /// True while holding a link to a camera that is connected at the BLE layer but powered off (its handshake writes
    /// are rejected). We push nothing and probe slowly for power-on rather than churning the link — the fix for the
    /// standby drain (see `docs/05-battery-strategy.md`).
    private var inStandby = false
    /// Handshake attempts in the current (re)connect, so a pre-bond failure is retried a bounded number of times before
    /// concluding the camera is off.
    private var handshakeAttempts = 0
    /// Slow "is it back on yet?" probe armed while holding a dormant standby link.
    private var standbyProbe: DispatchWorkItem?
    /// Watchdog for the connect → ready pipeline. The A7R V accepts a (re)connect while its Sony GATT is not being
    /// served — field-verified 2026-07-14 in the **power-on boot window** (the radio answers within a second of the
    /// lever, before the services exist; a Cnct-ON off-standby body presumably behaves the same) — and answers
    /// service discovery with a reduced GATT or not at all. Without a watchdog that link sits "connected" forever:
    /// never ready, never failed, never probed (the zombie that ate a background power-cycle in the field). If no
    /// location characteristic has materialized when this fires, the link is held in standby instead.
    private var discoveryStall: DispatchWorkItem?
    /// Set when `willRestoreState` handed us a peripheral on this launch; consumed once by the next `beginDiscovery`,
    /// which either resumes the link (if it survived) or backs off (never blindly reconnects — a restored *pending*
    /// `connect()` is exactly the background "wake magnet" `docs/05` warns about).
    private var didRestore = false

    /// How long a foreground scan may run before we give up quietly (never hold a scan open indefinitely).
    private static let scanTimeoutSeconds = 12.0
    /// How long to keep scanning for a power-on after the camera is seen advertising off, before backing off. Bounds the
    /// foreground battery cost of waiting out a camera the user left off.
    private static let offWaitSeconds = 120.0
    private static let maxBondRetries = 3
    /// Pre-bond handshake retries before concluding the camera is powered off (first-pairing tolerance).
    private static let maxHandshakeRetries = 3
    /// While holding a dormant standby link, re-attempt the handshake this often to catch the camera powering on.
    /// A dispatch timer only fires while the app has runtime, so this covers the foreground/awake case; the
    /// *suspended*-background power-on detector is the camera's Service Changed indication (`didModifyServices`).
    private static let standbyProbeSeconds = 60.0
    /// How long connect → ready may take before the link is presumed to be a powered-off camera (see
    /// ``discoveryStall``). Generous enough for a slow discovery on a genuinely-on body; the watchdog additionally
    /// no-ops once any location characteristic is known, so it can never cut short a slow first-pairing handshake.
    private static let discoveryStallSeconds = 15.0

    init(
        restoreIdentifier: String?,
        knownIdentifier: UUID?,
        onEvent: @escaping @Sendable (LinkEvent) -> Void
    ) {
        self.restoreIdentifier = restoreIdentifier
        self.knownIdentifier = knownIdentifier
        self.onEvent = onEvent
        didBond = knownIdentifier != nil // a remembered camera reached `.ready` before, so it is bonded
        super.init()
    }

    // MARK: - Commands (each hops onto `queue`)

    /// Creates the `CBCentralManager`. Deferred until the user enables geotagging so the system Bluetooth prompt is
    /// not shown prematurely.
    func activate() {
        queue.async { [self] in
            guard manager == nil else { return }
            var options: [String: Any] = [:]
            #if os(iOS)
            if let restoreIdentifier { options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier }
            #endif
            manager = CBCentralManager(delegate: self, queue: queue, options: options)
        }
    }

    func deactivate() {
        queue.async { [self] in
            teardown()
            manager = nil
        }
    }

    /// Tracks app foreground/background so the power gate's fallback stays safe (see ``isForeground``).
    func setForeground(_ active: Bool) {
        queue.async { [self] in isForeground = active }
    }

    /// Toggles the background auto-resume path (standing `connect()` on a dropped link). See ``backgroundResume``.
    func setBackgroundResume(_ enabled: Bool) {
        queue.async { [self] in backgroundResume = enabled }
    }

    func beginDiscovery() {
        queue.async { [self] in
            guard let manager, manager.state == .poweredOn else { return }

            // Resume a state-restored link exactly once, deciding by whether it actually survived the relaunch.
            if didRestore {
                didRestore = false
                if let peripheral, peripheral.state == .connected {
                    // The link survived: re-discover services to repopulate the characteristic handles lost across
                    // the relaunch, re-subscribe to notifications, and re-run the fw-gated handshake — then
                    // geotagging continues as before (`didDiscoverServices` → `runHandshake` → `.ready`).
                    log.notice("restore: link survived — re-discovering services to resume")
                    stopScan()
                    handshakeComplete = false
                    peripheral.discoverServices([SonyCBUUID.locationService, SonyCBUUID.cameraControlService, SonyCBUUID.remoteControlService])
                    scheduleDiscoveryStallTimeout()
                    return
                }
                if !backgroundResume {
                    // Background auto-resume OFF — anti-churn (docs/05 rule 1): do NOT re-issue a standing `connect()`;
                    // a restored *pending* connect is the background "wake magnet" the project exists to avoid. Cancel
                    // anything lingering, keep the camera identity for a later Sync, and report a disconnect (back off).
                    log.notice("restore: link dropped — cancelling intent and backing off (no reconnect)")
                    if let peripheral { manager.cancelPeripheralConnection(peripheral) }
                    clearPeripheralState()
                    onEvent(.disconnected)
                    return
                }
                if let peripheral, peripheral.state == .connecting {
                    // iOS handed back a still-pending standing connect. It is either the intent whose completion we
                    // were relaunched to service (the camera just powered on — `didConnect` is about to fire) or the
                    // intent still waiting for the camera's next power-on. Either way it IS the background auto-resume
                    // mechanism: leave it in place and let `didConnect` drive the rest. Cancelling and re-arming here
                    // would race the in-flight connect and add a pointless disconnect/connect cycle.
                    log.notice("restore: standing connect still pending — keeping it in place")
                    stopScan()
                    return
                }
                // Background auto-resume ON and the link genuinely dropped while we were terminated: re-arm a fresh
                // standing connect to the known identifier (which survives `clearPeripheralState`, unlike the
                // peripheral instance a `didDisconnect` may have nulled).
                log.notice("restore: link dropped — re-establishing (background auto-resume)")
                if let peripheral { manager.cancelPeripheralConnection(peripheral) }
                clearPeripheralState()
                // fall through to the normal discovery logic below
            }

            // Politeness (docs/05 rule 2): adopt an already-connected peripheral instead of adding a redundant intent.
            let connected = manager.retrieveConnectedPeripherals(withServices: [SonyCBUUID.locationService])
            if let existing = connected.first {
                adoptAndConnect(existing)
                return
            }

            // Background auto-resume (opt-in) — decided entirely here in the background; a background scan can't surface
            // manufacturer data (so the power gate can't run) and iOS may suspend us before a scan timeout fires. Hold a
            // standing `connect()` to the known camera so iOS reconnects it on the camera's next power-on (relaunching
            // us via state restoration). We connect regardless of power state: a "Cnct. while Power OFF" camera accepts
            // the link while off, so if it turns out to be off the link is held **dormant** (`enterStandby`) — no
            // writes, no reconnect churn — until the fw-gated handshake acknowledges on power-on. This ack-gating is
            // what keeps the standing connect from draining the camera (the earlier premature-`ready`-then-failed-write
            // storm was the actual drain, verified on-device 2026-07-14; see `docs/05`).
            if backgroundResume, !isForeground {
                if let id = knownIdentifier, let known = manager.retrievePeripherals(withIdentifiers: [id]).first {
                    log.notice("background auto-resume — standing connect to known camera")
                    adoptAndConnect(known)
                } else {
                    log.notice("background auto-resume — no known camera to reconnect; backing off")
                    onEvent(.disconnected)
                }
                return
            }

            // Scan so the advertisement — including the `0x21` power/status bytes — is observed *before* we commit to a
            // connect, instead of a blind `retrievePeripherals()` + `connect()` that re-links to an off-but-connectable
            // "Cnct. while Power OFF" camera and holds it awake. The power gate lives in `didDiscover`. Duplicate reports
            // are enabled (foreground-only; iOS ignores them in the background) so we see the camera's off→on transition
            // and reconnect the instant it powers on. Bounded by `scheduleScanTimeout`.
            sawCameraOff = false
            lastAdvCameraOn = nil
            offWaitTimeout?.cancel()
            offWaitTimeout = nil
            manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            scheduleScanTimeout()
        }
    }

    func disconnect() {
        queue.async { [self] in gracefulDisconnect() }
    }

    /// Forgets the current camera: clears the remembered identifier and gracefully drops the live link. The resulting
    /// `disconnected` event drives the policy to back off, giving the UI immediate, visible feedback.
    func forget() {
        queue.async { [self] in
            knownIdentifier = nil
            gracefulDisconnect()
        }
    }

    func backOff() {
        queue.async { [self] in
            stopScan()
            // Cancel any in-flight (not-yet-established) connection so no standing intent survives into standby.
            if let peripheral, peripheral.state != .connected {
                log.notice("backing off — cancelling pending connect intent")
                manager?.cancelPeripheralConnection(peripheral)
            }
        }
    }

    func writeLocation(_ bytes: [UInt8]) {
        queue.async { [self] in
            guard let peripheral, let writeChar, handshakeComplete else {
                // Field diagnostic: a push arriving before the link is ready to accept it means the camera won't get a
                // fix even though we think we're connected. Log *why* so a "camera has no location" report is traceable.
                log.notice("location push skipped — not ready (peripheral=\(self.peripheral != nil, privacy: .public) writeChar=\(self.writeChar != nil, privacy: .public) handshake=\(self.handshakeComplete, privacy: .public))")
                return
            }
            log.notice("location push → camera (\(bytes.count, privacy: .public) B)")
            peripheral.writeValue(Data(bytes), for: writeChar, type: .withResponse)
        }
    }

    /// Best-effort `CC13` clock sync (beta): stages the bytes and writes them if `CC13` is already known, otherwise
    /// they flush when it is discovered. A clean no-op on bodies that don't expose `CC13`.
    func writeTime(_ bytes: [UInt8]) {
        queue.async { [self] in
            pendingTimeSync = bytes
            flushTimeSync()
        }
    }

    // MARK: - Helpers (all on `queue`)

    private func adoptAndConnect(_ peripheral: CBPeripheral) {
        stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        knownIdentifier = peripheral.identifier
        handshakeComplete = false
        manager?.connect(peripheral, options: nil)
    }

    private func scheduleScanTimeout() {
        scanTimeout?.cancel()
        let item = DispatchWorkItem { [self] in
            guard peripheral == nil, !sawCameraOff else { return } // connecting, or waiting out a known-off camera
            stopScan()
            // The scan surfaced no advertisement at all. In the foreground that means the camera isn't advertising
            // (fully off / out of range, or a body that isn't connectable-while-off), so a direct connect is a harmless
            // standing intent that iOS services on genuine power-on — background wake preserved. In the background the
            // scan simply *can't* see manufacturer data, so we can't have run the power gate; declining to connect
            // avoids blindly re-linking to (and draining) an off-but-connectable camera. Resume then waits for the
            // foreground / an explicit Sync.
            guard isForeground, let id = knownIdentifier,
                  let known = manager?.retrievePeripherals(withIdentifiers: [id]).first else {
                log.notice("scan surfaced no advertisement — backing off (no blind connect)")
                onEvent(.disconnected)
                return
            }
            log.notice("scan surfaced no advertisement — falling back to direct connect (known camera)")
            adoptAndConnect(known)
        }
        scanTimeout = item
        queue.asyncAfter(deadline: .now() + Self.scanTimeoutSeconds, execute: item)
    }

    /// Armed once the camera is seen advertising off: keep scanning (to catch a power-on) but not forever. On expiry,
    /// stop and back off so a foreground scan doesn't burn the phone battery waiting out a camera left switched off.
    private func scheduleOffWaitTimeout() {
        offWaitTimeout?.cancel()
        let item = DispatchWorkItem { [self] in
            guard peripheral == nil else { return }
            log.notice("camera stayed powered-off for \(Int(Self.offWaitSeconds))s — backing off")
            stopScan()
            onEvent(.disconnected)
        }
        offWaitTimeout = item
        queue.asyncAfter(deadline: .now() + Self.offWaitSeconds, execute: item)
    }

    private func stopScan() {
        scanTimeout?.cancel()
        scanTimeout = nil
        offWaitTimeout?.cancel()
        offWaitTimeout = nil
        if manager?.isScanning == true { manager?.stopScan() }
    }

    /// Writes any staged time-sync bytes once `CC13` is known. Called both from `writeTime` and from `CC13` discovery.
    private func flushTimeSync() {
        guard let peripheral, let timeSyncChar, let bytes = pendingTimeSync else { return }
        peripheral.writeValue(Data(bytes), for: timeSyncChar, type: .withResponse)
        pendingTimeSync = nil
    }

    private func clearPeripheralState() {
        peripheral = nil
        writeChar = nil
        unlockChar = nil
        enableChar = nil
        notifyChar = nil
        powerStateChar = nil
        timeSyncChar = nil
        remoteStatusChar = nil
        pendingTimeSync = nil
        handshakeComplete = false
        bondRetries = 0
        powerNotifyRetries = 0
        remoteNotifyRetries = 0
        sawCameraOff = false
        lastAdvCameraOn = nil
        didBond = knownIdentifier != nil // bonding survives a drop; only a forgotten camera resets it
        inStandby = false
        handshakeAttempts = 0
        standbyProbe?.cancel()
        standbyProbe = nil
        discoveryStall?.cancel()
        discoveryStall = nil
    }

    private func gracefulDisconnect() {
        stopScan()
        guard let peripheral else { return }
        // Best-effort graceful close of the fw-gated endpoint before dropping the link.
        if let enableChar { peripheral.writeValue(Data([0x00]), for: enableChar, type: .withResponse) }
        if let unlockChar { peripheral.writeValue(Data([0x00]), for: unlockChar, type: .withResponse) }
        manager?.cancelPeripheralConnection(peripheral)
    }

    private func teardown() {
        stopScan()
        if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
        clearPeripheralState()
    }

    /// Integration-test hook (debug builds, opt-in via env `ALFA_TEST_ACCEPT_SIM=1`; never in the shipping app or a
    /// normal debug launch). A mock camera (`AlfaCameraSim`) can't advertise Sony manufacturer data from macOS
    /// CoreBluetooth, so when active, discovery accepts a peripheral that advertises the Sony **location service UUID**
    /// instead. Read via `getenv` — not `ProcessInfo.environment`, which Foundation may snapshot — so an on-device
    /// XCTest that calls `setenv` before creating the central reliably flips this on.
    private static var testSimModeActive: Bool {
        #if DEBUG
        guard let raw = getenv("ALFA_TEST_ACCEPT_SIM") else { return false }
        return String(cString: raw) == "1"
        #else
        return false
        #endif
    }

    private static func advertisesLocationService(_ advertisementData: [String: Any]) -> Bool {
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
        return advertised?.contains(SonyCBUUID.locationService) ?? false
    }

    /// fw ≥3.02 gate: write `0x01` to DD30 (unlock) then, on its acknowledgement, DD31 (enable). Readiness is declared
    /// **only** when the final write is acknowledged (`didWriteValueFor`) — never optimistically. This is the crux of
    /// the anti-drain fix: a link to a powered-off "Cnct. while Power OFF" camera accepts the connection but *rejects*
    /// these writes (ATT error), so instead of a false `ready` + failed location-push storm, it enters `standby`.
    private func startHandshake() {
        guard let peripheral else { return }
        handshakeComplete = false
        if let unlockChar {
            peripheral.writeValue(Data([0x01]), for: unlockChar, type: .withResponse)
        } else if let enableChar {
            peripheral.writeValue(Data([0x01]), for: enableChar, type: .withResponse)
        } else if writeChar != nil {
            // No fw-gated characteristics on this body: nothing to acknowledge, so it is ready immediately.
            markReady()
        } else {
            // A location service with no usable characteristic at all is the reduced GATT of a powered-off camera —
            // never declare that "ready" (nothing could be pushed anyway); hold it dormant instead.
            log.notice("location service exposes no usable characteristics — camera is powered off; holding link in standby")
            enterStandby()
        }
    }

    /// The handshake was acknowledged (or wasn't needed): the camera is powered on and accepting geotag writes.
    private func markReady() {
        guard let peripheral else { return }
        handshakeComplete = true
        inStandby = false
        handshakeAttempts = 0
        standbyProbe?.cancel()
        standbyProbe = nil
        discoveryStall?.cancel()
        discoveryStall = nil
        log.notice("ready — services + handshake acknowledged")
        onEvent(.ready(id: peripheral.identifier, name: peripheral.name))
    }

    /// A handshake write was rejected. On an already-bonded camera this means it is powered off → hold the link in
    /// standby. When we may not be bonded yet (first pairing), retry a bounded number of times first — the OS pairing
    /// dialog may still be resolving.
    private func handleHandshakeFailure() {
        guard !inStandby, !handshakeComplete else { return }
        if !didBond, handshakeAttempts < Self.maxHandshakeRetries {
            handshakeAttempts += 1
            queue.asyncAfter(deadline: .now() + 3) { [self] in
                guard peripheral != nil, !handshakeComplete, !inStandby else { return }
                startHandshake()
            }
            return
        }
        enterStandby()
    }

    /// Hold a link to a connected-but-powered-off camera without churning it: push nothing, and re-probe on a slow timer
    /// (and on any characteristic notification, `didUpdateValueFor`) so geotagging resumes the moment it powers on.
    private func enterStandby() {
        guard !inStandby else { return }
        inStandby = true
        handshakeComplete = false
        discoveryStall?.cancel()
        discoveryStall = nil
        log.notice("camera connected but not serving/accepting the Sony GATT (powered off or still booting) — holding link in standby (no writes), probing")
        onEvent(.standby)
        scheduleStandbyProbe()
    }

    /// One standby probe: if the off camera never yielded location characteristics (its reduced powered-off GATT),
    /// re-run service discovery — a powered-on camera answers with the full database and the normal path takes over.
    /// Otherwise re-try the handshake: acks → `markReady` (power-on); still rejected → stays in standby.
    private func probeStandby() {
        guard let peripheral, inStandby else { return }
        if writeChar == nil, unlockChar == nil, enableChar == nil {
            log.notice("standby probe — re-running service discovery")
            peripheral.discoverServices([SonyCBUUID.locationService, SonyCBUUID.cameraControlService, SonyCBUUID.remoteControlService])
        } else {
            handshakeAttempts = 0
            startHandshake()
        }
    }

    private func scheduleStandbyProbe() {
        standbyProbe?.cancel()
        let item = DispatchWorkItem { [self] in
            guard peripheral != nil, inStandby else { return }
            probeStandby()
            scheduleStandbyProbe() // keep probing until power-on or disconnect
        }
        standbyProbe = item
        queue.asyncAfter(deadline: .now() + Self.standbyProbeSeconds, execute: item)
    }

    /// Arms the connect → ready watchdog (see ``discoveryStall``). Gated on the location characteristics still being
    /// unknown when it fires, so a discovery that *did* deliver them (and is mid-handshake, e.g. a slow first
    /// pairing) is never cut short — those paths own their own liveness via write acks/errors.
    private func scheduleDiscoveryStallTimeout() {
        discoveryStall?.cancel()
        let item = DispatchWorkItem { [self] in
            guard peripheral != nil, !handshakeComplete, !inStandby else { return }
            guard writeChar == nil, unlockChar == nil, enableChar == nil else { return }
            log.notice("connected but no usable GATT after \(Int(Self.discoveryStallSeconds), privacy: .public)s — camera is powered off; holding link in standby")
            enterStandby()
        }
        discoveryStall = item
        queue.asyncAfter(deadline: .now() + Self.discoveryStallSeconds, execute: item)
    }
}

// MARK: - CBCentralManagerDelegate

extension CameraLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onEvent(.bluetoothAvailability(Self.availability(for: central)))
    }

    /// Maps CoreBluetooth's manager state (+ authorization, to tell "not asked yet" from "denied") to the
    /// coarse ``BluetoothAvailability`` the onboarding UI needs.
    private static func availability(for central: CBCentralManager) -> BluetoothAvailability {
        switch central.state {
        case .poweredOn: return .ready
        case .poweredOff: return .poweredOff
        case .unsupported: return .unsupported
        case .unauthorized: return .unauthorized
        case .resetting, .unknown: return CBManager.authorization == .notDetermined ? .notDetermined : .unknown
        @unknown default: return .unknown
        }
    }

    #if os(iOS)
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // CoreBluetooth relaunched us (foreground or background) to hand back the peripheral(s) it was tracking on
        // our behalf. Re-adopt the first — Phase 1 is single-camera — and re-attach as its delegate so callbacks
        // resume. In-memory characteristic handles were lost across the relaunch; they are re-discovered when the
        // link is resumed. The actual resume-or-back-off decision is deferred to `beginDiscovery` (via `didRestore`),
        // where the manager is guaranteed powered on. `willRestoreState` is delivered *before*
        // `centralManagerDidUpdateState`, so `didRestore` is always set before the reducer can trigger discovery.
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let restoredPeripheral = restored.first else { return }
        peripheral = restoredPeripheral
        restoredPeripheral.delegate = self
        knownIdentifier = restoredPeripheral.identifier
        handshakeComplete = false
        didRestore = true
        log.notice("restore: willRestoreState — \(restored.count) peripheral(s), first state=\(restoredPeripheral.state.rawValue)")
    }
    #endif

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let manufacturerData = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).map { [UInt8]($0) }
        let accept: Bool
        if Self.testSimModeActive {
            // Integration-test mode: accept ONLY the mock peripheral (advertises the location service UUID) and
            // ignore real Sony cameras, so a physical A7R V in range can't win the discovery race during a test.
            accept = Self.advertisesLocationService(advertisementData)
        } else {
            // Company-ID filter: only Sony advertisements.
            accept = manufacturerData.map { SonyAdvertisement(manufacturerData: $0) != nil } ?? false
        }
        guard accept else { return }

        let advertisement = manufacturerData.flatMap { SonyAdvertisement(manufacturerData: $0) }

        // Raw-advertisement log, throttled to power-state changes (an `allowDuplicates` scan fires many times a second)
        // for ongoing field diagnostics: `subsystem:me.congee.alfa`.
        if let mfg = manufacturerData, advertisement?.isCameraOn != lastAdvCameraOn {
            lastAdvCameraOn = advertisement?.isCameraOn
            let hex = mfg.map { String(format: "%02X", $0) }.joined(separator: " ")
            let g21 = advertisement?.powerGroupRaw?.map { String(format: "%02X", $0) }.joined(separator: " ") ?? "—"
            let on = advertisement?.isCameraOn.map { $0 ? "on" : "off" } ?? "?"
            log.notice("adv \(peripheral.name ?? "?", privacy: .public) mfg=[\(hex, privacy: .public)] group21=[\(g21, privacy: .public)] cameraOn=\(on, privacy: .public)")
        }

        onEvent(.discovered(
            id: peripheral.identifier,
            name: peripheral.name,
            rssi: RSSI.intValue,
            manufacturerData: manufacturerData
        ))

        // Power gate (docs/05 reconnect crux, ✅ verified on A7R V fw 4.0): an advertisement reporting the camera OFF
        // (`0x21` bit `0x40` clear) is an off-but-connectable "Cnct. while Power OFF" camera. Connecting would wake it
        // and hold it awake — the exact drain this project fixes — so decline and keep scanning to reconnect the moment
        // it powers on, bounded by `offWaitSeconds`. When the bit is absent (`isCameraOn == nil`: the test sim or an
        // older/other body) we fall through and connect, preserving prior behaviour.
        if advertisement?.isCameraOn == false {
            if !sawCameraOff {
                sawCameraOff = true
                log.notice("advertisement reports camera OFF — declining connect (anti-drain), waiting up to \(Int(Self.offWaitSeconds))s for power-on")
                scanTimeout?.cancel() // supersede the short "no advertisement" timeout with the bounded off-wait
                scanTimeout = nil
                scheduleOffWaitTimeout()
            }
            return
        }

        // Phase 1 is single-camera: connect to the first powered-on Sony device seen, then stop scanning.
        if self.peripheral == nil { adoptAndConnect(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Location service drives geotagging; the Camera Control service (CC05) is a best-effort standby signal.
        log.notice("connected — discovering services")
        peripheral.discoverServices([SonyCBUUID.locationService, SonyCBUUID.cameraControlService, SonyCBUUID.remoteControlService])
        scheduleDiscoveryStallTimeout()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.notice("connect failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        clearPeripheralState()
        onEvent(.connectFailed)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        // Anti-churn: deliberately do NOT reconnect here. Report and let the policy decide (it backs off).
        log.notice("disconnected: \(error?.localizedDescription ?? "clean", privacy: .public)")
        clearPeripheralState()
        onEvent(.disconnected)
    }
}

// MARK: - CBPeripheralDelegate

extension CameraLink: CBPeripheralDelegate {
    /// The camera's GATT database changed. On the A7R V this is the **power seam**: during power transitions (the
    /// boot window right after lever-on, the shutdown tail — and presumably Cnct-ON off-standby) the body serves a
    /// reduced database without the Sony services; once fully on it restores them and the bonded Service Changed
    /// indication lands here — waking even a *suspended* app, which makes this THE background power-on detector for a
    /// held standby link (the dispatch-timer probe cannot fire while suspended). Invalidate the stale handles and
    /// re-discover: a serving camera answers → handshake → ready; a still-dark one converges back to standby via the
    /// discovery-stall watchdog.
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        log.notice("services modified (\(invalidatedServices.count, privacy: .public) invalidated) — re-discovering")
        writeChar = nil
        unlockChar = nil
        enableChar = nil
        notifyChar = nil
        powerStateChar = nil
        timeSyncChar = nil
        remoteStatusChar = nil
        handshakeComplete = false
        peripheral.discoverServices([SonyCBUUID.locationService, SonyCBUUID.cameraControlService, SonyCBUUID.remoteControlService])
        scheduleDiscoveryStallTimeout()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            // A camera that is not serving its GATT yet (boot window / off-standby) can fail discovery outright.
            // That is the dormant case, not a terminal failure — Service Changed / the standby probe recovers.
            log.notice("service discovery failed (\(error?.localizedDescription ?? "no services", privacy: .public)) — holding link in standby")
            enterStandby()
            return
        }
        var foundLocationService = false
        for service in services {
            switch service.uuid {
            case SonyCBUUID.locationService:
                foundLocationService = true
                peripheral.discoverCharacteristics(
                    [
                        SonyCBUUID.locationWrite,
                        SonyCBUUID.locationUnlock,
                        SonyCBUUID.locationEnable,
                        SonyCBUUID.locationNotify,
                        SonyCBUUID.locationConfig,
                    ],
                    for: service
                )
            case SonyCBUUID.cameraControlService:
                var controlCharacteristics = [SonyCBUUID.cameraPowerState, SonyCBUUID.cameraTimeSync]
                #if DEBUG
                // Battery probe (docs/03): CC10 "Battery Information" is a doc-only lead with zero working code
                // behind it anywhere in the OSS ecosystem. Debug builds probe it (read + log raw bytes) so a real
                // connect settles whether the path exists; nothing is built on it until it returns plausible data.
                controlCharacteristics.append(SonyCBUUID.cameraBatteryInfo)
                #endif
                peripheral.discoverCharacteristics(controlCharacteristics, for: service)
            case SonyCBUUID.remoteControlService:
                // FF02 only — the status feed for "update location on focus". FF01 (commands) is Phase 2.
                peripheral.discoverCharacteristics([SonyCBUUID.remoteStatus], for: service)
            default:
                break
            }
        }
        if !foundLocationService {
            // The camera's reduced GATT (field-verified on the A7R V 2026-07-14: the body accepted the reconnect in
            // its power-on boot window and answered discovery without any Sony service, leaving a silent "connected"
            // zombie before this branch existed). Hold dormant; Service Changed / the probe picks up the full GATT.
            log.notice("no location service in GATT (\(services.count, privacy: .public) service(s)) — camera not serving Sony GATT yet; holding link in standby")
            enterStandby()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else {
            // Same dormant-case treatment as a failed service discovery — but only the location service is
            // load-bearing; a Camera Control hiccup alone must not park an otherwise viable link in standby.
            if service.uuid == SonyCBUUID.locationService {
                log.notice("characteristic discovery failed on the location service — holding link in standby")
                enterStandby()
            }
            return
        }
        switch service.uuid {
        case SonyCBUUID.locationService:
            for characteristic in characteristics {
                switch characteristic.uuid {
                case SonyCBUUID.locationWrite: writeChar = characteristic
                case SonyCBUUID.locationUnlock: unlockChar = characteristic
                case SonyCBUUID.locationEnable: enableChar = characteristic
                case SonyCBUUID.locationNotify: notifyChar = characteristic
                default: break
                }
            }
            // Bonding trick (docs/03): subscribing to a notify characteristic triggers the OS pairing dialog.
            if let notifyChar { peripheral.setNotifyValue(true, for: notifyChar) }
            handshakeAttempts = 0
            startHandshake()
        case SonyCBUUID.cameraControlService:
            for characteristic in characteristics {
                switch characteristic.uuid {
                case SonyCBUUID.cameraPowerState:
                    powerStateChar = characteristic
                    // Best-effort standby signal: subscribe and read the initial value. May need bonding first
                    // (retried in didUpdateNotificationStateFor); absence is fine — geotagging still works.
                    peripheral.setNotifyValue(true, for: characteristic)
                    peripheral.readValue(for: characteristic)
                case SonyCBUUID.cameraTimeSync:
                    // Best-effort clock sync (beta): flush any staged time packet now that CC13 is known.
                    timeSyncChar = characteristic
                    flushTimeSync()
                #if DEBUG
                case SonyCBUUID.cameraBatteryInfo:
                    // Battery probe: read + subscribe and let the generic didUpdateValueFor hex log capture whatever
                    // comes back. Purely observational — no state is kept and nothing downstream consumes it.
                    log.notice("CC10 battery probe: present, properties 0x\(String(characteristic.properties.rawValue, radix: 16), privacy: .public) — reading")
                    if characteristic.properties.contains(.notify) { peripheral.setNotifyValue(true, for: characteristic) }
                    if characteristic.properties.contains(.read) { peripheral.readValue(for: characteristic) }
                #endif
                default:
                    break
                }
            }
            #if DEBUG
            if !characteristics.contains(where: { $0.uuid == SonyCBUUID.cameraBatteryInfo }) {
                // The probe's negative result matters as much as a hit: absence on the real body closes the
                // battery-display question for good (docs/03).
                log.notice("CC10 battery probe: absent from Camera Control service")
            }
            #endif
        case SonyCBUUID.remoteControlService:
            for characteristic in characteristics where characteristic.uuid == SonyCBUUID.remoteStatus {
                // Focus/shutter status feed. Subscribing is listen-only and safe whatever the camera's Bluetooth
                // remote-control setting: when it's off the camera stays silent or reports `02 C3 00` (docs/03) —
                // absence of the whole service is equally fine, geotagging works without it.
                remoteStatusChar = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log.notice("write FAILED on \(characteristic.uuid.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if !handshakeComplete {
                // A handshake write rejected before we ever went ready: a bonded camera that refuses writes is powered
                // off ("Cnct. while Power OFF"). Hold in standby instead of declaring a false "connected" and pushing
                // location into the void — that premature-ready + failed-push storm was the standby drain (docs/05).
                handleHandshakeFailure()
            } else {
                // A push/keep-alive write failed on a live link — surface it (the link likely just dropped).
                onEvent(.failure("write failed: \(error.localizedDescription)"))
            }
            return
        }
        if !handshakeComplete {
            // Advance the ack-gated handshake: unlock (DD30) acked → enable (DD31); enable acked → ready.
            switch characteristic.uuid {
            case SonyCBUUID.locationUnlock:
                if let enableChar {
                    peripheral.writeValue(Data([0x01]), for: enableChar, type: .withResponse)
                } else {
                    markReady()
                }
            case SonyCBUUID.locationEnable:
                markReady()
            default:
                break
            }
            return
        }
        if characteristic.uuid == SonyCBUUID.locationWrite {
            log.notice("location write acked")
            onEvent(.wroteLocation)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        #if DEBUG
        if characteristic.uuid == SonyCBUUID.cameraBatteryInfo, let error {
            // The probe's error result is diagnostic (e.g. "read not permitted" vs an auth error) — the generic
            // guard below would swallow it silently.
            log.notice("CC10 battery probe: read FAILED — \(error.localizedDescription, privacy: .public)")
            return
        }
        #endif
        guard error == nil, let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        // Log the raw notify/read value at the lifecycle seam so the camera's actual CC05 power-state behaviour is
        // observable in the device log (Console.app / `log collect`, filter `subsystem:me.congee.alfa`) — the only way
        // to see what the A7R V really reports for standby/power-off without a debugger. CC05/DD01 carry no PII.
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        log.notice("notify \(characteristic.uuid.uuidString, privacy: .public) = \(hex, privacy: .public)")
        // A notification while holding a dormant standby link means the camera is alive again (powering on) — probe
        // immediately rather than waiting for the slow standby timer.
        if inStandby {
            log.notice("standby: notification received — probing (possible power-on)")
            probeStandby()
        }
        onEvent(.notify(characteristic: characteristic.uuid.uuidString, value: bytes))
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // An ATT auth/encryption error here means bonding is required; iOS shows the dialog and re-invokes once bonded.
        // A few spaced retries cover transient authentication errors (docs/03 pairing trick). Retries are
        // per-characteristic: DD01 is the bonding trigger, CC05 is the best-effort standby signal.
        switch characteristic.uuid {
        case SonyCBUUID.locationNotify:
            if error == nil { didBond = true; return } // subscription succeeded ⇒ the camera is bonded
            guard bondRetries < Self.maxBondRetries else { return }
            bondRetries += 1
            queue.asyncAfter(deadline: .now() + 3) { [self] in
                if let notifyChar { self.peripheral?.setNotifyValue(true, for: notifyChar) }
            }
        case SonyCBUUID.cameraPowerState:
            guard error != nil, powerNotifyRetries < Self.maxBondRetries else { return }
            powerNotifyRetries += 1
            queue.asyncAfter(deadline: .now() + 3) { [self] in
                if let powerStateChar {
                    self.peripheral?.setNotifyValue(true, for: powerStateChar)
                    self.peripheral?.readValue(for: powerStateChar)
                }
            }
        case SonyCBUUID.remoteStatus:
            guard error != nil, remoteNotifyRetries < Self.maxBondRetries else { return }
            remoteNotifyRetries += 1
            queue.asyncAfter(deadline: .now() + 3) { [self] in
                if let remoteStatusChar { self.peripheral?.setNotifyValue(true, for: remoteStatusChar) }
            }
        default:
            break
        }
    }
}
