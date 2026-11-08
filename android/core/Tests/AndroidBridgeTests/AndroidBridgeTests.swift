import Foundation
import RecBridgeModel
import RecorderKit
import XCTest
@testable import AndroidBridge

/// The windows over the app's model, against the demo's invented recorder: what the Android screens are handed. Each
/// test makes a model of its own on a folder it throws away, as the model's own tests do; nothing reaches the LAN,
/// since nothing here is given an address but the demo's.
final class AndroidBridgeTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    private func demo() async -> RecBridgeApp {
        let app = RecBridgeApp(model: AppModel(surroundings: .android(files: folder.path, version: "0.1 (1)")))
        await app.start()
        await app.devices().enterDemo()
        return app
    }

    /// Waits for what a window shows to come to `done`, reading it as the screen does.
    @MainActor
    private func until<Shown>(_ read: () async -> Shown, _ done: (Shown) -> Bool,
                              file: StaticString = #filePath, line: UInt = #line) async -> Shown {
        for _ in 0..<200 {
            let shown = await read()
            if done(shown) { return shown }
            try? await Task.sleep(for: .milliseconds(25))
        }
        let shown = await read()
        XCTAssertTrue(done(shown), "never came to it", file: file, line: line)
        return shown
    }

    @MainActor
    func testTheDemosGuideIsWordedAsTheIOSListWordsIt() async throws {
        let guide = await demo().guide()
        let shown = await until(guide.read) { $0.shows == "programmes" }
        XCTAssertTrue(shown.demo)
        XCTAssertEqual(shown.broadcasting, "td")
        XCTAssertEqual(shown.heading, "地デジ")
        XCTAssertEqual(shown.station, -1, "every station")
        XCTAssertFalse(shown.stations.isEmpty)
        XCTAssertTrue(shown.broadcastings.contains { $0.code == "bs" && $0.label == Codes.broadcastingLabel["bs"] })
        XCTAssertEqual(shown.days.count, GuideStore.broadcastDays().count)
        XCTAssertEqual(shown.day, 0)
        XCTAssertTrue(shown.programmes.allSatisfy { $0.time.count == 5 && $0.length.hasSuffix("分") })
        XCTAssertGreaterThan(Set(shown.programmes.map(\.station)).count, 1, "every station's programmes")
        let now = Int64(Date().timeIntervalSince1970)
        XCTAssertGreaterThan(shown.programmes.filter { $0.starts <= now && now < $0.ends }.count, 0, "some on air now")

        let first = try XCTUnwrap(shown.programmes.first)
        let sheet = await guide.programme(first.id)
        XCTAssertEqual(sheet?.title, first.title)
        XCTAssertEqual(sheet?.station, first.station)
        XCTAssertTrue(sheet?.starts.hasSuffix(first.time) ?? false)
        let nothing = await guide.programme("none")
        XCTAssertNil(nothing)
    }

    @MainActor
    func testTheGuideFollowsWhatTheReaderChooses() async throws {
        let guide = await demo().guide()
        let today = await until(guide.read) { $0.shows == "programmes" }
        let station = try XCTUnwrap(today.stations.last)

        await guide.chooseStation(station.serviceID)
        let narrowed = await until(guide.read) { $0.station == station.serviceID }
        XCTAssertEqual(narrowed.heading, station.name)
        XCTAssertTrue(narrowed.programmes.allSatisfy { $0.station == station.name })

        await guide.chooseDay(1)
        let tomorrow = await until(guide.read) { $0.day == 1 }
        XCTAssertNotEqual(tomorrow.programmes.first?.id, narrowed.programmes.first?.id)

        await guide.chooseStation(-1)
        await guide.chooseBroadcasting("bs")
        let bs = await until(guide.read) { $0.broadcasting == "bs" && $0.shows == "programmes" }
        XCTAssertEqual(bs.heading, "BS")

        await guide.goToNow()
        let back = await until(guide.read) { $0.day == 0 && $0.nowRequests > tomorrow.nowRequests }
        XCTAssertEqual(back.broadcasting, "bs", "going to now keeps the type")
    }

    @MainActor
    func testAWindowTellsItsListenerOfAChange() async throws {
        let guide = await demo().guide()
        _ = await until(guide.read) { $0.shows == "programmes" }
        let listener = Counting()
        guide.observe(listener)
        _ = await until({ listener.count }) { $0 >= 1 }
        let told = listener.count
        await guide.chooseDay(2)
        _ = await until({ listener.count }) { $0 > told }
        let shown = await guide.read()
        XCTAssertEqual(shown.day, 2, "what it told of is what is read")
    }

    @MainActor
    func testTheDemosReservationsAndRecordingsAreListed() async throws {
        let app = await demo()
        let reservations = app.reservations()
        await reservations.load()
        let listed = await until(reservations.read) { !$0.sections.isEmpty }
        XCTAssertFalse(listed.hasNoRecorder)
        XCTAssertFalse(listed.isEmpty)
        XCTAssertTrue(listed.subtitle.contains("件"))
        XCTAssertTrue(listed.sections.allSatisfy { $0.title.contains("(") && !$0.rows.isEmpty })
        XCTAssertTrue(listed.sections.flatMap(\.rows).allSatisfy { $0.time.count == 5 && !$0.title.isEmpty })

        let recordings = app.recordings()
        await recordings.load()
        let titles = await until(recordings.read) { !$0.rows.isEmpty }
        XCTAssertFalse(titles.hasNoRecorder)
        XCTAssertEqual(titles.subtitle, "\(titles.rows.count) 件")
        XCTAssertTrue(titles.rows.allSatisfy { $0.details.contains("(") && !$0.watched.isEmpty })
    }

    @MainActor
    func testLeavingTheDemoGoesBackToNoRecorder() async throws {
        let app = await demo()
        let devices = app.devices()
        let inDemo = await devices.read()
        XCTAssertTrue(inDemo.demo)
        XCTAssertFalse(inDemo.welcomes)
        // The demo is left only while the model is free to change the recorder, as the button waits on iOS.
        _ = await until(devices.read) { $0.canChoose }
        await devices.leaveDemo()
        let after = await until(devices.read) { !$0.demo }
        XCTAssertTrue(after.welcomes, "nothing was set up before the demo")
        let guide = await until(app.guide().read) { $0.shows == "noRecorder" }
        XCTAssertEqual(guide.noRecorder.kind, "notAdded")
        XCTAssertEqual(guide.noRecorder.said.title, AppModel.notAdded.title)
    }

    @MainActor
    func testATypedAddressIsSaidAsTheIOSFieldSaysIt() {
        let app = RecBridgeApp(model: AppModel(surroundings: .android(files: folder.path, version: "0.1 (1)")))
        let devices = app.devices()
        XCTAssertFalse(devices.typed("").usable)
        XCTAssertEqual(devices.typed("").note, "")
        let wrong = devices.typed("レコーダー")
        XCTAssertFalse(wrong.usable)
        XCTAssertTrue(wrong.warning)
        let port = devices.typed("192.0.2.10:64220")
        XCTAssertTrue(port.usable)
        XCTAssertEqual(port.host, "192.0.2.10")
        XCTAssertTrue(port.note.contains(":64220"))
        let wide = devices.typed("１９２．０．２．１０")
        XCTAssertEqual(wide.host, "192.0.2.10", "full-width digits are taken")
    }
}

final class Counting: ScreenListener, @unchecked Sendable {
    private let lock = NSLock()
    private var told = 0

    var count: Int { lock.withLock { told } }

    func changed() { lock.withLock { told += 1 } }
}
