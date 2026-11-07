// swift-tools-version: 6.2
// What the Android app calls in Swift: a thin layer over RecorderKit whose Java side swift-java's JNI mode generates
// (android/README.md). Reads only, for now.
import PackageDescription

let package = Package(
    name: "AndroidBridge",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "AndroidBridge", type: .dynamic, targets: ["AndroidBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-java", exact: "0.7.0"),
        .package(path: "../../app/RecorderKit"),
    ],
    targets: [
        .target(
            name: "AndroidBridge",
            dependencies: [
                .product(name: "RecorderKit", package: "RecorderKit"),
                .product(name: "SwiftJava", package: "swift-java"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            plugins: [.plugin(name: "JExtractSwiftPlugin", package: "swift-java")]
        ),
        .testTarget(name: "AndroidBridgeTests", dependencies: ["AndroidBridge"]),
    ]
)
