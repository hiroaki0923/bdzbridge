import XCTest
@testable import RecorderKit

/// The strip's report (`StripReport`) and the rules for the list of recordings with a USB disk
/// (`keeping(_:readFrom:usb:)`, `isOutdated(readFrom:usb:)`).
final class StripReportTests: XCTestCase {
    func testASendingAddsOnlyTheSentencesTheReportDoesNotHoldYet() {
        XCTAssertEqual(StripReport.adding("1 件を送りました。", toUnread: nil), "1 件を送りました")
        XCTAssertEqual(StripReport.adding("2 件を送りました。1 件は理由付きで残っています",
                                          toUnread: "1 件は理由付きで残っています"),
                       "1 件は理由付きで残っています。2 件を送りました")
        XCTAssertNil(StripReport.adding("1 件は理由付きで残っています。", toUnread: "1 件は理由付きで残っています"),
                     "nothing new: the report stays as it was")
    }

    func testAFullStopInsideATitleIsNoEndOfASentence() {
        XCTAssertEqual(StripReport.sentences("「なぜ。どうして」を送りました。次の文"),
                       ["「なぜ。どうして」を送りました", "次の文"])
    }

    func testTheCountHeldForAnotherRecorderIsReplacedAndTheRestKept() throws {
        let first = try XCTUnwrap(StripReport.afterASending(report: nil, heldBefore: nil, held: "2 件を保留しています",
                                                           said: "1 件を送りました"))
        XCTAssertEqual(first.report, "2 件を保留しています。1 件を送りました")
        XCTAssertEqual(first.held, "2 件を保留しています")

        let second = try XCTUnwrap(StripReport.afterASending(report: first.report, heldBefore: first.held,
                                                            held: "1 件を保留しています", said: nil))
        XCTAssertEqual(second.report, "1 件を保留しています。1 件を送りました", "the count said before is replaced")

        let gone = try XCTUnwrap(StripReport.afterASending(report: second.report, heldBefore: second.held, held: nil,
                                                          said: nil))
        XCTAssertEqual(gone.report, "1 件を送りました")
        XCTAssertNil(gone.held)

        XCTAssertNil(StripReport.afterASending(report: nil, heldBefore: nil, held: nil, said: nil),
                     "nothing held and nothing to say: the strip stays as it was")
    }

    // MARK: - the list with a USB disk

    private let usb = RecorderDisk(destination: RecorderDisk.usbID, name: "外付け", mounted: true, freeMB: 1000,
                                   totalMB: 2000, registered: "2026-01-01")
    private let another = RecorderDisk(destination: RecorderDisk.usbID, name: "別の外付け", mounted: true,
                                       freeMB: 1000, totalMB: 2000, registered: "2026-02-01")

    private func recording(_ id: String, on disk: RecorderDisk?) -> RecordedTitle {
        var row = RecordedTitle(id: id, title: "", start: Date(timeIntervalSince1970: 1_800_000_000), durationSec: 60,
                                broadcastingType: 0, serviceID: 0, qualityCode: 0, protected: false, isNew: false,
                                recording: false, destination: disk?.destination ?? RecorderDisk.internalID,
                                sizeMB: nil)
        row.readFrom = disk
        return row
    }

    func testAReadWithNoUSBRowsKeepsThoseOfTheDiskStillInTheSlot() {
        let held = [recording("h1", on: nil), recording("u1", on: usb)]
        let read = [recording("h2", on: nil)]
        XCTAssertEqual(held.keeping(read, readFrom: nil, usb: usb).map(\.id), ["h2", "u1"])
        XCTAssertEqual(held.keeping(read, readFrom: nil, usb: another).map(\.id), ["h2"],
                       "the rows of a disk that has left the slot go")
        XCTAssertEqual(held.keeping(read + [recording("u2", on: usb)], readFrom: usb, usb: usb).map(\.id),
                       ["h2", "u2"], "a read of the disk replaces its rows")
    }

    func testTheListIsOutdatedWhenTheDiskItWasReadWithIsNotTheOneThereNow() {
        let internalOnly = [recording("h1", on: nil)]
        XCTAssertFalse(internalOnly.isOutdated(readFrom: nil, usb: nil), "nothing changes in a home with no USB disk")
        XCTAssertTrue(internalOnly.isOutdated(readFrom: nil, usb: usb), "a disk has turned up")
        XCTAssertTrue([recording("u1", on: usb)].isOutdated(readFrom: nil, usb: nil),
                      "rows held of a disk that has gone")
        XCTAssertFalse(internalOnly.isOutdated(readFrom: usb, usb: usb))
        XCTAssertTrue(internalOnly.isOutdated(readFrom: usb, usb: another))
        XCTAssertTrue(internalOnly.isOutdated(readFrom: usb, usb: nil))
    }
}
