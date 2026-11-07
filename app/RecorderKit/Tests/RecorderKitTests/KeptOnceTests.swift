import XCTest
@testable import RecorderKit

/// What the runs with no screen told once, kept between runs in a store handed in (`KeptOnce`).
final class KeptOnceTests: XCTestCase {
    /// A store in memory, as a platform's settings would keep it.
    private final class Store: KeptData, @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [String: Data] = [:]
        func data(forKey key: String) -> Data? { lock.withLock { kept[key] } }
        func set(_ data: Data, forKey key: String) { lock.withLock { kept[key] = data } }
        func removeData(forKey key: String) { lock.withLock { kept[key] = nil } }
    }

    func testWhatIsKeptIsReadBackAndEachDeviceHasItsOwn() {
        let store = Store()
        let told = ToldOnce(stop: .another, rows: ["a", "b"], registration: Date(timeIntervalSince1970: 1_800_000_000))
        KeptOnce.recorder(in: store).keep(told)
        XCTAssertEqual(KeptOnce.recorder(in: store).read(), told)
        XCTAssertNil(KeptOnce.television(in: store).read(), "the television's is kept apart")
        XCTAssertEqual(KeptOnce.recorder(in: store).reading(), told)
        XCTAssertNotNil(store.data(forKey: KeptOnce.recorderKey))
    }

    func testNothingKeptOrNothingReadableIsNothingTold() {
        let store = Store()
        let kept = KeptOnce.television(in: store)
        XCTAssertNil(kept.read())
        XCTAssertEqual(kept.reading(), ToldOnce())
        store.set(Data("not JSON".utf8), forKey: KeptOnce.televisionKey)
        XCTAssertNil(kept.read())
        XCTAssertEqual(kept.reading(), ToldOnce())
    }

    func testForgettingTakesItAway() {
        let store = Store()
        let kept = KeptOnce.recorder(in: store)
        kept.keep(ToldOnce(stop: .disk))
        kept.forget()
        XCTAssertNil(kept.read())
        XCTAssertNil(store.data(forKey: KeptOnce.recorderKey))
    }
}
