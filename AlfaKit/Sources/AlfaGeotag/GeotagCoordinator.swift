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
    /// Advertised name of the camera Alfa is working with. Persists across standby; cleared on disable/forget.
    public private(set) var cameraName: String?
    public private(set) var lastFix: LocationFix?
    public private(set) var pushCount = 0
    public private(set) var lastError: String?
    /// System Bluetooth availability (for the onboarding/permissions UI).
    public private(set) var bluetooth: BluetoothAvailability = .unknown
    /// Location permission state (for the onboarding/permissions UI).
    public private(set) var locationAuthorization: LocationAuthorization
    /// Convenience: whether location is usable for geotagging at all.
    public var locationAuthorized: Bool { locationAuthorization.isGranted }
    /// User-tunable geotag settings (distance, interval, time sync). Persisted; mirrored into the engine.
    public private(set) var settings: GeotagSettings
    /// Whether the user has finished first-run onboarding. Persisted.
    public private(set) var hasCompletedOnboarding: Bool

    private let central: CameraCentral
    private let location = LocationProvider()
    private let settingsStore: GeotagSettingsStore
    private let defaults: UserDefaults
    private var minimumDistanceMeters: Double
    private var started = false
    private var tasks: [Task<Void, Never>] = []

    private static let onboardingKey = "me.congee.alfa.hasCompletedOnboarding"

    public init(
        settingsStore: GeotagSettingsStore = UserDefaultsGeotagSettingsStore(),
        defaults: UserDefaults = .standard
    ) {
        self.settingsStore = settingsStore
        self.defaults = defaults
        let loaded = settingsStore.load()
        settings = loaded
        central = CameraCentral(policy: loaded.policy())
        minimumDistanceMeters = loaded.distanceMeters
        locationAuthorization = location.authorizationStatus.locationAuthorization
        hasCompletedOnboarding = defaults.bool(forKey: Self.onboardingKey)
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
        escalateLocationPermission()
        location.setDistanceFilter(minimumDistanceMeters)
        location.start()
        Task {
            await central.start()
            await applySettingsToCentral()
            await central.setEnabled(true)
        }
    }

    /// Turns geotagging off: stops location updates and tells the engine to disconnect and stay backed off. The
    /// CoreBluetooth manager is left instantiated but idle (no scan, no pending connect) — a good BLE citizen.
    public func disable() {
        guard isEnabled else { return }
        isEnabled = false
        cameraName = nil
        location.stop()
        Task { await central.setEnabled(false) }
    }

    /// Explicit low-frequency trigger to re-establish the link and push the current location.
    public func syncNow() {
        Task { await central.requestSync() }
    }

    // MARK: - Permissions (onboarding)

    /// Triggers the system Bluetooth prompt (by creating the CoreBluetooth manager) and starts observing
    /// availability — **without** enabling geotagging. Used by the onboarding Bluetooth step.
    public func requestBluetooth() {
        startPipelinesIfNeeded()
        Task { await central.start() }
    }

    /// Requests "While Using the App" location access (the first onboarding location step).
    public func requestLocationWhenInUse() {
        location.requestWhenInUse()
    }

    /// Requests the upgrade to "Always" — shown after a successful pair, per Apple's/Geotag Alpha's guidance.
    public func requestLocationAlways() {
        location.requestAlways()
    }

    /// Marks first-run onboarding complete (persisted) so it isn't shown again next launch.
    public func completeOnboarding() {
        hasCompletedOnboarding = true
        defaults.set(true, forKey: Self.onboardingKey)
    }

    // MARK: - Settings

    /// Updates and persists geotag settings, mirroring the change into the engine (thresholds + time sync) and the
    /// CoreLocation distance filter. Safe to call while connected — a threshold change never disturbs a live link.
    public func updateSettings(_ newSettings: GeotagSettings) {
        settings = newSettings
        settingsStore.save(newSettings)
        minimumDistanceMeters = newSettings.distanceMeters
        location.setDistanceFilter(newSettings.distanceMeters)
        Task { await applySettingsToCentral() }
    }

    private func applySettingsToCentral() async {
        await central.setPolicy(settings.policy())
        await central.setTimeSync(clock: settings.syncClock, timeZone: settings.syncTimeZone)
    }

    /// Escalates location permission one step toward Always when geotagging is enabled outside the guided flow.
    private func escalateLocationPermission() {
        switch locationAuthorization {
        case .notDetermined: location.requestWhenInUse()
        case .whenInUse: location.requestAlways()
        case .denied, .always: break
        }
    }

    /// Forgets the current camera: clears its identity immediately (visible feedback) and tells the engine to
    /// disconnect and stop retrieving it. The next enable/sync scans for a camera afresh.
    public func forgetCamera() {
        cameraName = nil
        Task { await central.forgetCamera() }
    }

    /// Loads the remembered camera (if any) so the UI shows it on a cold launch — before the BLE engine is started —
    /// the way Alpha Remote lists a known camera you can see and forget while it's offline.
    public func loadRememberedCameraIfNeeded() async {
        guard cameraName == nil else { return }
        if let remembered = await central.rememberedCamera() {
            cameraName = remembered.name ?? "Sony camera"
        }
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
                self.locationAuthorization = status.locationAuthorization
            }
        })
    }

    private func handle(_ event: CameraEvent) {
        switch event {
        case let .stateChanged(state): connection = state
        case let .bluetoothAvailability(availability): bluetooth = availability
        case .discovered: break
        case let .cameraIdentified(_, name): cameraName = name ?? "Sony camera"
        case let .locationPushed(count): pushCount = count
        case let .failure(message): lastError = message
        }
    }
}
