// swift-tools-version: 6.0
import PackageDescription

// The app's model over RecorderKit: what the screens share and what the runs with no screen do, with what only
// the platform has handed in (`Surroundings`). It has no UI, so its tests run with `swift test` on a Mac, and
// it builds for Android as RecorderKit does (see docs/android-port-study.md).
let package = Package(
    name: "RecBridgeModel",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RecBridgeModel", targets: ["RecBridgeModel"]),
    ],
    dependencies: [
        .package(path: "../RecorderKit"),
    ],
    targets: [
        .target(name: "RecBridgeModel", dependencies: [
            .product(name: "RecorderKit", package: "RecorderKit"),
        ]),
        .testTarget(name: "RecBridgeModelTests", dependencies: [
            "RecBridgeModel",
            .product(name: "RecorderKit", package: "RecorderKit"),
            // Bench.swift imports it where SQLite3 cannot be imported.
            .product(name: "CSQLite", package: "RecorderKit", condition: .when(platforms: [.android])),
        ]),
    ]
)
