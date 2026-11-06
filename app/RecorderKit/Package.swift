// swift-tools-version: 6.0
import PackageDescription

// The recorder-facing layer of the iOS app: the client and what it sends and reads, the guide and logo
// decoders, the cache, and the rules the screens and the overnight run share. It has no UI, and its tests stub
// the transport, so `swift test` runs it headlessly on the Mac and checks it against the language-neutral
// vectors in docs/port (see docs/porting.md).
//
// It also builds for Android with the Swift SDK for Android (see docs/android-port-study.md). There zlib and
// SQLite have no Swift module of their own: the NDK's zlib is reached through a module map here, and SQLite,
// which Android does not offer an app, is built from its own source.
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
        // SQLite 3.54.1 as sqlite.org gives it, the two files of its amalgamation. Only Android's build takes it
        // in: Apple's platforms have their own. A newer one goes in by putting its sqlite3.c and sqlite3.h in
        // place of these.
        .target(name: "CSQLite", cSettings: [
            // An app on Android may write to none of the directories SQLite falls back to for its temporary
            // files (/var/tmp, /usr/tmp, /tmp), so they are kept in memory.
            .define("SQLITE_TEMP_STORE", to: "2"),
        ]),
        .testTarget(name: "RecorderKitTests", dependencies: ["RecorderKit"]),
    ]
)
