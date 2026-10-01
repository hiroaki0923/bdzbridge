import Foundation

/// One attempt at a device: the order in which it is woken, asked, waited for and looked for.
///
/// The screens' connect, the check before an operation and the overnight run each made an attempt of their
/// own, and what was learnt in one did not reach the others (docs/porting.md, 待っていることを画面に出す): the
/// packet goes before the first ask, a device that answers with an error is there, silence may be the local
/// network permission rather than sleep, and a device that does not wake may be at another address. The order
/// is here once. The steps are the caller's: the screens say what they are doing on the way and read what
/// the device says about itself, the overnight run does neither.
public enum Reach {
    public enum Outcome: Sendable, Equatable {
        /// It answered: at once, after waking, or at another address.
        case answered
        /// Something answered, and not as asked. The device is there, so it is neither woken nor looked for,
        /// and it is not given up on (`LinkRules.givesUp`).
        case refused
        /// Nothing answered, after everything this attempt had to try.
        case silent
        /// The system is keeping the app off the local network. Nothing was woken, since the packet could not
        /// leave either: the caller waits for the permission.
        case blocked
    }

    /// What the caller does at each step. A step that asks the device answers with why it failed, or nil when
    /// the device answered.
    public struct Steps {
        /// Sends the magic packet, when there is a device to send one to and it may be sent.
        public var sendPacket: () async -> Void
        /// The first ask, a short one.
        public var probe: () async -> DeviceFailure?
        /// Whether the local network permission is why the device said nothing. Not asked by a caller with no
        /// screen to explain it on.
        public var blocked: () async -> Bool
        /// Waits for the device to come up after the packet, and asks it again. `.silent` at once when there
        /// was nothing to wake it with.
        public var wake: () async -> DeviceFailure?
        /// Looks for the device at another address and asks it there. `.silent` when it is not looked for,
        /// or not found.
        public var elsewhere: () async -> DeviceFailure?

        public init(sendPacket: @escaping () async -> Void,
                    probe: @escaping () async -> DeviceFailure?,
                    blocked: @escaping () async -> Bool = { false },
                    wake: @escaping () async -> DeviceFailure?,
                    elsewhere: @escaping () async -> DeviceFailure? = { .silent }) {
            self.sendPacket = sendPacket
            self.probe = probe
            self.blocked = blocked
            self.wake = wake
            self.elsewhere = elsewhere
        }
    }

    /// Runs the steps in order and says what the attempt came to.
    ///
    /// The packet first and the ask after: a device that is asleep is on its way up while the ask waits, and
    /// one that is awake ignores it. An answer ends it. A refusal ends it too, unless `wakesAfterRefusal`, which
    /// is the overnight run's way: a device still starting up may answer anything, and nobody is watching
    /// the wait. An address nothing can be sent to is never waited for. After silence the permission is asked
    /// about, then the device is woken, and only when that brings silence again is it looked for elsewhere:
    /// once, and after the waking, which is what gives a device that moved the time to come up where it is.
    ///
    /// The steps run on the caller's actor, as if written out in place.
    public static func run(isolation: isolated (any Actor)? = #isolation, _ steps: Steps,
                           wakesAfterRefusal: Bool = false) async -> Outcome {
        await steps.sendPacket()
        guard let first = await steps.probe() else { return .answered }
        if first == .silent {
            if await steps.blocked() { return .blocked }
        } else if !wakesAfterRefusal || first == .badAddress {
            return .refused
        }
        guard let woken = await steps.wake() else { return .answered }
        guard woken == .silent else { return .refused }
        guard let moved = await steps.elsewhere() else { return .answered }
        return moved == .silent ? .silent : .refused
    }
}
