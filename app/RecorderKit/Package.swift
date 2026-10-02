// swift-tools-version: 6.0
import PackageDescription

// The recorder-facing layer of the iOS app: the client and what it sends and reads, the guide and logo
// decoders, the cache, and the rules the screens and the overnight run share. It has no UI, and its tests stub
// the transport, so `swift test` runs it headlessly on the Mac and checks it against the language-neutral
// vectors in docs/port (see docs/porting.md).
let package = Package(
    name: "RecorderKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "RecorderKit", targets: ["RecorderKit"])],
    targets: [
        .target(name: "RecorderKit"),
        .testTarget(name: "RecorderKitTests", dependencies: ["RecorderKit"]),
    ]
)
