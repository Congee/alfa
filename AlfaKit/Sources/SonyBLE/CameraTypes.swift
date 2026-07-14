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

/// System Bluetooth availability, surfaced to the onboarding/permissions UI. Distinct from
/// ``CameraConnectionState`` (which is about the camera link): this is the state of the phone's Bluetooth stack and
/// the app's authorization to use it.
public enum BluetoothAvailability: Sendable, Equatable {
    /// State not yet reported by CoreBluetooth (manager still initializing).
    case unknown
    /// The user has not yet been asked for Bluetooth permission.
    case notDetermined
    /// The user denied (or restricted) Bluetooth permission for Alfa.
    case unauthorized
    /// Bluetooth is turned off in Control Center / Settings.
    case poweredOff
    /// This device has no Bluetooth LE support.
    case unsupported
    /// Bluetooth is on and authorized — ready to use.
    case ready
}

/// Events emitted by ``CameraCentral`` as an `AsyncStream`. All associated values are `Sendable`.
public enum CameraEvent: Sendable, Equatable {
    case stateChanged(CameraConnectionState)
    /// System Bluetooth availability changed (for the permissions/onboarding UI).
    case bluetoothAvailability(BluetoothAvailability)
    case discovered(peripheralID: UUID, modelCode: String?, rssi: Int)
    /// The connected camera's identity (its advertised name), for the UI's camera indicator.
    case cameraIdentified(peripheralID: UUID, name: String?)
    case locationPushed(count: Int)
    case failure(String)
}

/// Tunable connection behavior. See `docs/05-battery-strategy.md`.
public struct ConnectionPolicy: Sendable, Equatable {
    /// Minimum movement (meters) before pushing a new location while connected.
    public var minimumDistanceMeters: Double
    /// Minimum time (seconds) between location pushes while connected. `0` disables the interval throttle (push is
    /// then governed by distance alone). Complements `minimumDistanceMeters` — both gates must clear.
    public var minimumIntervalSeconds: TimeInterval
    /// Keep-alive: the maximum time (seconds) the camera's location fix may go without a refresh before it silently
    /// expires ("Location information cannot be obtained"). Once this elapses since the last write, the next
    /// opportunity re-pushes regardless of movement — while stationary via the heartbeat, while moving via the
    /// location gate (pushing the *fresh* position). `0` disables the keep-alive. Must stay below the camera-side
    /// timeout (`docs/08` IT-11 measures it); default matches Sony's own ~10 s cadence (`docs/07`).
    public var keepAliveSeconds: TimeInterval
    /// Keep the link while the camera is powered on (fresh per-shot geotags).
    public var stayConnectedWhileCameraOn: Bool
    /// Never hold a standing `connect()` or auto-reconnect while the camera is in standby.
    public var backOffInStandby: Bool

    public init(
        minimumDistanceMeters: Double,
        minimumIntervalSeconds: TimeInterval = 0,
        keepAliveSeconds: TimeInterval = 10,
        stayConnectedWhileCameraOn: Bool,
        backOffInStandby: Bool
    ) {
        self.minimumDistanceMeters = minimumDistanceMeters
        self.minimumIntervalSeconds = minimumIntervalSeconds
        self.keepAliveSeconds = keepAliveSeconds
        self.stayConnectedWhileCameraOn = stayConnectedWhileCameraOn
        self.backOffInStandby = backOffInStandby
    }

    /// The locked Phase 1 default (decision D4): connected while on, fully backed off in standby. The interval
    /// throttle is off by default (distance-only), matching the pre-settings behavior; the 10 s keep-alive prevents
    /// the camera from expiring a fix while the phone is stationary or moving slowly.
    public static let balanced = ConnectionPolicy(
        minimumDistanceMeters: 25,
        minimumIntervalSeconds: 0,
        keepAliveSeconds: 10,
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
