import Foundation
import SonyBLE

/// Composition root for the one shared `CameraCentral`: builds the single actor and both `@MainActor` façades
/// around it — ``GeotagCoordinator`` (connection lifecycle + geotagging, unchanged responsibility) and
/// ``RemoteCoordinator`` (Phase 2 remote control, zero lifecycle authority).
///
/// This lives in `AlfaGeotag` because the App layer cannot name `CameraCentral` (it depends only on the
/// `AlfaGeotag` product — the import boundary is enforced in `project.yml`). `AppDelegate` owns one
/// `CameraSession`; the geotag coordinator's single event-consumption loop forwards every event to the remote
/// façade through `remoteEventSink`, keeping the engine's `AsyncStream` at exactly one consumer.
@MainActor
public final class CameraSession {
    public let geotag: GeotagCoordinator
    public let remote: RemoteCoordinator

    public init() {
        let central = CameraCentral()
        let remote = RemoteCoordinator(central: central)
        self.remote = remote
        geotag = GeotagCoordinator(central: central)
        geotag.remoteEventSink = { [weak remote] event in remote?.handle(event) }
    }
}
