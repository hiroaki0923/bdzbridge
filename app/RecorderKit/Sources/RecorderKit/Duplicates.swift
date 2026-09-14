import Foundation

/// Recordings that look like copies of one broadcast.
public struct DuplicateSet: Sendable, Identifiable {
    /// How sure we are that these really are the same broadcast.
    public enum Confidence: String, Sendable {
        case high, low

        public var label: String {
            switch self {
            case .high: "番組内容も同じ"
            case .low: "タイトルと長さが同じ（内容は未確認）"
            }
        }
    }

    public var title: String
    public var confidence: Confidence
    public var sizeMB: Int
    /// In broadcast order, so the one to keep is normally the first.
    public var items: [RecordedTitle]
    public var keep: String
    /// Everything but the one to keep, minus anything protected.
    public var suggestDelete: [String]
    /// Why each recording is kept or offered up, by id.
    public var reasons: [String: String]

    public var id: String { items.map(\.id).joined(separator: "-") }
    public var sizeGB: Double { Double(sizeMB) / 1024 }
}

public enum Duplicates {
    /// Recordings that could be copies of one broadcast: the same title, then lengths within two minutes of
    /// each other. This costs nothing, which is why it comes first; confirming a set means asking the
    /// recorder what each recording is about, one at a time.
    public static func candidates(_ titles: [RecordedTitle]) -> [[RecordedTitle]] {
        var order: [String] = []
        var groups: [String: [RecordedTitle]] = [:]
        for title in titles {
            let key = Series.sameTitleKey(title.title)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(title)
        }

        var candidates: [[RecordedTitle]] = []
        for key in order {
            guard let group = groups[key], group.count > 1 else { continue }
            var cluster: [RecordedTitle] = []
            for title in stableSorted(group, by: { $0.durationSec < $1.durationSec }) {
                if let last = cluster.last, abs(title.durationSec - last.durationSec) > 120 {
                    if cluster.count > 1 { candidates.append(cluster) }
                    cluster = [title]
                } else {
                    cluster.append(title)
                }
            }
            if cluster.count > 1 { candidates.append(cluster) }
        }
        return candidates
    }

    /// The sets themselves, once each candidate's programme text is known. Recordings whose text matches are
    /// the same broadcast for certain; with no text at all only the title and the length agree. Biggest first,
    /// since that is the reason to bother.
    public static func sets(candidates: [[RecordedTitle]], summaries: [String: String]) -> [DuplicateSet] {
        var found: [DuplicateSet] = []
        for members in candidates {
            var order: [String] = []
            var bySummary: [String: [RecordedTitle]] = [:]
            for title in members {
                let key = Series.summaryKey(summaries[title.id] ?? "")
                if bySummary[key] == nil { order.append(key) }
                bySummary[key, default: []].append(title)
            }
            for key in order {
                guard let same = bySummary[key], same.count > 1 else { continue }
                found.append(set(same, confidence: key.isEmpty ? .low : .high))
            }
        }
        return stableSorted(found) { $0.sizeMB > $1.sizeMB }
    }

    /// Which copy to keep: one that is protected, then one that is partway through, then the better recording
    /// mode, then the earlier broadcast.
    static func set(_ members: [RecordedTitle], confidence: DuplicateSet.Confidence) -> DuplicateSet {
        let members = stableSorted(members) { $0.start < $1.start }

        func rank(_ title: RecordedTitle) -> (Int, Int, Int, Date) {
            (title.protected ? 0 : 1, (title.resumeSec ?? 0) > 0 ? 0 : 1, quality(title), title.start)
        }
        let keep = members.min { rank($0) < rank($1) } ?? members[0]
        let others = members.filter { $0.id != keep.id }

        var reasons: [String: String] = [:]
        for title in members {
            if title.id == keep.id {
                if title.protected {
                    reasons[title.id] = "保護中"
                } else if (title.resumeSec ?? 0) > 0 {
                    reasons[title.id] = "視聴途中"
                } else if others.allSatisfy({ title.start < $0.start }) {
                    reasons[title.id] = "先に放送"
                } else if others.contains(where: { quality(title) < quality($0) }) {
                    reasons[title.id] = "高画質"
                } else {
                    reasons[title.id] = "同じ内容"
                }
            } else if title.protected {
                reasons[title.id] = "保護中"
            } else if title.start > keep.start {
                reasons[title.id] = "後の放送"
            } else if quality(title) > quality(keep) {
                reasons[title.id] = "低画質"
            } else {
                reasons[title.id] = "同じ内容"
            }
        }

        return DuplicateSet(title: members[0].title, confidence: confidence,
                            sizeMB: members.reduce(0) { $0 + ($1.sizeMB ?? 0) }, items: members,
                            keep: keep.id,
                            suggestDelete: members.filter { $0.id != keep.id && !$0.protected }.map(\.id),
                            reasons: reasons)
    }

    /// DR is the best mode and the recorder numbers it lowest but one; every other mode already sorts right.
    private static func quality(_ title: RecordedTitle) -> Int {
        title.qualityCode == 100 ? 0 : title.qualityCode
    }

    /// Swift's sort is not stable, and the order of equal elements is part of what the server produces.
    private static func stableSorted<T>(_ items: [T], by less: (T, T) -> Bool) -> [T] {
        items.enumerated()
            .sorted { left, right in
                less(left.element, right.element) ? true
                    : less(right.element, left.element) ? false
                    : left.offset < right.offset
            }
            .map(\.element)
    }
}
