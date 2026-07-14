import CoreBluetooth
import Foundation
import SonyProtocol

/// High-level connection state of a camera link.
public enum CameraConnectionState: Sendable, Equatable {
    case idle
    case scanning
    case connecting
    case connected
    /// Camera is in standby; the engine has deliberately backed off (no standing connect, no auto-reconnect).
    case backedOff
    case unavailable
}

/// Events emitted by ``CameraCentral`` as an `AsyncStream`. All associated values are `Sendable`.
public enum CameraEvent: Sendable, Equatable {
    case stateChanged(CameraConnectionState)
    case discovered(peripheralID: UUID, modelCode: String?, rssi: Int)
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

/// The CoreBluetooth central engine.
///
/// An `actor` that will own a `CBCentralManager` on a dedicated queue and confine all non-`Sendable` `CB*` objects to
/// its executor, emitting only `Sendable` snapshots via ``events``.
///
/// - Important: The connection lifecycle is **not** yet implemented. It must be built directly from the CoreBluetooth
///   semantics in `docs/05-battery-strategy.md` (scan/connect only when needed, disconnect promptly, no standing
///   connect or aggressive reconnect in standby) — **not** ported from `Saschl/alpha-gps`, whose lifecycle reproduces
///   the very drain this project fixes.
public actor CameraCentral {
    public let policy: ConnectionPolicy

    public init(policy: ConnectionPolicy = .balanced) {
        self.policy = policy
    }

    /// Begins observing for the paired camera under the current policy.
    ///
    /// TODO(Phase 1): create `CBCentralManager` (dedicated queue, opt-in state restoration), prefer
    /// `retrieveConnectedPeripherals`, scan filtered by company ID `0x012D`, drive the Balanced state machine.
    public func start() {
        // Intentionally unimplemented — see docs/02-roadmap.md (Phase 1).
    }

    /// Cleanly tears down: cancel pending connections, stop scanning, release the link.
    ///
    /// TODO(Phase 1).
    public func stop() {
        // Intentionally unimplemented — see docs/02-roadmap.md (Phase 1).
    }
}
