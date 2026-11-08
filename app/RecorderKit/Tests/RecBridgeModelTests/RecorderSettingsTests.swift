import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// The recorder's part of the settings as the reader works it (`RecorderSettingsState`): the address and MAC fields
/// starting at what is saved and following the model, what an address typed offers and says, and the presses. The
/// connect itself is the model's, held elsewhere.
@MainActor
final class RecorderSettingsTests: XCTestCase {
    /// The fields start at what is saved. A MAC typed is kept as it is typed, a half-typed one is not, and an emptied
    /// field forgets it; the field follows the model's MAC, but for a half-typed MAC with none saved, which already
    /// agrees with none.
    func testTheFieldsStartAtWhatIsSavedAndTheMACIsKeptAsItIsTyped() async throws {
        let bench = try aBench()
        bench.keep(mac: WhichRecorderTests.firstsMAC)
        let model = bench.model(recorders: [:])
        let saved = try XCTUnwrap(model.mac, "the MAC kept was not read")
        let settings = RecorderSettingsState(model: model)
        settings.appeared()
        settings.macMoved()
        XCTAssertEqual(settings.typedHost, Bench.host)
        XCTAssertEqual(settings.typedMac, saved)

        let typed = "F8-4E-17-00-00-02"
        settings.typedMac = typed
        XCTAssertEqual(model.mac, WakeOnLan.normalise(typed), "the MAC typed was not kept")
        settings.typedMac = "02:00"
        XCTAssertEqual(model.mac, WakeOnLan.normalise(typed), "a half-typed MAC replaced the one before it")
        settings.typedMac = ""
        XCTAssertNil(model.mac, "the emptied field did not forget the MAC")

        model.remember(mac: WhichRecorderTests.firstsMAC)
        settings.macMoved()
        XCTAssertEqual(settings.typedMac, saved, "the field did not follow the MAC the model kept")
        model.forgetMac()
        settings.macMoved()
        XCTAssertEqual(settings.typedMac, "", "the field kept a MAC the model forgot")
        settings.typedMac = "02:00"
        settings.macMoved()
        XCTAssertEqual(settings.typedMac, "02:00", "a half-typed MAC was taken away with no MAC saved")

        // An address field that is not empty is not put back as the screen appears again.
        settings.typedHost = Bench.otherHost
        settings.appeared()
        XCTAssertEqual(settings.typedHost, Bench.otherHost)
    }

    /// With the saved address in the field and nothing connected, 再接続 is offered; an address typed offers
    /// このアドレスに接続 in its place, said back with a port it will not use, and held for an address no URL can be
    /// built on.
    func testAnAddressTypedOffersTheConnectAndTheSavedOneTheReconnect() async throws {
        let bench = try aBench()
        let model = bench.model(recorders: [:])
        await model.start()
        try await untilGivenUp(model)
        let settings = RecorderSettingsState(model: model)
        settings.appeared()
        XCTAssertFalse(settings.offersConnect)
        XCTAssertTrue(settings.offersReconnect)
        XCTAssertFalse(settings.holdsReconnect)
        XCTAssertEqual(settings.standing, model.session.standing())
        XCTAssertNil(settings.tidied.note)

        settings.typedHost = "\(Bench.otherHost):64220"
        XCTAssertTrue(settings.offersConnect)
        XCTAssertFalse(settings.offersReconnect)
        XCTAssertFalse(settings.holdsConnect)
        XCTAssertEqual(settings.tidied.note?.text, "ポート番号は不要です。「:64220」は使わずに \(Bench.otherHost) に接続します。")
        XCTAssertEqual(settings.tidied.note?.warning, false)

        settings.typedHost = "192.0.2.10/guide"
        XCTAssertTrue(settings.offersConnect)
        XCTAssertTrue(settings.holdsConnect, "an address no URL can be built on could be connected to")
        XCTAssertEqual(settings.tidied.note?.text,
                       "アドレスの形式が正しくありません。192.168.1.10 のような IP アドレスを入力してください。")
        XCTAssertEqual(settings.tidied.note?.warning, true)

        // An address saved untidy, as an older version saved one typed with its port: the field shows it as saved,
        // and this offers the connect that saves it tidied, where 再接続 would only try it again.
        let older = try aBench().model(recorders: [:], saved: "\(Bench.host):64220")
        let untidy = RecorderSettingsState(model: older)
        untidy.appeared()
        XCTAssertEqual(untidy.typedHost, "\(Bench.host):64220")
        XCTAssertTrue(untidy.offersConnect, "an address saved untidy was offered only 再接続")

        // With no address saved there is nothing to say of the link, nor to connect to again.
        let first = try aBench().modelWithNoRecorder()
        let none = RecorderSettingsState(model: first)
        none.appeared()
        XCTAssertNil(none.standing)
        XCTAssertFalse(none.offersConnect)
        XCTAssertFalse(none.offersReconnect)
    }

    /// このアドレスに接続 saves the address tidied, which the field then shows, and connects to it; a recorder the search
    /// found, tapped, does the same; and the field follows the address when the model moves it.
    func testTheConnectSavesTheAddressTidiedAndTheFieldShowsIt() async throws {
        let bench = try aBench()
        let model = bench.model(recorders: [Bench.host: NamedRecorder(1), Bench.otherHost: NamedRecorder(2)])
        await model.start()
        try await untilConnected(model)
        let settings = RecorderSettingsState(model: model)
        settings.appeared()
        XCTAssertFalse(settings.offersConnect)
        XCTAssertFalse(settings.offersReconnect, "再接続 was offered for the recorder connected to")

        settings.typedHost = " \(Bench.otherHost):64220 "
        await settings.connect()
        XCTAssertEqual(settings.typedHost, Bench.otherHost, "the field did not show the address saved")
        XCTAssertEqual(model.host, Bench.otherHost)
        try await untilConnected(model, "the address typed was never connected to")
        XCTAssertFalse(settings.offersConnect)

        await settings.choose(Bench.host)
        XCTAssertEqual(settings.typedHost, Bench.host)
        XCTAssertEqual(model.host, Bench.host)

        settings.typedHost = Bench.otherHost
        settings.hostMoved()
        XCTAssertEqual(settings.typedHost, model.host, "the field kept an address the model had moved from")
    }
}
