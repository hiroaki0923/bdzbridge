import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// What a screen says when it has nothing to list, and why (`AppModelEmptyScreens.swift`): no recorder to talk to,
/// a guide with nothing for the day by the reader's choice or the cache's, and the reservations' and recordings'
/// empty lists.
@MainActor
final class EmptyScreenTests: XCTestCase {
    /// With no recorder set up, every tab says so and offers the search; the guide, with nothing cached, shows that
    /// in place of its programmes.
    func testWithNoRecorderSetUpItIsSaidThatNoneHasBeenAdded() async throws {
        let bench = try aBench()
        let model = bench.modelWithNoRecorder()
        await model.start()
        XCTAssertEqual(model.noRecorderSays, .notAdded)
        XCTAssertEqual(AppModel.notAdded.title, "レコーダーが追加されていません")
        XCTAssertEqual(model.guideShows(grid: false), .noRecorder)
        XCTAssertTrue(model.reservationsHaveNoRecorder)
        XCTAssertTrue(model.recordingsHaveNoRecorder)
    }

    /// A recorder set up that does not answer: said as not reached, with the power and the network to check, and
    /// the guide in the cache shown all the same. The reservations tab shows its queue once something waits.
    func testARecorderThatDoesNotAnswerIsSaidNotReachedAndTheCacheIsShownAllTheSame() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let model = bench.model(recorder: SilentRecorder())
        await model.start()
        try await untilGivenUp(model)
        guard case .notReached(let why, let phones) = model.noRecorderSays else {
            return XCTFail("a recorder that does not answer was said as \(model.noRecorderSays)")
        }
        XCTAssertFalse(phones)
        XCTAssertEqual(AppModel.notReached(why: why, phones: phones).title, "レコーダーに接続できません")
        XCTAssertEqual(AppModel.notReached(why: nil, phones: false).detail,
                       "レコーダーの電源と、同じネットワークに接続されているかを確かめてください")
        XCTAssertEqual(model.guideShows(grid: false), .programmes, "the cached guide was not shown away from home")

        XCTAssertTrue(model.reservationsHaveNoRecorder)
        let program = try await aProgramme(model)
        expectTrue(await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none"))
        XCTAssertFalse(model.reservationsHaveNoRecorder, "the queue was not shown away from home")
        XCTAssertFalse(model.reservationsAreEmpty)
    }

    /// Every channel of the type hidden is said ahead of anything about the recorder, which is not the reason, with
    /// the way to the channel settings; so is the list narrowed to a channel with nothing that day.
    func testWhatTheReaderChoseIsSaidAheadOfTheRecorder() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let model = bench.model(recorder: SilentRecorder())
        await model.start()
        try await untilGivenUp(model)
        let every = try await model.channelsToArrange(broadcasting: model.broadcasting).map(\.serviceID)
        try await model.setChannelPreferences(broadcasting: model.broadcasting, hidden: every)
        XCTAssertTrue(model.everyChannelHidden)
        XCTAssertEqual(model.guideShows(grid: false), .empty, "a choice of the reader's was said as the recorder's")
        XCTAssertEqual(model.guideEmpty(narrowed: false), .everyChannelHidden)
        let type = Codes.broadcastingInSentence(model.broadcasting)
        XCTAssertEqual(model.says(.everyChannelHidden), .init("\(type)の局をすべて非表示にしています",
                                                              "表示する局を選ぶと、番組表に出てきます"))
    }

    /// The guide of the demo with nothing for a type says what the demo's line-up covers, and a cache with nothing
    /// fetched says so, with the refresh to fetch it.
    func testAGuideWithNothingSaysWhetherItIsTheDemosOrNotYetFetched() async throws {
        let bench = try aBench()
        let model = bench.model(recorder: SilentRecorder())
        await model.start()
        try await untilGivenUp(model)
        XCTAssertEqual(model.guideEmpty(narrowed: false), model.whyNothingToShow.map { .cannotShow($0) } ?? .notFetched)
        XCTAssertEqual(model.says(.notFetched), .init("番組表をまだ取得していません", "右上の更新ボタンでレコーダーから取得できます"))
        XCTAssertEqual(model.says(.nothingThatDay).title, "この日の番組表はありません")
        XCTAssertEqual(model.says(.demo).detail, DemoLineUp.guideCoverage)
    }

    /// An empty list of recordings says there is nothing; the loading line is the recorder's read with none read yet.
    func testAnEmptyListOfRecordingsSaysThereIsNothing() async throws {
        let bench = try aBench()
        let model = bench.model(recorders: [Bench.host: NamedRecorder(1)])
        await model.start()
        try await untilConnected(model)
        XCTAssertFalse(model.recordingsHaveNoRecorder)
        XCTAssertEqual(model.noRecordingsSays, .init("録画された番組はありません"))
        XCTAssertEqual(AppModel.loadingRecordings, .init("読み込み中", "レコーダーから録画一覧を取得しています"))
        XCTAssertEqual(AppModel.noReservations, .init("予約はありません", "番組表から番組を選んで予約できます"))
    }
}
