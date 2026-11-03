// swift-tools-version: 6.2

// Mirlumi's own features, kept out of upstream files so that a Firefox update rebases a few small hooks.

import PackageDescription

let package = Package(
    name: "MirlumiKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "MirlumiKit", targets: ["MirlumiKit"])
    ],
    targets: [
        .target(
            name: "MirlumiKit",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MirlumiKitTests",
            dependencies: ["MirlumiKit"]
        )
    ]
)
