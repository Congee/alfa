import Foundation

/// High-level connection state of the camera link, surfaced to the UI.
public enum CameraConnectionState: Sendable, Equatable {
    case idle
    case scanning
    case connecting
    case connected
    /// Camera is in standby; the engine has deliberately backed off (no standing connect, no auto-reconnect).
    case backedOff
    /// Bluetooth is unavailable (powered off / unauthorized).
    case unavailable

    /// True while the engine is holding or actively pursuing a link.
    public var isActive: Bool {
        switch self {
        case .scanning, .connecting, .connected: true
        case .idle, .backedOff, .unavailable: false
        }
    }
}

/// Events emitted by ``CameraCentral`` as an `AsyncStream`. All associated values are `Sendable`.
public enum CameraEvent: Sendable, Equatable {
    case stateChanged(CameraConnectionState)
    case discovered(peripheralID: UUID, modelCode: String?, rssi: Int)
    case locationPushed(count: Int)
    case failure(String)
}

/// Tunable connection behavior. See `docs/05-battery-strategy.md`.
public struct ConnectionPolicy: Sendable, Equatable {
    /// Minimum movement (meters) before pushing a new location while connected.
    public var minimumDistanceMeters: Double
    /// Keep the link while the camera is powered on (fresh per-shot geotags).
    public var stayConnectedWhileCameraOn: Bool
    /// Never hold a standing `connect()` or auto-reconnect while the camera is in standby.
    public var backOffInStandby: Bool

    public init(
        minimumDistanceMeters: Double,
        stayConnectedWhileCameraOn: Bool,
        backOffInStandby: Bool
    ) {
        self.minimumDistanceMeters = minimumDistanceMeters
        self.stayConnectedWhileCameraOn = stayConnectedWhileCameraOn
        self.backOffInStandby = backOffInStandby
    }

    /// The locked Phase 1 default (decision D4): connected while on, fully backed off in standby.
    public static let balanced = ConnectionPolicy(
        minimumDistanceMeters: 25,
        stayConnectedWhileCameraOn: true,
        backOffInStandby: true
    )
}

/// A `Sendable` location sample fed to the policy and encoded into the Sony location packet.
public struct LocationFix: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var timestamp: Date
    public var horizontalAccuracyMeters: Double

    public init(latitude: Double, longitude: Double, timestamp: Date, horizontalAccuracyMeters: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
    }

    /// Great-circle distance to another fix, in meters (Haversine — pure, dependency-free).
    public func distance(to other: LocationFix) -> Double {
        let earthRadius = 6_371_000.0
        let deg2rad = Double.pi / 180
        let dLat = (other.latitude - latitude) * deg2rad
        let dLon = (other.longitude - longitude) * deg2rad
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * deg2rad) * cos(other.latitude * deg2rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(a)))
    }
}
