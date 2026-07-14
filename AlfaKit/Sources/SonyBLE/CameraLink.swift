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
/// The lifecycle is designed from CoreBluetooth semantics, **not** ported from `Saschl/alpha-gps`: no standing
/// `connect()`, no reconnect inside `didDisconnectPeripheral`, bounded scans only.
final class CameraLink: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "me.congee.alfa.ble", qos: .userInitiated)
    private let onEvent: @Sendable (LinkEvent) -> Void
    private let restoreIdentifier: String
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
    /// Time-sync bytes staged before `CC13` is known (or written the moment it is), so the write survives whichever
    /// order the location- and camera-control services finish discovery in.
    private var pendingTimeSync: [UInt8]?

    private var knownIdentifier: UUID?
    private var handshakeComplete = false
    private var scanTimeout: DispatchWorkItem?
    private var bondRetries = 0
    private var powerNotifyRetries = 0
    /// Whether the app is in the foreground. A background scan can't surface manufacturer data (so the power gate can't
    /// run), so the "saw no advertisement → direct connect" fallback is allowed only in the foreground — otherwise a
    /// background reconnect would blindly re-link to an off-but-connectable camera and drain it.
    private var isForeground = true
    /// Set when the current scan has seen the camera advertising *powered-off* (`0x21` bit `0x40` clear): an
    /// off-but-connectable "Cnct. while Power OFF" camera we must decline rather than hold. Reset when a scan starts.
    private var sawCameraOff = false
    /// Bounded "wait for power-on" timer, armed once the camera is seen advertising off so a foreground scan doesn't run
    /// forever against a camera that just sits there off. Fires → stop scanning and back off.
    private var offWaitTimeout: DispatchWorkItem?
    /// Last camera-on state logged during the current scan, so the raw advertisement is logged on change only (an
    /// `allowDuplicates` scan fires many times a second).
    private var lastAdvCameraOn: Bool?
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

    init(
        restoreIdentifier: String,
        knownIdentifier: UUID?,
        onEvent: @escaping @Sendable (LinkEvent) -> Void
    ) {
        self.restoreIdentifier = restoreIdentifier
        self.knownIdentifier = knownIdentifier
        self.onEvent = onEvent
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
            options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier
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
                    peripheral.discoverServices([SonyCBUUID.locationService, SonyCBUUID.cameraControlService])
                    return
                }
                // The link had dropped (camera in standby, or a connect that never completed). Anti-churn
                // (docs/05 rule 1): do NOT re-issue a standing `connect()` — that pending intent is the background
                // "wake magnet" the whole project exists to avoid. Cancel anything lingering, keep the camera
                // identity for a later explicit Sync, and report a disconnect so the policy backs off.
                log.notice("restore: link dropped — cancelling intent and backing off (no reconnect)")
                if let peripheral { manager.cancelPeripheralConnection(peripheral) }
                clearPeripheralState()
                onEvent(.disconnected)
                return
            }

            // Politeness (docs/05 rule 2): adopt an already-connected peripheral instead of adding a redundant intent.
            let connected = manager.retrieveConnectedPeripherals(withServices: [SonyCBUUID.locationService])
            if let existing = connected.first {
                adoptAndConnect(existing)
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
            guard let peripheral, let writeChar, handshakeComplete else { return }
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
        pendingTimeSync = nil
        handshakeComplete = false
        bondRetries = 0
        powerNotifyRetries = 0
        sawCameraOff = false
        lastAdvCameraOn = nil
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

    /// fw ≥3.02 gate: write `0x01` to DD30 then DD31 (skipped cleanly when the characteristics are absent).
    private func runHandshake() {
        guard let peripheral else { return }
        if let unlockChar { peripheral.writeValue(Data([0x01]), for: unlockChar, type: .withResponse) }
        if let enableChar { peripheral.writeValue(Data([0x01]), for: enableChar, type: .withResponse) }
        handshakeComplete = true
        log.notice("ready — services + handshake complete")
        onEvent(.ready(id: peripheral.identifier, name: peripheral.name))
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
        peripheral.discoverServices([SonyCBUUID.locationService, SonyCBUUID.cameraControlService])
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
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            onEvent(.failure("service discovery failed"))
            return
        }
        for service in services {
            switch service.uuid {
            case SonyCBUUID.locationService:
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
                peripheral.discoverCharacteristics(
                    [SonyCBUUID.cameraPowerState, SonyCBUUID.cameraTimeSync],
                    for: service
                )
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else {
            onEvent(.failure("characteristic discovery failed"))
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
            runHandshake()
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
                default:
                    break
                }
            }
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            onEvent(.failure("write failed: \(error.localizedDescription)"))
            return
        }
        if characteristic.uuid == SonyCBUUID.locationWrite { onEvent(.wroteLocation) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        let bytes = [UInt8](value)
        // Log the raw notify/read value at the lifecycle seam so the camera's actual CC05 power-state behaviour is
        // observable in the device log (Console.app / `log collect`, filter `subsystem:me.congee.alfa`) — the only way
        // to see what the A7R V really reports for standby/power-off without a debugger. CC05/DD01 carry no PII.
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        log.notice("notify \(characteristic.uuid.uuidString, privacy: .public) = \(hex, privacy: .public)")
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
            guard error != nil, bondRetries < Self.maxBondRetries else { return }
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
        default:
            break
        }
    }
}
