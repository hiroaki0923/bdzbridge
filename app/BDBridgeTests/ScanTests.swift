import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// レコーダーを探す, pressed on a bench: the model as the app makes it at its first launch, with no recorder
/// saved, on a Wi-Fi the test invents (`Bench.joinWiFi`). The search looks round that Wi-Fi's addresses, which
/// are reserved for documentation, and its requests go to the bench's subnet and nowhere else: nothing is put
/// on the network the tests run on.
@MainActor
final class ScanTests: XCTestCase {
    /// The addresses of the Wi-Fi a bench's phone is put on: a /24 without the network's own, the broadcast
    /// address and the phone's. A search asks each once.
    private let addresses = 253

    func testAPressFindsTheRecorderOnTheWiFi() async throws {
        let bench = try aBench()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        let model = bench.modelWithNoRecorder()
        await model.start()

        model.scanForRecorders()
        try await until("the search never ended") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .found(1))
        XCTAssertEqual(model.found.map(\.host), [Bench.host])
        XCTAssertEqual(model.found.first?.udn, NamedRecorder.udn(1))
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        XCTAssertFalse(model.scanBlocked)
        expectEqual(await subnet.asked, addresses, "each address of the subnet is asked once")
    }

    func testAPressThatFindsNobodySaysSo() async throws {
        let bench = try aBench()
        let subnet = bench.joinWiFi()
        let model = bench.modelWithNoRecorder()
        await model.start()

        model.scanForRecorders()
        try await until("the search never ended") { model.scanOutcome != nil }

        XCTAssertEqual(model.scanOutcome, .nothing)
        XCTAssertEqual(model.scanOutcome?.text, "レコーダーが見つかりませんでした")
        XCTAssertEqual(model.found, [])
        XCTAssertNil(model.scanning, "the button was left held back after the search")
        expectEqual(await subnet.asked, addresses, "each address of the subnet is asked once")
    }
}
