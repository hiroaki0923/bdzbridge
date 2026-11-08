import Foundation
import RecBridgeModel
import RecorderKit
import XCTest
@testable import BDBridge

/// What only the iOS app has, which the model's tests in the package (`RecBridgeModelTests`) cannot reach: the
/// app's own start, its surroundings, its notifications' identifiers and marks, and the demo's logo tiles.
@MainActor
final class TheAppsOwnTests: XCTestCase {
    /// The tests make models of their own, and the app they run inside must not be starting one of its own
    /// beside them, connected to whatever recorder this simulator last saved.
    func testTheAppLeavesItsOwnStartOutWhileHostingTheTests() {
        XCTAssertTrue(BDBridgeApp.hostingUnitTests)
    }

    /// The app's own surroundings hand the search the app's own pause and transport, which every other test
    /// here has the bench's for: a pause before a single request lasts as long as the search asks, where one
    /// left out takes no time, and the requests go through the real session (`URLSessionTransport`), where one
    /// left out reaches nobody. The pause is only waited out and the transport only made: nothing is sent.
    func testTheAppsSearchPausesForAsLongAsItAsksAndSendsThroughTheRealSession() async throws {
        let app = Surroundings.app
        let pause = app.scanPause
        let began = ContinuousClock.now

        await pause(.milliseconds(300))

        XCTAssertGreaterThanOrEqual(ContinuousClock.now - began, .milliseconds(300),
                                    "the app's search does not pause for as long as it asks")
        XCTAssertTrue(app.scanTransport() is URLSessionTransport,
                      "the app's search does not send through the real session")
    }

    /// The television's two notifications have identifiers of their own, which the recorder's
    /// (`queue-flushed`) is not, nor either the other's: none takes another's place.
    func testTheTelevisionsNotificationsHaveIdentifiersOfTheirOwn() {
        XCTAssertEqual(Notify.televisionQueue, "tv-queue-flushed")
        XCTAssertEqual(Notify.televisionNotYet, "tv-not-yet-sent")
    }

    /// The USB disk's warning is given once per fall below the line, for the disk in the slot: a disk that was
    /// warned about is not warned about again until it has had room, and another disk -- or the same one renamed,
    /// which is not to be told from another -- has not been warned about yet. A warning leaves the disk's
    /// identity as the mark, and goes under an identifier of its own.
    func testTheUSBDisksLowSpaceMarkIsTheDisksOwn() {
        func disk(freeGB: Int, name: String = "録画用ディスク", registered: String = "2026-01-02T03:04:05+0900",
                  mounted: Bool = true) -> RecorderDisk {
            RecorderDisk(destination: RecorderDisk.usbID, name: name, mounted: mounted, freeMB: freeGB * 1000,
                         totalMB: 2_000_398, registered: registered)
        }
        let low = disk(freeGB: 10), roomy = disk(freeGB: 100)
        let another = disk(freeGB: 10, registered: "2026-02-03T04:05:06+0900")
        let renamed = disk(freeGB: 10, name: "別のディスク")

        XCTAssertEqual(Notify.usbSpace(low, marked: nil, warnBelowGB: 50), .warn(freeGB: 10, mark: low.identity),
                       "the warning does not leave the disk's identity as its mark")
        XCTAssertEqual(Notify.usbSpace(low, marked: low.identity, warnBelowGB: 50), .nothing, "warned twice")
        XCTAssertEqual(Notify.usbSpace(another, marked: low.identity, warnBelowGB: 50),
                       .warn(freeGB: 10, mark: another.identity), "another disk taken for the one warned about")
        XCTAssertEqual(Notify.usbSpace(renamed, marked: low.identity, warnBelowGB: 50),
                       .warn(freeGB: 10, mark: renamed.identity))
        XCTAssertEqual(Notify.usbSpace(roomy, marked: roomy.identity, warnBelowGB: 50), .roomAgain)
        XCTAssertEqual(Notify.usbSpace(roomy, marked: another.identity, warnBelowGB: 50), .nothing)
        XCTAssertEqual(Notify.usbSpace(roomy, marked: nil, warnBelowGB: 50), .nothing)
        XCTAssertEqual(Notify.usbSpace(disk(freeGB: 10, mounted: false), marked: nil, warnBelowGB: 50), .nothing,
                       "a disk that is not there was warned about")

        // Pinned as written: a notice still shown from an earlier version is replaced by the next under it.
        XCTAssertEqual(Notify.usbLowSpaceID, "low-space-usb")
    }

    /// Six terrestrial stations and three on BS, by their ids and names in the guide's order, each with a logo
    /// drawn as a PNG.
    func testItsStationsAndTheirLogos() async throws {
        let store = try await seeded()

        let terrestrial = try await store.channels(broadcasting: "td")
        XCTAssertEqual(terrestrial.map { "\($0.serviceID) \($0.name)" }, [
            "1024 サンプルテレビ", "1032 サンプル教育", "1040 みほんテレビ", "1048 テレビみほん", "1056 サンプル放送",
            "1064 ひなたテレビ",
        ])
        let satellite = try await store.channels(broadcasting: "bs")
        XCTAssertEqual(satellite.map { "\($0.serviceID) \($0.name)" }, ["2048 サンプルBS", "2056 みほんBS", "2064 BSみほん"])

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        for channel in terrestrial + satellite {
            XCTAssertEqual(channel.logo?.prefix(8), png, "\(channel.serviceID) has no logo drawn")
        }
    }

    /// The demo's guide written into a cache in a folder of the test's own, which goes once the test is over.
    private func seeded() async throws -> GuideStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let store = try GuideStore(path: folder.appendingPathComponent("guide-demo.sqlite3").path)
        try await DemoData.seed(store: store)
        return store
    }
}
