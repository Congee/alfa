import CoreLocation
import Foundation
import SonyBLE

/// Coarse location-permission state for the onboarding/permissions UI.
public enum LocationAuthorization: Sendable, Equatable {
    /// Not yet asked.
    case notDetermined
    /// Denied or restricted — the user must change it in Settings.
    case denied
    /// Granted "While Using the App" — enough to geotag in the foreground; background needs Always.
    case whenInUse
    /// Granted "Always" — background geotagging works after the screen sleeps.
    case always

    /// Usable for geotagging at all (foreground or background).
    public var isGranted: Bool { self == .whenInUse || self == .always }
}

extension CLAuthorizationStatus {
    /// Whether location access is usable for geotagging.
    var isGranted: Bool { locationAuthorization.isGranted }

    /// Maps CoreLocation's status to the coarse ``LocationAuthorization`` the UI needs.
    var locationAuthorization: LocationAuthorization {
        switch self {
        case .authorizedAlways: return .always
        #if os(iOS) || os(watchOS) || os(tvOS)
        case .authorizedWhenInUse: return .whenInUse
        #endif
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }
}

/// Thin CoreLocation wrapper that vends `Sendable` ``LocationFix`` samples and authorization changes as
/// `AsyncStream`s.
///
/// `@unchecked Sendable` is justified by confinement: `CLLocationManager` is created on and used only from the main
/// actor (via the owning ``GeotagCoordinator``), and its delegate callbacks are delivered on the main run loop. The
/// delegate methods touch only the `Sendable`, thread-safe stream continuations — never other mutable state.
final class LocationProvider: NSObject, @unchecked Sendable {
    let samples: AsyncStream<LocationFix>
    let authorizations: AsyncStream<CLAuthorizationStatus>

    private let manager = CLLocationManager()
    private let sampleContinuation: AsyncStream<LocationFix>.Continuation
    private let authContinuation: AsyncStream<CLAuthorizationStatus>.Continuation

    override init() {
        (samples, sampleContinuation) = AsyncStream.makeStream(of: LocationFix.self)
        (authorizations, authContinuation) = AsyncStream.makeStream(of: CLAuthorizationStatus.self)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    func setDistanceFilter(_ meters: Double) {
        manager.distanceFilter = max(meters, 1)
    }

    /// Requests "While Using the App" — the first, low-friction step (per Apple's guidance and Geotag Alpha's flow).
    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    /// Requests the upgrade to "Always", shown after a successful pair when iOS trusts the prompt more.
    func requestAlways() {
        manager.requestAlwaysAuthorization()
    }

    /// Begins location updates. Authorization is requested separately (via `requestWhenInUse`/`requestAlways`) so the
    /// onboarding flow controls prompt timing rather than firing "Always" the instant geotagging is enabled.
    func start() {
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = true
        // Default to iOS's battery-smart auto-pause while no camera is connected. `setContinuous(true)` overrides it
        // for the lifetime of a live link (see below) — the connection state, not this entry point, decides.
        manager.pausesLocationUpdatesAutomatically = true
        #endif
        manager.startUpdatingLocation()
    }

    /// Continuous mode, tied by the coordinator to the camera link. While a camera is **connected**, location must
    /// keep flowing in the background: both to geotag movement and because the keep-alive heartbeat only runs while
    /// the app has runtime — iOS's stationary auto-pause suspends the app, freezing the 45 s re-push mid-session
    /// until the camera's fix expires (field log 2026-07-14: a 4-minute background silence). `true` disables the
    /// auto-pause and re-kicks updates (a pause never undoes itself — Apple requires an explicit restart); `false`
    /// restores the battery-smart default the moment no live camera depends on updates.
    func setContinuous(_ continuous: Bool) {
        #if os(iOS)
        manager.pausesLocationUpdatesAutomatically = !continuous
        #endif
        if continuous { manager.startUpdatingLocation() }
    }

    func stop() {
        manager.stopUpdatingLocation()
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authContinuation.yield(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations where location.horizontalAccuracy >= 0 {
            // CoreLocation replays the last cached fix when updates (re)start; on a background resume that replay can
            // be minutes old. The DD11 packet embeds the fix's timestamp (which the camera may treat as time
            // correction), so a stale replay must never be pushed — a genuinely fresh fix follows within seconds.
            guard Date().timeIntervalSince(location.timestamp) < 60 else { continue }
            sampleContinuation.yield(LocationFix(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                timestamp: location.timestamp,
                horizontalAccuracyMeters: location.horizontalAccuracy
            ))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient CoreLocation errors (e.g. momentarily no fix) are expected; the next update recovers.
    }
}
