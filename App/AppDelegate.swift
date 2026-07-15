import AlfaGeotag
import UIKit

/// Owns the single ``CameraSession`` and gives CoreBluetooth state restoration a reliable launch hook.
///
/// State restoration requires the `CBCentralManager` to be re-created (with the same restore identifier) during app
/// launch — including the *background* relaunches iOS performs to deliver BLE events after the app was terminated.
/// `application(_:didFinishLaunchingWithOptions:)` is the dependable hook for that: a SwiftUI `.task` is not
/// guaranteed to run promptly on a background launch. When geotagging was on before, we resume non-interactively so
/// `willRestoreState` is delivered and the link is re-adopted (if it survived) or cleanly backed off (if it dropped).
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The one session (shared CameraCentral + both façades) handed to the SwiftUI view tree (see `AlfaApp`).
    let session = CameraSession()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Under `xcodebuild test` the app is only a test host: skip auto-resuming geotagging so the app's own
        // CameraCentral doesn't race the on-device integration test's own central over the mock camera.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            session.geotag.resumeIfPreviouslyEnabled()
        }
        return true
    }
}
