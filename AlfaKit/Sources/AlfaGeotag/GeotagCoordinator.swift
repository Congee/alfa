import Foundation
import Observation
import SonyBLE

/// Orchestrates battery-efficient geotagging: owns the CoreLocation source and drives ``CameraCentral`` under the
/// Balanced policy (decision D4). UI-facing and observable.
///
/// - Important: Location acquisition and the connect-while-on / back-off-in-standby state machine are implemented in
///   Phase 1 (see `docs/02-roadmap.md`, `docs/05-battery-strategy.md`). This is the shape the app builds against.
@MainActor
@Observable
public final class GeotagCoordinator {
    public private(set) var isEnabled = false

    private let central: CameraCentral

    public init(policy: ConnectionPolicy = .balanced) {
        central = CameraCentral(policy: policy)
    }

    /// Turns geotagging on. TODO(Phase 1): start location updates and the connection engine.
    public func enable() {
        isEnabled = true
    }

    /// Turns geotagging off. TODO(Phase 1): stop location updates and tear down the link.
    public func disable() {
        isEnabled = false
    }
}
