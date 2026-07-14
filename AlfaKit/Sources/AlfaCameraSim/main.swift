import CoreBluetooth
import Foundation
import SonyBLE
import SonyProtocol

#if os(macOS)

/// Logs a line to stdout and flushes immediately — when stdout is redirected to a file (as the integration-test
/// scripts do), the C stdio layer switches to full buffering, which would otherwise delay lines past the point a
/// `grep`-based assertion checks the file.
func simLog(_ message: String) {
    print(message)
    fflush(stdout)
}

/// Decodes the subset of the `DD11` location packet the sim needs for logging (see
/// `Sources/SonyProtocol/LocationPacket.swift` for the authoritative encoder). Byte offsets are relative to the full
/// wire packet (2-byte length header + body), matching `docs/03-ble-protocol.md`.
struct DecodedLocation {
    let latitude: Double
    let longitude: Double
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    let second: Int

    init?(bytes: [UInt8]) {
        guard bytes.count >= 26 else { return nil }
        func int32BE(_ b: ArraySlice<UInt8>) -> Int32 {
            var value: UInt32 = 0
            for byte in b { value = (value << 8) | UInt32(byte) }
            return Int32(bitPattern: value)
        }
        func uint16BE(_ b: ArraySlice<UInt8>) -> UInt16 {
            var value: UInt16 = 0
            for byte in b { value = (value << 8) | UInt16(byte) }
            return value
        }
        latitude = Double(int32BE(bytes[11...14])) / SonyLocationPacket.coordinateScale
        longitude = Double(int32BE(bytes[15...18])) / SonyLocationPacket.coordinateScale
        year = Int(uint16BE(bytes[19...20]))
        month = Int(bytes[21])
        day = Int(bytes[22])
        hour = Int(bytes[23])
        minute = Int(bytes[24])
        second = Int(bytes[25])
    }

    var utcDescription: String {
        String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", year, month, day, hour, minute, second)
    }
}

/// Mock Sony A7R V BLE peripheral. Runs the GATT server side of the location + camera-control services so the real
/// `CameraCentral`/`CameraLink` engine — running on a **separate radio** (an iOS device under `xcodebuild test`) — can
/// be exercised with no physical camera. macOS `CBPeripheralManager` cannot advertise Sony manufacturer data, so this
/// advertises the location service UUID instead; the central accepts that when `ALFA_TEST_ACCEPT_SIM=1` is set
/// (`CameraLink.acceptsTestPeripheral`).
///
/// **A hard power-off (radio-drop) cannot be emulated from here.** On macOS the *central* owns the link and
/// `bluetoothd` keeps it alive even after this peripheral tears down its `CBPeripheralManager` or the process exits
/// (verified on-device: the iPad stayed `connected`, only seeing `didModifyServices`). So this mock covers the paths
/// that don't require the peer's radio to vanish: connect / bond / handshake / location-push, and the **CC05 standby**
/// signal (a notification over the live link, which the engine backs off from). A real link-drop reconnect needs an
/// actual radio-off — see `Tools/ble-integration/README.md`.
final class CameraSim: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "alfa.sim.ble")
    private var manager: CBPeripheralManager!

    /// Held so CC05 notifications can be pushed to subscribed centrals.
    private var powerStateChar: CBMutableCharacteristic!

    private var cameraAwake = true

    private var lastWriteDate: Date?
    private var locationExpired = false
    private let expirySeconds: TimeInterval
    private var expiryTimer: DispatchSourceTimer?

    /// Autonomous scenario driver (`ALFA_SIM_SCRIPT`). `.standby` sends a CC05 power-off notification shortly after the
    /// first location write, so an on-device `xcodebuild test` deterministically observes the standby-bail path (the
    /// engine backs off). `.none` leaves the sim a plain, long-running GATT mock driven by interactive stdin commands.
    enum Script: String { case none, standby }
    private let script: Script
    private var scriptFired = false

    init(expirySeconds: TimeInterval, script: Script) {
        self.expirySeconds = expirySeconds
        self.script = script
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: queue)
    }

    // MARK: - Service setup

    private func startUp() {
        guard manager.state == .poweredOn else { return }
        for service in makeServices() {
            manager.add(service)
        }
        advertise()
        startExpiryTimer()
    }

    private func makeServices() -> [CBMutableService] {
        let locationWriteChar = CBMutableCharacteristic(
            type: SonyCBUUID.locationWrite, properties: [.write], value: nil, permissions: [.writeable]
        )
        let locationUnlockChar = CBMutableCharacteristic(
            type: SonyCBUUID.locationUnlock, properties: [.write], value: nil, permissions: [.writeable]
        )
        let locationEnableChar = CBMutableCharacteristic(
            type: SonyCBUUID.locationEnable, properties: [.write], value: nil, permissions: [.writeable]
        )
        let locationNotifyChar = CBMutableCharacteristic(
            type: SonyCBUUID.locationNotify, properties: [.notify], value: nil, permissions: []
        )
        let locationConfigChar = CBMutableCharacteristic(
            type: SonyCBUUID.locationConfig, properties: [.read], value: nil, permissions: [.readable]
        )

        let locationService = CBMutableService(type: SonyCBUUID.locationService, primary: true)
        locationService.characteristics = [
            locationWriteChar, locationUnlockChar, locationEnableChar, locationNotifyChar, locationConfigChar,
        ]

        powerStateChar = CBMutableCharacteristic(
            type: SonyCBUUID.cameraPowerState,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )
        let timeSyncChar = CBMutableCharacteristic(
            type: SonyCBUUID.cameraTimeSync, properties: [.write], value: nil, permissions: [.writeable]
        )

        let cameraControlService = CBMutableService(type: SonyCBUUID.cameraControlService, primary: true)
        cameraControlService.characteristics = [powerStateChar, timeSyncChar]

        return [locationService, cameraControlService]
    }

    private func powerStateBytes() -> [UInt8] {
        cameraAwake ? [0x04, 0x00, 0x00, 0x00, 0x00] : [0x04, 0x00, 0x00, 0x02, 0x04]
    }

    private func advertise() {
        guard manager.state == .poweredOn else { return }
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [SonyCBUUID.locationService],
            CBAdvertisementDataLocalNameKey: "Alfa Sim A7RV",
        ])
    }

    private func startExpiryTimer() {
        guard expiryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.checkExpiry() }
        timer.resume()
        expiryTimer = timer
    }

    private func checkExpiry() {
        guard let lastWriteDate else { return }
        let elapsed = Date().timeIntervalSince(lastWriteDate)
        if elapsed >= expirySeconds, !locationExpired {
            locationExpired = true
            simLog("[SIM] LOCATION EXPIRED (no DD11 for \(Int(expirySeconds))s)")
        }
    }

    // MARK: - CC05 standby / wake (interactive + scripted; all on `queue`)

    private func sendPowerState(awake: Bool) {
        cameraAwake = awake
        manager.updateValue(Data(powerStateBytes()), for: powerStateChar, onSubscribedCentrals: nil)
        simLog("[SIM] CC05 notify -> \(awake ? "wake (on)" : "standby (off)")")
    }

    func handleCommand(_ raw: String) {
        let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        queue.async { [self] in
            switch command {
            case "standby":
                sendPowerState(awake: false)
            case "wake":
                sendPowerState(awake: true)
            case "status":
                simLog(
                    "[SIM] status cameraAwake=\(cameraAwake) "
                        + "lastWrite=\(lastWriteDate.map(String.init(describing:)) ?? "none") expired=\(locationExpired)"
                )
            case "quit":
                simLog("[SIM] quitting")
                exit(0)
            default:
                simLog("[SIM] unknown command: \(command)")
            }
        }
    }

    /// Runs the autonomous scenario after the first location write, once. Called on `queue` from `handleWrite`.
    private func runScriptIfNeeded() {
        guard script == .standby, !scriptFired else { return }
        scriptFired = true
        simLog("[SIM] SCRIPT standby — sending CC05 power-off notify in 2s")
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.sendPowerState(awake: false)
        }
    }

    // MARK: - Write/read handling

    private func handleWrite(_ request: CBATTRequest) {
        guard let data = request.value else {
            manager.respond(to: request, withResult: .invalidAttributeValueLength)
            return
        }
        let bytes = [UInt8](data)
        switch request.characteristic.uuid {
        case SonyCBUUID.locationWrite:
            let wasExpired = locationExpired
            lastWriteDate = Date()
            locationExpired = false
            if let decoded = DecodedLocation(bytes: bytes) {
                simLog(
                    "[SIM] DD11 write lat=\(decoded.latitude) lon=\(decoded.longitude) "
                        + "utc=\(decoded.utcDescription) bytes=\(bytes.count)"
                )
            } else {
                simLog("[SIM] DD11 write (undecodable) bytes=\(bytes.count)")
            }
            if wasExpired {
                simLog("[SIM] location OBTAINED")
            }
            manager.respond(to: request, withResult: .success)
            runScriptIfNeeded()
            return
        case SonyCBUUID.locationUnlock:
            simLog("[SIM] handshake DD30")
        case SonyCBUUID.locationEnable:
            simLog("[SIM] handshake DD31")
        case SonyCBUUID.cameraTimeSync:
            simLog("[SIM] CC13 clock write")
        default:
            break
        }
        manager.respond(to: request, withResult: .success)
    }

    private func handleRead(_ request: CBATTRequest) {
        switch request.characteristic.uuid {
        case SonyCBUUID.locationConfig:
            request.value = Data([0x01])
            manager.respond(to: request, withResult: .success)
        case SonyCBUUID.cameraPowerState:
            request.value = Data(powerStateBytes())
            manager.respond(to: request, withResult: .success)
        default:
            manager.respond(to: request, withResult: .attributeNotFound)
        }
    }
}

extension CameraSim: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        simLog("[SIM] peripheral manager state=\(peripheral.state.rawValue)")
        if peripheral.state == .poweredOn {
            startUp()
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            simLog("[SIM] didAdd service \(service.uuid) error=\(error.localizedDescription)")
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            simLog("[SIM] advertising failed: \(error.localizedDescription)")
        } else {
            simLog("[SIM] advertising started (service=locationService, name=\"Alfa Sim A7RV\")")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        simLog("[SIM] central subscribed to \(characteristic.uuid.uuidString)")
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        simLog("[SIM] central unsubscribed from \(characteristic.uuid.uuidString)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests { handleWrite(request) }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        handleRead(request)
    }
}

// MARK: - Entry point

let expirySeconds: TimeInterval = {
    if let raw = ProcessInfo.processInfo.environment["ALFA_SIM_EXPIRY_SECONDS"], let value = TimeInterval(raw) {
        return value
    }
    return 30
}()

let script = CameraSim.Script(rawValue: ProcessInfo.processInfo.environment["ALFA_SIM_SCRIPT"] ?? "none") ?? .none

simLog("[SIM] starting AlfaCameraSim (mock Sony A7R V peripheral) script=\(script.rawValue) expiry=\(Int(expirySeconds))s")

let sim = CameraSim(expirySeconds: expirySeconds, script: script)

// Read stdin commands on a background thread (readLine() blocks) and dispatch them onto the sim's BLE queue.
let stdinThread = Thread {
    while let line = readLine(strippingNewline: true) {
        sim.handleCommand(line)
    }
}
stdinThread.name = "alfa.sim.stdin"
stdinThread.start()

RunLoop.main.run()

#else
print("AlfaCameraSim is macOS-only.")
#endif
