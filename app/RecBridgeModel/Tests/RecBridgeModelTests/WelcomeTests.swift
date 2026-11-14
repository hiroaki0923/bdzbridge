import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// The tutorial as the reader works it (`WelcomeState`): what holds the search, the recorders, the televisions, the
/// address and the demo; when a recorder chosen has answered, and so when the tutorial closes; the button's label;
/// the address typed; and the demo. The connect itself is the model's, held elsewhere.
@MainActor
final class WelcomeTests: XCTestCase {
    /// A recorder chosen is not `done` before the press, holds the televisions and everything that would change the
    /// recorder while the connect is out, and is `done` once it has answered.
    func testARecorderChosenClosesTheTutorialOnceItAnswers() async throws {
        let bench = try aBench()
        let other = NamedRecorder(2)
        let model = bench.model(recorders: [Bench.host: NamedRecorder(1), Bench.otherHost: other])
        await model.start()
        try await untilConnected(model)
        let welcome = WelcomeState(model: model)
        XCTAssertFalse(welcome.done, "the tutorial was over before anything was chosen here")
        XCTAssertFalse(welcome.holdsTelevisions)
        XCTAssertFalse(welcome.holdsRecorders)
        XCTAssertFalse(welcome.holdsDemo)

        await other.hold()
        addTeardownBlock { await other.letGo() }
        let choosing = Task { await welcome.take(Bench.otherHost) }
        try await until("the choice was never out") { !model.canChangeRecorder }

        XCTAssertTrue(welcome.holdsTelevisions, "a television could be registered over a recorder being chosen")
        XCTAssertTrue(welcome.holdsRecorders)
        XCTAssertTrue(welcome.holdsDemo)
        XCTAssertFalse(welcome.done, "the tutorial closed before the recorder answered")
        welcome.typedHost = Bench.otherHost
        XCTAssertTrue(welcome.holdsConnect, "an address could be connected to while the recorder could not be changed")
        XCTAssertTrue(welcome.holdsSearch, "the search was not held while the recorder worked")

        await other.letGo()
        await choosing.value
        XCTAssertEqual(model.info?.host, Bench.otherHost, "the recorder was not connected to")
        XCTAssertTrue(welcome.done, "the tutorial did not close on the recorder's answer")
    }

    /// A choice that stays silent is over with its answer: the televisions are free again and the tutorial does not
    /// close.
    func testARecorderThatStaysSilentEndsTheChoice() async throws {
        let bench = try aBench()
        let model = bench.model(recorders: [Bench.host: NamedRecorder(1)])
        await model.start()
        try await untilConnected(model)
        let welcome = WelcomeState(model: model)

        await welcome.take(Bench.otherHost)

        XCTAssertFalse(welcome.holdsTelevisions, "the televisions stayed held after the choice was over")
        XCTAssertFalse(welcome.done)
    }

    /// Opened with a connection already up, the tutorial does not close at once: only an answer to a choice made on it
    /// does, which is counted from the press.
    func testATutorialOpenedWithAConnectionUpClosesOnlyOnTheAnswerToItsOwnChoice() async throws {
        let (_, _, model) = try await connectedHome()
        XCTAssertGreaterThan(model.timesAttached, 0)
        let welcome = WelcomeState(model: model)
        XCTAssertFalse(welcome.done, "a connection that was already up closed the tutorial")

        await welcome.take(Bench.host)

        XCTAssertTrue(welcome.done, "the recorder chosen again was not taken for an answer")
    }

    /// With the system keeping the app off the local network, the connect waits for the permission: the choice stays out
    /// after `take` returns, and the tutorial closes when the recorder answers after the permission comes.
    func testAChoiceWaitsForThePermissionAndClosesWhenTheRecorderAnswersAfterIt() async throws {
        let (bench, recorder, model) = try await connectedHome()
        addTeardownBlock { await recorder.letGo() }
        bench.linksAreKeptOff = true
        await recorder.goQuiet(for: 1_000)
        let welcome = WelcomeState(model: model)

        await welcome.take(Bench.host)

        XCTAssertTrue(model.connectBlocked, "the connect was not waiting for the permission")
        XCTAssertTrue(welcome.showsPermissionNotice)
        XCTAssertTrue(welcome.holdsTelevisions, "the choice was dropped while it waited for the permission")
        XCTAssertFalse(welcome.done)
        try await until("the model's wait for the permission was never begun") { !bench.linksPermissionWaits.isEmpty }

        await recorder.goQuiet(for: 0)
        bench.linksAreKeptOff = false
        bench.theLinksPermissionComes()
        try await until("the recorder never answered after the permission came") { welcome.done }
        XCTAssertFalse(welcome.showsPermissionNotice)
    }

    /// あとで設定 while nothing is set up, 閉じる once a recorder is saved, and once only a television is.
    func testTheCloseButtonSaysLaterWhileNothingIsSetUp() async throws {
        let bench = try aBench()
        let none = bench.modelWithNoRecorder()
        XCTAssertEqual(WelcomeState(model: none).closeLabel, "あとで設定")

        let saved = bench.model(recorders: [:])
        XCTAssertEqual(WelcomeState(model: saved).closeLabel, "閉じる")

        let only = DemoTV()
        let television = bench.modelWithNoRecorder(television: only, credentials: MemoryTVCredentials())
        XCTAssertFalse(television.welcomes)
        XCTAssertEqual(WelcomeState(model: television).closeLabel, "閉じる")
    }

    /// An address typed is tidied, and held for one no URL can be built on; the press writes what it connects to back
    /// into the field, port taken off, and connects to it.
    func testTheTypedAddressIsTidiedHeldAndWrittenBack() async throws {
        let bench = try aBench()
        let model = bench.model(recorders: [Bench.host: NamedRecorder(1), Bench.otherHost: NamedRecorder(2)])
        await model.start()
        try await untilConnected(model)
        let welcome = WelcomeState(model: model)
        XCTAssertTrue(welcome.holdsConnect, "an empty field could be connected to")

        welcome.typedHost = "192.0.2.10/guide"
        XCTAssertTrue(welcome.holdsConnect)

        welcome.typedHost = "\(Bench.otherHost):64220"
        XCTAssertFalse(welcome.holdsConnect)
        XCTAssertEqual(welcome.tidied.host, Bench.otherHost)

        await welcome.connectTyped()

        XCTAssertEqual(welcome.typedHost, Bench.otherHost, "the field did not show what was connected to")
        XCTAssertEqual(model.host, Bench.otherHost)
        XCTAssertEqual(model.info?.host, Bench.otherHost)
        XCTAssertTrue(welcome.done)
    }

    /// The search is held while a scan holds the button, and starts nothing then; the progress is none while the scan
    /// is held up by the permission; `closed()` ends a scan under way.
    func testTheSearchIsHeldWhileOneRunsAndEndsWithTheScreen() async throws {
        let bench = try aBench()
        let subnet = bench.joinWiFi(with: [Bench.host: NamedRecorder(1)])
        let model = bench.modelWithNoRecorder()
        await model.start()
        let welcome = WelcomeState(model: model)
        XCTAssertFalse(welcome.holdsSearch)
        XCTAssertNil(welcome.progress)

        await subnet.hold()
        addTeardownBlock { await subnet.letGo() }
        welcome.search()
        try await until("the search never began") { model.scanning != nil }
        XCTAssertTrue(welcome.holdsSearch)
        XCTAssertTrue(welcome.searching)
        XCTAssertEqual(welcome.progress?.total, model.scanning?.total)
        let asked = await subnet.asked

        welcome.search()
        expectEqual(await subnet.asked, asked, "a second press asked more addresses")

        welcome.closed()
        XCTAssertNil(model.scanning, "the scan outlived the tutorial")
        XCTAssertFalse(welcome.holdsSearch)
    }

    /// The demo, entered from the tutorial, turns on and ends a scan under way.
    func testTheDemoIsEnteredFromTheTutorialAndEndsTheScan() async throws {
        let bench = try aBench()
        let subnet = bench.joinWiFi()
        let model = bench.modelWithNoRecorder()
        await model.start()
        let welcome = WelcomeState(model: model)
        await subnet.hold()
        addTeardownBlock { await subnet.letGo() }
        welcome.search()
        try await until("the search never began") { model.scanning != nil }

        await welcome.enterDemo()

        XCTAssertTrue(model.demo)
        XCTAssertNil(model.scanning, "the scan went on into the demo")
        XCTAssertFalse(welcome.holdsDemo)
    }

    /// The sentences the screens lay out are as the iOS tutorial words them.
    func testTheTutorialsSentences() {
        XCTAssertEqual(Tutorial.heading, "セットアップ")
        XCTAssertEqual(Tutorial.reviewRow, "セットアップ手順を見る")
        XCTAssertEqual(Tutorial.step3Title, "「レコーダーとテレビを探す」をタップする")
        XCTAssertTrue(Tutorial.demoFooter.hasSuffix("いつでも設定から終了できます。"))
    }
}
