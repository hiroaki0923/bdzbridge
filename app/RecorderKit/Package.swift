// swift-tools-version: 6.0
import PackageDescription

// The recorder-facing layer of the iOS app: the client and what it sends and reads, the guide and logo
// decoders, the cache, and the rules the screens and the overnight run share. It has no UI, and its tests stub
// the transport, so `swift test` runs it headlessly on the Mac and checks it against the language-neutral
// vectors in docs/port (see docs/porting.md).
//
// It also builds for Android with the Swift SDK for Android. There zlib and SQLite have no Swift module of
// their own, so each is reached through a module map here: the NDK has zlib, and SQLite, which Android does
// not offer an app, is put on the search paths by whoever builds (see docs/android-port-study.md).
let package = Package(
    name: "RecorderKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "RecorderKit", targets: ["RecorderKit"])],
    targets: [
        .target(name: "RecorderKit", dependencies: [
            .target(name: "CZlib", condition: .when(platforms: [.android])),
            .target(name: "CSQLite", condition: .when(platforms: [.android])),
        ], linkerSettings: [
            // The system's log, which the package writes to on Android in place of Apple's (AppleShims.swift).
            .linkedLibrary("log", .when(platforms: [.android])),
        ]),
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .testTarget(name: "RecorderKitTests", dependencies: ["RecorderKit"]),
    ]
)
