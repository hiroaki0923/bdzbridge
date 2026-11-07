import Foundation

/// What became of a registration with a television, once the app has kept what a registration keeps.
public enum TVRegistered: Sendable, Equatable {
    /// The television wants its PIN, which it shows on its screen when it is showing a broadcast.
    case pinNeeded
    case registered
    case failed(String)
}

/// What the form that adds a television does after one press of its button (`TVDriver.register`).
public enum TVRegistrationStep: Sendable, Equatable {
    /// The television put its PIN on its screen: the form asks for it.
    case askForThePIN
    /// The television turned the PIN down: the form says so and asks for it again, the field empty.
    case askForThePINAgain(saying: String)
    case registered
    /// Why it went no further, for the form to say.
    case say(String)
    /// The form was closed meanwhile, and nothing more was asked.
    case nothing
}

/// Registering with a television from the form that adds one: the order of the steps, and the client id the
/// registration goes with. What a registration keeps -- the address, the MAC, the link made afresh and its
/// connect -- is the app's, which registers through `ScalarClient.enrol` and says what came of it
/// (`TVRegistered`).
extension TVDriver {
    /// The client id a registration goes with: the one saved with the registration held, the one a registration
    /// under way began with (`pending`), which the app keeps until it has gone through so that the PIN goes with
    /// the request that asked for it, or a new one.
    public static func clientID(saved: TVCredentials?, pending: String?) -> String {
        saved?.clientID ?? pending ?? "BDBridge:\(UUID().uuidString)"
    }

    /// One press of the form's button. Asked for the PIN already, it registers with the one typed. Otherwise it
    /// asks what is at the address first (`find`), and goes on only to a television that is on, which it
    /// registers with nothing, so that the television puts its PIN on its screen. `register` is the app's
    /// registration with the PIN given, or with none; `closed` says whether the form has been closed, after which
    /// nothing is registered, so that no number is put on a panel for nobody.
    public static func register(askingForPIN: Bool, pin: String, find: () async -> TVPresence,
                                register: (String?) async -> TVRegistered,
                                closed: () -> Bool) async -> TVRegistrationStep {
        if askingForPIN {
            switch await register(pin) {
            case .registered: return .registered
            case .pinNeeded: return .askForThePINAgain(saying: pinTurnedDown)
            case .failed(let why): return .say(why)
            }
        }
        let found = await find()
        if let why = says(found) { return .say(why) }
        guard !closed() else { return .nothing }
        switch await register(nil) {
        case .pinNeeded: return .askForThePIN
        case .registered: return .registered
        case .failed(let why): return .say(why)
        }
    }
}
