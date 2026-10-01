import Foundation
import XCTest
@testable import RecorderKit

/// The decisions about a device that has stopped answering: whether to give up, whether to try once more,
/// and whether a return to the app or a change of network is worth another try. One test to a rule of
/// docs/porting.md (端末側の設計メモ); the app's `SessionRuleTests` hold the same rules from the outside.
final class LinkRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - where it was tried

    func testNothingHasBeenTriedAtFirst() {
        let link = LinkState()
        XCTAssertNil(link.triedOn)
        XCTAssertEqual(link.tries, 0)
        XCTAssertTrue(link.changed(now: "home"), "a network never tried on is one worth trying")
    }

    func testATryIsCountedAndRemembersItsNetwork() {
        var link = LinkState()
        link.tried(on: "home")
        XCTAssertEqual(link.triedOn, "home")
        XCTAssertEqual(link.tries, 1)
        XCTAssertFalse(link.changed(now: "home"))
        XCTAssertTrue(link.changed(now: "away"))

        link.tried(on: "home")
        XCTAssertEqual(link.tries, 2, "a second try on the same network is still a try")
    }

    /// The Wi-Fi going and coming back while a request was out is how a request meets silence at home, and
    /// the network before and after it is the same one. That the phone was elsewhere in between is kept.
    func testHavingBeenOnAnotherNetworkIsRememberedOnceBack() {
        var link = LinkState()
        link.tried(on: "home")
        link.noted(network: "")
        link.noted(network: "home")
        XCTAssertTrue(link.sawAnotherNetwork)
        XCTAssertTrue(link.changed(now: "home"), "back where it tried, but it has been away since")
    }

    func testALookThatFindsTheSameNetworkNotesNothing() {
        var link = LinkState()
        link.tried(on: "home")
        link.noted(network: "home")
        XCTAssertFalse(link.sawAnotherNetwork)
        XCTAssertFalse(link.changed(now: "home"))
    }

    func testATryForgetsThatThePhoneWasAway() {
        var link = LinkState()
        link.tried(on: "home")
        link.noted(network: "")
        link.tried(on: "home")
        XCTAssertFalse(link.sawAnotherNetwork)
        XCTAssertFalse(link.changed(now: "home"))
    }

    // MARK: - after a connect

    /// Only silence is given up on. A device that answered, if only to refuse, is there and has said what
    /// is wrong.
    func testOnlySilenceIsGivenUpOn() {
        XCTAssertTrue(LinkRules.givesUp(reached: false, silent: true))
        XCTAssertFalse(LinkRules.givesUp(reached: false, silent: false))
        XCTAssertFalse(LinkRules.givesUp(reached: true, silent: false))
        XCTAssertFalse(LinkRules.givesUp(reached: true, silent: true))
    }

    /// A connect that got nowhere tries once more when the network it started on is no longer the one under
    /// it; the caller asks this once.
    func testAConnectThatGotNowhereTriesAgainOnlyWhenTheNetworkChangedUnderIt() {
        XCTAssertTrue(LinkRules.triesOnceMore(reached: false, networkChanged: true))
        XCTAssertFalse(LinkRules.triesOnceMore(reached: false, networkChanged: false))
        XCTAssertFalse(LinkRules.triesOnceMore(reached: true, networkChanged: true))
        XCTAssertFalse(LinkRules.triesOnceMore(reached: true, networkChanged: false))
    }

    // MARK: - before an operation

    /// A device quiet for a minute and a half is made sure of first; one that answered more lately is not,
    /// unless the network has changed since and the answer says nothing any more.
    func testADeviceQuietForAMinuteAndAHalfIsMadeSureOfFirst() {
        XCTAssertEqual(LinkRules.dozeAfter, 90)
        XCTAssertFalse(LinkRules.needsCheck(lastAnswer: now.addingTimeInterval(-89), now: now))
        XCTAssertTrue(LinkRules.needsCheck(lastAnswer: now.addingTimeInterval(-90), now: now))
        XCTAssertTrue(LinkRules.needsCheck(lastAnswer: nil, now: now), "one that never answered is not known to be up")
        XCTAssertTrue(LinkRules.needsCheck(lastAnswer: now, now: now, evenIfRecent: true))
    }

    // MARK: - coming back to the app

    private func onReturn(wasAway: Bool = true, hasAddress: Bool = true, busy: Bool = false,
                          checking: Bool = false, connected: Bool = false, answered secondsAgo: TimeInterval? = nil,
                          gaveUp: Bool = false, networkChanged: Bool = false) -> LinkRules.OnReturn {
        LinkRules.onReturn(wasAway: wasAway, hasAddress: hasAddress, busy: busy, checking: checking,
                           connected: connected, lastAnswer: secondsAgo.map { now.addingTimeInterval(-$0) },
                           now: now, gaveUp: gaveUp, networkChanged: networkChanged)
    }

    /// Becoming active is not coming back: Control Centre and a system alert go nowhere.
    func testBecomingActiveWithoutHavingBeenAwayDoesNothing() {
        XCTAssertEqual(onReturn(wasAway: false), .nothing)
        XCTAssertEqual(onReturn(wasAway: false, gaveUp: true, networkChanged: true), .nothing)
    }

    func testWithNoAddressThereIsNothingToComeBackTo() {
        XCTAssertEqual(onReturn(hasAddress: false), .nothing)
        XCTAssertEqual(onReturn(hasAddress: false, busy: true), .nothing, "not even a look: there is nothing to look for")
    }

    /// While something is under way, or the device is being made sure of, connecting would make a second
    /// client beside the one at work. The network may have moved all the same, and is looked at.
    func testWhileBusyOrCheckingTheNetworkIsOnlyLookedAt() {
        XCTAssertEqual(onReturn(busy: true), .lookAtTheNetwork)
        XCTAssertEqual(onReturn(checking: true), .lookAtTheNetwork)
        XCTAssertEqual(onReturn(busy: true, connected: true, answered: 5), .lookAtTheNetwork)
    }

    /// Not on every flick between apps: a device that answered within the last minute is left alone.
    func testADeviceThatAnsweredWithinAMinuteIsNotAskedAgain() {
        XCTAssertEqual(LinkRules.freshAnswer, 60)
        XCTAssertEqual(onReturn(connected: true, answered: 59), .nothing)
        XCTAssertEqual(onReturn(connected: true, answered: 60), .connect)
        XCTAssertEqual(onReturn(connected: true, answered: nil), .connect)
        // Not connected, the age of an answer says nothing.
        XCTAssertEqual(onReturn(connected: false, answered: 5), .connect)
    }

    /// Given up stays given up on the network it was given up on: coming back is not news. It may be news a
    /// moment from now, so the network is looked at.
    func testHavingGivenUpOnThisNetworkOnlyLooks() {
        XCTAssertEqual(onReturn(gaveUp: true, networkChanged: false), .lookAtTheNetwork)
        XCTAssertEqual(onReturn(gaveUp: true, networkChanged: true), .connect)
    }

    func testOtherwiseComingBackConnects() {
        XCTAssertEqual(onReturn(), .connect)
    }

    // MARK: - the network changing while the app is open

    private func onChange(hasAddress: Bool = true, busy: Bool = false, networkChanged: Bool = true,
                          connected: Bool = false) -> LinkRules.OnNetworkChange {
        LinkRules.onNetworkChange(hasAddress: hasAddress, busy: busy, networkChanged: networkChanged,
                                  connected: connected)
    }

    func testANetworkThatHasNotChangedIsNoReason() {
        XCTAssertEqual(onChange(networkChanged: false), .nothing)
        XCTAssertEqual(onChange(networkChanged: false, connected: true), .nothing)
    }

    func testNothingIsDoneWhileBusyOrWithNoAddress() {
        XCTAssertEqual(onChange(busy: true), .nothing)
        XCTAssertEqual(onChange(hasAddress: false), .nothing)
    }

    /// Not connected, another network is worth a connect. Connected, the last answer is worth nothing any
    /// more, and the device is made sure of with the client in hand.
    func testAnotherNetworkConnectsOrMakesSure() {
        XCTAssertEqual(onChange(connected: false), .connect)
        XCTAssertEqual(onChange(connected: true), .makeSure)
    }

    // MARK: - the looks after a report

    /// A report of the network comes before the address does; the network is looked at again over the half
    /// minute after it.
    func testTheLooksAfterAReportCoverHalfAMinute() {
        XCTAssertEqual(LinkRules.looksAfterAReport.first, 0, "the first look is at once")
        XCTAssertEqual(LinkRules.looksAfterAReport.reduce(0, +), 30)
        XCTAssertEqual(LinkRules.looksAfterAReport, LinkRules.looksAfterAReport.map { max($0, 0) })
    }
}
