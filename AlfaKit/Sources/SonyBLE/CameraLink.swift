import CoreBluetooth
import Foundation
import SonyProtocol

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

    /// How long a foreground scan may run before we give up quietly (never hold a scan open indefinitely).
    private static let scanTimeoutSeconds = 12.0
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

    func beginDiscovery() {
        queue.async { [self] in
            guard let manager, manager.state == .poweredOn else { return }
            // Politeness (docs/05 rule 2): adopt an already-connected peripheral instead of adding a redundant intent.
            let connected = manager.retrieveConnectedPeripherals(withServices: [SonyCBUUID.locationService])
            if let existing = connected.first {
                adoptAndConnect(existing)
                return
            }
            if let id = knownIdentifier, let known = manager.retrievePeripherals(withIdentifiers: [id]).first {
                adoptAndConnect(known)
                return
            }
            // Foreground scan; company-ID filtering happens in `didDiscover`. Bounded so no scan is ever left running.
            manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
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
            if peripheral == nil { stopScan() }
        }
        scanTimeout = item
        queue.asyncAfter(deadline: .now() + Self.scanTimeoutSeconds, execute: item)
    }

    private func stopScan() {
        scanTimeout?.cancel()
        scanTimeout = nil
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

    /// fw ≥3.02 gate: write `0x01` to DD30 then DD31 (skipped cleanly when the characteristics are absent).
    private func runHandshake() {
        guard let peripheral else { return }
        if let unlockChar { peripheral.writeValue(Data([0x01]), for: unlockChar, type: .withResponse) }
        if let enableChar { peripheral.writeValue(Data([0x01]), for: enableChar, type: .withResponse) }
        handshakeComplete = true
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
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let restoredPeripheral = restored.first else { return }
        peripheral = restoredPeripheral
        restoredPeripheral.delegate = self
        knownIdentifier = restoredPeripheral.identifier
    }
    #endif

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let manufacturerData = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).map { [UInt8]($0) }
        // Company-ID filter: only Sony advertisements.
        guard let manufacturerData, SonyAdvertisement(manufacturerData: manufacturerData) != nil else { return }
        onEvent(.discovered(
            id: peripheral.identifier,
            name: peripheral.name,
            rssi: RSSI.intValue,
            manufacturerData: manufacturerData
        ))
        // Phase 1 is single-camera: connect to the first Sony device seen, then stop scanning.
        if self.peripheral == nil { adoptAndConnect(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Location service drives geotagging; the Camera Control service (CC05) is a best-effort standby signal.
        peripheral.discoverServices([SonyCBUUID.locationService, SonyCBUUID.cameraControlService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        clearPeripheralState()
        onEvent(.connectFailed)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        // Anti-churn: deliberately do NOT reconnect here. Report and let the policy decide (it backs off).
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
        onEvent(.notify(characteristic: characteristic.uuid.uuidString, value: [UInt8](value)))
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
