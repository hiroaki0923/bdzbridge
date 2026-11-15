import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// The strip at the top of every screen, line by line, and the buttons it shares with the screen with no recorder to
/// talk to (`AppModel.Strip.says`, `offer`, `AppModel.Offer`): what each line says, which button it has and what that
/// is called, when a button is held, and what a press and a close do. Which line is shown, and in what order, is held
/// by `QueueWithATelevisionTests` and `HostGateTests`; the screen's own words by `EmptyScreenTests`.
@MainActor
final class StripTests: XCTestCase {
    private static let every: [AppModel.Offer] = [.close, .leaveDemo, .reconnect, .search, .registerTV, .reconnectTV]

    /// The buttons held now.
    private func held(_ model: AppModel) -> [AppModel.Offer] {
        Self.every.filter { model.holds($0) }
    }

    /// Each line in the words the strip has always said, with its button: 閉じる for the two that stay until they
    /// are closed, 終了 for the demo, 再接続 for either device given up on, 登録 for the television to be registered
    /// again, and none while something is under way, while the permission is in the way and for the disk away.
    func testEachLineSaysWhatTheStripHasAlwaysSaidWithItsButton() {
        let lines: [(line: AppModel.Strip, says: String, offer: AppModel.Offer?)] = [
            (.busy("予約一覧を取得中"), "予約一覧を取得中", nil),
            (.anotherTookOver, "別のレコーダーが応答したため、一覧を読み直しました。操作の途中だった場合は、確かめてからやり直してください。",
             .close),
            (.report("「朝の番組」を送信しました", inFull: true), "「朝の番組」を送信しました", .close),
            (.demo, "サンプルデータを表示しています", .leaveDemo),
            (.blocked, "ローカルネットワークが許可されていません", nil),
            (.recorderGaveUp, "レコーダーの応答がありません", .reconnect),
            (.tvNeedsPairing, "テレビの登録が必要です", .registerTV),
            (.tvGaveUp, "テレビの応答がありません", .reconnectTV),
            (.tvDiskAway, "録画用の USB HDD が見つからないため、テレビへの予約は送っていません", nil),
        ]
        for (line, says, offer) in lines {
            XCTAssertEqual(line.says, says, "\(line)")
            XCTAssertEqual(line.offer, offer, "\(line)")
        }
        XCTAssertEqual(Self.every.map(\.label), ["閉じる", "終了", "再接続", "レコーダーを探す", "登録", "再接続"])
    }

    /// 終了 is held while the recorder in play may not be changed, and 再接続 and the search while a bulk job has the
    /// recorder; 閉じる, 登録 and the television's 再接続 never are. With the job over, nothing is held.
    func testTheButtonsAreHeldWhileAJobHasTheRecorder() async throws {
        let (_, recorder, model) = try await connectedHome(guide: false)
        addTeardownBlock { await recorder.letGo() }
        try await until("the recorder in play never came free") { model.canChangeRecorder }
        XCTAssertEqual(held(model), [], "a button is held with nothing under way")

        await model.loadTitles()
        let idle = try XCTUnwrap(model.titles.first { !$0.recording && !$0.protected })
        await recorder.hold(only: Ask.details)
        model.startBulk(.delete, ids: [idle.id])
        XCTAssertTrue(model.jobRunning, "the job was not started")
        XCTAssertEqual(held(model), [.leaveDemo, .reconnect, .search])

        await recorder.letGo()
        try await until("the run never ended") { !model.jobRunning }
        try await until("the recorder in play never came free") { model.canChangeRecorder }
        XCTAssertEqual(held(model), [], "a button is still held with the job over")
    }

    /// 閉じる takes down the line it is on and nothing else: that another recorder took over, then what became of
    /// what was waiting. Closing any other line leaves the strip as it was.
    func testClosingALineTakesDownThatLineAlone() async throws {
        let (_, _, model) = try await connectedHome(guide: false)
        model.anotherTookOver = true
        model.recorderHost.report = "「朝の番組」を送信しました"
        let report = AppModel.Strip.report("「朝の番組」を送信しました", inFull: false)
        XCTAssertEqual(model.strip(), .anotherTookOver)

        let others: [AppModel.Strip] = [.busy("予約一覧を取得中"), .demo, .blocked, .recorderGaveUp, .tvNeedsPairing,
                                        .tvGaveUp, .tvDiskAway]
        for other in others { model.close(other) }
        XCTAssertEqual(model.strip(), .anotherTookOver, "closing another line took this one down")

        model.close(.anotherTookOver)
        XCTAssertFalse(model.anotherTookOver)
        XCTAssertEqual(model.strip(), report, "closing that another recorder took over took the report with it")
        model.close(report)
        XCTAssertNil(model.queueReport)
        XCTAssertNil(model.strip())
    }

    /// 再接続 connects to the recorder given up on, and 終了 leaves the demo. The search, 登録 and 閉じる do nothing
    /// here: the first two open screens of the platform's, and 閉じる is a close.
    func testAPressConnectsAgainOrLeavesTheDemo() async throws {
        let (_, recorder, model) = try await connectedHome(guide: false)
        await recorder.goQuiet(on: Ask.reservations)
        await model.loadReservations()
        XCTAssertEqual(model.strip(), .recorderGaveUp, "the recorder was not given up on")

        let before = await recorder.asked
        for nothing in [AppModel.Offer.close, .search, .registerTV] { await model.act(on: nothing) }
        XCTAssertTrue(model.gaveUp, "a button that does nothing here connected")
        expectEqual(await recorder.asked(Ask.description, since: before), 0, "a button that does nothing asked")

        await model.act(on: .reconnect)
        try await untilIdle(model)
        XCTAssertTrue(model.connected, "再接続 did not connect: \(model.problem(for: .recorder) ?? "no reason given")")
        XCTAssertNil(model.strip())

        await model.enterDemo()
        XCTAssertEqual(model.strip(), .demo, "the demo did not start")
        try await until("the demo's recorder never came free") { !model.holds(.leaveDemo) }
        await model.act(on: .leaveDemo)
        XCTAssertFalse(model.demo, "終了 did not leave the demo")
    }

    /// The television's 再接続 connects to the television given up on, once it answers again.
    func testAPressConnectsToTheTelevisionGivenUpOn() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let television = DemoTV()
        await television.goSilent()
        let model = bench.model(recorder: DemoRecorder(), television: television,
                                credentials: await registered(with: television))
        await model.start()
        try await untilConnected(model)
        try await until("the television was not given up on") { model.tv?.session.gaveUp == true }
        XCTAssertEqual(model.strip(), .tvGaveUp)

        await television.goSilent(false)
        await model.act(on: .reconnectTV)
        try await untilTheTelevisionIsConnected(model)
        XCTAssertNotEqual(model.strip(), .tvGaveUp, "the television connected is still said to be given up on")
    }
}
