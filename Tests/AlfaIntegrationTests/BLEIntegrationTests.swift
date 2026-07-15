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

    /// A central isolated from the host app's: an ephemeral bonded store, and **no restore identifier** — the tests
    /// run inside the real Alfa app, and a second central sharing the app's restore ID would be handed (and, backing
    /// off, *cancel*) the app's preserved standing connect from real field use instead of scanning for the sim.
    /// Verified on-device 2026-07-15: exactly that made the connect scenario go `scanning → backedOff` in 20 µs.
    private static func makeTestCentral() -> CameraCentral {
        CameraCentral(bondedStore: EphemeralBondedStore(), restoreIdentifier: nil)
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
        let central = Self.makeTestCentral()

        let connected = expectation(description: "connected to the mock camera")
        let pushed = expectation(description: "pushed a location (DD11 write acknowledged)")

        let monitor = Task {
            for await event in central.events {
                switch event {
                case .stateChanged(let state):
                    NSLog("[IT] stateChanged(\(state))")
                    if state == .connected { connected.fulfill() }
                case .locationPushed(let count, _):
                    NSLog("[IT] locationPushed(\(count))")
                    if count == 1 { pushed.fulfill() } // exact: a second push must not over-fulfill (fatal in XCTest)
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

    /// Feeds the **same** coordinate repeatedly, so after the on-connect push nothing clears the 25 m distance gate —
    /// any further write within the test window can only come from another trigger (e.g. a focus push).
    private func startFeedingStationary(_ central: CameraCentral) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                let fix = LocationFix(
                    latitude: 35.0, longitude: 139.0, timestamp: Date(), horizontalAccuracyMeters: 5
                )
                await central.submitLocation(fix)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Requires the Mac sim in **`ALFA_SIM_SCRIPT=focus`** mode (an FF02 focus-acquired notification shortly after the
    /// first location write, then a shutter-fired pair past the capture throttle). Proves both update-on-focus triggers
    /// over the real radio: each status notify produces an immediate DD11 push even though the phone hasn't moved (the
    /// stationary feeder never clears the distance gate, and the 45 s keep-alive can't fire inside the assertion
    /// windows — so pushes #2 and #3 can only be the focus and shutter pushes).
    func testFocusTriggersImmediatePush() async throws {
        try requireIntegrationEnv()
        let central = Self.makeTestCentral()

        let connected = expectation(description: "connected to the mock camera")
        let pushedOnConnect = expectation(description: "initial on-connect push")
        let pushedOnFocus = expectation(description: "second push triggered by FF02 focus-acquired")
        let pushedOnShutter = expectation(description: "third push triggered by FF02 shutter-fired")

        let monitor = Task {
            for await event in central.events {
                switch event {
                case .stateChanged(let state):
                    NSLog("[IT] stateChanged(\(state))")
                    if state == .connected { connected.fulfill() }
                case .locationPushed(let count, _):
                    NSLog("[IT] locationPushed(\(count))")
                    // Exact matches: `>=` would re-fulfill on the next push, and XCTest treats an over-fulfilled
                    // expectation as a fatal API violation (it crashes the runner — seen on-device 2026-07-15).
                    if count == 1 { pushedOnConnect.fulfill() }
                    if count == 2 { pushedOnFocus.fulfill() }
                    if count == 3 { pushedOnShutter.fulfill() }
                case .failure(let message):
                    NSLog("[IT] failure(\(message))")
                default:
                    break
                }
            }
        }

        await central.start()
        await central.setEnabled(true)
        let feeder = startFeedingStationary(central)

        await fulfillment(of: [connected, pushedOnConnect], timeout: 45)
        await fulfillment(of: [pushedOnFocus], timeout: 20)
        await fulfillment(of: [pushedOnShutter], timeout: 20)

        feeder.cancel()
        monitor.cancel()
        await central.stop()
    }

    /// Requires the Mac sim in **any** mode (default `none`) — the FF01 echoes are write-driven, not scripted.
    /// Proves Phase 2's capture sequence end to end over the real radio: `shutterTapped()` → FF01 half-press → the
    /// sim's focus-ack → FF01 full-press → picture-being-taken (Exposing indicator) → release-through →
    /// shutter-ready (exposure duration recorded). Then a record tap → `02 D5 20` → wire-confirmed recording, and a
    /// second tap stops it.
    func testShutterTapRunsCaptureSequence() async throws {
        try requireIntegrationEnv()
        let central = Self.makeTestCentral()

        let connected = expectation(description: "connected to the mock camera")
        let pushed = expectation(description: "initial on-connect push")
        let exposing = expectation(description: "picture-being-taken observed (exposure started)")
        let exposureFinished = expectation(description: "shutter-ready observed (exposure duration recorded)")
        let recordingStarted = expectation(description: "wire-confirmed recording started")
        let recordingStopped = expectation(description: "wire-confirmed recording stopped")

        let monitor = Task {
            // Transition-guarded fulfillments: remote state re-emits on every field change, so matching a *level*
            // (e.g. exposureStartedAt != nil) would over-fulfill — fatal in XCTest. Track edges instead.
            var wasExposing = false
            var wasRecording = false
            for await event in central.events {
                switch event {
                case .stateChanged(let state):
                    NSLog("[IT] stateChanged(\(state))")
                    if state == .connected { connected.fulfill() }
                case .locationPushed(let count, _):
                    NSLog("[IT] locationPushed(\(count))")
                    if count == 1 { pushed.fulfill() }
                case .remoteControl(let remote):
                    NSLog("[IT] remote(shutter=\(String(describing: remote.shutter)) exposing=\(remote.exposureStartedAt != nil) recording=\(remote.isRecording))")
                    if !wasExposing, remote.exposureStartedAt != nil {
                        wasExposing = true
                        exposing.fulfill()
                    } else if wasExposing, remote.exposureStartedAt == nil, remote.lastExposureSeconds != nil {
                        wasExposing = false
                        exposureFinished.fulfill()
                    }
                    if !wasRecording, remote.isRecording {
                        wasRecording = true
                        recordingStarted.fulfill()
                    } else if wasRecording, !remote.isRecording {
                        wasRecording = false
                        recordingStopped.fulfill()
                    }
                case .failure(let message):
                    NSLog("[IT] failure(\(message))")
                default:
                    break
                }
            }
        }

        await central.start()
        await central.setEnabled(true)
        let feeder = startFeedingStationary(central)

        await fulfillment(of: [connected, pushed], timeout: 45)
        // Give the remote-control service discovery a beat to settle — FF01 is discovered in the same pass as the
        // handshake characteristics but its assignment isn't ordered against `.connected`.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        await central.shutterTapped()
        await fulfillment(of: [exposing], timeout: 15)
        await fulfillment(of: [exposureFinished], timeout: 15)

        await central.recordTapped()
        await fulfillment(of: [recordingStarted], timeout: 15)
        await central.recordTapped()
        await fulfillment(of: [recordingStopped], timeout: 15)

        feeder.cancel()
        monitor.cancel()
        await central.stop()
    }

    /// Requires the Mac sim in **`ALFA_SIM_SCRIPT=standby`** mode (it sends a CC05 power-off notification shortly after
    /// the first location write). Proves the standby-bail path over the real radio: on a CC05 `off` signal the engine
    /// backs off (no standing connect, no auto-reconnect) rather than churning.
    func testBacksOffOnCameraStandby() async throws {
        try requireIntegrationEnv()
        let central = Self.makeTestCentral()

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
