import CoreLocation
import Foundation
import Observation
import SonyBLE

/// Orchestrates battery-efficient geotagging: owns the CoreLocation source and drives ``CameraCentral`` under the
/// Balanced policy (decision D4). `@MainActor` and `@Observable` so SwiftUI can bind directly.
///
/// The connection decisions live in the pure `GeotagPolicyEngine` inside `CameraCentral`; this type is the UI-facing
/// façade that pipes location samples in and mirrors engine events out as observable properties.
@MainActor
@Observable
public final class GeotagCoordinator {
    public private(set) var isEnabled = false
    public private(set) var connection: CameraConnectionState = .idle
    public private(set) var lastFix: LocationFix?
    public private(set) var pushCount = 0
    public private(set) var lastError: String?
    public private(set) var locationAuthorized = false

    private let central: CameraCentral
    private let location = LocationProvider()
    private let minimumDistanceMeters: Double
    private var started = false
    private var tasks: [Task<Void, Never>] = []

    public init(policy: ConnectionPolicy = .balanced) {
        central = CameraCentral(policy: policy)
        minimumDistanceMeters = policy.minimumDistanceMeters
        locationAuthorized = location.authorizationStatus.isGranted
    }

    // The pipeline tasks capture `[weak self]` and iterate streams owned by this coordinator; when it deallocates the
    // streams finish and the tasks end, so no explicit `deinit` cancellation is needed (and a `@MainActor deinit`
    // cannot touch `tasks` anyway).

    // MARK: - User intents

    /// Turns geotagging on: starts CoreLocation and the connection engine. The system Bluetooth/Location prompts are
    /// deferred to this point so nothing is requested until the user opts in.
    public func enable() {
        guard !isEnabled else { return }
        isEnabled = true
        startPipelinesIfNeeded()
        location.setDistanceFilter(minimumDistanceMeters)
        location.start()
        Task {
            await central.start()
            await central.setEnabled(true)
        }
    }

    /// Turns geotagging off: stops location updates and tells the engine to disconnect and stay backed off. The
    /// CoreBluetooth manager is left instantiated but idle (no scan, no pending connect) — a good BLE citizen.
    public func disable() {
        guard isEnabled else { return }
        isEnabled = false
        location.stop()
        Task { await central.setEnabled(false) }
    }

    /// Explicit low-frequency trigger to re-establish the link and push the current location.
    public func syncNow() {
        Task { await central.requestSync() }
    }

    /// Forgets the remembered camera; the next enable/sync scans for a camera afresh instead of retrieving it.
    public func forgetCamera() {
        Task { await central.forgetCamera() }
    }

    // MARK: - UI display helpers (keep the app layer free of SonyBLE types)

    public var connectionDescription: String {
        switch connection {
        case .idle: "Idle"
        case .scanning: "Searching…"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .backedOff: "Standby (backed off)"
        case .unavailable: "Bluetooth off"
        }
    }

    public var lastFixDescription: String? {
        guard let lastFix else { return nil }
        return String(
            format: "%.5f, %.5f  (±%.0f m)",
            lastFix.latitude,
            lastFix.longitude,
            lastFix.horizontalAccuracyMeters
        )
    }

    // MARK: - Pipelines

    private func startPipelinesIfNeeded() {
        guard !started else { return }
        started = true

        let events = central.events
        tasks.append(Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        })

        let samples = location.samples
        tasks.append(Task { [weak self] in
            for await fix in samples {
                guard let self else { return }
                self.lastFix = fix
                await self.central.submitLocation(fix)
            }
        })

        let auths = location.authorizations
        tasks.append(Task { [weak self] in
            for await status in auths {
                guard let self else { return }
                self.locationAuthorized = status.isGranted
            }
        })
    }

    private func handle(_ event: CameraEvent) {
        switch event {
        case let .stateChanged(state): connection = state
        case .discovered: break
        case let .locationPushed(count): pushCount = count
        case let .failure(message): lastError = message
        }
    }
}
