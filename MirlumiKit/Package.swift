// swift-tools-version: 6.2
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

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
