import Foundation
import RecorderKit
import XCTest

/// A waiting row whose create met silence, which may have been made all the same. A recorder's round holds it
/// for the reader, with the sentence the recorder's driver gives it; a television's leaves it as it was, for
/// its next round to look for on the television.
final class SilenceAtACreateTests: XCTestCase {
    /// Three rows wait for the recorder: the first is made, the create of the second meets silence, and the
    /// third is not sent. The second carries the sentence on the phone, and nothing more is written: the first
    /// has left the queue and the third waits as it was. The round says it stopped at silence after sending.
    ///
    /// Two wait for a television whose create of the first is carried out and never answered: the round stops
    /// the same way, and neither row has anything written on it.
    func testARecordersRowWhoseCreateMetSilenceIsHeldWithItsSentenceAndATelevisionsIsLeftAsItWas() async throws {
        // At whole seconds, as the cache keeps a start, so that the rows read back are the ones queued.
        let tomorrow = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 24 * 3600).rounded(.down))
        let recorders = [pending("サンプル劇場", eventID: 0x3121, start: tomorrow),
                         pending("サンプル紀行", eventID: 0x3122, start: tomorrow.addingTimeInterval(3600)),
                         pending("サンプル天気", eventID: 0x3123, start: tomorrow.addingTimeInterval(7200))]
        let store = try temporaryStore()
        for row in recorders { try await store.queue(row) }
        let made = Stub.soap("X_CreateRecordSchedule", extra: "<RecordScheduleID>0x1</RecordScheduleID>")
        let transport = StubTransport { _, index in
            guard index == 0 else { throw RecorderError.transport("timed out") }
            return made
        }

        let round = await PendingQueue.flush(client: RecorderClient(host: Stub.host, transport: transport),
                                             store: store)

        XCTAssertEqual(round.stopped, .silent(afterSending: true))
        XCTAssertEqual(round.sent.map(\.id), [recorders[0].id])
        expectEqual(await transport.requests.count, 2, "something was sent after the create that met silence")
        let left = try await store.pendingReservations()
        XCTAssertEqual(left.map(\.id), [recorders[1].id, recorders[2].id])
        XCTAssertEqual(left.map(\.problem), [RecorderDriver.heldAfterSilence, nil],
                       "the row whose create met silence is not held with the sentence, or another row was written")

        let television = DemoTV(stations: [DemoTV.Station(serviceID: 0x428)])
        await television.knows("BDBridge:test", cookie: "kept")
        await television.atTheNextCreate(.carriedOutAndNotAnswered)
        let credentials = MemoryTVCredentials(TVCredentials(clientID: "BDBridge:test", cookie: "kept"))
        let televisions = [pending("サンプル劇場", eventID: 0x3121, start: tomorrow, target: .tv),
                           pending("サンプル紀行", eventID: 0x3122, start: tomorrow.addingTimeInterval(3600),
                                   target: .tv)]
        let tvStore = try temporaryStore()
        for row in televisions { try await tvStore.queue(row) }

        let tvRound = await PendingQueue.flush(client: ScalarClient(host: Stub.host, transport: television,
                                                                    credentials: credentials),
                                               store: tvStore)

        XCTAssertEqual(tvRound.stopped, .silent(afterSending: true), "the television's create was meant to meet silence")
        expectEqual(await television.schedules.count, 1, "the television's create was meant to be carried out")
        expectEqual(try await tvStore.pendingReservations().map(\.problem), [nil, nil],
                    "a television's row was written on")
    }
}
