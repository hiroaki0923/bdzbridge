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

    /// What the recorder lists of its recordings while its USB slot comes back after a wake: whether a list read
    /// in those first seconds has the USB disk's recordings in it, or leaves them out. Read only. Run with the
    /// recorder off the network -- left alone until it dropped off, its USB disk connected with at least one
    /// finished recording on it -- so that the wake is a real one; nobody needs to watch it:
    ///
    ///     RECORDER_HOST=192.0.2.63 RECORDER_MAC=<the recorder's MAC> \
    ///         swift test --filter LiveSlotAfterAWakeTests/testTheListsAfterAWake
    ///
    /// Skipped without RECORDER_MAC: what it reads is what a wake leaves. Every five seconds from the moment the
    /// recorder answered the wake it reads the slot, the list asked for by the slot's criteria and the list asked
    /// for with none, as the recordings screen asks for it, and prints the seconds since, whether the slot answered
    /// a registered disk that is mounted, and each list's count by the disk each row says it is on -- never a title,
    /// an id or the disk's name. It ends half a minute after the slot first answered its disk, or after three
    /// minutes.
    func testTheListsAfterAWake() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["RECORDER_HOST"], !host.isEmpty else {
            throw XCTSkip("set RECORDER_HOST to a recorder on the LAN")
        }
        guard let mac = environment["RECORDER_MAC"], !mac.isEmpty else {
            throw XCTSkip("set RECORDER_MAC as well: this reads what a wake leaves")
        }
        let answered = try await LiveWaking.wakeTheRecorderIfAsked() ?? ContinuousClock.now
        let client = RecorderClient(host: host)
        var diskAnswered: ContinuousClock.Instant?
        while ContinuousClock.now - answered < .seconds(180) {
            let since = String(format: "%6.2f s", (ContinuousClock.now - answered) / .seconds(1))
            var slot: String
            do {
                let disk = try await client.disk(RecorderDisk.usbID)
                let present = disk?.mounted == true && !(disk?.registered.isEmpty ?? true)
                slot = "disk \(present ? "present" : "absent")"
                if present, diskAnswered == nil { diskAnswered = ContinuousClock.now }
            } catch {
                slot = "slot \(Self.code(error))"
            }
            let bySlot: String
            do {
                bySlot = Self.byDisk(try await client.titles(count: 200, on: RecorderDisk.usbID))
            } catch {
                bySlot = Self.code(error)
            }
            let unnarrowed: String
            do {
                unnarrowed = Self.byDisk(try await client.allTitles())
            } catch {
                unnarrowed = Self.code(error)
            }
            print("\(since): \(slot); slot's criteria \(bySlot); no criteria \(unnarrowed)")
            if let diskAnswered, ContinuousClock.now - diskAnswered >= .seconds(30) { return }
            try await Task.sleep(for: .seconds(5))
        }
        print(diskAnswered == nil ? "no disk answered within three minutes" : "three minutes passed")
    }

    /// A list's count, and how many of its rows say they are on each disk, by the disk's id.
    private static func byDisk(_ titles: [RecordedTitle]) -> String {
        let counted = Dictionary(grouping: titles, by: \.destination)
            .map { "\($0.key.isEmpty ? "(none)" : $0.key) \($0.value.count)" }.sorted()
        return "\(titles.count)" + (counted.isEmpty ? "" : " (\(counted.joined(separator: ", ")))")
    }

    /// What stopped a request, as the action and its code: never the answer's body.
    private static func code(_ error: Error) -> String {
        guard let error = error as? RecorderError else { return "\(type(of: error))" }
        switch error {
        case .soap(let action, let status, let code, _): return "\(action) refused, HTTP \(status), code \(code ?? "-")"
        case .transport: return "no answer"
        default: return "\(error.failure)"
        }
    }
}
