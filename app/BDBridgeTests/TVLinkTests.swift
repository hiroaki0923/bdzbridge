import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The television beside the recorder: added by the PIN it shows, connected on a link of its own, and neither
/// device held up by the other's silence. Let go of in the demo and given back after it, and taken away whole.
@MainActor
final class TVLinkTests: XCTestCase {
    /// A television is found at its address, asks for its PIN, and with it is registered, saved and connected:
    /// its address and its MAC go in the defaults, its registration in the store.
    func testATelevisionIsAddedByItsPIN() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let television = DemoTV(power: "active")
        let credentials = MemoryTVCredentials()
        let model = bench.model(recorder: DemoRecorder(), television: television, credentials: credentials, saved: false)
        await model.start()
        XCTAssertNil(model.tv)

        expectEqual(await model.findTV(at: Bench.tvHost), .on(model: DemoTV.model))
        expectEqual(await model.registerTV(at: Bench.tvHost, pin: nil), .pinNeeded)
        XCTAssertNil(credentials.load(), "kept something before the PIN")
        expectEqual(await model.registerTV(at: Bench.tvHost, pin: DemoTV.pin), .registered)

        try await until("the television was not connected") { model.tv?.session.connected == true }
        XCTAssertEqual(bench.defaults.string(forKey: DefaultsKey.tvHost), Bench.tvHost)
        XCTAssertEqual(bench.defaults.string(forKey: DefaultsKey.tvMac), DemoTV.mac)
        let kept = try XCTUnwrap(credentials.load())
        XCTAssertTrue(kept.clientID.hasPrefix("BDBridge:"))
        XCTAssertNotNil(kept.cookie)
        XCTAssertEqual(model.tvDriver?.facts.model, DemoTV.model)
        let calls = await television.calls
        let registrations = calls.filter { $0.hasPrefix("actRegister") }
        XCTAssertEqual(registrations, ["actRegister cookie=no pin=no", "actRegister cookie=no pin=yes"])
    }

    /// A television in standby shows no PIN, so it is found but not asked for one. Asked all the same -- its
    /// display gone off after it was found on -- it turns the registration down, which is said in words the
    /// reader can act on, and nothing is kept.
    func testATelevisionInStandbyIsNotAskedForItsPIN() async throws {
        let bench = try aBench()
        let television = DemoTV()
        let credentials = MemoryTVCredentials()
        let model = bench.model(recorder: SilentRecorder(), television: television, credentials: credentials,
                                saved: false)

        expectEqual(await model.findTV(at: Bench.tvHost), .standby(model: DemoTV.model))
        let calls = await television.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("actRegister") })

        expectEqual(await model.registerTV(at: Bench.tvHost, pin: nil), .failed(ScalarClient.screenIsOff))
        XCTAssertNil(credentials.load())
        XCTAssertNil(bench.defaults.string(forKey: DefaultsKey.tvHost))
        XCTAssertNil(model.tv)
    }

    // MARK: - an address typed while the system keeps the app off the local network

    /// An address typed for a television on a phone the system keeps off the local network -- behind its
    /// question, or after a no -- says nothing, as an address where nobody is does. So the permission is looked
    /// at there once, and when the look says the app is kept off, the sheet says so in place of the address not
    /// answering, and waits. Once the permission comes the address is asked again, by itself, and what answers
    /// is handed back: the sheet goes on to the registration with no second press, and the television hears
    /// what a registration sends after that question and nothing else.
    func testATypedAddressBehindTheQuestionWaitsForThePermissionAndGoesOnByItself() async throws {
        let bench = try aBench()
        bench.permissionLookSays = .blocked
        let television = DemoTV(power: "active")
        await television.goSilent()
        let model = bench.modelWithNoRecorder(television: television, credentials: MemoryTVCredentials(),
                                              saved: false)

        let asking = Task { await model.findTV(at: Bench.tvHost) }
        try await until("the sheet never said the app is kept off the local network", within: 2) {
            model.tvAddressTurnedAway
        }
        XCTAssertTrue(bench.isWaitingForPermission, "said that nothing answered in place of waiting")
        XCTAssertEqual(bench.permissionLooks, [Bench.tvHost])
        XCTAssertEqual(bench.permissionWaits, [Bench.tvHost])
        expectEqual(await television.calls, ["getPowerStatus cookie=no pin=no"])

        await television.goSilent(false)
        bench.permissionComes()
        expectEqual(await asking.value, .on(model: DemoTV.model), "the address was not asked again")
        XCTAssertFalse(model.tvAddressTurnedAway, "the notice stayed up once the permission came")
        // What the sheet does next with a television that is on, as it always has.
        expectEqual(await model.registerTV(at: Bench.tvHost, pin: nil), .pinNeeded)
        expectEqual(await television.calls, [
            "getPowerStatus cookie=no pin=no",
            "getPowerStatus cookie=no pin=no", "getInterfaceInformation cookie=no pin=no",
            "getSystemSupportedFunction cookie=no pin=no", "actRegister cookie=no pin=no",
        ])
        XCTAssertEqual(bench.permissionLooks.count, 1, "the permission was looked at again")
        XCTAssertEqual(bench.permissionWaits.count, 1, "the permission was waited for again")
    }

    /// Closing the sheet while it waits for the permission -- キャンセル, or swiping it away -- ends the wait,
    /// as the sheet closes it: its step cancelled and `stopFindingTV`. The notice goes, and when the permission
    /// comes after that the address is not asked again and nothing is handed back that the sheet would go on
    /// from: no registration is asked for, and no number put on a panel, with no sheet to type it into. The
    /// bench's wait ends only when the permission comes, which stands for a real one the permission ended in
    /// the moment the sheet closed.
    func testClosingTheSheetDuringTheWaitEndsItWithNothingSentAfter() async throws {
        let bench = try aBench()
        bench.permissionLookSays = .blocked
        let television = DemoTV(power: "active")
        await television.goSilent()
        let model = bench.modelWithNoRecorder(television: television, credentials: MemoryTVCredentials(),
                                              saved: false)
        let asking = Task { await model.findTV(at: Bench.tvHost) }
        try await until("the sheet never said the app is kept off the local network", within: 2) {
            model.tvAddressTurnedAway
        }
        let before = await television.calls

        asking.cancel()
        model.stopFindingTV()
        XCTAssertFalse(model.tvAddressTurnedAway, "the notice stayed up after the sheet had gone")
        await television.goSilent(false)
        bench.permissionComes()

        expectEqual(await asking.value, .nothing, "the wait went on after the sheet had gone")
        expectEqual(await television.calls, before, "the television was asked something after the sheet went")
        XCTAssertFalse(model.tvAddressTurnedAway)
    }

    /// A wait that ends with the permission still not given -- the Wi-Fi gone, or the wait given up on -- hands
    /// back that nothing answered, takes the notice down, and asks the address nothing more: there is nothing
    /// for the sheet to go on to, and a notice left up would promise that it goes on by itself.
    func testAWaitThatEndsWithoutThePermissionAsksNothingMoreAndTakesTheNoticeDown() async throws {
        for ending in [LocalNetwork.Access.unavailable, .blocked] {
            let bench = try aBench()
            bench.permissionLookSays = .blocked
            let television = DemoTV(power: "active")
            await television.goSilent()
            let model = bench.modelWithNoRecorder(television: television, credentials: MemoryTVCredentials(),
                                                  saved: false)
            let asking = Task { await model.findTV(at: Bench.tvHost) }
            try await until("the sheet never said the app is kept off the local network", within: 2) {
                model.tvAddressTurnedAway
            }
            let before = await television.calls
            await television.goSilent(false)

            bench.permissionComes(ending)

            expectEqual(await asking.value, .nothing, "\(ending)")
            XCTAssertFalse(model.tvAddressTurnedAway, "\(ending): the notice stayed up with nothing waiting")
            expectEqual(await television.calls, before, "\(ending): the address was asked again")
        }
    }

    /// With the permission given an address typed for a television goes on as it always has: one that answers
    /// is handed back with nothing asked of the permission, and one where nothing answers is said so at once,
    /// after one look at the permission there that does not say the app is kept off -- allowed, or nothing to
    /// say in the time it is given -- and no wait.
    func testATypedAddressWithThePermissionGivenGoesOnAsBefore() async throws {
        let bench = try aBench()
        let television = DemoTV(power: "active")
        let model = bench.modelWithNoRecorder(television: television, credentials: MemoryTVCredentials(),
                                              saved: false)

        expectEqual(await model.findTV(at: Bench.tvHost), .on(model: DemoTV.model))
        XCTAssertEqual(bench.permissionLooks, [], "the permission was looked at with the television answering")

        await television.goSilent()
        for says in [LocalNetwork.Access.allowed, nil] {
            bench.permissionLookSays = says
            let saying = String(describing: says)
            let found = try await within(2, "a silent address was waited on with the look saying \(saying)") {
                await model.findTV(at: Bench.tvHost)
            }
            XCTAssertEqual(found, .nothing)
        }
        XCTAssertEqual(bench.permissionLooks, [Bench.tvHost, Bench.tvHost])
        XCTAssertEqual(bench.permissionWaits, [], "waited for with the look not saying the permission is in the way")
        XCTAssertFalse(model.tvAddressTurnedAway)
    }

    /// In the demo nothing is asked of the local network: an address typed there that says nothing is not
    /// looked at for the permission, nor waited on.
    func testATypedAddressInTheDemoAsksNothingOfThePermission() async throws {
        let bench = try aBench()
        bench.permissionLookSays = .blocked
        let television = DemoTV()
        await television.goSilent()
        let model = bench.modelWithNoRecorder(television: television, credentials: MemoryTVCredentials(),
                                              saved: false)
        await model.start()
        await model.enterDemo()
        try await untilIdle(model)

        let found = try await within(2, "a silent address was waited on in the demo") {
            await model.findTV(at: Bench.tvHost)
        }

        XCTAssertEqual(found, .nothing)
        XCTAssertEqual(bench.permissionLooks, [], "the permission was looked at in the demo")
        XCTAssertEqual(bench.permissionWaits, [])
        XCTAssertFalse(model.tvAddressTurnedAway)
    }

    /// A cookie the television no longer takes need not mean the app is off its list: one that ran out leaves the
    /// client listed, and registering again then takes no PIN.
    func testAClientTheTelevisionStillListsRegistersAgainWithoutAPIN() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let television = DemoTV(power: "active")
        await television.knows("BDBridge:test", cookie: "kept")
        let credentials = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "run out"))
        let model = bench.model(recorder: DemoRecorder(), television: television, credentials: credentials)
        await model.start()
        try await until("the television was not said to need a registration") { model.tvDriver?.facts.needsPairing == true }

        expectEqual(await model.registerTV(at: Bench.tvHost, pin: nil), .registered)

        try await until("the television was not connected") { model.tv?.session.connected == true }
        XCTAssertEqual(model.tvDriver?.facts.needsPairing, false)
        XCTAssertEqual(credentials.load()?.clientID, "BDBridge:test")
        let registrations = await television.calls.filter { $0.hasPrefix("actRegister") }
        XCTAssertEqual(registrations, ["actRegister cookie=no pin=no"])
    }

    /// The television's silence holds up nothing of the recorder's, and the recorder's nothing of the
    /// television's: each gives up on its own, and the other connects.
    func testNeitherDevicesSilenceHoldsUpTheOther() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let quietTV = DemoTV()
        await quietTV.goSilent()
        let model = bench.model(recorder: DemoRecorder(), television: quietTV,
                                credentials: await registered(with: quietTV))
        await model.start()
        try await untilConnected(model)
        try await until("the television was not given up on") { model.tv?.session.gaveUp == true }
        XCTAssertFalse(model.gaveUp, "the television's silence gave up on the recorder")

        let other = try aBench()
        try await other.cacheAGuide()
        let television = DemoTV()
        let second = other.model(recorder: SilentRecorder(), television: television,
                                 credentials: await registered(with: television))
        await second.start()
        try await until("the television was not connected") { second.tv?.session.connected == true }
        try await untilGivenUp(second)
        XCTAssertTrue(second.tv?.session.connected == true, "the recorder's silence took the television with it")
    }

    /// A television saved without a working registration answers, and is said to need one; the recorder is
    /// connected as ever. Registered by its PIN, it is connected on a link made afresh, where an attach still out
    /// with the last cookie can say nothing.
    func testATelevisionWithoutARegistrationIsSaidToNeedOne() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let model = bench.model(recorder: DemoRecorder(), television: DemoTV(power: "active"),
                                credentials: MemoryTVCredentials())
        await model.start()

        try await until("the television was not said to need a registration") { model.tvDriver?.facts.needsPairing == true }
        try await untilConnected(model)
        XCTAssertNotNil(model.tvHost?.problem)
        XCTAssertNil(model.problem, "the television's problem was said as the recorder's")

        let before = model.tv
        expectEqual(await model.registerTV(at: Bench.tvHost, pin: DemoTV.pin), .registered)
        XCTAssertFalse(model.tv === before, "the link with the last cookie was kept")
        try await until("the television was not connected") { model.tv?.session.connected == true }
        XCTAssertEqual(model.tvDriver?.facts.needsPairing, false)
        XCTAssertNil(model.tvHost?.problem)
    }

    /// The television saved is known by its MAC from the first answer after a launch: another at its address is
    /// not taken up, its MAC is not written over the one saved, and the cookie does not go to it.
    func testAnotherTelevisionAtTheSavedAddressIsNotTakenUpAfterALaunch() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        bench.defaults.set("f8:4e:17:00:00:0b", forKey: DefaultsKey.tvMac)
        let television = DemoTV()
        let model = bench.model(recorder: DemoRecorder(), television: television,
                                credentials: await registered(with: television))
        await model.start()

        try await until("the other television was not said to be another") {
            model.tvHost?.problem == TVDriver.anotherAnswered
        }
        XCTAssertEqual(model.tv?.session.connected, false)
        XCTAssertEqual(bench.defaults.string(forKey: DefaultsKey.tvMac), "f8:4e:17:00:00:0b")
        let calls = await television.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("getStorageList") }, "the cookie went to another television")
    }

    /// Another television where the one connected to was, heard by the check before an operation -- the address
    /// handed to it while the app stayed open -- is said on the television's line, in the words for another
    /// device, and nothing that needs the registration is asked of it from then on: the list is not read, and
    /// the cookie does not go to it.
    func testAnotherTelevisionHeardByTheCheckIsSaidAndNotAsked() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let television = DemoTV()
        let model = bench.model(recorder: DemoRecorder(), television: television,
                                credentials: await registered(with: television))
        await model.start()
        try await until("the television was not connected") { model.tvDriver?.canBeAsked == true }

        await television.becomeAnother(mac: "f8:4e:17:00:00:0b")
        let before = await television.calls.count
        let up = await model.tv?.ensureUp(evenIfRecent: true)
        await model.tvHost?.loadReservations()

        XCTAssertEqual(up, false)
        XCTAssertEqual(model.tvHost?.problem, TVDriver.anotherAnswered)
        XCTAssertEqual(model.tvDriver?.canBeAsked, false)
        let after = await television.calls.dropFirst(before)
        XCTAssertEqual(Array(after), ["getSystemSupportedFunction cookie=no pin=no"])
    }

    /// The television's own passing fault at the check before an operation -- an HTTP 500 where it is asked which
    /// television it is -- is said on its line as that fault, and not in the words for another device, which
    /// would send the reader to テレビを外す: it stays connected, and is not said to want a registration. Nothing
    /// with the cookie goes to it meanwhile: the list a screen asks for asks again which television it is, and
    /// reads nothing.
    func testTheTelevisionsOwnFaultAtTheCheckIsSaidAsItsFault() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let television = DemoTV()
        let faulting = FaultingTelevision(television)
        let model = bench.model(recorder: DemoRecorder(), television: faulting,
                                credentials: await registered(with: television))
        await model.start()
        try await until("the television was not connected") { model.tvDriver?.canBeAsked == true }

        await faulting.fail(with: 500)
        let before = await television.calls.count
        _ = await model.tv?.ensureUp(evenIfRecent: true)
        await model.tvHost?.loadReservations()

        let fault = ScalarError.http(status: 500, method: "getSystemSupportedFunction").explanation
        XCTAssertEqual(model.tvHost?.problem, fault, "not said as the television's own fault")
        XCTAssertEqual(model.tv?.session.connected, true)
        XCTAssertEqual(model.tvDriver?.facts.needsPairing, false)
        let after = await television.calls.dropFirst(before)
        XCTAssertEqual(Array(after), Array(repeating: "getSystemSupportedFunction cookie=no pin=no", count: 2))
    }

    /// A registration writes down the MAC the television gave as it registered: the link made next knows the
    /// television by it. A television that gives no MAC leaves none saved: the one from before would be kept as
    /// its own. Another television takes the place of the one saved only after テレビを外す
    /// (`testRegisteringAnotherTelevisionThanTheOneSavedIsRefused`).
    func testARegistrationWritesDownTheMACItRead() async throws {
        let other = try aBench()
        other.defaults.set("f8:4e:17:00:00:0b", forKey: DefaultsKey.tvMac)
        let nameless = DemoTV(mac: "")
        let second = other.model(recorder: SilentRecorder(), television: nameless,
                                 credentials: await registered(with: nameless))

        expectEqual(await second.registerTV(at: Bench.tvHost, pin: nil), .registered)

        XCTAssertEqual(second.tv?.session.connected, true)
        XCTAssertNil(other.defaults.string(forKey: DefaultsKey.tvMac), "the MAC saved before was left for this one")
    }

    /// Registering where a television answers that is not the one saved -- told by the MAC saved with it -- is
    /// refused before anything that registers is sent to it, and the sheet says how another television is
    /// added: テレビを外す first. With the PIN as well: no PIN comes up on its panel for a registration the app
    /// would refuse. What is saved stays as it was: the address, the MAC, the registration, and what waits for
    /// the television saved.
    func testRegisteringAnotherTelevisionThanTheOneSavedIsRefused() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let request = ReservationRequest(title: "サンプル番組", start: Date().addingTimeInterval(3600), durationSec: 1800,
                                         repeatCode: "1", broadcastingType: 2, serviceID: 1024, qualityCode: 100,
                                         eventID: 4321)
        var row = PendingReservation(request: request, serviceName: "サンプルテレビ")
        row.target = .tv
        try await GuideStore(path: bench.guidePath).queue(row)
        bench.defaults.set("f8:4e:17:00:00:0b", forKey: DefaultsKey.tvMac)
        let television = DemoTV(power: "active")
        let saved = TVCredentials(clientID: "BDBridge:saved", cookie: "kept")
        let credentials = MemoryTVCredentials(saved)
        let model = bench.model(recorder: DemoRecorder(), television: television, credentials: credentials)
        await model.start()
        try await until("the other television was not said to be another") {
            model.tvHost?.problem == TVDriver.anotherAnswered
        }

        expectEqual(await model.registerTV(at: Bench.tvHost, pin: nil), .failed(ScalarClient.anotherTelevision))
        expectEqual(await model.registerTV(at: Bench.tvHost, pin: DemoTV.pin), .failed(ScalarClient.anotherTelevision))

        XCTAssertEqual(bench.defaults.string(forKey: DefaultsKey.tvHost), Bench.tvHost)
        XCTAssertEqual(bench.defaults.string(forKey: DefaultsKey.tvMac), "f8:4e:17:00:00:0b")
        XCTAssertEqual(credentials.load(), saved)
        expectEqual(try await GuideStore(path: bench.guidePath).pendingReservations().map(\.id), [row.id])
        let calls = await television.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("actRegister") }, "the other television was asked to register")
        XCTAssertEqual(model.tv?.session.connected, false)
    }

    /// The tutorial is for a phone with nothing set up. A home with a television and no recorder has set up
    /// what it has, and is not shown the tutorial at every launch; nor is a home with a recorder.
    func testOnlyAPhoneWithNothingSetUpIsWelcomed() throws {
        let nothing = try aBench()
        XCTAssertTrue(nothing.modelWithNoRecorder().welcomes)

        let television = try aBench()
        XCTAssertFalse(television.modelWithNoRecorder(television: DemoTV(), credentials: MemoryTVCredentials()).welcomes)

        let recorder = try aBench()
        XCTAssertFalse(recorder.model(recorder: SilentRecorder()).welcomes)
    }

    /// What each device is doing is its own: while the television attaches, the recorder is not busy and may be
    /// changed, and the recorder's work does not make the television busy.
    func testEachDeviceIsBusyWithItsOwnWorkOnly() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let television = HeldTelevision(DemoTV())
        let model = bench.model(recorder: DemoRecorder(), television: television, credentials: MemoryTVCredentials())
        await model.start()
        try await until("the television's attach was never under way") { await television.isHolding }

        try await until("the television's attach made the recorder busy") {
            model.connected && !isConnecting(model) && !model.isBusy
        }
        XCTAssertEqual(model.busy, TVDriver.connectingLine, "the television's line is not on the strip")
        XCTAssertEqual(model.tvHost?.isBusy, true)
        XCTAssertTrue(model.canChangeRecorder, "the television's attach held the recorder's choice back")

        await television.letGo()
        try await until("the television's attach never ended") { model.tvHost?.isBusy == false }
        let line = model.beginActivity("録画一覧を取得中")
        XCTAssertEqual(model.tvHost?.isBusy, false, "the recorder's work made the television busy")
        model.endActivity(line)
    }

    /// The registration is renewed with the app in front only: a connect made in the background -- the network
    /// changing while the app is kept alive there -- reads the television and leaves the cookie as it was.
    func testTheRegistrationIsNotRenewedInTheBackground() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let television = DemoTV()
        await television.goSilent()
        let credentials = await registered(with: television, daysAgo: 8)
        let model = bench.model(recorder: DemoRecorder(), television: television, credentials: credentials)
        await model.start()
        try await until("the television was not given up on") { model.tv?.session.gaveUp == true }

        model.wentToBackground()
        await television.goSilent(false)
        bench.network = "elsewhere"
        model.networkReported()

        try await until("the report did not reach the television") { model.tv?.session.connected == true }
        let calls = await television.calls
        XCTAssertFalse(calls.contains { $0.hasPrefix("actRegister") }, "renewed in the background")
        XCTAssertEqual(credentials.load()?.cookie, "kept")
    }

    /// The demo lets go of the real television, which would otherwise answer beside the invented recorder, and
    /// gives it back when it ends.
    func testTheDemoLetsGoOfTheTelevisionAndGivesItBack() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let television = DemoTV()
        let model = bench.model(recorder: DemoRecorder(), television: television,
                                credentials: await registered(with: television))
        await model.start()
        try await untilConnected(model)
        XCTAssertNotNil(model.tv)

        await model.enterDemo()
        XCTAssertNil(model.tv)
        try await untilIdle(model)

        await model.leaveDemo()
        XCTAssertNotNil(model.tv)
        try await until("the television was not connected again") { model.tv?.session.connected == true }
    }

    /// Coming back to the app on another network, and a report of the network changing, reach the television's
    /// link as they reach the recorder's: a television given up on is tried again by each.
    func testComingBackAndANewNetworkReachTheTelevisionToo() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let television = DemoTV()
        await television.goSilent()
        let model = bench.model(recorder: DemoRecorder(), television: television,
                                credentials: await registered(with: television))
        await model.start()
        try await untilConnected(model)
        try await until("the television was not given up on") { model.tv?.session.gaveUp == true }

        await television.goSilent(false)
        bench.network = "elsewhere"
        model.wentToBackground()
        await model.returnedToForeground()
        try await until("coming back did not try the television again") { model.tv?.session.connected == true }

        await television.goSilent()
        _ = await model.tv?.ensureUp(evenIfRecent: true)
        XCTAssertEqual(model.tv?.session.gaveUp, true)
        await television.goSilent(false)
        bench.network = "further"
        model.networkReported()
        try await until("a report of the network did not try the television again") {
            model.tv?.session.connected == true
        }
    }

    /// Taking the television away forgets its link, its address and its registration, and an attach still out
    /// writes none of them back.
    func testTakingTheTelevisionAwayForgetsItWhole() async throws {
        let bench = try aBench()
        try await bench.cacheAGuide()
        let television = DemoTV()
        let credentials = await registered(with: television)
        let model = bench.model(recorder: DemoRecorder(), television: television, credentials: credentials)
        await model.start()
        try await until("the television was not connected") { model.tv?.session.connected == true }

        let host = try XCTUnwrap(model.tvHost)
        model.removeTV()

        XCTAssertNil(model.tv)
        XCTAssertNil(credentials.load())
        // An attach still out writes nothing back.
        host.keepAddress(Bench.tvHost)
        host.keepMAC(DemoTV.mac)
        XCTAssertNil(bench.defaults.string(forKey: DefaultsKey.tvHost))
        XCTAssertNil(bench.defaults.string(forKey: DefaultsKey.tvMac))
    }
}

/// The invented television, answering the ask of which television it is with `status` while one is set: a
/// passing fault of its own. Every request still reaches it, so that its `calls` say what was sent.
private actor FaultingTelevision: HTTPTransport {
    private let television: DemoTV
    private var status: Int?

    init(_ television: DemoTV) { self.television = television }

    func fail(with status: Int?) { self.status = status }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let answer = try await television.send(request)
        let asksWhich = String(decoding: request.body ?? Data(), as: UTF8.self).contains("getSystemSupportedFunction")
        guard let status, asksWhich else { return answer }
        return HTTPResponse(statusCode: status)
    }
}
