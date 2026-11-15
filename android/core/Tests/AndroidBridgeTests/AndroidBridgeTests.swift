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
        let app = RecBridgeApp.made(files: folder.path, kept: folder.appendingPathComponent("kept").path, version: "0.1 (1)")
        await app.start()
        await app.devices().enterDemo()
        return app
    }

    /// Waits for what a window shows to come to `done`, reading it as the screen does.
    @MainActor
    private func until<Shown>(_ read: () async -> Shown, tries: Int = 200, _ done: (Shown) -> Bool,
                              file: StaticString = #filePath, line: UInt = #line) async -> Shown {
        for _ in 0..<tries {
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
        let opening = await guide.open(first.id)
        let sheet = try XCTUnwrap(opening)
        defer { Task { await sheet.closed() } }
        let opened = await sheet.read()
        XCTAssertEqual(opened.title, first.title)
        XCTAssertEqual(opened.station, first.station)
        XCTAssertTrue(opened.starts.hasSuffix(first.time), "the sheet says the day and the time: \(opened.starts)")
        let nothing = await guide.open("none")
        XCTAssertNil(nothing)
    }

    /// The demo's stations get the tiles Kotlin draws, which come back as the guide's logos; with no drawer there are
    /// none.
    @MainActor
    func testTheDemosStationsGetTheTilesKotlinDraws() async throws {
        let app = RecBridgeApp.made(files: folder.path, kept: folder.appendingPathComponent("kept").path,
                                    version: "0.1 (1)")
        app.drawsTiles(Drawing())
        await app.start()
        await app.devices().enterDemo()
        let shown = await until(app.guide().read) { $0.shows == "programmes" && !$0.stations.isEmpty }
        XCTAssertTrue(shown.stations.allSatisfy { $0.logo.starts(with: [0x89, 0x50, 0x4E, 0x47]) })
        let first = try XCTUnwrap(shown.stations.first)
        XCTAssertEqual(String(decoding: first.logo.dropFirst(8), as: UTF8.self).prefix(2), "0:")
        let kept = folder.appendingPathComponent("demo-tiles").path
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: kept), [], "the files are not kept")

        // The rows of the reservations and the recordings name their stations' logos, which come once each.
        let reservationsWindow = await app.reservations()
        await reservationsWindow.load()
        let reservations = await until(reservationsWindow.read) { !$0.sections.isEmpty }
        let reserved = reservations.sections.flatMap(\.rows)
        XCTAssertTrue(reserved.contains { !$0.logo.isEmpty })
        XCTAssertTrue(reserved.allSatisfy { row in
            row.logo.isEmpty || reservations.logos.contains { $0.key == row.logo }
        })
        XCTAssertEqual(Set(reservations.logos.map(\.key)).count, reservations.logos.count)
        let recordingsWindow = await app.recordings()
        await recordingsWindow.load()
        let recordings = await until(recordingsWindow.read) { !$0.rows.isEmpty }
        let recorded = try XCTUnwrap(recordings.rows.first { !$0.logo.isEmpty })
        XCTAssertTrue(recordings.logos.contains { $0.key == recorded.logo })
        XCTAssertTrue(recorded.details.utf16.count >= Int(recorded.logoAt), "the logo goes inside the details")

        let bare = await demo().guide()
        let without = await until(bare.read) { $0.shows == "programmes" && !$0.stations.isEmpty }
        XCTAssertTrue(without.stations.allSatisfy { $0.logo.isEmpty })
    }

    /// What Android's watcher reports reaches what the model handed over, for as long as the model holds its token.
    func testTheNetworksChangesReachTheModelForAsLongAsItWatches() {
        let reports = NetworkReports()
        let told = NSLock()
        nonisolated(unsafe) var count = 0
        var token: AnyObject? = reports.watch { told.withLock { count += 1 } }
        reports.report()
        reports.report()
        XCTAssertEqual(told.withLock { count }, 2)
        token = nil
        reports.report()
        XCTAssertEqual(told.withLock { count }, 2, "nothing is told once the model has let go")
        XCTAssertNil(token)
    }

    /// A programme's page hands over its recordings' stations' logos, as the list does.
    @MainActor
    func testAProgrammesPageHasItsStationsLogos() async throws {
        let app = RecBridgeApp.made(files: folder.path, kept: folder.appendingPathComponent("kept").path,
                                    version: "0.1 (1)")
        app.drawsTiles(Drawing())
        await app.start()
        await app.devices().enterDemo()
        let recordings = await app.recordings()
        await recordings.load()
        _ = await until(recordings.read) { !$0.rows.isEmpty }
        let programme = try XCTUnwrap(app.model.titleGroups.first)
        let opening = await recordings.openGroup(programme.id)
        let page = try XCTUnwrap(opening)
        let shown = await page.read()
        XCTAssertFalse(shown.logos.isEmpty)
        XCTAssertTrue(shown.rows.allSatisfy { member in
            member.row.logo.isEmpty || shown.logos.contains { $0.key == member.row.logo }
        })
        XCTAssertTrue(shown.rows.contains { !$0.row.logo.isEmpty })
    }

    /// Where a recording's logo goes is never past its details, even for one with no channel's name and nothing after
    /// its time: the row is cut there on the screen.
    @MainActor
    func testARecordingWithNoChannelNameKeepsItsLogoInsideItsDetails() async throws {
        let app = await demo()
        let window = await app.recordings()
        await window.load()
        _ = await until(window.read) { !$0.rows.isEmpty }
        var title = try XCTUnwrap(app.model.allTitles.first)
        title.channelName = nil
        title.broadcastingType = 999
        title.qualityCode = 999
        title.durationSec = 0
        title.sizeMB = nil
        title.destination = ""
        let row = RecordingsWindow.row(title, app.model, shelf: LogoShelf())
        XCTAssertLessThanOrEqual(Int(row.logoAt), row.details.utf16.count)
        XCTAssertFalse(row.details.isEmpty)
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
        let reservations = await app.reservations()
        await reservations.load()
        let listed = await until(reservations.read) { !$0.sections.isEmpty }
        XCTAssertFalse(listed.hasNoRecorder)
        XCTAssertFalse(listed.isEmpty)
        XCTAssertTrue(listed.subtitle.contains("件"))
        XCTAssertTrue(listed.sections.allSatisfy { $0.title.contains("(") && !$0.rows.isEmpty })
        XCTAssertTrue(listed.sections.flatMap(\.rows).allSatisfy { $0.time.count == 5 && !$0.title.isEmpty })

        let recordings = await app.recordings()
        await recordings.load()
        let titles = await until(recordings.read) { !$0.rows.isEmpty && $0.subtitle == "\($0.rows.count) 件" }
        XCTAssertFalse(titles.hasNoRecorder)
        XCTAssertEqual(titles.subtitle, "\(titles.rows.count) 件")
        XCTAssertTrue(titles.rows.allSatisfy { $0.details.contains("(") && !$0.watched.isEmpty })
    }

    @MainActor
    func testTheSearchFindsProgrammesReservationsAndRecordings() async throws {
        let app = await demo()
        let today = await until(app.guide().read) { $0.shows == "programmes" }
        let search = await app.search()
        let blank = await search.read()
        XCTAssertEqual(blank.shows, "scopeExplained", "the scopes are on the screen from the start")
        XCTAssertEqual(blank.said.title, "番組表を検索")
        XCTAssertEqual(blank.scopes.map(\.label), ["番組表", "予約", "録画"])
        XCTAssertEqual(blank.prompt, "番組名・出演者・番組内容")

        // A programme still to come, looked for by its own title.
        let coming = try XCTUnwrap(today.programmes.last)
        await search.shown(true)
        await search.type(coming.title)
        let found = await until(search.read) { $0.shows == "results" }
        XCTAssertTrue(found.countLine.hasPrefix("番組表 "), found.countLine)
        XCTAssertTrue(found.programmes.contains { $0.row.title == coming.title })
        XCTAssertTrue(found.programmes.allSatisfy { $0.day.contains("(") }, "each says its day")
        XCTAssertTrue(found.reservations.isEmpty && found.recordings.isEmpty, "only the scope's rows")
        let hit = try XCTUnwrap(found.programmes.first)
        let opening = await search.openProgramme(hit.row.id)
        let sheet = try XCTUnwrap(opening)
        let opened = await sheet.read()
        XCTAssertEqual(opened.title, hit.row.title)
        await sheet.closed()

        // The recordings: read as the scope is turned to, and narrowed by the words in the box.
        await search.type("")
        await search.chooseScope("recordings")
        let explained = await until(search.read) { $0.scope == "recordings" }
        XCTAssertEqual(explained.shows, "scopeExplained")
        XCTAssertEqual(explained.said.title, "録画を検索")
        let titles = await until(await app.recordings().read) { !$0.rows.isEmpty }
        let recording = try XCTUnwrap(titles.rows.first)
        await search.type(recording.title)
        let recorded = await until(search.read) { $0.shows == "results" && !$0.recordings.isEmpty }
        XCTAssertTrue(recorded.recordings.contains { $0.id == recording.id })
        XCTAssertEqual(recorded.countLine, "録画 \(recorded.recordings.count) 件", "the rows are the ones counted")
        XCTAssertLessThan(recorded.recordings.count, titles.rows.count, "the words narrowed nothing")
        let openingTitle = await search.openRecording(recording.id)
        let titleSheet = try XCTUnwrap(openingTitle)
        await titleSheet.closed()

        // The reservations the same way.
        await search.type("")
        await search.chooseScope("reservations")
        let listed = await until(await app.reservations().read) { !$0.sections.isEmpty }
        let reservation = try XCTUnwrap(listed.sections.first?.rows.first)
        await search.type(reservation.title)
        let reserved = await until(search.read) { $0.shows == "results" && !$0.reservations.isEmpty }
        let foundReservation = try XCTUnwrap(reserved.reservations.first { $0.id == reservation.id })
        XCTAssertEqual(reserved.countLine, "予約 \(reserved.reservations.count) 件", "the rows are the ones counted")
        XCTAssertLessThan(reserved.reservations.count, listed.sections.flatMap(\.rows).count, "the words narrowed nothing")
        XCTAssertTrue(foundReservation.time.contains("(") && foundReservation.time.hasSuffix(reservation.time),
                      "found away from the days' headings, it says its day: \(foundReservation.time)")
        let openingReservation = await search.openReservation(reservation.id)
        let reservationSheet = try XCTUnwrap(openingReservation)
        await reservationSheet.closed()

        // Words nothing has.
        await search.type("どこにもない言葉")
        let nothing = await until(search.read) { $0.shows == "nothingFound" }
        XCTAssertTrue(nothing.said.detail.contains("どこにもない言葉"))
        XCTAssertEqual(nothing.countLine, "")

        // With the screen gone the guide is searched no more: the words wait for it to come back.
        await search.chooseScope("guide")
        _ = await until(search.read) { $0.shows == "nothingFound" || $0.shows == "waiting" }
        await search.shown(false)
        await search.type(coming.title)
        try await Task.sleep(for: .milliseconds(600))
        let away = await search.read()
        XCTAssertEqual(away.shows, "waiting")
        await search.shown(true)
        _ = await until(search.read) { $0.shows == "results" }
        await search.shown(false)
    }

    /// The reservations' menu narrows and sorts the list; a row's delete is asked first and goes by the question it
    /// was shown with; a waiting row a device refused is offered to be sent again, and its delete is asked in its own
    /// words. Writes only to the demo's recorder and the demo's queue.
    @MainActor
    func testTheReservationsAreNarrowedSortedAndDeletedAfterAQuestion() async throws {
        let app = await demo()
        _ = await until(app.guide().read) { $0.shows == "programmes" }
        let list = await app.reservations()
        await list.load()
        let listed = await until(list.read) { !$0.sections.isEmpty && $0.line.isEmpty }
        XCTAssertEqual(listed.kinds.map(\.label), ["すべて", "通常の予約", "おまかせ"])
        XCTAssertEqual(listed.sorts.map(\.label), ["日時", "ジャンル", "局"])
        XCTAssertEqual(listed.kind, "all")
        XCTAssertEqual(listed.sort, "time")
        XCTAssertFalse(listed.filtering)
        XCTAssertFalse(listed.hasAsked)
        XCTAssertEqual(listed.staleKey, "", "the list of a recorder that answers was said to be old")
        let nothingOld = await list.stale()
        XCTAssertEqual(nothingOld, "")

        await list.chooseKind("automatic")
        let automatic = await until(list.read) { $0.kind == "automatic" }
        XCTAssertTrue(automatic.filtering)
        XCTAssertTrue(automatic.subtitle.hasPrefix("おまかせ · "), automatic.subtitle)
        XCTAssertTrue(automatic.sections.flatMap(\.rows).allSatisfy(\.byTheRecorder))
        await list.chooseKind("all")
        await list.chooseSort("channel")
        let byStation = await until(list.read) { $0.sort == "channel" && $0.kind == "all" }
        XCTAssertTrue(byStation.filtering)
        XCTAssertFalse(byStation.sections.contains { $0.title.contains("(") }, "the headings are stations, not days")
        await list.chooseSort("time")

        // Two programmes still to come that nothing is set to record: one reserved, to delete from the list, and
        // one put in the queue as a device had refused it. Of tomorrow's, which has them at any hour: late in a
        // broadcast day today has none left.
        await app.guide().chooseDay(1)
        _ = await until(app.guide().read) { $0.day == 1 && $0.shows == "programmes" }
        let free = app.model.programs.filter {
            app.model.reservation(for: $0) == nil && app.model.pending(for: $0) == nil
        }
        let (reserving, queued) = (try XCTUnwrap(free.first), try XCTUnwrap(free.dropFirst().first))
        _ = await app.model.reserve(reserving, on: .recorder, quality: "DR", repeating: "none")
        let reservation = try XCTUnwrap(app.model.reservation(for: reserving))

        await list.delete(reservation.listKey)
        let asking = await until(list.read) { $0.hasAsked }
        XCTAssertEqual(asking.asked.title, "この予約を削除しますか？")
        XCTAssertEqual(asking.asked.action, "削除する")
        XCTAssertTrue(asking.asked.destructive)
        XCTAssertEqual(asking.asked.closing, "キャンセル")
        XCTAssertTrue(asking.asked.message.contains(reserving.title))
        await list.act("another question")
        let still = await list.read()
        XCTAssertEqual(still.asked.key, asking.asked.key, "a press for another question answered this one")
        XCTAssertNotNil(app.model.reservation(for: reserving))
        await list.closeAsked(asking.asked.key)
        let left = await until(list.read) { !$0.hasAsked }
        XCTAssertTrue(left.sections.flatMap(\.rows).contains { $0.id == reservation.listKey }, "キャンセル deleted it")

        await list.delete(reservation.listKey)
        let again = await until(list.read) { $0.hasAsked }
        await list.act(again.asked.key)
        let gone = await until(list.read) { shown in
            !shown.sections.flatMap(\.rows).contains { $0.id == reservation.listKey } && shown.line.isEmpty
        }
        XCTAssertFalse(gone.hasAsked, "a delete that went through said something: \(gone.asked.message)")

        let store = try GuideStore(path: Storage.guidePath(demo: true, in: folder))
        let request = try XCTUnwrap(ReservationRequest(program: queued, quality: "DR", repeating: "none"))
        let refused = PendingReservation(request: request, serviceName: queued.serviceName, problem: "断られた理由")
        try await store.queue(refused)
        await app.model.loadPending()
        let waiting = await until(list.read) { !$0.waiting.isEmpty }
        let row = try XCTUnwrap(waiting.waiting.first)
        XCTAssertTrue(row.offersSendingAgain)
        XCTAssertFalse(row.held)
        XCTAssertEqual(row.problem, "断られた理由。")

        await list.deleteWaiting(row.id)
        let askingOfIt = await until(list.read) { $0.hasAsked }
        XCTAssertEqual(askingOfIt.asked.title, "送信待ちの予約を削除しますか？")
        XCTAssertTrue(askingOfIt.asked.message.hasSuffix("この端末から削除し、レコーダーには送りません。"), askingOfIt.asked.message)
        await list.closeAsked(askingOfIt.asked.key)
        _ = await until(list.read) { !$0.hasAsked }

        // Sent again, the demo's recorder makes it: the row goes, the guide marks it, and nothing is left to say.
        await list.sendAgain(row.id)
        let sent = await until(list.read) { $0.waiting.isEmpty && $0.line.isEmpty }
        XCTAssertFalse(sent.hasAsked, "a row made said something: \(sent.asked.message)")
        XCTAssertNotNil(app.model.reservation(for: queued))
    }

    /// The recordings' three views, kept as picked; what a row offers under a swipe; a delete asked first and gone
    /// with its question's own key; and 保護解除 from a protected row. Writes only to the demo's recorder.
    @MainActor
    func testTheRecordingsViewsAndARowsSwipe() async throws {
        let app = await demo()
        let recordings = await app.recordings()
        await recordings.load()
        let listed = await until(recordings.read) { !$0.rows.isEmpty && $0.subtitle == "\($0.rows.count) 件" }
        XCTAssertEqual(listed.modes.map(\.label), ["一覧", "まとめ", "重複"])
        XCTAssertEqual(listed.mode, "list")
        XCTAssertTrue(listed.groups.isEmpty, "the programmes were worked out with the list on")
        XCTAssertFalse(listed.hasAsked)
        XCTAssertTrue(listed.rows.contains { $0.swipe == "delete" && !$0.protected })
        let protected = try XCTUnwrap(listed.rows.first { $0.protected && !$0.recording }, "the demo has no protected recording")
        XCTAssertEqual(protected.swipe, "unprotect")
        XCTAssertTrue(listed.rows.filter(\.recording).allSatisfy { $0.swipe.isEmpty }, "a recording being recorded offers a swipe")
        let partway = try XCTUnwrap(listed.rows.first { $0.resume >= 0 }, "the demo has no recording watched partway")
        XCTAssertTrue((1...99).contains(partway.resume), "\(partway.resume)")
        XCTAssertTrue(listed.rows.filter { $0.watched != partway.watched }.allSatisfy { $0.resume == -1 })

        await recordings.chooseMode("groups")
        let grouped = await until(recordings.read) { $0.mode == "groups" }
        XCTAssertTrue(grouped.rows.isEmpty)
        XCTAssertFalse(grouped.groups.isEmpty)
        XCTAssertEqual(grouped.subtitle, "\(grouped.groups.count) 番組")
        XCTAssertTrue(grouped.groups.allSatisfy { $0.count.hasSuffix(" 件") && $0.size.hasSuffix(" GB") && $0.span.contains(" 〜 ") })
        // Kept where the next start of the app reads it.
        let again = RecBridgeApp.made(files: folder.path, kept: folder.appendingPathComponent("kept").path, version: "0.1 (1)")
        let kept = await again.recordings().read()
        XCTAssertEqual(kept.mode, "groups")
        await recordings.chooseMode("list")
        _ = await until(recordings.read) { $0.mode == "list" && !$0.rows.isEmpty }

        let going = try XCTUnwrap(listed.rows.first { $0.swipe == "delete" && !$0.held })
        await recordings.delete(going.id)
        let asking = await until(recordings.read) { $0.hasAsked }
        XCTAssertEqual(asking.asked.title, "この録画を削除しますか？")
        XCTAssertTrue(asking.asked.message.hasPrefix(going.title))
        XCTAssertEqual(asking.asked.action, "削除する")
        XCTAssertFalse(asking.actionHeld)
        await recordings.act("another question")
        await recordings.closeAsked(asking.asked.key)
        let left = await until(recordings.read) { !$0.hasAsked }
        XCTAssertTrue(left.rows.contains { $0.id == going.id }, "キャンセル deleted it")
        await recordings.delete(going.id)
        let asked = await until(recordings.read) { $0.hasAsked }
        await recordings.act(asked.asked.key)
        let gone = await until(recordings.read) { shown in
            !shown.rows.contains { $0.id == going.id } && shown.subtitle == "\(shown.rows.count) 件"
        }
        XCTAssertFalse(gone.hasAsked, "a delete that went through said something: \(gone.asked.message)")

        // 保護解除 on a row that offers the delete does nothing; on the protected one it takes the protection off.
        await recordings.unprotect(try XCTUnwrap(gone.rows.first { $0.swipe == "delete" }).id)
        await recordings.unprotect(protected.id)
        let unprotected = await until(recordings.read) { shown in shown.rows.contains { $0.id == protected.id && !$0.protected } }
        XCTAssertEqual(unprotected.rows.first { $0.id == protected.id }?.swipe, "delete")
    }

    /// A programme's page: the selection, a run over what is ticked with the job's bar following it, a row's own
    /// delete, and the bulk delete asked first. Writes only to the demo's recorder.
    @MainActor
    func testAProgrammesPageSelectsAndRunsOverItsRecordings() async throws {
        let app = await demo()
        let recordings = await app.recordings()
        await recordings.load()
        _ = await until(recordings.read) { !$0.rows.isEmpty && $0.subtitle == "\($0.rows.count) 件" }
        let programme = try XCTUnwrap(app.model.titleGroups.max { $0.count < $1.count })
        XCTAssertGreaterThan(programme.count, 2, "the demo has no programme with three recordings")
        let opening = await recordings.openGroup(programme.id)
        let page = try XCTUnwrap(opening)
        let nothing = await recordings.openGroup("none")
        XCTAssertNil(nothing)
        let job = app.job()
        let idle = await job.read()
        XCTAssertFalse(idle.hasJob)

        let first = await page.read()
        XCTAssertEqual(first.name, programme.name)
        XCTAssertEqual(first.rows.count, programme.count)
        XCTAssertFalse(first.selecting)
        XCTAssertEqual(first.selectLabel, "選択")
        XCTAssertFalse(first.offersActions)
        XCTAssertFalse(first.done)

        // Picking: a row ticked, then every row a delete would take.
        await page.toggle(first.rows[0].row.id)
        let notPicking = await page.read()
        XCTAssertFalse(notPicking.rows[0].selected, "a row was ticked with the selection off")
        await page.toggleSelecting()
        await page.toggle(first.rows[0].row.id)
        let ticked = await until(page.read) { $0.rows[0].selected }
        XCTAssertEqual(ticked.selectLabel, "完了")
        XCTAssertEqual(ticked.count, "1 件")
        XCTAssertTrue(ticked.offersActions)
        XCTAssertTrue(ticked.deleteLabel.hasPrefix("選択した 1 件を削除（"), ticked.deleteLabel)
        XCTAssertTrue(ticked.rows.allSatisfy { $0.row.swipe.isEmpty }, "a row offers its swipe while picking")
        await page.selectWhatCanBeDeleted()
        let all = await until(page.read) { $0.rows.filter(\.selected).count > 1 }
        XCTAssertEqual(Set(all.rows.filter(\.selected).map(\.row.id)), Set(all.rows.filter(\.wouldBeDeleted).map(\.row.id)))
        await page.selectNothing()
        _ = await until(page.read) { !$0.offersActions }

        // 保護する over one row: the run begins, the selection ends, and the bar says what it came to.
        let unprotected = try XCTUnwrap(first.rows.first { !$0.row.protected && !$0.row.recording })
        await page.toggle(unprotected.row.id)
        _ = await until(page.read) { $0.offersActions && !$0.actionsHeld }
        await page.protect(true)
        let ended = await until(job.read) { $0.hasJob && $0.finished }
        XCTAssertFalse(ended.line.isEmpty)
        XCTAssertEqual(ended.note, "")
        let after = await until(page.read) { shown in shown.rows.contains { $0.row.id == unprotected.row.id && $0.row.protected } }
        XCTAssertFalse(after.selecting, "the run began and the selection stayed")
        await job.clear()
        _ = await until(job.read) { !$0.hasJob }

        // A row's own delete from its swipe, asked first.
        let going = try XCTUnwrap(after.rows.first { $0.row.swipe == "delete" })
        _ = await until(page.read) { shown in shown.rows.contains { $0.row.id == going.row.id && !$0.row.held } }
        await page.delete(going.row.id)
        let one = await until(page.read) { $0.hasAsked }
        XCTAssertEqual(one.asked.title, "この録画を削除しますか？")
        await page.act(one.asked.key)
        let fewer = await until(page.read) { shown in !shown.rows.contains { $0.row.id == going.row.id } && !shown.asking }
        XCTAssertFalse(fewer.hasAsked, "a delete that went through said something: \(fewer.asked.message)")

        // The bulk delete of one ticked row: asked with how many, and the run takes it.
        let last = try XCTUnwrap(fewer.rows.first { $0.wouldBeDeleted })
        await page.toggleSelecting()
        await page.toggle(last.row.id)
        _ = await until(page.read) { $0.offersActions && !$0.actionsHeld }
        await page.deleteChosen()
        let bulk = await until(page.read) { $0.hasAsked }
        XCTAssertEqual(bulk.asked.title, "選択した 1 件を削除しますか？")
        XCTAssertEqual(bulk.asked.action, "1 件を削除する")
        XCTAssertTrue(bulk.asked.destructive)
        await page.act(bulk.asked.key)
        _ = await until(job.read) { $0.hasJob && $0.finished }
        let least = await until(page.read) { shown in !shown.rows.contains { $0.row.id == last.row.id } }
        XCTAssertFalse(least.selecting)
        await job.clear()
        await page.closed()
    }

    /// The duplicates: the scan offered, the set it finds with the copy to go ticked, a tick taken off and put back,
    /// and the delete of what is ticked asked first. Writes only to the demo's recorder.
    @MainActor
    func testTheDuplicatesAreScannedTickedAndDeleted() async throws {
        let app = await demo()
        let recordings = await app.recordings()
        await recordings.load()
        _ = await until(recordings.read) { !$0.rows.isEmpty && $0.subtitle == "\($0.rows.count) 件" }
        let duplicates = await app.duplicates()
        let before = await until(duplicates.read) { !$0.scanHeld }
        XCTAssertFalse(before.hasSets)
        XCTAssertEqual(before.prompt.title, "重複した録画を探す")
        XCTAssertEqual(before.scanLabel, "検出を開始")
        XCTAssertFalse(before.hasAsked)

        await duplicates.scan()
        let found = await until(duplicates.read, tries: 800) { $0.hasSets && !$0.scanAgainHeld }
        let set = try XCTUnwrap(found.sets.first)
        XCTAssertTrue(set.details.hasPrefix("\(set.copies.count) 本 · "), set.details)
        XCTAssertTrue(set.copies.contains { $0.keeping && $0.mark == "残す" }, "no copy of the set is kept")
        let going = try XCTUnwrap(set.copies.first { !$0.keeping }, "the scan ticked no copy")
        XCTAssertEqual(going.mark, "削除")
        XCTAssertTrue(going.deletable && !going.tickHeld)
        XCTAssertTrue(going.tickLabel.hasSuffix("の録画を削除する対象に選ぶ"))
        XCTAssertTrue(found.deleteLabel.hasPrefix("選択した "), found.deleteLabel)
        await app.job().clear()

        await duplicates.toggle(going.id)
        let unticked = await until(duplicates.read) { shown in shown.sets.first?.copies.first { $0.id == going.id }?.keeping == true }
        XCTAssertEqual(unticked.sets.first?.copies.first { $0.id == going.id }?.mark, "残す")
        await duplicates.toggle(going.id)
        _ = await until(duplicates.read) { shown in shown.sets.first?.copies.first { $0.id == going.id }?.keeping == false }

        let opening = await duplicates.open(going.id)
        let sheet = try XCTUnwrap(opening)
        await sheet.closed()

        await duplicates.delete()
        let asking = await until(duplicates.read) { $0.hasAsked }
        XCTAssertTrue(asking.asked.title.hasPrefix("重複した "), asking.asked.title)
        XCTAssertTrue(asking.asked.action.hasSuffix(" 件を削除する"), asking.asked.action)
        XCTAssertEqual(asking.asked.closing, "キャンセル")
        await duplicates.act("another question")
        let still = await duplicates.read()
        XCTAssertTrue(still.hasAsked)
        await duplicates.act(asking.asked.key)
        _ = await until(app.job().read, tries: 800) { $0.hasJob && $0.finished }
        let after = await until(recordings.read) { shown in !shown.rows.contains { $0.id.hasSuffix(going.id) } }
        XCTAssertFalse(after.rows.isEmpty)
        let closed = await duplicates.read()
        XCTAssertFalse(closed.hasAsked)
    }

    /// The recorder's own keyword conditions: the list read, a row's delete asked first and gone with its question's
    /// own key, and a new condition typed, narrowed and registered from the form, which closes. Writes only to the
    /// demo's recorder.
    @MainActor
    func testTheKeywordConditionsAreListedDeletedAndAdded() async throws {
        let app = await demo()
        let reservations = await app.reservations()
        let shown = await until(reservations.read) { !$0.conditionsHeld }
        XCTAssertFalse(shown.conditionsHeld)

        let conditions = await app.conditions()
        await conditions.load()
        // Once the recorder's work after the connect is done: while it works, adding and deleting are held.
        let listed = await until(conditions.read) { !$0.rows.isEmpty && !$0.addHeld && !$0.deleteHeld }
        XCTAssertEqual(listed.title, "おまかせ・まる録")
        XCTAssertEqual(listed.listSays, "")
        XCTAssertFalse(listed.addHeld)
        XCTAssertTrue(listed.footer.hasPrefix("レコーダー本体が番組を自動で探して録画する条件です。"))
        let rule = try XCTUnwrap(listed.rows.first)
        XCTAssertFalse(rule.details.isEmpty)

        await conditions.delete(rule.id)
        let asking = await until(conditions.read) { $0.hasAsked }
        XCTAssertEqual(asking.asked.title, "この条件を削除しますか？")
        XCTAssertTrue(asking.asked.message.contains(rule.name))
        await conditions.act("another question")
        await conditions.closeAsked(asking.asked.key)
        _ = await until(conditions.read) { !$0.hasAsked && !$0.deleteHeld }
        await conditions.delete(rule.id)
        let again = await until(conditions.read) { $0.hasAsked }
        await conditions.act(again.asked.key)
        let fewer = await until(conditions.read) { shown in
            !shown.rows.contains { $0.id == rule.id } && !shown.addHeld
        }
        XCTAssertFalse(fewer.hasAsked)

        let form = await conditions.newCondition()
        let blank = await form.read()
        XCTAssertEqual(blank.keywords.count, 1)
        XCTAssertFalse(blank.mayRemoveKeyword)
        XCTAssertTrue(blank.registerHeld, "a condition with no keyword nor genre could be sent")
        XCTAssertEqual(blank.keywordFooter, "キーワードかジャンルを指定してください。")
        XCTAssertEqual(blank.genres.first?.label, "指定しない")
        XCTAssertTrue(blank.subGenres.isEmpty)
        // The demo's recorder has a USB disk: 録画先 is a choice, starting on the internal disk.
        XCTAssertGreaterThan(blank.disks.count, 1)
        XCTAssertEqual(blank.disk, blank.disks.first?.code)
        XCTAssertEqual(blank.diskAlone, "")

        let first = try XCTUnwrap(blank.keywords.first)
        await form.typeKeyword(first.id, "ためしの言葉")
        await form.addKeyword()
        let two = await until(form.read) { $0.keywords.count == 2 }
        XCTAssertFalse(two.registerHeld)
        XCTAssertTrue(two.mayRemoveKeyword)
        await form.typeKeyword(two.keywords[1].id, "もうひとつ")
        let combined = await until(form.read) { $0.asksHowToCombine }
        XCTAssertEqual(combined.logics.map(\.label), ["いずれかを含む", "すべてを含む"])
        await form.chooseLogic("AND")
        let genre = try XCTUnwrap(combined.genres.dropFirst().first)
        await form.chooseGenre(genre.code)
        let narrowed = await until(form.read) { $0.genre == genre.code }
        XCTAssertEqual(narrowed.subGenres.first?.label, "すべて")
        await form.removeKeyword(two.keywords[1].id)
        _ = await until(form.read) { $0.keywords.count == 1 }

        await form.register()
        let made = await until(form.read) { $0.done }
        XCTAssertEqual(made.failure, "")
        await form.closed()
        let more = await until(conditions.read) { $0.rows.count == fewer.rows.count + 1 }
        XCTAssertTrue(more.rows.contains { $0.details.contains("ためしの言葉") })
        await conditions.closed()
    }

    @MainActor
    func testLeavingTheDemoGoesBackToNoRecorder() async throws {
        let app = await demo()
        let devices = await app.devices()
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

    /// The address field as the iOS tutorial's: what is typed is said back, a keystroke typed over a value the model
    /// has replaced is dropped, and a window that has closed starts clean, with the field following the model.
    @MainActor
    func testTheTutorialsAddressFieldIsSaidAsTheIOSFieldSaysIt() async throws {
        let app = RecBridgeApp.made(files: folder.path, kept: folder.appendingPathComponent("kept").path, version: "0.1 (1)")
        let devices = await app.devices()
        let first = await devices.read()
        XCTAssertTrue(first.welcomes)
        XCTAssertEqual(first.closeLabel, "あとで設定")
        XCTAssertFalse(first.typing)
        XCTAssertTrue(first.connectHeld, "an empty address could be connected to")

        await devices.showAddress()
        await devices.typeHost("レコーダー", seen: first.hostSet)
        let wrong = await devices.read()
        XCTAssertTrue(wrong.typing)
        XCTAssertEqual(wrong.typedHost, "レコーダー")
        XCTAssertTrue(wrong.addressWarning)
        XCTAssertTrue(wrong.connectHeld)

        await devices.typeHost("192.0.2.10:64220", seen: first.hostSet)
        let port = await devices.read()
        XCTAssertFalse(port.connectHeld)
        XCTAssertFalse(port.addressWarning)
        XCTAssertTrue(port.addressNote.contains(":64220"))

        await devices.typeHost("１９２．０．２．１０", seen: first.hostSet)
        let wide = await devices.read()
        XCTAssertFalse(wide.connectHeld, "full-width digits are taken")

        // The window closes: the next opening starts clean, and a keystroke typed before it is dropped.
        await devices.closed()
        let clean = await devices.read()
        XCTAssertEqual(clean.typedHost, "")
        XCTAssertFalse(clean.typing)
        XCTAssertNotEqual(clean.hostSet, first.hostSet, "the screen was not told to take the model's text")
        await devices.typeHost("192.0.2.20", seen: first.hostSet)
        let dropped = await devices.read()
        XCTAssertEqual(dropped.typedHost, "", "a keystroke typed over a replaced value was kept")
    }

    /// The chooser in the demo: the search finds the demo's recorder, the televisions wait while it is chosen, the
    /// screen is done once it has answered, and closing it starts the next opening clean.
    @MainActor
    func testARecorderChosenOnTheTutorialClosesItByItself() async throws {
        let app = await demo()
        let devices = await app.devices()
        await devices.search()
        let found = await until(devices.read, tries: 800) { !$0.recorders.isEmpty && !$0.searching }
        XCTAssertEqual(found.recorders.first?.host, DemoRecorder.host)
        XCTAssertFalse(found.done)
        XCTAssertFalse(found.choosing)
        XCTAssertEqual(found.permissionNotice, "")

        await devices.choose(DemoRecorder.host)
        let chosen = await until(devices.read) { $0.done }
        XCTAssertTrue(chosen.done)
        await devices.closed()
        let after = await devices.read()
        XCTAssertFalse(after.done)
        XCTAssertFalse(after.choosing)
        XCTAssertEqual(after.closeLabel, "閉じる")
    }
}

// MARK: - the sheets

extension AndroidBridgeTests {
    /// A programme that has not begun and is not reserved: one the sheet offers to reserve.
    @MainActor
    private func aProgrammeToReserve(_ guide: GuideWindow) async throws -> GuideRow {
        // Of tomorrow's, which has programmes ahead at any hour: late in a broadcast day today has none left.
        await guide.chooseDay(1)
        let shown = await until(guide.read) { $0.day == 1 && $0.shows == "programmes" }
        return try XCTUnwrap(shown.programmes.first { $0.mark.isEmpty })
    }

    @MainActor
    func testAProgrammeIsReservedFromItsSheetAndTheGuideMarksIt() async throws {
        let app = await demo()
        let guide = app.guide()
        let row = try await aProgrammeToReserve(guide)
        let opening = await guide.open(row.id)
        let sheet = try XCTUnwrap(opening)
        defer { Task { await sheet.closed() } }
        let opened = await until(sheet.read) { $0.offer == "recorder" && !$0.reserveHeld }
        XCTAssertEqual(opened.title, row.title)
        XCTAssertFalse(opened.hasRecorders)
        XCTAssertTrue(opened.qualities.contains { $0.code == opened.quality }, "the mode starts at one offered")
        XCTAssertTrue(opened.repeats.contains { $0.code == "none" })

        await sheet.reserve()
        let asked = await until(sheet.read) { $0.hasAsked }
        XCTAssertEqual(asked.asked.title, "この番組を録画予約しますか？")
        XCTAssertEqual(asked.asked.action, "予約する")
        XCTAssertTrue(asked.asked.message.contains(row.station))
        await sheet.act(asked.asked.key)
        let made = await until(sheet.read) { $0.done || $0.hasAsked }
        XCTAssertTrue(made.done || !made.asked.title.contains("エラー"), "made: \(made.asked.message)")

        let marked = await until(guide.read) { shown in shown.programmes.contains { $0.id == row.id && $0.mark == "予約" } }
        XCTAssertNotNil(marked.programmes.first { $0.id == row.id })
        let reopening = await guide.open(row.id)
        let again = try XCTUnwrap(reopening)
        defer { Task { await again.closed() } }
        let reserved = await until(again.read) { $0.hasRecorders }
        XCTAssertTrue(reserved.recorders.offersChanging)
        XCTAssertNotEqual(reserved.offer, "recorder", "a programme the recorder holds is not offered again")

        // 予約を変更する opens the reservation's own sheet over this one.
        let changing = await again.change("recorder")
        let editing = try XCTUnwrap(changing)
        defer { Task { await editing.closed() } }
        let opened2 = await until(editing.read) { !$0.quality.isEmpty }
        XCTAssertEqual(opened2.title, row.title)
        XCTAssertFalse(opened2.onTelevision)
        let none = await again.change("tv")
        XCTAssertNil(none, "the television holds nothing of it")
    }

    /// A reservation of the demo's whose sheet offers the change, opened: one neither recording nor over, which the
    /// list still shows for a while after it ends. The demo's reservations are at times of the day, so which those are
    /// depends on the hour.
    @MainActor
    private func aReservationToChange(_ list: ReservationsWindow) async throws -> (ReservationRow, ReservationSheetWindow) {
        await list.load()
        let listed = await until(list.read) { !$0.sections.isEmpty }
        for row in listed.sections.flatMap(\.rows) where !row.recording && !row.byTheRecorder {
            let opening = await list.open(row.id)
            let sheet = try XCTUnwrap(opening)
            if await !sheet.read().settled { return (row, sheet) }
            await sheet.closed()
        }
        XCTFail("the demo has no reservation to change")
        throw StillWaiting()
    }

    @MainActor
    func testAReservationIsChangedAndDeletedFromItsSheet() async throws {
        let app = await demo()
        let list = await app.reservations()
        let (row, sheet) = try await aReservationToChange(list)
        defer { Task { await sheet.closed() } }
        let opened = await until(sheet.read) { !$0.quality.isEmpty && !$0.buttonsHeld }
        XCTAssertEqual(opened.title, row.title)
        XCTAssertFalse(opened.changed, "nothing changed yet")
        let other = try XCTUnwrap(opened.qualities.first { $0.code != opened.quality })

        await sheet.chooseQuality(other.code)
        let changed = await until(sheet.read) { $0.changed }
        XCTAssertEqual(changed.changeLabel, "変更をレコーダーに送る")
        await sheet.sendTheChange()
        _ = await until(sheet.read) { $0.done || $0.hasAsked }
        let relisted = await until(list.read) { shown in
            shown.sections.flatMap(\.rows).contains { $0.title == row.title && $0.details.contains(other.code) }
        }
        let moved = try XCTUnwrap(relisted.sections.flatMap(\.rows).first { $0.title == row.title })

        let reopening = await list.open(moved.id)
        let deleting = try XCTUnwrap(reopening)
        defer { Task { await deleting.closed() } }
        _ = await until(deleting.read) { !$0.buttonsHeld }
        await deleting.delete()
        let question = await until(deleting.read) { $0.hasAsked }
        XCTAssertEqual(question.asked.title, "この予約を削除しますか？")
        XCTAssertEqual(question.asked.action, "削除する")
        await deleting.confirmDelete("not the question shown")
        let stillAsked = await deleting.read()
        XCTAssertTrue(stillAsked.hasAsked, "a press for another question does nothing")
        await deleting.confirmDelete(question.asked.key)
        _ = await until(deleting.read) { $0.done }
        let gone = await until(list.read) { shown in !shown.sections.flatMap(\.rows).contains { $0.title == row.title } }
        XCTAssertFalse(gone.sections.flatMap(\.rows).contains { $0.id == moved.id })
    }
}

extension AndroidBridgeTests {
    /// A second press while the first one's request is out does nothing: what Compose shows comes a turn after the
    /// model, and the model's own hold is what the window goes by.
    @MainActor
    func testASecondPressWhileARequestIsOutSendsNothing() async throws {
        let app = await demo()
        let list = await app.reservations()
        let (_, sheet) = try await aReservationToChange(list)
        defer { Task { await sheet.closed() } }
        let opened = await until(sheet.read) { !$0.quality.isEmpty && !$0.buttonsHeld }
        let other = try XCTUnwrap(opened.qualities.first { $0.code != opened.quality })
        await sheet.chooseQuality(other.code)
        _ = await until(sheet.read) { $0.changed }
        await sheet.sendTheChange()
        let sending = await sheet.read()
        XCTAssertFalse(sending.asking.isEmpty, "the change is out")
        await sheet.delete()
        let after = await sheet.read()
        XCTAssertFalse(after.hasAsked, "no question to delete while the change is out")
        _ = await until(sheet.read) { $0.done || $0.hasAsked }
    }
}

// MARK: - the recordings

extension AndroidBridgeTests {
    @MainActor
    func testTheRecordingsAreNarrowedAndSortedByTheMenu() async throws {
        let app = await demo()
        let recordings = await app.recordings()
        await recordings.load()
        let all = await until(recordings.read) { !$0.rows.isEmpty && $0.subtitle == "\($0.rows.count) 件" }
        XCTAssertFalse(all.filtering)
        XCTAssertEqual(all.genre, "")
        XCTAssertTrue(all.genres.first?.label.hasPrefix("すべて") ?? false)
        XCTAssertEqual(Set(all.sorts.map(\.code)), Set(AppModel.TitleSort.allCases.map(\.rawValue)))
        let genre = try XCTUnwrap(all.genres.dropFirst().first)

        await recordings.chooseGenre(genre.code)
        let narrowed = await until(recordings.read) { $0.genre == genre.code }
        XCTAssertTrue(narrowed.filtering)
        XCTAssertLessThan(narrowed.rows.count, all.rows.count, "a genre narrowed nothing")
        XCTAssertTrue(narrowed.subtitle.contains("\(narrowed.rows.count) 件"))

        await recordings.chooseGenre("")
        await recordings.chooseState("unwatched")
        let unwatched = await until(recordings.read) { $0.state == "unwatched" }
        XCTAssertFalse(unwatched.rows.isEmpty, "the demo has recordings not yet watched")
        XCTAssertTrue(unwatched.rows.allSatisfy(\.unwatched))
        await recordings.chooseState("")

        // Oldest first puts the first of the newest-first list last.
        await recordings.chooseSort(AppModel.TitleSort.oldest.rawValue)
        let oldest = await until(recordings.read) { $0.sort == AppModel.TitleSort.oldest.rawValue }
        XCTAssertTrue(oldest.filtering, "a sort other than newest first was not said")
        XCTAssertEqual(oldest.rows.last?.id, all.rows.first?.id)
        await recordings.chooseSort(AppModel.TitleSort.newest.rawValue)
        _ = await until(recordings.read) { !$0.filtering }
    }

    /// A recording's sheet protects it, says why it then cannot be deleted, and, unprotected, deletes it after asking
    /// and closes. Writes only to the demo's invented recorder.
    @MainActor
    func testARecordingIsProtectedAndDeletedFromItsSheet() async throws {
        let app = await demo()
        let recordings = await app.recordings()
        await recordings.load()
        let listed = await until(recordings.read) { !$0.rows.isEmpty }
        let row = try XCTUnwrap(listed.rows.first { !$0.recording && !$0.protected })
        let opening = await recordings.open(row.id)
        let sheet = try XCTUnwrap(opening)
        defer { Task { await sheet.closed() } }
        let opened = await until(sheet.read) { !$0.deleteHeld }
        XCTAssertEqual(opened.title, row.title)
        XCTAssertTrue(opened.offersPlayback)
        XCTAssertEqual(opened.protectLabel, "保護（自動削除の対象外にする）")

        await sheet.setProtected(true)
        let protected = await until(sheet.read) { $0.protected && !$0.asking }
        XCTAssertEqual(protected.whyNotDeleted, RecorderDriver.protectedCannotBeDeleted.asABody)
        XCTAssertTrue(protected.deleteHeld)
        await sheet.delete()
        let refused = await sheet.read()
        XCTAssertFalse(refused.hasAsked, "a protected recording was asked to be deleted")

        await sheet.setProtected(false)
        let unprotected = await until(sheet.read) { !$0.protected && !$0.asking && !$0.deleteHeld }
        XCTAssertEqual(unprotected.whyNotDeleted, "")
        await sheet.delete()
        let question = await until(sheet.read) { $0.hasAsked }
        XCTAssertEqual(question.asked.title, "この録画を削除しますか？")
        await sheet.confirmDelete(question.asked.key)
        _ = await until(sheet.read) { $0.done }
        let after = await until(recordings.read) { shown in !shown.rows.contains { $0.id == row.id } }
        XCTAssertEqual(after.rows.count, listed.rows.count - 1)
    }
}

struct StillWaiting: Error {}

/// A drawer that writes what it was asked for as a PNG's signature and the text, so a test sees what reached it.
final class Drawing: TileDrawer, @unchecked Sendable {
    func draw(_ text: String, _ index: Int64, _ path: String) {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += Array("\(index):\(text)".utf8)
        FileManager.default.createFile(atPath: path, contents: Data(bytes))
    }
}

final class Counting: ScreenListener, @unchecked Sendable {
    private let lock = NSLock()
    private var told = 0

    var count: Int { lock.withLock { told } }

    func changed() { lock.withLock { told += 1 } }
}

// MARK: - the settings

extension AndroidBridgeTests {
    /// The settings say the demo's recorder and the guide kept, take what is typed as the reader's and what the model
    /// sets as its own, keep the mode chosen, and end the demo, the fields following.
    @MainActor
    func testTheSettingsSayTheRecorderAndFollowTheFields() async throws {
        let app = await demo()
        let settings = await app.settings()
        await settings.appeared()
        let shown = await until(settings.read) { !$0.facts.isEmpty && $0.canChoose && $0.typedHost == DemoRecorder.host }
        XCTAssertTrue(shown.demo)
        XCTAssertEqual(shown.facts.first?.label, "機種")
        XCTAssertFalse(shown.standing.isEmpty)
        XCTAssertFalse(shown.offersConnect)
        XCTAssertFalse(shown.offersReconnect)
        XCTAssertEqual(shown.version, "0.1 (1)")
        XCTAssertTrue(shown.guide.contains { $0.label == Codes.broadcastingLabel["td"] && $0.value.hasSuffix(" 番組") })
        XCTAssertGreaterThan(shown.hostSet, 0, "the address the field started at was not said to be the model's")

        // Typed, the address is offered the connect and said back, and is not taken for the model's own setting.
        await settings.typeHost("192.0.2.10:64220", seen: shown.hostSet)
        let typed = await until(settings.read) { $0.offersConnect }
        XCTAssertEqual(typed.typedHost, "192.0.2.10:64220")
        XCTAssertEqual(typed.hostSet, shown.hostSet, "what was typed was taken for the model's")
        XCTAssertTrue(typed.addressNote.contains("「:64220」"))
        XCTAssertFalse(typed.addressWarning)
        XCTAssertFalse(typed.connectHeld)
        // A keystroke typed over a value the model has replaced since is dropped.
        await settings.typeHost("192.0.2.1", seen: shown.hostSet - 1)
        let stale = await settings.read()
        XCTAssertEqual(stale.typedHost, "192.0.2.10:64220", "a keystroke over the model's older value was kept")

        // このアドレスに接続 held back, for an address no URL can be built on, does nothing: pressed all the same, it
        // would have ended the demo for that address.
        await settings.typeHost("192.0.2.10/guide", seen: shown.hostSet)
        let unusable = await until(settings.read) { $0.addressWarning }
        XCTAssertTrue(unusable.connectHeld)
        await settings.connect()
        let held = await settings.read()
        XCTAssertTrue(held.demo, "a press held back went through")
        XCTAssertEqual(held.hostSet, unusable.hostSet)
        await settings.typeHost("192.0.2.10:64220", seen: shown.hostSet)

        let other = try XCTUnwrap(shown.qualities.first { $0.code != shown.quality })
        await settings.chooseQuality(other.code)
        _ = await until(settings.read) { $0.quality == other.code }
        XCTAssertEqual(DefaultQuality.current(in: app.quality.defaults), other.code, "the mode chosen was not kept")
        await settings.chooseQuality("not a mode")
        let kept = await settings.read()
        XCTAssertEqual(kept.quality, other.code)

        let disclaimer = settings.disclaimer()
        XCTAssertEqual(disclaimer.title, Disclaimer.title)
        XCTAssertEqual(disclaimer.sections.map(\.label), Disclaimer.sections.map(\.heading))

        // Nothing was set up before the demo, so ending it leaves no address, which the field follows.
        await settings.leaveDemo()
        let after = await until(settings.read) { !$0.demo && $0.typedHost.isEmpty }
        XCTAssertGreaterThan(after.hostSet, typed.hostSet, "the model's moving the address was not said")
        XCTAssertTrue(after.facts.isEmpty)
        XCTAssertEqual(after.standing, "")
    }

    /// The demo's television, found by the search, registered from its sheet by the number the sheet says -- a wrong
    /// one turned down, the field emptied, and a keystroke typed over the number before it dropped -- and then in the
    /// settings: what it says of itself, and テレビを外す, which asks with what waits for it and takes it away.
    @MainActor
    func testTheDemosTelevisionIsRegisteredFromItsSheetAndTakenAwayFromTheSettings() async throws {
        let app = await demo()
        let devices = await app.devices()
        let settings = await app.settings()
        let before = await until(settings.read) { $0.canChoose }
        XCTAssertFalse(before.television.added)
        XCTAssertTrue(before.television.facts.isEmpty)

        await devices.search()
        let found = await until(devices.read, tries: 800) { !$0.televisions.isEmpty && !$0.searching }
        let television = try XCTUnwrap(found.televisions.first)
        XCTAssertEqual(television.host, DemoTV.host)
        XCTAssertEqual(television.name, DemoTV.model)
        XCTAssertTrue(television.registers)
        XCTAssertFalse(television.inUse)
        XCTAssertFalse(found.choosing)

        let sheet = await app.registerTV(host: television.host, connectAtOnce: true, again: false)
        await sheet.appeared()
        let asking = await until(sheet.read) { $0.askingForPIN && !$0.working }
        XCTAssertEqual(asking.title, "テレビを追加")
        XCTAssertEqual(asking.typedHost, DemoTV.host)
        XCTAssertTrue(asking.addressHeld)
        XCTAssertEqual(asking.pressLabel, "登録する")
        XCTAssertTrue(asking.pressHeld, "an empty number could be pressed")
        XCTAssertTrue(asking.pinNote.contains(DemoTV.pin), "the demo's number was not said")
        await sheet.typeHost("192.0.2.99")
        let held = await sheet.read()
        XCTAssertEqual(held.typedHost, DemoTV.host, "the address changed with the PIN asked for")

        await sheet.typePIN("0000", seen: asking.pinSet)
        _ = await until(sheet.read) { !$0.pressHeld }
        await sheet.press()
        let turnedDown = await until(sheet.read) { !$0.message.isEmpty && !$0.working }
        XCTAssertEqual(turnedDown.pin, "")
        XCTAssertGreaterThan(turnedDown.pinSet, asking.pinSet, "the model's emptying the field was not said")
        await sheet.typePIN("9", seen: asking.pinSet)
        let stale = await sheet.read()
        XCTAssertEqual(stale.pin, "", "a keystroke over the number turned down was kept")
        XCTAssertEqual(stale.pinSet, turnedDown.pinSet)

        await sheet.typePIN(DemoTV.pin, seen: turnedDown.pinSet)
        _ = await until(sheet.read) { $0.pin == DemoTV.pin }
        await sheet.press()
        _ = await until(sheet.read) { $0.done }
        await sheet.closed()

        let added = await until(settings.read) { $0.television.facts.contains { $0.label == "状態" && $0.value == "接続済み" } }
        XCTAssertTrue(added.television.added)
        XCTAssertTrue(added.television.facts.contains { $0.label == "機種" && $0.value == DemoTV.model })
        XCTAssertTrue(added.television.facts.contains { $0.label == "IP アドレス" && $0.value == DemoTV.host })
        XCTAssertFalse(added.television.offersRegistering)
        XCTAssertFalse(added.television.offersReconnect)
        XCTAssertFalse(added.television.offersTheHelper, "the demo's television was offered a helper")
        XCTAssertEqual(added.televisions.first?.inUse, true)
        XCTAssertEqual(added.televisions.first?.registers, false, "a found television could be tapped with one added")

        await settings.removeTV()
        let asked = await until(settings.read) { $0.television.asksToRemove }
        XCTAssertEqual(asked.television.removalQuestion, TVSettingsState.removalQuestion)
        XCTAssertTrue(asked.television.removalMessage.hasPrefix("この端末から、テレビのアドレスと登録を消します。"))
        await settings.removalClosed()
        let kept = await until(settings.read) { !$0.television.asksToRemove }
        XCTAssertTrue(kept.television.added, "closing the question took the television away")
        await settings.confirmRemovingTV()
        let still = await settings.read()
        XCTAssertTrue(still.television.added, "外す went through with no question up")
        await settings.removeTV()
        _ = await until(settings.read) { $0.television.asksToRemove }
        await settings.confirmRemovingTV()
        let removed = await until(settings.read) { !$0.television.added }
        XCTAssertFalse(removed.television.asksToRemove)
        XCTAssertTrue(removed.demo)
    }

    /// The television's registration and the helper's token are kept in files of the folder that never leaves the
    /// device: read back as written, gone once removed, and a file that does not read as one is none.
    func testTheRegistrationIsKeptInTheFolderThatStaysOnTheDevice() throws {
        let kept = folder.appendingPathComponent("kept")
        let credentials = KeptTVCredentials(folder: kept)
        XCTAssertNil(credentials.load())
        let registration = TVCredentials(clientID: "BDBridge:kept", cookie: "cookie", cookieReceived: Date(),
                                         cookieMaxAge: 1_209_600)
        credentials.save(registration)
        XCTAssertEqual(KeptTVCredentials(folder: kept).load(), registration, "not read back as written")
        credentials.remove()
        XCTAssertNil(credentials.load())
        try Data("not a registration".utf8).write(to: credentials.file)
        XCTAssertNil(credentials.load(), "a file that is no registration read as one")

        let token = KeptTVHelperToken(folder: kept)
        XCTAssertNil(token.load())
        token.save("token")
        XCTAssertEqual(KeptTVHelperToken(folder: kept).load(), "token")
        token.remove()
        XCTAssertNil(token.load())
    }

    /// A station hidden, moved and put back, as the guide then shows them; kept in the cache, so that the list read
    /// again has them as they were left.
    @MainActor
    func testTheStationsAreHiddenMovedAndPutBack() async throws {
        let app = await demo()
        let guide = app.guide()
        _ = await until(guide.read) { $0.shows == "programmes" }
        let channels = await app.channels()
        defer { Task { await channels.closed() } }
        let listed = await until(channels.read) { $0.loaded && $0.stations.count >= 3 }
        XCTAssertEqual(listed.broadcasting, "td")
        XCTAssertFalse(listed.customised)
        XCTAssertEqual(listed.footer, ChannelsState.footer)
        XCTAssertTrue(listed.types.contains { $0.code == "bs" })
        let first = listed.stations[0], third = listed.stations[2]

        await channels.show(first.id, false)
        let hidden = await until(channels.read) { !$0.stations[0].shown }
        XCTAssertTrue(hidden.customised)
        _ = await until(guide.read) { shown in !shown.stations.contains { $0.name == first.name } }

        let movedDown = await channels.move(first.id, from: 0, to: 2)
        XCTAssertTrue(movedDown)
        let moved = await until(channels.read) { $0.stations[2].id == first.id }
        XCTAssertEqual(moved.stations[1].id, third.id)
        // A move for a list that has changed since -- the station is no longer where the drag began -- is refused.
        let stale = await channels.move(first.id, from: 0, to: 1)
        XCTAssertFalse(stale)
        let again = await app.channels()
        defer { Task { await again.closed() } }
        let reread = await until(again.read) { $0.loaded && !$0.stations.isEmpty }
        XCTAssertEqual(reread.stations.map(\.id), moved.stations.map(\.id), "the order was not kept")
        let movedUp = await channels.move(first.id, from: 2, to: 0)
        XCTAssertTrue(movedUp)
        let up = await until(channels.read) { $0.stations[0].id == first.id }
        XCTAssertEqual(up.stations.map(\.id), listed.stations.map(\.id), "moved back up, the order is the first")

        await channels.reset()
        let back = await until(channels.read) { !$0.customised }
        XCTAssertEqual(back.stations.map(\.id), listed.stations.map(\.id))
        XCTAssertTrue(back.stations.allSatisfy(\.shown))

        await channels.choose("bs")
        let bs = await until(channels.read) { $0.broadcasting == "bs" && $0.stations.first?.id.hasPrefix("bs") == true }
        XCTAssertFalse(bs.stations.isEmpty)
        await channels.choose("none of them")
        let still = await channels.read()
        XCTAssertEqual(still.broadcasting, "bs")
    }
}
