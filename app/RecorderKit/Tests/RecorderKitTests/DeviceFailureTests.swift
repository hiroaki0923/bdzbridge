import XCTest
@testable import RecorderKit

/// `DeviceFailure` is what everything that does not care which device it talks to reads from an error: the
/// queue, the waking loop, the guide refresh, the screens. For the recorder, each kind of error its client
/// throws reads as one failure.
final class DeviceFailureTests: XCTestCase {
    private func fault(_ code: String?, status: Int = 500) -> RecorderError {
        .soap(action: "X_CreateRecordSchedule", status: status, code: code, body: "")
    }

    /// One of every kind of error the recorder's client throws, what it reads as, and whether the queue holds
    /// a reservation back for it with the reason written on it (`turnsTheRequestDown`).
    func testEachKindOfErrorReadsAsOneFailure() {
        let refused = { (error: RecorderError) in DeviceFailure.refused(reason: error.explanation) }
        let unexpected = { (error: RecorderError) in DeviceFailure.unexpected(error.explanation) }
        let table: [(error: RecorderError, failure: DeviceFailure, turnsDown: Bool)] = [
            // nothing answered: the one failure worth waking the recorder for
            (.transport("timed out"), .silent, false),
            (.notHTTP, .silent, false),
            // busy whichever way it arrives, whatever code came with a 503
            (.busy(action: "X_GetRecordScheduleList"), .busy, false),
            (fault("402", status: 503), .busy, false),
            (fault(nil, status: 503), .busy, false),
            // a code of its own about the request, carrying the sentence the reader is shown
            (fault("402"), refused(fault("402")), true),
            (fault("831"), refused(fault("831")), true),
            (fault("999"), refused(fault("999")), true),
            // the reservation or the recording has gone: a stale list, not a refusal
            (fault("804"), .unknownItem, true),
            (fault("820"), .unknownItem, true),
            // standby is about the recorder, not the request
            (fault("880"), .needsPower, false),
            // answers that say nothing about the request
            (fault(nil), unexpected(fault(nil)), false),
            (.badResponse(status: 404), unexpected(.badResponse(status: 404)), false),
            (.unexpectedAnswer(action: "X_GetPrivateIp"), unexpected(.unexpectedAnswer(action: "X_GetPrivateIp")),
             false),
            (.guideFileMissing(name: "EPG_TRDEPG_FILE.dat", status: 500),
             unexpected(.guideFileMissing(name: "EPG_TRDEPG_FILE.dat", status: 500)), false),
            (.notARecorder(host: "192.0.2.10"), unexpected(.notARecorder(host: "192.0.2.10")), false),
            // nothing was sent, and waking would not make the address any better
            (.badAddress(host: "nonsense"), .badAddress, false),
        ]
        for row in table {
            XCTAssertEqual(row.error.failure, row.failure, "\(row.error)")
            XCTAssertEqual(row.error.failure.turnsTheRequestDown, row.turnsDown, "\(row.error)")
        }
        // 831 is the recorder refusing a channel it cannot receive -- a pay channel not subscribed to -- and reads
        // as a broken app unless the sentence says so.
        XCTAssertTrue(fault("831").explanation.contains("受信"), fault("831").explanation)
    }
}
