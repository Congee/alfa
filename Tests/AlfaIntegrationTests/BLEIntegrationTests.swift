import XCTest
@testable import SonyBLE

/// On-device BLE integration tests: the **real** `CameraCentral`/`CameraLink` running on this device, over the real
/// radio, against the `AlfaCameraSim` mock camera running on a nearby Mac. This is the two-radio setup that a single
/// Mac cannot achieve (a lone Mac won't discover its own advertisement).
///
/// These cover the paths a macOS peripheral *can* drive over a live link. A hard power-off that drops the link — and
/// thus the auto-reconnect path — cannot be emulated from a macOS peripheral (the central owns the link and bluetoothd
/// keeps it alive across the peripheral's teardown/exit); that path is covered by the pure-reducer host tests in
/// `SonyBLETests` and, for the real camera's actual behavior, by on-device logs (`docs/08` IT-12). See
/// `Tools/ble-integration/README.md`.
///
/// Skipped unless `ALFA_RUN_BLE_IT=1`, so a normal `xcodebuild test` (or CI with no Mac sim) skips rather than fails.
/// Each test names the `ALFA_SIM_SCRIPT` mode the Mac sim must run in.
final class BLEIntegrationTests: XCTestCase {

    /// Non-persisting bonded store: the tests run inside the Alfa app host process and would otherwise share (and
    /// pollute) the real app's `UserDefaults`-backed remembered camera with the mock's identity.
    private struct EphemeralBondedStore: BondedCameraStore {
        func load() -> RememberedCamera? { nil }
        func save(_ camera: RememberedCamera) {}
        func clear() {}
    }

    private func requireIntegrationEnv() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ALFA_RUN_BLE_IT"] == "1",
            "Set ALFA_RUN_BLE_IT=1 and run AlfaCameraSim (see Tools/ble-integration/README.md) to run this."
        )
        // Accept the mock peripheral (advertises the location service UUID, not Sony manufacturer data). Set before the
        // central creates its CBCentralManager; `CameraLink` reads it via getenv at discovery time.
        setenv("ALFA_TEST_ACCEPT_SIM", "1", 1)
    }

    /// Continuously feeds walking coordinates so each fix clears the distance gate; returns the Task to cancel.
    private func startFeeding(_ central: CameraCentral) -> Task<Void, Never> {
        Task {
            var step = 0.0
            while !Task.isCancelled {
                let fix = LocationFix(
                    latitude: 35.0 + step * 0.001,
                    longitude: 139.0 + step * 0.001,
                    timestamp: Date(),
                    horizontalAccuracyMeters: 5
                )
                await central.submitLocation(fix)
                step += 1
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// Requires the Mac sim in **any** mode (default `ALFA_SIM_SCRIPT=none`). Proves the full connect path over the
    /// real radio: discovery → bond (notify-subscribe) → fw-gated handshake (DD30/DD31) → DD11 location push.
    func testConnectsHandshakesAndPushesLocation() async throws {
        try requireIntegrationEnv()
        let central = CameraCentral(bondedStore: EphemeralBondedStore())

        let connected = expectation(description: "connected to the mock camera")
        let pushed = expectation(description: "pushed a location (DD11 write acknowledged)")

        let monitor = Task {
            for await event in central.events {
                switch event {
                case .stateChanged(let state):
                    NSLog("[IT] stateChanged(\(state))")
                    if state == .connected { connected.fulfill() }
                case .locationPushed(let count):
                    NSLog("[IT] locationPushed(\(count))")
                    if count >= 1 { pushed.fulfill() }
                case .failure(let message):
                    NSLog("[IT] failure(\(message))")
                default:
                    break
                }
            }
        }

        await central.start()
        await central.setEnabled(true)
        let feeder = startFeeding(central)

        await fulfillment(of: [connected, pushed], timeout: 45)

        feeder.cancel()
        monitor.cancel()
        await central.stop()
    }

    /// Requires the Mac sim in **`ALFA_SIM_SCRIPT=standby`** mode (it sends a CC05 power-off notification shortly after
    /// the first location write). Proves the standby-bail path over the real radio: on a CC05 `off` signal the engine
    /// backs off (no standing connect, no auto-reconnect) rather than churning.
    func testBacksOffOnCameraStandby() async throws {
        try requireIntegrationEnv()
        let central = CameraCentral(bondedStore: EphemeralBondedStore())

        let connected = expectation(description: "connected to the mock camera")
        let backedOff = expectation(description: "backed off after CC05 standby")

        let monitor = Task {
            for await event in central.events {
                if case .stateChanged(let state) = event {
                    NSLog("[IT] stateChanged(\(state))")
                    if state == .connected { connected.fulfill() }
                    if state == .backedOff { backedOff.fulfill() }
                }
            }
        }

        await central.start()
        await central.setEnabled(true)
        let feeder = startFeeding(central)

        await fulfillment(of: [connected], timeout: 45)
        await fulfillment(of: [backedOff], timeout: 30)

        feeder.cancel()
        monitor.cancel()
        await central.stop()
    }
}
