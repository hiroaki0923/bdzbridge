import XCTest
@testable import RecorderKit

/// Reads the guide from a real recorder and from the helper on a real television, through the clients the app
/// reads with, and says where the two differ: the channels each has, how far ahead each reaches, which
/// programmes only one has, and for the programmes both have, which fields disagree. Skipped unless both
/// devices are named:
///
///     RECORDER_HOST=192.0.2.63 TV_HOST=192.0.2.20 TV_HELPER_TOKEN=… \
///         swift test --filter LiveGuideComparisonTests
///
/// With RECORDER_MAC as well the recorder is woken first (`LiveWaking`). Counts are printed for every type,
/// and for each kind of difference a few examples, so that the kind can be told from the count; the whole of
/// neither guide is printed.
final class LiveGuideComparisonTests: XCTestCase {
    private struct Side {
        var name: String
        var services: [GuideService]

        var byID: [Int: GuideService] { Dictionary(uniqueKeysWithValues: services.map { ($0.serviceID, $0) }) }
        var programs: [GuideProgram] { services.flatMap(\.programs) }
        var proper: [GuideProgram] { programs.filter { !$0.isReference } }
        var earliest: Date? { programs.map(\.start).min() }
        var latest: Date? { programs.map(\.end).max() }
    }

    private struct Key: Hashable {
        var serviceID: Int
        var eventID: Int
    }

    func testTheTelevisionAgainstTheRecorder() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let recorderHost = environment["RECORDER_HOST"], !recorderHost.isEmpty else {
            throw XCTSkip("RECORDER_HOST is not set")
        }
        guard let tvHost = environment["TV_HOST"], !tvHost.isEmpty else { throw XCTSkip("TV_HOST is not set") }
        guard let token = environment["TV_HELPER_TOKEN"], !token.isEmpty else {
            throw XCTSkip("TV_HELPER_TOKEN is not set")
        }
        try await LiveWaking.wakeTheRecorderIfAsked()

        let recorder = RecorderClient(host: recorderHost)
        _ = try await recorder.describe()
        let helper = TVHelperClient(host: tvHost, transport: URLSessionTransport.withoutCookies(),
                                    tokens: MemoryTVHelperToken(token))
        let helperTypes = try await helper.broadcastingTypes()

        for broadcasting in GuideRefresh.broadcastingTypes {
            print("\n== \(broadcasting) ==")
            let fromRecorder = try await recorder.guide(broadcasting)
            let fromTV = helperTypes.contains(broadcasting) ? try await helper.guide(broadcasting) : nil
            guard let fromRecorder, let fromTV else {
                print("recorder: \(fromRecorder == nil ? "no channels" : "has channels"), "
                      + "television: \(fromTV == nil ? "no channels" : "has channels")")
                continue
            }
            compare(Side(name: "recorder", services: fromRecorder), Side(name: "television", services: fromTV))
        }
    }

    private func compare(_ a: Side, _ b: Side) {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        func stamp(_ date: Date?) -> String { date.map(formatter.string) ?? "-" }

        // Channels.
        let idsA = Set(a.byID.keys), idsB = Set(b.byID.keys)
        print("channels: \(a.name) \(idsA.count), \(b.name) \(idsB.count), both \(idsA.intersection(idsB).count)")
        for id in idsA.subtracting(idsB).sorted() { print("  only \(a.name): \(id) \(a.byID[id]!.name)") }
        for id in idsB.subtracting(idsA).sorted() { print("  only \(b.name): \(id) \(b.byID[id]!.name)") }
        let renamed = idsA.intersection(idsB).filter { a.byID[$0]!.name != b.byID[$0]!.name }.sorted()
        print("channel names differing: \(renamed.count)")
        for id in renamed.prefix(5) { print("  \(id): \(a.name) '\(a.byID[id]!.name)', \(b.name) '\(b.byID[id]!.name)'") }

        // Reach.
        print("\(a.name): \(a.programs.count) programmes (\(a.programs.count - a.proper.count) references), "
              + "\(stamp(a.earliest)) to \(stamp(a.latest))")
        print("\(b.name): \(b.programs.count) programmes (\(b.programs.count - b.proper.count) references), "
              + "\(stamp(b.earliest)) to \(stamp(b.latest))")
        guard let windowStart = [a.earliest, b.earliest].compactMap({ $0 }).max(),
              let windowEnd = [a.latest, b.latest].compactMap({ $0 }).min() else { return }
        print("common window: \(stamp(windowStart)) to \(stamp(windowEnd))")

        // Programmes by (service, event), on the channels both have, inside the window both cover.
        let shared = idsA.intersection(idsB)
        func inside(_ program: GuideProgram) -> Bool {
            shared.contains(program.serviceID) && program.start >= windowStart && program.end <= windowEnd
        }
        let keyedA = Dictionary(a.proper.filter(inside).map { (Key(serviceID: $0.serviceID, eventID: $0.eventID), $0) },
                                uniquingKeysWith: { first, _ in first })
        let keyedB = Dictionary(b.proper.filter(inside).map { (Key(serviceID: $0.serviceID, eventID: $0.eventID), $0) },
                                uniquingKeysWith: { first, _ in first })
        let both = Set(keyedA.keys).intersection(keyedB.keys)
        let onlyA = Set(keyedA.keys).subtracting(keyedB.keys), onlyB = Set(keyedB.keys).subtracting(keyedA.keys)
        print("in the window: \(a.name) \(keyedA.count), \(b.name) \(keyedB.count), both \(both.count), "
              + "only \(a.name) \(onlyA.count), only \(b.name) \(onlyB.count)")
        // A programme one side alone has by event id may be there on the other at the same time under another
        // id: say how many, and show a few of the rest.
        let startsB = Set(keyedB.values.map { "\($0.serviceID)@\(Int($0.start.timeIntervalSince1970))" })
        let startsA = Set(keyedA.values.map { "\($0.serviceID)@\(Int($0.start.timeIntervalSince1970))" })
        func describe(_ p: GuideProgram) -> String {
            "\(p.serviceID) \(stamp(p.start)) \(p.durationSec / 60) min eid \(p.eventID) '\(p.title.prefix(30))'"
        }
        for (name, only, keyed, starts) in [(a.name, onlyA, keyedA, startsB), (b.name, onlyB, keyedB, startsA)] {
            let programs = only.compactMap { keyed[$0] }.sorted { $0.start < $1.start }
            let sameSlot = programs.filter { starts.contains("\($0.serviceID)@\(Int($0.start.timeIntervalSince1970))") }
            print("only \(name): \(programs.count), of which \(sameSlot.count) have a programme on the other side "
                  + "starting at the same time (another event id)")
            for p in sameSlot.prefix(3) { print("  same slot: \(describe(p))") }
            for p in programs.filter({ !sameSlot.contains($0) }).prefix(5) { print("  \(describe(p))") }
        }

        // Fields of the programmes both have.
        var differing: [String: [(GuideProgram, GuideProgram)]] = [:]
        for key in both {
            let x = keyedA[key]!, y = keyedB[key]!
            if x.start != y.start { differing["start", default: []].append((x, y)) }
            if x.end != y.end { differing["end", default: []].append((x, y)) }
            if x.title != y.title { differing["title", default: []].append((x, y)) }
            if x.summary != y.summary { differing["summary", default: []].append((x, y)) }
            if x.extended != y.extended { differing["extended", default: []].append((x, y)) }
            if x.genres != y.genres { differing["genres", default: []].append((x, y)) }
            if x.parentalRating != y.parentalRating { differing["parentalRating", default: []].append((x, y)) }
        }
        // The television writes ARIB's alphanumerics at half width where the recorder writes them at full
        // width: a text that differs only so is the same text to NFKC, and is counted apart.
        func text(_ p: GuideProgram, _ field: String) -> String {
            switch field {
            case "title": return p.title
            case "summary": return p.summary
            default: return p.extended
            }
        }
        func sameToNFKC(_ x: GuideProgram, _ y: GuideProgram, _ field: String) -> Bool {
            text(x, field).precomposedStringWithCompatibilityMapping
                == text(y, field).precomposedStringWithCompatibilityMapping
        }
        print("fields differing among the \(both.count) programmes both have:")
        for field in ["start", "end", "title", "summary", "extended", "genres", "parentalRating"] {
            var pairs = (differing[field] ?? []).sorted { $0.0.start < $1.0.start }
            if ["title", "summary", "extended"].contains(field) {
                let beyondWidth = pairs.filter { !sameToNFKC($0.0, $0.1, field) }
                print("  \(field): \(pairs.count), of which \(beyondWidth.count) differ beyond character width")
                pairs = beyondWidth
            } else {
                print("  \(field): \(pairs.count)")
            }
            for (x, y) in pairs.prefix(4) {
                switch field {
                case "start", "end":
                    print("    \(x.serviceID) eid \(x.eventID): \(a.name) \(stamp(x.start))-\(stamp(x.end)), "
                          + "\(b.name) \(stamp(y.start))-\(stamp(y.end))")
                case "title":
                    print("    \(x.serviceID) eid \(x.eventID): \(a.name) '\(x.title)' / \(b.name) '\(y.title)'")
                case "summary", "extended":
                    let s = text(x, field).precomposedStringWithCompatibilityMapping
                    let t = text(y, field).precomposedStringWithCompatibilityMapping
                    let at = firstDifference(s, t) ?? 0
                    print("    \(x.serviceID) eid \(x.eventID): \(a.name) \(s.count) chars, \(b.name) \(t.count) chars, "
                          + "first difference at \(at):")
                    print("      \(a.name): '\(around(s, at))'")
                    print("      \(b.name): '\(around(t, at))'")
                case "genres":
                    print("    \(x.serviceID) eid \(x.eventID): \(a.name) \(x.genres.map(\.code)) / \(b.name) \(y.genres.map(\.code))")
                default:
                    print("    \(x.serviceID) eid \(x.eventID): \(a.name) \(x.parentalRating) / \(b.name) \(y.parentalRating)")
                }
            }
        }
        let emptyExtendedA = both.filter { keyedA[$0]!.extended.isEmpty }.count
        let emptyExtendedB = both.filter { keyedB[$0]!.extended.isEmpty }.count
        print("without an extended description: \(a.name) \(emptyExtendedA), \(b.name) \(emptyExtendedB)")
    }

    /// Up to twenty characters before and after a position, newlines shown as `⏎`.
    private func around(_ s: String, _ at: Int) -> String {
        let characters = Array(s)
        let from = max(0, at - 20), to = min(characters.count, at + 20)
        return String(characters[from..<to]).replacingOccurrences(of: "\n", with: "⏎")
    }

    private func firstDifference(_ x: String, _ y: String) -> Int? {
        for (i, (cx, cy)) in zip(x, y).enumerated() where cx != cy { return i }
        return x.count == y.count ? nil : min(x.count, y.count)
    }
}
