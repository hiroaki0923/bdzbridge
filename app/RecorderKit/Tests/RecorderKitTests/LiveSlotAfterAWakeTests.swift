import XCTest
@testable import RecorderKit

/// How long after a wake the recorder takes to answer its USB slot with the disk it has: right after one it answers
/// as if no disk were registered, and a while later with the disk. Read only. Meant to be run with the recorder off
/// the network, so that the wake is a real one (`LiveWaking`, which needs RECORDER_MAC as well):
///
///     RECORDER_HOST=192.0.2.63 RECORDER_MAC=<the recorder's MAC> swift test --filter LiveSlotAfterAWakeTests
///
/// It reads the slot every five seconds for three minutes at most and prints, for each read, the time since the
/// recorder first answered and whether a registered disk was in the answer -- nothing of the disk itself.
final class LiveSlotAfterAWakeTests: XCTestCase {
    func testHowLongTheSlotTakesToAnswerItsDiskAfterAWake() async throws {
        guard let host = ProcessInfo.processInfo.environment["RECORDER_HOST"], !host.isEmpty else {
            throw XCTSkip("set RECORDER_HOST to a recorder on the LAN")
        }
        let woke = ContinuousClock.now
        try await LiveWaking.wakeTheRecorderIfAsked()
        let answered = ContinuousClock.now
        print(String(format: "the wake took %.2f s; reading the slot from here", (answered - woke) / .seconds(1)))
        let client = RecorderClient(host: host)
        while ContinuousClock.now - answered < .seconds(180) {
            let since = String(format: "%6.2f s", (ContinuousClock.now - answered) / .seconds(1))
            do {
                let disk = try await client.disk(RecorderDisk.usbID)
                let registered = !(disk?.registered.isEmpty ?? true)
                print("\(since): mounted \(disk?.mounted ?? false), registered \(registered)")
                if registered, disk?.mounted == true { return }
            } catch {
                print("\(since): \(error)")
            }
            try await Task.sleep(for: .seconds(5))
        }
        print("no disk answered within three minutes")
    }
}
