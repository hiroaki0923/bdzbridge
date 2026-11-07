import XCTest
@testable import RecorderKit

/// Registering with a television from the form that adds one (`TVDriver.register`, `TVDriver.clientID`), over
/// stand-ins for what is found at the address and for the app's registration.
@MainActor
final class TVRegistrationTests: XCTestCase {
    private var asked: [String] = []

    private func press(askingForPIN: Bool = false, pin: String = "", found: TVPresence = .on(model: "KJ-55X95K"),
                       answers: TVRegistered = .registered, closed: Bool = false) async -> TVRegistrationStep {
        await TVDriver.register(askingForPIN: askingForPIN, pin: pin,
                                find: {
                                    asked.append("find")
                                    return found
                                },
                                register: { pin in
                                    asked.append("register \(pin ?? "with nothing")")
                                    return answers
                                },
                                closed: { closed })
    }

    override func setUp() async throws {
        asked = []
    }

    func testATelevisionThatIsOnIsRegisteredWithNothingSoThatItShowsItsPIN() async {
        let step = await press(answers: .pinNeeded)
        XCTAssertEqual(step, .askForThePIN)
        XCTAssertEqual(asked, ["find", "register with nothing"])
    }

    func testThePINTheReaderTypedIsSentWithNothingAskedFirst() async {
        var step = await press(askingForPIN: true, pin: "1234")
        XCTAssertEqual(step, .registered)
        XCTAssertEqual(asked, ["register 1234"])

        step = await press(askingForPIN: true, pin: "0000", answers: .pinNeeded)
        XCTAssertEqual(step, .askForThePINAgain(saying: TVDriver.pinTurnedDown))

        step = await press(askingForPIN: true, pin: "1234", answers: .failed("登録を断られました"))
        XCTAssertEqual(step, .say("登録を断られました"))
    }

    func testOnlyATelevisionThatIsOnIsRegistered() async {
        for found in [TVPresence.nothing, .notATelevision, .standby(model: "KJ-55X95K")] {
            asked = []
            let step = await press(found: found)
            XCTAssertEqual(step, .say(TVDriver.says(found) ?? ""), "\(found)")
            XCTAssertEqual(asked, ["find"], "\(found): registered")
        }
    }

    func testARegistrationThatWentThroughOrFailedIsSaidSo() async {
        var step = await press()
        XCTAssertEqual(step, .registered)
        step = await press(answers: .failed(ScalarClient.screenIsOff))
        XCTAssertEqual(step, .say(ScalarClient.screenIsOff))
    }

    func testNothingIsRegisteredOnceTheFormHasBeenClosed() async {
        let step = await press(closed: true)
        XCTAssertEqual(step, .nothing)
        XCTAssertEqual(asked, ["find"], "a number was put on a panel for nobody")
    }

    func testTheClientIDIsTheSavedOneThenTheOneUnderWayThenANewOne() {
        let saved = TVCredentials(clientID: "BDBridge:saved", cookie: "c", cookieReceived: Date(), cookieMaxAge: 60)
        XCTAssertEqual(TVDriver.clientID(saved: saved, pending: "BDBridge:pending"), "BDBridge:saved")
        XCTAssertEqual(TVDriver.clientID(saved: nil, pending: "BDBridge:pending"), "BDBridge:pending")
        let new = TVDriver.clientID(saved: nil, pending: nil)
        XCTAssertTrue(new.hasPrefix("BDBridge:"))
        XCTAssertNotEqual(new, TVDriver.clientID(saved: nil, pending: nil), "each registration begun afresh has its own")
    }
}
