// swift-tools-version: 6.0
import PackageDescription

// Everything pure and testable lives here, so the iOS app, the tvOS app and the
// test suite all run the same compiled code. No UIKit, no SwiftUI, no AppKit.
let package = Package(
    name: "CascadeKit",
    platforms: [.iOS(.v18), .tvOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "CascadeKit", targets: ["CascadeKit"]),
    ],
    targets: [
        .target(name: "CascadeKit"),
        .testTarget(name: "CascadeKitTests", dependencies: ["CascadeKit"]),
    ]
)
