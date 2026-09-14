// swift-tools-version: 6.0
import PackageDescription

// The recorder-facing layer of the iOS app: SOAP payloads, response parsing, code tables, and (later) the
// EPG and logo decoders. It has no UI and no networking, so `swift test` runs it headlessly on the Mac and
// checks it against the language-neutral vectors in docs/port (see docs/porting.md).
let package = Package(
    name: "RecorderKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "RecorderKit", targets: ["RecorderKit"])],
    targets: [
        .target(name: "RecorderKit"),
        .testTarget(name: "RecorderKitTests", dependencies: ["RecorderKit"]),
    ]
)
