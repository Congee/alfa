import CoreLocation
import Foundation
import Observation
import SonyBLE
import os

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
    private let log = Logger(subsystem: "me.congee.alfa", category: "coordinator")
    private var minimumDistanceMeters: Double
    private var started = false
    private var tasks: [Task<Void, Never>] = []
    /// Fires the keep-alive re-push while connected (see ``startHeartbeat()``). Nil when not connected.
    private var heartbeatTask: Task<Void, Never>?

    #if DEBUG
    /// Diagnostics (debug builds only): when on, Alfa stops sending **any** location to the camera — real pushes and
    /// keep-alive heartbeats alike — while still receiving fixes locally. Lets the camera-side location-staleness
    /// timeout be measured (`docs/08` test T1) and heartbeat recovery verified (T2) without a code change per run.
    public private(set) var pushesFrozen = false
    #endif
    /// Whether geotagging was enabled when the app was last terminated — the signal to resume on relaunch (including
    /// the background relaunches iOS performs for CoreBluetooth state restoration). Read once at init.
    private let wasEnabledAtLaunch: Bool

    private static let onboardingKey = "me.congee.alfa.hasCompletedOnboarding"
    private static let enabledKey = "me.congee.alfa.geotagEnabled"

    /// Stationary keep-alive cadence. The camera silently expires a location fix that stops being refreshed ("Location
    /// information cannot be obtained"; ~60 s tolerance — user-confirmed, exact number pinned by `docs/08` IT-11), so
    /// while connected the last position is re-pushed after this much write silence. Derived from the policy's
    /// `keepAliveSeconds` (the single source of truth, 45 s) so the timer and the reducer's expiry override can never
    /// disagree. Deliberately independent of the user's update *interval* (that throttles genuine position changes;
    /// this only defeats staleness).
    private static let heartbeatInterval: Duration = .seconds(ConnectionPolicy.balanced.keepAliveSeconds)

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
        wasEnabledAtLaunch = defaults.bool(forKey: Self.enabledKey)
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
        defaults.set(true, forKey: Self.enabledKey) // remembered so a relaunch resumes (state restoration)
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

    /// Non-interactively resumes geotagging after an app relaunch — including the *background* relaunches iOS performs
    /// for CoreBluetooth state restoration — when it was enabled before the app was last terminated. Unlike ``enable()``
    /// it shows **no** permission prompts: it reuses whatever access is already granted and re-creates the CoreBluetooth
    /// central (with the same restore identifier) so `willRestoreState` is delivered and the link is re-adopted or, if
    /// it had dropped, cleanly backed off. Called from the app-launch hook; a no-op unless geotagging was on before.
    public func resumeIfPreviouslyEnabled() {
        guard wasEnabledAtLaunch, !isEnabled else { return }
        log.notice("resuming geotag after relaunch (state restoration)")
        isEnabled = true
        startPipelinesIfNeeded()
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
        defaults.set(false, forKey: Self.enabledKey) // won't resume on the next launch
        cameraName = nil
        location.stop()
        Task { await central.setEnabled(false) }
    }

    /// Explicit low-frequency trigger to re-establish the link and push the current location.
    public func syncNow() {
        Task { await central.requestSync() }
    }

    /// Reports app foreground/background transitions (wire this to `scenePhase`). In the foreground a dropped link is
    /// re-established automatically — so the camera geotags again as soon as it powers back on, without a "Sync now"
    /// tap — and returning to the foreground retries from back-off. Backgrounding cancels any *pending* connect so
    /// none lingers as a wake-magnet, while keeping a live link for background geotagging.
    public func setForeground(_ active: Bool) {
        Task { await central.setForeground(active) }
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

    public var bluetoothDescription: String {
        switch bluetooth {
        case .unknown: "Checking…"
        case .notDetermined: "Not enabled"
        case .unauthorized: "Denied — enable in Settings"
        case .poweredOff: "Turn on Bluetooth"
        case .unsupported: "Unavailable"
        case .ready: "On"
        }
    }

    public var locationAccessDescription: String {
        switch locationAuthorization {
        case .notDetermined: "Not asked"
        case .denied: "Denied — enable in Settings"
        case .whenInUse: "While Using"
        case .always: "Always"
        }
    }

    // MARK: - UI intent helpers (primitive so the app layer never names SonyBLE types)

    /// Bluetooth is on and authorized.
    public var isBluetoothReady: Bool { bluetooth == .ready }
    /// The Bluetooth prompt hasn't been shown yet — `requestBluetooth()` will surface it.
    public var canRequestBluetooth: Bool { bluetooth == .notDetermined || bluetooth == .unknown }

    /// Location is granted at the "Always" level (background geotagging works).
    public var locationIsAlways: Bool { locationAuthorization == .always }
    /// The location prompt hasn't been shown yet — `requestLocationWhenInUse()` will surface it.
    public var canRequestLocation: Bool { locationAuthorization == .notDetermined }
    /// Location was denied/restricted — the user must fix it in Settings.
    public var locationDenied: Bool { locationAuthorization == .denied }

    /// A camera link is fully established.
    public var isConnected: Bool { connection == .connected }
    /// The engine is actively scanning/connecting.
    public var isSearching: Bool { connection == .scanning || connection == .connecting }

    // Settings, as primitives the UI can bind to without importing SonyBLE.
    public var distanceMeters: Double { settings.distanceMeters }
    public var intervalSeconds: TimeInterval { settings.intervalSeconds }
    public var syncClock: Bool { settings.syncClock }
    public var syncTimeZone: Bool { settings.syncTimeZone }

    public func setDistanceMeters(_ meters: Double) {
        var updated = settings; updated.distanceMeters = meters; updateSettings(updated)
    }

    public func setIntervalSeconds(_ seconds: TimeInterval) {
        var updated = settings; updated.intervalSeconds = seconds; updateSettings(updated)
    }

    public func setSyncClock(_ on: Bool) {
        var updated = settings; updated.syncClock = on; updateSettings(updated)
    }

    public func setSyncTimeZone(_ on: Bool) {
        var updated = settings; updated.syncTimeZone = on; updateSettings(updated)
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
                #if DEBUG
                // Diagnostics: keep showing fresh fixes locally but stop sending them, so the camera-side staleness
                // timeout can be measured (T1) — the phone is proven to still have location; only the writes cease.
                if self.pushesFrozen { continue }
                #endif
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
        case let .stateChanged(state):
            connection = state
            // The heartbeat lives no longer than a live link; it is (re)armed by each push below, not here.
            if state != .connected { stopHeartbeat() }
        case let .bluetoothAvailability(availability): bluetooth = availability
        case .discovered: break
        case let .cameraIdentified(_, name): cameraName = name ?? "Sony camera"
        case let .locationPushed(count):
            pushCount = count
            // Every write (real push or keep-alive) pushes the keep-alive deadline back, so the heartbeat only fires
            // after a full interval of silence — i.e. when stationary.
            armHeartbeat()
        case let .failure(message): lastError = message
        }
    }

    // MARK: - Keep-alive heartbeat
    //
    // The camera silently expires a location fix that stops being refreshed ("Location information cannot be
    // obtained"), and signals that expiry over no BLE characteristic — so it can only be prevented, not observed. This
    // is a one-shot timer re-armed after **every** write (via `.locationPushed`): a real position push keeps resetting
    // it, so it only ever fires after a full ``heartbeatInterval`` of silence — i.e. when the phone is stationary. Its
    // own re-push emits `.locationPushed`, which re-arms it, so a motionless link self-sustains at the keep-alive
    // cadence. Foreground-only by construction: a suspended app can't run this timer.

    private func armHeartbeat() {
        #if DEBUG
        guard !pushesFrozen else { return }
        #endif
        guard isConnected else { return }
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            try? await Task.sleep(for: Self.heartbeatInterval)
            guard !Task.isCancelled, let self else { return }
            await self.central.heartbeat()
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    #if DEBUG
    /// Diagnostics (debug builds only): freeze/unfreeze all outgoing location writes for the `docs/08` IT-11 T1/T2
    /// tests. Freezing stops the heartbeat and gates the sample pipeline; unfreezing pushes once immediately (whose
    /// `.locationPushed` re-arms the heartbeat), so recovery without a reconnect can be verified (T2).
    public func setPushesFrozen(_ frozen: Bool) {
        pushesFrozen = frozen
        if frozen {
            stopHeartbeat()
        } else if isConnected {
            Task { await central.heartbeat() }
        }
    }
    #endif
}
