import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// The search as the reader works it (`SearchState`): what the screen says before anything is typed, the guide's
/// answer and the old one left up while the next comes, and the lists searched in memory. And the channels'
/// screen (`ChannelsState`): a channel hidden, the order dragged, the reset, each saved in turn.
@MainActor
final class SearchAndChannelsTests: XCTestCase {
    /// A model with the demo's guide cached and a recorder that never answered, given up on: the guide and the
    /// queue are the phone's own. `storeBusyTimeout`, in milliseconds, is how long its writes to the cache wait
    /// for another connection's, where it is not the app's five seconds.
    private func offline(storeBusyTimeout: Int32? = nil) async throws -> (bench: Bench, model: AppModel) {
        let bench = try aBench()
        if let storeBusyTimeout { bench.storeBusyTimeoutMilliseconds = storeBusyTimeout }
        try await bench.cacheAGuide()
        let model = bench.model(recorder: SilentRecorder())
        await model.start()
        try await untilGivenUp(model)
        return (bench, model)
    }

    /// Before anything is typed the screen says what can be searched, and once the field is in use what the chosen
    /// scope searches and how; the box and the scope start from what the defaults hold for the screenshots.
    func testBeforeAnythingIsTypedTheScreenSaysWhatCanBeSearched() async throws {
        let (bench, model) = try await offline()
        let search = SearchState(model: model)
        XCTAssertEqual(search.shows, .invitation)
        XCTAssertNil(search.countLine)
        search.searching = true
        XCTAssertEqual(search.shows, .scopeExplained)
        XCTAssertEqual(search.scopeExplained.title, "番組表を検索")
        XCTAssertTrue(search.scopeExplained.detail?.hasPrefix(SearchState.Scope.guide.explanation(withTelevision: false))
                      ?? false)
        search.query = "   "
        XCTAssertEqual(search.shows, .scopeExplained, "spaces alone were taken for something to look for")

        bench.defaults.set("ニュース", forKey: DefaultsKey.searchFor)
        bench.defaults.set("recordings", forKey: DefaultsKey.searchScope)
        let launched = SearchState(model: model)
        XCTAssertEqual(launched.query, "ニュース")
        XCTAssertEqual(launched.scope, .recordings)
    }

    /// The guide's answer comes after the words, and while the next words are on their way the old answer is left
    /// up; coming back to the guide from another scope with other words, it is not, since nothing would say it is
    /// the old one.
    func testTheGuidesAnswerIsLeftUpWhileTypingButNotAcrossAScope() async throws {
        let (_, model) = try await offline()
        let search = SearchState(model: model)
        search.query = "サンプル"
        XCTAssertEqual(search.shows, .waiting)
        await search.searchTheGuide()
        XCTAssertEqual(search.shows, .results)
        XCTAssertGreaterThan(search.count, 0)
        XCTAssertTrue(search.countLine?.hasPrefix("番組表 \(search.count) 件") ?? false, search.countLine ?? "none")

        search.query = "サンプル 番組"
        XCTAssertEqual(search.shows, .results, "the old answer was taken down while the next was on its way")
        search.scope = .reservations
        search.query = "まだ探していない語"
        search.scope = .guide
        XCTAssertEqual(search.shows, .waiting, "the old answer was left up across a scope")
        await search.searchTheGuide()
        XCTAssertEqual(search.shows, .nothingFound)
    }

    /// What is set to record is searched by its title in memory, every word of the box in it.
    func testTheReservationsAreSearchedByTheirTitles() async throws {
        let (_, model) = try await offline()
        let program = try await aProgramme(model)
        expectTrue(await reserveOnTheRecorder(model, program, quality: "DR", repeating: "none"))
        let search = SearchState(model: model)
        search.scope = .reservations
        search.query = program.title
        XCTAssertEqual(search.reservations.map(\.title), model.allReservations.filter { $0.title == program.title }
                                                              .map(\.title))
        search.query = program.title + " 含まれない語"
        XCTAssertEqual(search.shows, .nothingFound)
    }

    /// A channel turned off is off in the list at once and in the guide once saved; the order dragged is the order
    /// saved; the reset shows every channel in the recorder's order again.
    func testAChannelHiddenAndTheOrderDraggedAreSavedAndTheResetUndoesBoth() async throws {
        let (_, model) = try await offline()
        let channels = ChannelsState(broadcasting: model.broadcasting, model: model)
        await channels.load()
        XCTAssertTrue(channels.loaded)
        let first = try XCTUnwrap(channels.channels.first)
        XCTAssertGreaterThan(channels.channels.count, 2)
        XCTAssertFalse(channels.customised)
        XCTAssertTrue(channels.isShown(first))

        channels.show(first, false)
        XCTAssertFalse(channels.isShown(first))
        XCTAssertTrue(channels.customised)
        await channels.load()
        XCTAssertFalse(model.channels.contains { $0.serviceID == first.serviceID }, "the guide still shows it")

        let order = channels.channels.map(\.serviceID)
        channels.move(from: IndexSet(integer: 0), to: order.count)
        let moved = Array(order.dropFirst()) + [order[0]]
        XCTAssertEqual(channels.channels.map(\.serviceID), moved)
        await channels.load()
        XCTAssertEqual(channels.channels.map(\.serviceID), moved, "the order dragged was not the order saved")

        XCTAssertEqual(channels.resetQuestion,
                       "\(Codes.broadcastingInSentence(model.broadcasting))の局をすべて表示して、レコーダーの順に戻しますか？")
        channels.reset()
        await channels.load()
        XCTAssertFalse(channels.customised, "the reset left a channel hidden or an order")
        XCTAssertEqual(channels.channels.map(\.serviceID), order)
    }

    /// A second channels screen opened while the first screen's saves wait for the cache -- here behind another
    /// connection's write -- shows what they come to, the channel turned off and the order dragged: it reads once
    /// they are done, as the screen that made them does. Read in between, it would show the list without the later
    /// save, would have nothing to read it again for, and a drag there would write that list back over the save.
    func testAScreenOpenedWhileTheSavesWaitShowsWhatWasSaved() async throws {
        // Long enough for the steps below to be made while the first save waits: the save waits only until the
        // other connection lets go, never this long.
        let (bench, model) = try await offline(storeBusyTimeout: 30_000)
        let first = ChannelsState(broadcasting: model.broadcasting, model: model)
        await first.load()
        let hiding = try XCTUnwrap(first.channels.last)

        let writer = Writer(to: bench.guidePath)
        first.show(hiding, false)
        // The drag, and then the second screen opened, each in a turn of the main actor's own, as the reader's
        // touches and a screen's appearing come. A task's first turn comes after those already waiting, so by the
        // drag the first save's write has gone to the store, and waits there behind the other connection; and the
        // second screen's read has set out by the turn the other connection lets go in.
        await Task { first.move(from: IndexSet(integer: 0), to: first.channels.count) }.value
        let moved = first.channels.map(\.serviceID)
        let second = ChannelsState(broadcasting: model.broadcasting, model: model)
        let source = second.source
        let loading = Task { await second.load() }
        await Task { writer.letGo() }.value
        _ = try await within(10, "the second screen's list was never read") { await loading.value }

        await first.load()
        let saved = try await model.channelsToArrange(broadcasting: model.broadcasting)
        XCTAssertEqual(saved.map(\.serviceID), moved, "the first screen's saves did not land")
        XCTAssertEqual(saved.first { $0.id == hiding.id }?.hidden, true, "the channel turned off was not saved so")
        XCTAssertEqual(second.source, source, "the second screen was given something to read again for")
        XCTAssertFalse(second.isShown(hiding), "the second screen shows the channel turned off as on")
        XCTAssertEqual(second.channels.map(\.serviceID), moved,
                       "the second screen shows an order the cache no longer holds")

        second.move(from: IndexSet(integer: 1), to: 0)
        await second.load()
        let after = try await model.channelsToArrange(broadcasting: model.broadcasting).map(\.serviceID)
        XCTAssertEqual(after, [moved[1], moved[0]] + moved.dropFirst(2), "the drag wrote the old order back")
    }

    /// Rows are moved as a list moves them: those taken out keep their order, and go before the row that was at the
    /// place they were dropped.
    func testRowsAreMovedAsAListMovesThem() async throws {
        let (_, model) = try await offline()
        let channels = ChannelsState(broadcasting: model.broadcasting, model: model)
        await channels.load()
        let id = channels.channels.map(\.serviceID)
        XCTAssertGreaterThan(id.count, 4)
        func firstFour() -> [Int] { Array(channels.channels.map(\.serviceID).prefix(4)) }

        channels.move(from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(firstFour(), [id[1], id[0], id[2], id[3]], "a row moved down")
        channels.move(from: IndexSet(integer: 3), to: 0)
        XCTAssertEqual(firstFour(), [id[3], id[1], id[0], id[2]], "a row moved to the top")
        channels.move(from: IndexSet([0, 2]), to: 4)
        XCTAssertEqual(firstFour(), [id[1], id[2], id[3], id[0]], "two rows moved together")
        await channels.load()
        XCTAssertEqual(firstFour(), [id[1], id[2], id[3], id[0]], "the moves were not saved in turn")
    }

    /// The words of the stations screen as it has always said them, byte for byte: its title, the button at the foot
    /// and the one of the question it asks, and the title of the alert that says a change was not saved. The button
    /// that closes that alert is the sheets' (`SheetWords.okLabel`).
    func testTheStationsScreenSaysWhatItSaid() {
        XCTAssertEqual(ChannelsState.title, "チャンネルの表示と並び順")
        XCTAssertEqual(ChannelsState.resetRowLabel, "レコーダーの順に戻して、すべて表示")
        XCTAssertEqual(ChannelsState.resetLabel, "レコーダーの順に戻す")
        XCTAssertEqual(ChannelsState.failureTitle, "保存できませんでした")
        XCTAssertEqual(SheetWords.okLabel, "OK")
    }
}
