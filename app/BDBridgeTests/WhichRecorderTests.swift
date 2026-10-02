import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// Which recorder the app is talking to, and what the phone keeps of one when another answers.
///
/// The address is only where to knock: a recorder is known by what it says it is (its UDN). The same one
/// keeps everything the phone holds of it wherever it answers. Another one -- chosen by the reader, or found
/// at the address the first had -- gets nothing that was the first's: not its lists, which name recordings
/// by numbers each recorder gives out for itself, and not what the phone kept of it. What the reader chose
/// and what is on screen meanwhile is `SessionRuleTests`' ("another recorder"); this is what happens once
/// somebody has answered.
///
/// Two recorders here hold the same recordings under the same numbers, which is the case that matters: a row
/// or a text left from the first would stand for another recording on the second.
///
/// The tests are in four files beside this one, which holds what they share: the recorder the phone knows
/// (`WhichRecorderSameTests.swift`), another recorder taking its place (`WhichRecorderAnotherTests.swift`),
/// another heard by the check before an operation (`WhichRecorderCheckTests.swift`), and the paths with no
/// screen (`WhichRecorderNoScreenTests.swift`).
@MainActor
final class WhichRecorderTests: XCTestCase {
    // MARK: - what the tests start from

    /// The recording whose text is put in the cache, by `connected` or by the test itself.
    var recording = ""

    /// When the overnight run is on record as having last fetched (`leaveMarks`).
    static let lastNight = "2026-09-30T02:00:00+09:00"

    /// The MAC the first recorder's UDN carries (`NamedRecorder.udn(1)`).
    static let firstsMAC = "f8:4e:17:00:00:01"

    /// A model connected to the recorder at `Bench.host`, with its recordings and keyword conditions read,
    /// one recording's text in the cache, and on record a low-space warning and an overnight fetch.
    func connected(_ bench: Bench, at places: [String: any HTTPTransport]) async throws -> AppModel {
        try await bench.cacheAGuide()
        leaveMarks(in: bench)
        let model = bench.model(recorders: places)
        await model.start()
        try await untilConnected(model)
        await model.loadTitles()
        await model.loadRecorderRules()
        XCTAssertFalse(model.titles.isEmpty)
        XCTAssertFalse(model.reservations.isEmpty)
        XCTAssertFalse(model.recorderRules.isEmpty)
        recording = try XCTUnwrap(model.titles.first).id
        try await store(bench).setTitleSummary(recording, "あらすじ")
        return model
    }

    /// The usual start: a bench, the first recorder at `Bench.host`, and a model connected to it as `connected`
    /// leaves one. `wakeable` saves the MAC its UDN carries beforehand, so that the model can wake it;
    /// `waiting` puts a reservation in the queue once the lists are read.
    func atHome(wakeable: Bool = false, waiting: Bool = false) async throws
        -> (bench: Bench, recorder: NamedRecorder, model: AppModel) {
        let bench = try aBench()
        if wakeable { bench.keep(mac: Self.firstsMAC) }
        let recorder = NamedRecorder(1)
        let model = try await connected(bench, at: [Bench.host: recorder])
        if waiting { try await queueAReservation(bench, model) }
        return (bench, recorder, model)
    }

    /// What the defaults keep about one recorder's disk and guide: that a low-space warning was given, and
    /// when the overnight run last fetched.
    func leaveMarks(in bench: Bench) {
        bench.defaults.set(true, forKey: DefaultsKey.warnedLowSpace)
        bench.defaults.set(Self.lastNight, forKey: DefaultsKey.lastBackgroundRefresh)
    }

    func store(_ bench: Bench) throws -> GuideStore {
        try GuideStore(path: bench.guidePath)
    }

    /// A programme from the cached guide that starts an hour or more from now: the first, or the one after
    /// as many as `skipping`.
    func aProgramme(_ model: AppModel, skipping: Int = 0) async throws -> GuideProgramRow {
        let later = Date().addingTimeInterval(3600)
        let found = await model.search("サンプル").hits.filter { $0.program.start > later }.dropFirst(skipping).first
        return try XCTUnwrap(found?.program, "the cached guide had nothing more an hour or more ahead")
    }

    /// Puts a reservation for it in the queue, as the app queues one away from home.
    func queueAReservation(_ bench: Bench, _ model: AppModel) async throws {
        let program = try await aProgramme(model)
        let request = try XCTUnwrap(ReservationRequest(program: program, quality: "DR", repeating: "none"))
        try await store(bench).queue(PendingReservation(request: request, serviceName: program.serviceName))
    }

    /// A client of the kind the paths with no screen make for themselves, asking `recorder`.
    func client(_ recorder: NamedRecorder) -> RecorderClient {
        RecorderClient(host: Bench.host, transport: recorder)
    }

    // MARK: - what the tests look at

    /// What the phone keeps of a recorder, apart from its queue: whose the cache is, the text of the recording
    /// put there, and what the defaults say of its disk and its guide.
    struct Kept: Equatable {
        var owner: String?
        var text: Bool
        var warned: Bool
        var fetchedLastNight: Bool

        /// Everything, as `connected` leaves it, and the recorder's own.
        static func all(of recorder: Int) -> Kept {
            Kept(owner: NamedRecorder.udn(recorder), text: true, warned: true, fetchedLastNight: true)
        }

        /// Nothing that was the last recorder's, and this one's name on the cache.
        static func nothing(nowOf recorder: Int) -> Kept {
            Kept(owner: NamedRecorder.udn(recorder), text: false, warned: false, fetchedLastNight: false)
        }
    }

    func kept(_ bench: Bench) async throws -> Kept {
        let cache = try store(bench)
        return Kept(owner: try await cache.owner(),
                    text: try await !cache.titleSummaries([recording]).isEmpty,
                    warned: bench.defaults.bool(forKey: DefaultsKey.warnedLowSpace),
                    fetchedLastNight: bench.defaults.string(forKey: DefaultsKey.lastBackgroundRefresh) == Self.lastNight)
    }

    func expect(_ bench: Bench, keeps expected: Kept, _ message: String = "",
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        expectEqual(try await kept(bench), expected, message, file: file, line: line)
    }

    /// The reservations waiting, as the model shows them, are `count` and each is held for another recorder.
    func expectHeld(_ model: AppModel, _ count: Int, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(model.pending.map(\.problem),
                       Array(repeating: AppModel.heldForAnotherRecorder, count: count), message, file: file, line: line)
    }

    func expectTheStripSaysWhatIsHeld(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(model.flushReport?.contains("送らずに残しています") ?? false,
                      "nothing on the strip says the reservation was held back: \(model.flushReport ?? "nothing")",
                      file: file, line: line)
    }

    /// Waits for the recorder named `number` to have been taken up, with nothing under way.
    func untilTakenUp(_ model: AppModel, _ number: Int,
                              _ what: String = "the newcomer was never taken up") async throws {
        try await until(what) {
            model.info?.udn == NamedRecorder.udn(number) && !model.connecting && model.busy == nil
        }
    }
}
