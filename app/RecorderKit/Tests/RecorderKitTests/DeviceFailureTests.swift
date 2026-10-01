import XCTest
@testable import RecorderKit

/// `DeviceFailure` is what the rules that do not care which device they talk to read from an error. For the
/// recorder it has to say the same thing as the predicates those rules read until now, case for case.
final class DeviceFailureTests: XCTestCase {
    private func fault(_ code: String?, status: Int = 500) -> RecorderError {
        .soap(action: "X_CreateRecordSchedule", status: status, code: code, body: "")
    }

    /// One of every kind of error the recorder's client throws.
    private var everyKind: [RecorderError] {
        [.transport("timed out"), .notHTTP, .busy(action: "X_GetRecordScheduleList"),
         fault("402"), fault("804"), fault("820"), fault("831"), fault("880"), fault("999"),
         fault("402", status: 503), fault(nil), fault(nil, status: 503),
         .badResponse(status: 404), .unexpectedAnswer(action: "X_GetPrivateIp"),
         .guideFileMissing(name: "EPG_TRDEPG_FILE.dat", status: 500), .notARecorder(host: "192.0.2.10"),
         .badAddress(host: "nonsense")]
    }

    func testSilenceIsWhatUnreachableMeant() {
        XCTAssertEqual(RecorderError.transport("timed out").failure, .silent)
        XCTAssertEqual(RecorderError.notHTTP.failure, .silent)
        for error in everyKind {
            XCTAssertEqual(error.failure == .silent, error.unreachable, "\(error)")
        }
    }

    func testARefusalCarriesTheSentenceTheReaderIsShown() {
        let error = fault("831")
        XCTAssertEqual(error.failure, .refused(reason: error.explanation))
        XCTAssertEqual(fault("999").failure, .refused(reason: fault("999").explanation))
    }

    /// The queue holds a reservation back, with the reason on it, after exactly the errors it did before.
    func testWhatTurnsTheRequestDownIsWhatRefusalMeant() {
        for error in everyKind {
            XCTAssertEqual(error.failure.turnsTheRequestDown, error.refusal, "\(error)")
        }
    }

    func testStandbyIsNeedsPower() {
        XCTAssertEqual(fault("880").failure, .needsPower)
        for error in everyKind {
            XCTAssertEqual(error.failure == .needsPower, error.needsPowerOn, "\(error)")
        }
    }

    func testAnItemTheRecorderDoesNotHaveIsUnknown() {
        XCTAssertEqual(fault("804").failure, .unknownItem)
        XCTAssertEqual(fault("820").failure, .unknownItem)
        for error in everyKind where error.unknownReservation {
            XCTAssertEqual(error.failure, .unknownItem, "\(error)")
        }
    }

    func testBusyIsBusyWhicheverWayItArrives() {
        XCTAssertEqual(RecorderError.busy(action: "X_GetTitleList").failure, .busy)
        XCTAssertEqual(fault("402", status: 503).failure, .busy)
        XCTAssertEqual(fault(nil, status: 503).failure, .busy)
    }

    func testAnAnswerThatSaysNothingAboutTheRequestIsUnexpected() {
        for error in [fault(nil), .badResponse(status: 404), .unexpectedAnswer(action: "X_GetPrivateIp"),
                      .guideFileMissing(name: "EPG_TRDEPG_FILE.dat", status: 500),
                      .notARecorder(host: "192.0.2.10")] as [RecorderError] {
            XCTAssertEqual(error.failure, .unexpected(error.explanation), "\(error)")
        }
    }

    func testAnAddressNothingCanBeSentToIsItsOwnKind() {
        XCTAssertEqual(RecorderError.badAddress(host: "nonsense").failure, .badAddress)
    }

    /// What a caller that knows no device catches.
    func testTheRecordersErrorIsADeviceError() {
        let thrown: any Error = RecorderError.transport("timed out")
        let device = thrown as? any DeviceError
        XCTAssertEqual(device?.failure, .silent)
        XCTAssertEqual(device?.explanation, RecorderError.transport("timed out").explanation)
    }
}
