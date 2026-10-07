import Foundation
import XCTest
@testable import RecorderKit

/// What a real recorder says of each disk it records to, read through the app's own client and transport. Read
/// only, and skipped unless RECORDER_HOST names a recorder on the LAN:
///
///     RECORDER_HOST=192.0.2.63 swift test --filter LiveRecordingDestinationTests
///
/// It prints counts, codes and the shape of the recorder's answers, never a title, a disk's name, a channel or a
/// time of day: a text is printed as its length and a digest, which tells a later run's from this one's without
/// saying what either is. So what it prints can be kept in the notes. Run it with the recorder in network standby
/// as well as on, just after a wake, and with the USB disk unplugged: what the slot answers in the last two has
/// not been seen. With RECORDER_MAC set as well it wakes the recorder first (`LiveWaking`).
final class LiveRecordingDestinationTests: XCTestCase {
    override func setUp() async throws {
        try await LiveWaking.wakeTheRecorderIfAsked()
    }

    /// The transport the app sends with, keeping the last answer's body so that the raw answer can be shown
    /// beside what the client read from it.
    private actor Keeping: HTTPTransport {
        private let transport = URLSessionTransport()
        private(set) var last: Data?

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let response = try await transport.send(request)
            last = response.body
            return response
        }

        /// The SOAP answer's `Result`, and its `TotalMatches` where it has one.
        var result: (text: String, total: String?) {
            guard let last, let root = try? XmlNode.parse(last) else { return ("", nil) }
            return (root.firstDescendantText("Result") ?? "", root.firstDescendantText("TotalMatches"))
        }
    }

    func testReadsEachRecordingDestination() async throws {
        guard let host = ProcessInfo.processInfo.environment["RECORDER_HOST"], !host.isEmpty else {
            throw XCTSkip("set RECORDER_HOST to a recorder on the LAN")
        }
        let transport = Keeping()
        let client = RecorderClient(host: host, transport: transport)
        let began = ContinuousClock.now
        func at() -> String { Self.seconds(since: began) }

        // First, before anything wakes it further.
        let power: String
        do {
            power = try await client.playStatus()["powerstatus"] ?? "-"
        } catch {
            power = Self.code(error)
        }
        print("powerstatus: \(power) (\(at()))")
        let info = try await client.describe()
        print("recorder: \(info.product) (\(at()))")
        defer { print("done at \(at())") }

        var internalDisk: (disk: RecorderDisk?, recordable: String?) = (nil, nil)
        for id in [RecorderDisk.internalID, RecorderDisk.usbID, "BD"] {
            let asked = ContinuousClock.now
            do {
                let disk = try await client.disk(id)
                let raw = await transport.result.text
                print("disk \(id) in \(Self.seconds(since: asked)): \(Self.describe(disk))")
                print("  raw: \(Self.shape(raw))")
                if id == RecorderDisk.internalID {
                    internalDisk = (disk, (try? XmlNode.parse(raw))?.firstDescendantText("recordableRemain"))
                }
            } catch {
                print("disk \(id) in \(Self.seconds(since: asked)): \(Self.code(error))")
            }
        }
        let known = try await RecorderDriver.usbDisk(of: client)
        print("a USB disk known to the app: \(known != nil), takes recordings: \(known?.takesRecordings ?? false)")

        // The internal disk's bytes undivided, beside its own figures in the recorder's MB.
        do {
            let capacity = try await client.recordDestinationInfo()
            print("X_HDLnkGetRecordDestinationInfo: totalCapacity \(capacity.totalBytes),"
                  + " availableCapacity \(capacity.freeBytes)")
        } catch {
            print("X_HDLnkGetRecordDestinationInfo: \(Self.code(error))")
        }
        let remain = internalDisk.disk?.freeMB.map(String.init) ?? "-"
        let total = internalDisk.disk?.totalMB.map(String.init) ?? "-"
        print("internal disk: remain \(remain), recordableRemain \(internalDisk.recordable ?? "-"), total \(total)")

        var lists: [String: [RecordedTitle]] = [:]
        for id in [RecorderDisk.internalID, RecorderDisk.usbID] {
            var start = 0
            while start < 5000 {
                let page = try await client.titles(count: 200, startingAt: start, on: id)
                let (raw, total) = await transport.result
                let rows = (try? XsrsParse.items(inResult: raw).count) ?? 0
                print("titles on \(id) from \(start): \(rows) rows (\(page.count) read) of \(total ?? "-"),"
                      + " disks \(Self.histogram(page.map(\.destination))),"
                      + " id prefixes \(Self.histogram(page.map { String($0.id.prefix(6)) }))")
                start += rows
                if rows == 0 || start >= Int(total ?? "") ?? 0 { break }
            }
            let all = try await client.allTitles(on: id)
            lists[id] = all
            print("allTitles on \(id): \(all.count)")
        }

        let reservations = try await client.reservations()
        print("reservations: \(reservations.count), by disk \(Self.histogram(reservations.map(\.destination)))")

        // Its channel and start as one digest: enough to tell the same recording in a later run, and to see an id
        // that changed under it, without naming a channel, as a terrestrial one says the area the recorder is in.
        for title in lists.values.joined() where title.recording {
            let which = Self.digest("\(title.broadcastingType) \(title.serviceID) \(RecorderTime.format(title.start))")
            print("being recorded: id \(title.id) on \(title.destination), channel and start \(which),"
                  + " started \(Int(-title.start.timeIntervalSinceNow / 60)) min ago, \(title.durationSec) s")
        }
        let usb = lists[RecorderDisk.usbID] ?? []
        print("USB disk's recording ids: \(usb.prefix(50).map(\.id))")
        if let finished = usb.first(where: { !$0.recording }) {
            do {
                let detail = try await client.titleDetail(id: finished.id)
                print("detail of \(finished.id): summary of \(detail.summary.count) characters")
            } catch {
                print("detail of \(finished.id): \(Self.code(error))")
            }
        }
        if let highest = usb.compactMap({ Int($0.id.dropFirst(2), radix: 16) }).max() {
            let madeUp = String(format: "0x%016llx", highest + 0x1000)
            do {
                let detail = try await client.titleDetail(id: madeUp)
                print("detail of the made-up \(madeUp): answered, summary of \(detail.summary.count) characters")
            } catch {
                print("detail of the made-up \(madeUp): \(Self.code(error))")
            }
        }
    }

    // MARK: - printing without the text

    private static func seconds(since start: ContinuousClock.Instant) -> String {
        String(format: "%.2f s", (ContinuousClock.now - start) / .seconds(1))
    }

    private static func describe(_ disk: RecorderDisk?) -> String {
        guard let disk else { return "no disk" }
        return "name \(digest(disk.name)), mounted \(disk.mounted), remain \(disk.freeMB.map(String.init) ?? "-"),"
            + " total \(disk.totalMB.map(String.init) ?? "-"), registered \(digest(disk.registered)),"
            + " takes recordings \(disk.takesRecordings)"
    }

    /// The answer's elements and attributes in order, with every value that is not a number put as its length
    /// and digest.
    private static func shape(_ raw: String) -> String {
        guard !raw.isEmpty else { return "(empty)" }
        guard let root = try? XmlNode.parse(raw) else { return "(not XML: \(digest(raw)))" }
        func walk(_ node: XmlNode) -> String {
            let attributes = node.attributes.sorted { $0.key < $1.key }.map { " \($0.key)=\(value($0.value))" }
            let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return "<\(node.name)\(attributes.joined())>" + (text.isEmpty ? "" : value(text))
                + node.children.map(walk).joined() + "</\(node.name)>"
        }
        return walk(root)
    }

    private static func value(_ text: String) -> String {
        !text.isEmpty && text.allSatisfy(\.isASCII) && Int(text) != nil ? text : digest(text)
    }

    /// The length of a text and an FNV-1a digest of it: the same text gives the same, run after run.
    private static func digest(_ text: String) -> String {
        guard !text.isEmpty else { return "«empty»" }
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return "«\(text.count) chars #\(String(format: "%08x", hash))»"
    }

    private static func code(_ error: Error) -> String {
        guard let error = error as? RecorderError else { return "\(type(of: error))" }
        switch error {
        case .soap(let action, let status, let code, _): return "\(action) refused, HTTP \(status), code \(code ?? "-")"
        case .transport: return "no answer"
        default: return "\(error.failure)"
        }
    }

    private static func histogram(_ values: [String]) -> String {
        Dictionary(grouping: values, by: { $0 }).map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: ", ")
    }
}
