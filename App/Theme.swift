import SwiftUI
import UIKit

/// The app-wide design language, derived from the camera body itself: α-mount orange as the single accent,
/// silkscreen-style tracked capitals for micro-labels, monospaced digits wherever data lives. Utility screens stay
/// adaptive (light/dark) and keep the honest List/Form idiom; only deliberate camera-chrome surfaces (the Remote
/// tab, Home's status plate) use the fixed ``CameraBody`` palette.
enum Theme {
    /// α-mount orange, the app accent. The dark value matches the Remote tab's mount ring exactly; the light value
    /// is deepened so filled controls and tinted text hold contrast on white.
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.890, green: 0.447, blue: 0.133, alpha: 1)
            : UIColor(red: 0.769, green: 0.365, blue: 0.075, alpha: 1)
    })
}

/// The camera-body palette — deliberate constants that do **not** adapt to the system theme, exactly as the body's
/// own chrome doesn't. Used by the Remote tab's whole surface and by the small "top plate" status display on Home.
enum CameraBody {
    static let surface = Color(red: 0.063, green: 0.067, blue: 0.071)      // matte magnesium
    static let control = Color(red: 0.110, green: 0.118, blue: 0.125)      // raised button face
    static let controlEdge = Color.white.opacity(0.08)
    static let label = Color(red: 0.604, green: 0.620, blue: 0.639)        // silkscreen gray
    static let text = Color(red: 0.949, green: 0.949, blue: 0.949)
    static let alphaOrange = Color(red: 0.890, green: 0.447, blue: 0.133)  // the α mount ring
    static let recRed = Color(red: 0.898, green: 0.282, blue: 0.302)       // reserved for recording
    static let okGreen = Color(red: 0.388, green: 0.757, blue: 0.455)
}

extension View {
    /// The silkscreen voice: small tracked capitals, as printed beside a camera's own controls. Used for section
    /// eyebrows, state words, and the labels of data readouts — one vocabulary across every screen.
    func silkscreen(_ style: Font.TextStyle = .caption) -> some View {
        self
            .font(.system(style, design: .rounded, weight: .semibold))
            .tracking(1.5)
            .textCase(.uppercase)
    }
}
