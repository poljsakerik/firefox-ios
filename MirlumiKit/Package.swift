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
        .macOS(.v14)
    ],
    products: [
        .library(name: "MirlumiKit", targets: ["MirlumiKit"])
    ],
    dependencies: [
        // Runs the image check's model.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2")
    ],
    targets: [
        .target(
            name: "MirlumiKit",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")
            ],
            resources: [
                .process("Resources"),
                // packages/content-rules/generate.mjs and packages/image-check/generate.mjs in the mirlumi repository
                // write these. Don't edit them here.
                .copy("ContentRules/Generated"),
                .copy("ImageCheck/ImageCheckGenerated")
            ]
        ),
        .testTarget(
            name: "MirlumiKitTests",
            dependencies: ["MirlumiKit"],
            exclude: ["Fixtures"]
        )
    ]
)
