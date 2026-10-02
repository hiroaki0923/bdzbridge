import Foundation
import Observation
import XCTest
@testable import RecorderKit

/// What the app knows of a device and of its link to it, and the handful of things that can happen to that.
/// The screens read it; nothing sets a field of it. It changes by what happened -- the device described
/// itself, it went silent, the attempt ended -- and each of those is tried here.
@MainActor
final class SessionStateTests: XCTestCase {
    private func description() -> RecorderDescription {
        RecorderDescription(host: Stub.host, port: 64220, friendlyName: "サンプルレコーダー", product: "BDZ",
                            model: "BDZ-SAMPLE", udn: "uuid:00000000-0000-0000-0000-000000000000",
                            epgCapable: true, location: "http://192.0.2.10:64220/description.xml", via: "manual")
    }

    /// A session that has attached once, as after a connect.
    private func attached(mac: String? = nil) -> SessionState {
        let session = SessionState(mac: mac)
        session.tried(on: "home")
        session.described(description())
        session.learned(firmware: "1.0")
        session.learned(storage: (free: 100, total: 200))
        session.answered()
        session.attached()
        return session
    }

    func testNothingIsKnownAtFirst() {
        let session = SessionState()
        XCTAssertFalse(session.connected)
        XCTAssertFalse(session.unreachable)
        XCTAssertFalse(session.gaveUp)
        XCTAssertFalse(session.canWake)
        XCTAssertEqual(session.timesAttached, 0)
        XCTAssertTrue(session.networkChanged(now: "home"))
        XCTAssertEqual(SessionState(mac: "F8-4E-17-00-00-00").mac, "F8-4E-17-00-00-00", "kept as it was saved")
    }

    /// Connected is decided by the description alone, and from the moment it arrives: the rest is read
    /// after, and is only shown.
    func testADeviceThatDescribesItselfIsConnectedBeforeTheRestIsRead() {
        let session = SessionState()
        session.described(description())
        XCTAssertTrue(session.connected)
        XCTAssertEqual(session.firmware, "")
        XCTAssertNil(session.storage)
        XCTAssertEqual(session.timesAttached, 0, "not counted until the attach is through")

        session.learned(firmware: "1.0")
        session.learned(storage: (free: 100, total: 200))
        session.answered()
        session.attached()
        XCTAssertEqual(session.firmware, "1.0")
        XCTAssertEqual(session.storage?.free, 100)
        XCTAssertEqual(session.timesAttached, 1)
    }

    /// After silence, the description makes it connected at once and the mark of having been unreachable
    /// stands until the rest has been read. A screen that loads on `connected` alone finds nothing to ask in
    /// between, which is why the screens key on connected and not offline together.
    func testADescriptionAfterSilenceIsConnectedAndStillUnreachableUntilItHasAnswered() {
        let session = attached()
        session.lost()
        session.described(description())
        XCTAssertTrue(session.connected)
        XCTAssertTrue(session.unreachable)
        session.answered()
        XCTAssertFalse(session.unreachable)
    }

    /// What the device would not say is put down as not known, over what an earlier attach read.
    func testWhatTheDeviceWouldNotSayThisTimeIsForgotten() {
        let session = attached()
        session.learned(firmware: "")
        session.learned(storage: nil)
        XCTAssertEqual(session.firmware, "")
        XCTAssertNil(session.storage)
    }

    func testAnAnswerClearsHavingBeenUnreachable() {
        let session = attached()
        session.lost()
        XCTAssertTrue(session.unreachable)
        session.answered()
        XCTAssertFalse(session.unreachable)
    }

    /// Silence anywhere leaves the session where a connect that got no answer leaves it.
    func testLosingTheDeviceLeavesItUnreachableUnknownAndGivenUp() {
        let session = attached()
        session.noted(network: "away")
        session.lost()
        XCTAssertTrue(session.unreachable)
        XCTAssertFalse(session.connected, "a description read earlier says nothing of a device that is not answering")
        XCTAssertTrue(session.gaveUp)
        XCTAssertEqual(session.link.triedOn, "home", "where it was tried is left as it was")
        XCTAssertEqual(session.link.tries, 1, "losing it is not a try")
        XCTAssertTrue(session.link.sawAnotherNetwork, "that the phone was elsewhere is what sets the looks going again")
    }

    /// The check before an operation that met silence: not yet given up, since waking comes next, and tried
    /// on the network it was asked on.
    func testSilenceOnACheckIsNotYetGivingUp() {
        let session = attached()
        session.wentSilent(on: "away")
        XCTAssertTrue(session.unreachable)
        XCTAssertFalse(session.connected)
        XCTAssertFalse(session.gaveUp)
        XCTAssertEqual(session.link.triedOn, "away")
        XCTAssertEqual(session.link.tries, 2)
    }

    func testAnAttachThatMetSilenceForgetsTheDescription() {
        let session = attached()
        session.noted(network: "away")
        session.attachFailed(.silent)
        XCTAssertTrue(session.unreachable)
        XCTAssertFalse(session.connected)
        XCTAssertFalse(session.gaveUp, "waking comes next: giving up is for when the connect has finished trying")
        XCTAssertEqual(session.link.tries, 1)
        XCTAssertTrue(session.link.sawAnotherNetwork)
    }

    /// Busy, or an answer in a shape of its own: it answered all the same.
    func testAnAttachThatWasAnsweredAnyOtherWayKeepsTheDescriptionToo() {
        for failure in [DeviceFailure.busy, .unexpected("HTTP 500")] {
            let session = attached()
            session.attachFailed(failure)
            XCTAssertFalse(session.unreachable, "\(failure)")
            XCTAssertTrue(session.connected, "\(failure)")
        }
    }

    /// Something answered, so the device is there: what was known of it stands.
    func testAnAttachThatWasRefusedKeepsTheDescription() {
        let session = attached()
        session.lost()
        session.described(description())
        session.attachFailed(.refused(reason: "402"))
        XCTAssertFalse(session.unreachable)
        XCTAssertTrue(session.connected)
    }

    /// Nor is a device there if the address is not an address: the last one's description must not stand.
    func testAnAddressThatIsNotOneForgetsTheDescription() {
        let session = attached()
        session.attachFailed(.badAddress)
        XCTAssertFalse(session.unreachable)
        XCTAssertFalse(session.connected)
    }

    func testAFailureThatIsNoDevicesIsNotSilence() {
        let session = attached()
        session.attachFailed(nil)
        XCTAssertFalse(session.unreachable)
        XCTAssertTrue(session.connected)

        // Nor does it leave an earlier silence standing: the attach got far enough to fail some other way.
        let lost = attached()
        lost.lost()
        lost.attachFailed(nil)
        XCTAssertFalse(lost.unreachable)
        XCTAssertTrue(lost.gaveUp, "only a connect that has finished trying takes that back")
    }

    /// Only silence is given up on (`LinkRules.givesUp`).
    func testAConnectThatEndsUnreachedGivesUpOnlyOnSilence() {
        let silent = SessionState()
        silent.attachFailed(.silent)
        silent.finishedTrying(reached: false)
        XCTAssertTrue(silent.gaveUp)

        let refused = SessionState()
        refused.attachFailed(.busy)
        refused.finishedTrying(reached: false)
        XCTAssertFalse(refused.gaveUp)

        let reached = attached()
        reached.lost()
        reached.answered()
        reached.finishedTrying(reached: true)
        XCTAssertFalse(reached.gaveUp, "a connect that reached it is no longer given up")

        // Given up before, and this time it answered, if only to refuse: it is there, and not given up on.
        let back = attached()
        back.lost()
        back.attachFailed(.busy)
        back.finishedTrying(reached: false)
        XCTAssertFalse(back.gaveUp)
    }

    /// Waiting for the local network permission is given up until it comes, and says so apart from a failure.
    func testWaitingForThePermissionIsGivenUpAndBlocked() {
        let session = SessionState()
        session.waitingForPermission()
        XCTAssertTrue(session.connectBlocked)
        XCTAssertTrue(session.gaveUp)

        session.permissionCleared()
        XCTAssertFalse(session.connectBlocked)
        XCTAssertTrue(session.gaveUp, "only a connect that reaches it takes that back")
    }

    /// Another device is chosen, or the demo entered or left: what the last one said is forgotten. The MAC
    /// and where the app last tried are the caller's to change, and the count goes on.
    func testForgettingTheDeviceKeepsTheMacTheLinkAndTheCount() {
        let session = attached(mac: "f8:4e:17:00:00:01")
        session.lost()
        session.waitingForPermission()
        // Described again, as it is part way through a reconnect: the description is one of the things to go.
        session.described(description())
        // And it had asked to be powered on, which the next device has not.
        session.powerNeeded(true)
        session.forgotTheDevice()
        XCTAssertFalse(session.needsPower, "the next device is offered a power button for what the last one said")
        XCTAssertFalse(session.connected)
        XCTAssertEqual(session.firmware, "")
        XCTAssertNil(session.storage)
        XCTAssertFalse(session.unreachable)
        XCTAssertFalse(session.gaveUp)
        XCTAssertFalse(session.connectBlocked)
        XCTAssertEqual(session.mac, "f8:4e:17:00:00:01")
        XCTAssertEqual(session.link.triedOn, "home")
        XCTAssertEqual(session.timesAttached, 1)

        // The count goes on, which is how a screen tells the answer to the new choice from what was up before.
        session.described(description())
        session.answered()
        session.attached()
        XCTAssertEqual(session.timesAttached, 2)
    }

    /// Another device was chosen, and what answers at its address does not describe itself: busy with somebody
    /// else, or not that kind of device at all. "What is known of it stands" is then nothing, because the last
    /// device was forgotten when this one was chosen. Left standing, its description had the app look connected
    /// to a device it was no longer set to, with every request going to the new address.
    func testADeviceForgottenIsNotBroughtBackByAnAttachThatWasAnsweredSomeOtherWay() {
        let answers: [DeviceFailure?] = [.busy, .unexpected("not a recorder"), .refused(reason: "402"), nil]
        for failure in answers {
            let session = attached(mac: "f8:4e:17:00:00:01")
            session.forgotTheDevice()
            session.tried(on: "home")
            session.attachFailed(failure)
            session.finishedTrying(reached: false)
            let what = String(describing: failure)
            XCTAssertFalse(session.connected, what)
            XCTAssertEqual(session.firmware, "", what)
            XCTAssertNil(session.storage, what)
            XCTAssertFalse(session.unreachable, what)
            XCTAssertFalse(session.gaveUp, "it answered, so it is there and not given up on: \(what)")
            XCTAssertEqual(session.mac, "f8:4e:17:00:00:01", what)
            XCTAssertEqual(session.timesAttached, 1, what)
        }

        // Silence at the new address is given up on, as anywhere, and the last device is no more known for it.
        let silent = attached()
        silent.forgotTheDevice()
        silent.tried(on: "home")
        silent.attachFailed(.silent)
        silent.finishedTrying(reached: false)
        XCTAssertFalse(silent.connected)
        XCTAssertTrue(silent.unreachable)
        XCTAssertTrue(silent.gaveUp)
    }

    /// Anything that is not a MAC is ignored rather than kept, so a half-typed one never replaces a good one.
    func testOnlyAMacIsRemembered() {
        let session = SessionState()
        XCTAssertFalse(session.remember(mac: "not a mac"))
        XCTAssertNil(session.mac)
        XCTAssertTrue(session.remember(mac: "F8-4E-17-00-00-01"))
        XCTAssertEqual(session.mac, WakeOnLan.normalise("F8-4E-17-00-00-01"))
        XCTAssertTrue(session.canWake)
        XCTAssertFalse(session.remember(mac: "f8:4e"))
        XCTAssertNotNil(session.mac, "a half-typed address replaced a good one")
        session.forgetMac()
        XCTAssertNil(session.mac)
        XCTAssertFalse(session.canWake)
    }

    func testTheFlagsSayWhatIsUnderWay() {
        let session = SessionState()
        session.beginConnecting()
        XCTAssertTrue(session.connecting)
        session.endConnecting()
        XCTAssertFalse(session.connecting)
        session.beginWaking()
        XCTAssertTrue(session.waking)
        session.endWaking()
        XCTAssertFalse(session.waking)
        session.powerNeeded(true)
        XCTAssertTrue(session.needsPower)
        session.powerNeeded(false)
        XCTAssertFalse(session.needsPower)
    }

    /// The screens are redrawn by this: a reader is told when the field it read changes, and not when another
    /// does. Without it every test here would still pass and no screen would follow the recorder.
    func testAReaderIsToldOfTheFieldItReadAndNotOfTheRest() {
        final class Told: @unchecked Sendable { var times = 0 }
        let session = attached()
        let gaveUp = Told(), connected = Told()
        withObservationTracking { _ = session.gaveUp } onChange: { gaveUp.times += 1 }
        withObservationTracking { _ = session.connected } onChange: { connected.times += 1 }

        session.noted(network: "away")
        session.tried(on: "away")
        session.beginWaking()
        XCTAssertEqual(gaveUp.times, 0, "told of a field it did not read")
        XCTAssertEqual(connected.times, 0, "told of a field it did not read")

        session.lost()
        XCTAssertEqual(gaveUp.times, 1)
        XCTAssertEqual(connected.times, 1)
    }

    func testTheNetworkIsNotedAndComparedThroughTheLink() {
        let session = SessionState()
        session.tried(on: "home")
        XCTAssertFalse(session.networkChanged(now: "home"))
        session.noted(network: "")
        XCTAssertTrue(session.networkChanged(now: "home"))
        XCTAssertTrue(session.link.sawAnotherNetwork)
    }
}
