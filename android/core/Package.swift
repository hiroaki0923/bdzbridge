// swift-tools-version: 6.2
// What the Android app calls in Swift: windows over the app's model (RecBridgeModel, beside RecorderKit), whose Java
// side swift-java's JNI mode generates (android/README.md). macOS 26 for Observation's `Observations`, which the
// windows watch the model by; nothing here is built for iOS.
import PackageDescription

let package = Package(
    name: "AndroidBridge",
    platforms: [.macOS(.v26)],
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
                .product(name: "RecBridgeModel", package: "RecorderKit"),
                .product(name: "SwiftJava", package: "swift-java"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            plugins: [.plugin(name: "JExtractSwiftPlugin", package: "swift-java")]
        ),
        .testTarget(name: "AndroidBridgeTests", dependencies: ["AndroidBridge"]),
    ]
)
