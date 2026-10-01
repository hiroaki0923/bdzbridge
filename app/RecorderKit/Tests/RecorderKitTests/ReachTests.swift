import Foundation
import XCTest
@testable import RecorderKit

/// One attempt at a device, as an order of steps: the packet, the first ask, the permission, the waking, the
/// look elsewhere. The steps are the caller's -- the screens' say what they are doing on the way, the overnight
/// run's say nothing -- and the order is what is tried here, with steps that only write down that they ran.
final class ReachTests: XCTestCase {
    /// Writes down each step as it runs and answers what the test set for it.
    @MainActor
    private final class Script {
        var ran: [String] = []
        var probe: DeviceFailure?
        var blocked = false
        var wake: DeviceFailure? = .silent
        var elsewhere: DeviceFailure? = .silent

        var steps: Reach.Steps {
            Reach.Steps(sendPacket: { self.ran.append("packet") },
                        probe: { self.ran.append("probe"); return self.probe },
                        blocked: { self.ran.append("blocked"); return self.blocked },
                        wake: { self.ran.append("wake"); return self.wake },
                        elsewhere: { self.ran.append("elsewhere"); return self.elsewhere })
        }
    }

    /// The packet goes before the first ask, so that a device that is asleep is on its way up while the ask
    /// waits; and a device that answers needs nothing else.
    @MainActor
    func testADeviceThatAnswersIsAskedOnceAfterThePacket() async {
        let script = Script()

        let outcome = await Reach.run(script.steps)

        XCTAssertEqual(outcome, .answered)
        XCTAssertEqual(script.ran, ["packet", "probe"])
    }

    /// Silence may be the system keeping the app off the local network. The packet could not leave either,
    /// so there is no waking: the caller waits for the permission.
    @MainActor
    func testSilenceThatIsThePermissionEndsThereWithoutWaking() async {
        let script = Script()
        script.probe = .silent
        script.blocked = true

        let outcome = await Reach.run(script.steps)

        XCTAssertEqual(outcome, .blocked)
        XCTAssertEqual(script.ran, ["packet", "probe", "blocked"])
    }

    @MainActor
    func testASilentDeviceThatWakesHasAnswered() async {
        let script = Script()
        script.probe = .silent
        script.wake = nil

        let outcome = await Reach.run(script.steps)

        XCTAssertEqual(outcome, .answered)
        XCTAssertEqual(script.ran, ["packet", "probe", "blocked", "wake"])
    }

    /// Not back where it was after the waking: it may be answering at another address. One look, after the
    /// waking and not before.
    @MainActor
    func testADeviceThatDoesNotWakeIsLookedForElsewhereOnce() async {
        let script = Script()
        script.probe = .silent
        script.elsewhere = nil

        let outcome = await Reach.run(script.steps)

        XCTAssertEqual(outcome, .answered)
        XCTAssertEqual(script.ran, ["packet", "probe", "blocked", "wake", "elsewhere"])
    }

    @MainActor
    func testSilenceAllTheWayIsSilentWithEachStepTakenOnce() async {
        let script = Script()
        script.probe = .silent

        let outcome = await Reach.run(script.steps)

        XCTAssertEqual(outcome, .silent)
        XCTAssertEqual(script.ran, ["packet", "probe", "blocked", "wake", "elsewhere"])
    }

    /// A device that answers, if only to refuse, is there: nothing is woken and nothing is looked for.
    @MainActor
    func testADeviceThatRefusesIsNotWokenOrLookedFor() async {
        let script = Script()
        script.probe = .busy

        let outcome = await Reach.run(script.steps)

        XCTAssertEqual(outcome, .refused)
        XCTAssertEqual(script.ran, ["packet", "probe"])
    }

    /// The overnight run waits for a device that answered its first ask with an error, as it always has: one
    /// still starting up may answer anything. The permission is not asked about: there is no screen.
    @MainActor
    func testTheOvernightRunWaitsAfterARefusalToo() async {
        let script = Script()
        script.probe = .unexpected("HTTP 500")
        script.wake = nil

        let outcome = await Reach.run(script.steps, wakesAfterRefusal: true)

        XCTAssertEqual(outcome, .answered)
        XCTAssertEqual(script.ran, ["packet", "probe", "wake"])
    }

    /// And when the wait brings nothing, the attempt is silent: what refused at first did not come up.
    @MainActor
    func testTheOvernightRunsWaitThatBringsNothingIsSilent() async {
        let script = Script()
        script.probe = .unexpected("HTTP 500")

        let outcome = await Reach.run(script.steps, wakesAfterRefusal: true)

        XCTAssertEqual(outcome, .silent)
        XCTAssertEqual(script.ran, ["packet", "probe", "wake", "elsewhere"])
    }

    /// Nothing could be asked at an address that is not one, so waiting would change nothing.
    @MainActor
    func testAnAddressThatIsNotOneIsNeverWaitedFor() async {
        let script = Script()
        script.probe = .badAddress

        let outcome = await Reach.run(script.steps, wakesAfterRefusal: true)

        XCTAssertEqual(outcome, .refused)
        XCTAssertEqual(script.ran, ["packet", "probe"])
    }

    /// Woken, and then refusing what it is asked: it is there, so it is not looked for anywhere else.
    @MainActor
    func testADeviceThatWakesAndRefusesIsNotLookedForElsewhere() async {
        let script = Script()
        script.probe = .silent
        script.wake = .refused(reason: "402")

        let outcome = await Reach.run(script.steps)

        XCTAssertEqual(outcome, .refused)
        XCTAssertEqual(script.ran, ["packet", "probe", "blocked", "wake"])
    }

    @MainActor
    func testADeviceFoundElsewhereThatRefusesIsThere() async {
        let script = Script()
        script.probe = .silent
        script.elsewhere = .busy

        let outcome = await Reach.run(script.steps)

        XCTAssertEqual(outcome, .refused)
    }

    /// The overnight run's steps as it gives them: no permission to ask about and nowhere else to look.
    @MainActor
    func testStepsLeftOutAreNotBlockedAndFindNothing() async {
        var ran: [String] = []
        let steps = Reach.Steps(sendPacket: { ran.append("packet") },
                                probe: { ran.append("probe"); return .silent },
                                wake: { ran.append("wake"); return .silent })

        let outcome = await Reach.run(steps, wakesAfterRefusal: true)

        XCTAssertEqual(outcome, .silent)
        XCTAssertEqual(ran, ["packet", "probe", "wake"])
    }
}
