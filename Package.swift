// swift-tools-version:6.0
import PackageDescription

// Two targets: ChatPlatformCore has no UIKit and builds and tests on
// Linux as well as Apple platforms; ChatPlatformKit is the UIKit UI on top.
let package = Package(
    name: "ChatPlatformKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ChatPlatformCore", targets: ["ChatPlatformCore"]),
        .library(name: "ChatPlatformKit", targets: ["ChatPlatformKit"]),
    ],
    targets: [
        .target(name: "ChatPlatformCore"),
        .target(
            name: "ChatPlatformKit", dependencies: ["ChatPlatformCore"],
            resources: [.process("Resources")]),
    ],
    swiftLanguageModes: [.v6]
)
