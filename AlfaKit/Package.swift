// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlfaKit",
    // .macOS is included so the pure `SonyProtocol` tests run on the host with no device.
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "SonyProtocol", targets: ["SonyProtocol"]),
        .library(name: "SonyBLE", targets: ["SonyBLE"]),
        .library(name: "AlfaGeotag", targets: ["AlfaGeotag"]),
    ],
    targets: [
        // PURE: Foundation only. No CoreBluetooth / CoreLocation.
        .target(name: "SonyProtocol"),
        // CoreBluetooth engine.
        .target(name: "SonyBLE", dependencies: ["SonyProtocol"]),
        // CoreLocation + geotag orchestration.
        .target(name: "AlfaGeotag", dependencies: ["SonyBLE"]),
        .testTarget(name: "SonyProtocolTests", dependencies: ["SonyProtocol"]),
    ]
)
