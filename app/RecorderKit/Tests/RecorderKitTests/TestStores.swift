import Foundation
import XCTest
@testable import RecorderKit

extension XCTestCase {
    /// Where a test keeps a cache file of its own. The file goes when the test ends, and so do the two that
    /// SQLite keeps beside it in WAL mode: left behind, every run added a few more to the temporary directory.
    func temporaryPath() -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderKitTests-\(UUID().uuidString).sqlite3").path
        addTeardownBlock {
            for file in [path, path + "-wal", path + "-shm"] {
                try? FileManager.default.removeItem(atPath: file)
            }
        }
        return path
    }

    /// A cache in a file of the test's own, which goes when the test ends.
    func temporaryStore() throws -> GuideStore {
        try GuideStore(path: temporaryPath())
    }
}

/// A reservation of the sample programme as the queue keeps it, with whatever a test changes. It was queued at
/// a whole second, as the cache keeps the moment, so that one read back is equal to the one that went in.
func pending(_ title: String = "サンプル番組", eventID: Int? = 0x311f,
             start: Date = Date(timeIntervalSince1970: 1_790_000_000), problem: String? = nil,
             target: DeviceSlot = .recorder) -> PendingReservation {
    PendingReservation(request: ReservationRequest(title: title, start: start, durationSec: 3600, repeatCode: "1",
                                                   broadcastingType: 2, serviceID: 0x428, qualityCode: 240,
                                                   eventID: eventID),
                       serviceName: "サンプルテレビ", queuedAt: Date(timeIntervalSince1970: 1_789_000_000),
                       problem: problem, target: target)
}
