import CoreLocation
import Foundation
import SonyBLE

extension CLAuthorizationStatus {
    /// Whether location access is usable for geotagging.
    var isGranted: Bool {
        switch self {
        case .authorizedAlways: true
        #if os(iOS) || os(watchOS) || os(tvOS)
        case .authorizedWhenInUse: true
        #endif
        default: false
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

    func start() {
        manager.requestAlwaysAuthorization()
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = true
        #endif
        manager.startUpdatingLocation()
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
