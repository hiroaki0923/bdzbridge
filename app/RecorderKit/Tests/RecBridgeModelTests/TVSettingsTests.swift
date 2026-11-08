import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// The television's sheets and its part of the settings as the reader works them (`TVRegisterState`,
/// `HelperRegisterState`, `TVSettingsState`): what each offers and holds, what it says, and the presses. The steps
/// behind them are the model's and the package's, held elsewhere (`TVLinkTests`).
@MainActor
final class TVSettingsTests: XCTestCase {
    /// The sheet asks for an address a URL can be built on, goes on to the PIN the television shows, says a wrong one
    /// was turned down with the field emptied, and with the right one registers and is done. The address is held once
    /// the PIN is asked for, and the button until it is four long.
    func testTheSheetAddsATelevisionByThePINAndSaysAWrongOne() async throws {
        let bench = try aBench()
        let television = DemoTV(power: "active")
        let model = bench.modelWithNoRecorder(television: television, credentials: MemoryTVCredentials(),
                                              saved: false)
        let sheet = TVRegisterState(model: model, host: "")
        XCTAssertEqual(sheet.title, "テレビを追加")
        XCTAssertEqual(sheet.pressLabel, "テレビに接続")
        XCTAssertTrue(sheet.holdsThePress, "an empty address could be pressed")
        sheet.typedHost = "192.0.2.30/guide"
        XCTAssertTrue(sheet.holdsThePress, "an address no URL can be built on could be pressed")
        sheet.typedHost = Bench.tvHost
        XCTAssertFalse(sheet.holdsThePress)
        XCTAssertFalse(sheet.holdsTheAddress)

        sheet.press()
        try await until("the PIN was never asked for") { sheet.askingForPIN && !sheet.working }
        XCTAssertEqual(sheet.pressLabel, "登録する")
        XCTAssertTrue(sheet.holdsTheAddress, "the address could be changed with the PIN asked for")
        XCTAssertTrue(sheet.holdsThePress, "a PIN not typed could be pressed")
        XCTAssertFalse(sheet.pinNote.contains(DemoTV.pin), "a real television's number was said")
        XCTAssertNil(sheet.message)

        sheet.pin = "0000"
        XCTAssertFalse(sheet.holdsThePress)
        sheet.press()
        try await until("the wrong number was never turned down") { !sheet.working && sheet.message != nil }
        XCTAssertEqual(sheet.message, TVDriver.pinTurnedDown)
        XCTAssertEqual(sheet.pin, "", "the field kept the number turned down")
        XCTAssertFalse(sheet.done)
        XCTAssertNil(model.tv)

        sheet.pin = DemoTV.pin
        sheet.press()
        try await until("the television was never registered") { sheet.done }
        XCTAssertNil(sheet.message)
        XCTAssertEqual(model.tv?.host, Bench.tvHost)
    }

    /// Opened for a television a scan found, the sheet goes on to it as it appears, and only once however often it
    /// appears. Closed while its step waits for the local network permission -- said in place of a wait, with no
    /// working shown -- the step ends there: the permission coming after it asks the television nothing.
    func testASheetForAFoundTelevisionGoesOnOnceAndClosingItEndsTheStep() async throws {
        let bench = try aBench()
        let television = DemoTV(power: "active")
        let model = bench.modelWithNoRecorder(television: television, credentials: MemoryTVCredentials(),
                                              saved: false)
        let sheet = TVRegisterState(model: model, host: Bench.tvHost, connectAtOnce: true)
        sheet.appeared()
        sheet.appeared()
        try await until("the sheet never went on to the PIN") { sheet.askingForPIN && !sheet.working }
        let registrations = await television.calls.filter { $0.hasPrefix("actRegister") }
        XCTAssertEqual(registrations, ["actRegister cookie=no pin=no"], "appearing again sent the step again")

        bench.permissionLookSays = .blocked
        await television.goSilent()
        let closing = TVRegisterState(model: model, host: Bench.tvHost, connectAtOnce: true, again: true)
        XCTAssertEqual(closing.title, "テレビを登録")
        closing.appeared()
        try await until("the sheet never said the app is kept off the local network", within: 2) {
            closing.turnedAway
        }
        XCTAssertTrue(closing.working)
        XCTAssertFalse(closing.showsWorking, "a wait was shown beside the notice of what it waits for")
        let before = await television.calls

        closing.closed()
        XCTAssertFalse(closing.turnedAway, "the notice stayed up after the sheet had gone")
        await television.goSilent(false)
        bench.permissionComes()
        try await until("the step never ended") { !closing.working }
        expectEqual(await television.calls, before, "the television was asked something after the sheet went")
        XCTAssertFalse(closing.askingForPIN)
        XCTAssertFalse(closing.done)
    }

    /// The helper's code is six figures: anything else holds the button, and so does a registration out. What went
    /// wrong is said, and the sheet stays.
    func testTheHelpersCodeIsSixFiguresAndWhatWentWrongIsSaid() async throws {
        let bench = try aBench()
        let television = DemoTV(power: "active")
        let credentials = await registered(with: television)
        let model = bench.modelWithNoRecorder(television: television, credentials: credentials)
        await model.start()
        try await untilTheTelevisionIsConnected(model)
        XCTAssertNotNil(model.tvHelper)

        let sheet = HelperRegisterState(model: model)
        XCTAssertTrue(sheet.holdsThePress, "an empty code could be pressed")
        sheet.code = "12345"
        XCTAssertTrue(sheet.holdsThePress, "five figures could be pressed")
        sheet.code = "12345a"
        XCTAssertTrue(sheet.holdsThePress, "a letter could be pressed")
        sheet.code = "123456"
        XCTAssertFalse(sheet.holdsThePress)

        sheet.press()
        XCTAssertTrue(sheet.working)
        XCTAssertTrue(sheet.holdsThePress, "the button was not held while the registration was out")
        try await until("the registration never ended", within: 10) { !sheet.working }
        XCTAssertNotNil(sheet.message, "a helper that is not there said nothing")
        XCTAssertFalse(sheet.done)
        XCTAssertFalse(model.helperRegistered)
    }

    /// With the television connected, its part offers neither 登録する nor 再接続; once it falls silent, 再接続, which
    /// brings it back. A television that wants the app registered again offers 登録する in its place.
    func testTheTelevisionsPartOffersWhatBringsItBack() async throws {
        let bench = try aBench()
        let television = DemoTV(power: "active")
        let credentials = await registered(with: television)
        let model = bench.modelWithNoRecorder(television: television, credentials: credentials)
        await model.start()
        try await untilTheTelevisionIsConnected(model)
        let settings = TVSettingsState(model: model)
        XCTAssertEqual(settings.standing, "接続済み")
        XCTAssertFalse(settings.offersRegistering)
        XCTAssertFalse(settings.offersReconnect)
        XCTAssertTrue(settings.offersTheHelper)
        XCTAssertFalse(settings.helperRegistered)
        XCTAssertNil(settings.footer)

        await television.goSilent()
        await settings.reconnect()
        try await until("the television's silence was never taken for its absence") {
            model.tv?.session.connected == false && model.tv?.session.connecting == false
        }
        XCTAssertTrue(settings.offersReconnect)
        XCTAssertFalse(settings.holdsReconnect)
        let problem = try XCTUnwrap(model.problem(for: .tv), "the television's silence said nothing")
        XCTAssertEqual(settings.footer, problem.asABody)
        await television.goSilent(false)
        await settings.reconnect()
        try await untilTheTelevisionIsConnected(model)
        XCTAssertFalse(settings.offersReconnect)

        let unknown = try aBench()
        let stranger = unknown.modelWithNoRecorder(television: DemoTV(power: "active"),
                                                   credentials: MemoryTVCredentials())
        await stranger.start()
        try await until("the television was not said to need a registration") {
            stranger.tvDriver?.facts.needsPairing == true
        }
        let asked = TVSettingsState(model: stranger)
        XCTAssertTrue(asked.offersRegistering)
        XCTAssertFalse(asked.offersReconnect, "再接続 was offered beside 登録する")
        XCTAssertEqual(asked.standing, "登録が必要です")
    }

    /// テレビを外す counts what waits for the television into its question, and goes only with 外す: closed, the
    /// question leaves everything as it was. With nothing waiting it says nothing of what waits.
    func testTakingTheTelevisionAwayAsksWithWhatWaitsForIt() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let television = DemoTV(power: "active")
        let credentials = await registered(with: television)
        let model = bench.model(recorder: DemoRecorder(), television: television, credentials: credentials)
        await model.start()
        try await untilConnected(model)
        try await untilTheTelevisionIsConnected(model)
        let settings = TVSettingsState(model: model)

        await settings.remove()
        XCTAssertTrue(settings.asksToRemove)
        XCTAssertFalse(settings.removalMessage.contains("送信待ち"), "said something of what waits with nothing waiting")
        settings.removalClosed()

        let programme = try await programmesNotReserved(model, 1)[0]
        let request = try XCTUnwrap(ReservationRequest(program: programme, quality: "DR", repeating: "none"))
        let store = try XCTUnwrap(model.store)
        try await store.queue(PendingReservation(request: request, serviceName: programme.serviceName, target: .tv))
        await settings.remove()
        XCTAssertTrue(settings.removalMessage.hasSuffix("\nこのテレビ宛の送信待ちの予約 1 件は、送らずに削除します。"),
                      settings.removalMessage)
        settings.removalClosed()
        XCTAssertFalse(settings.asksToRemove)
        XCTAssertNotNil(model.tv, "closing the question took the television away")
        expectEqual(await model.waitingForTheTelevision(), 1)

        await settings.remove()
        await settings.confirmRemoving()
        XCTAssertFalse(settings.asksToRemove)
        XCTAssertNil(model.tv)
        XCTAssertNil(settings.standing)
        expectEqual(await model.waitingForTheTelevision(), 0, "what waited for it stayed")
    }
}
