import Foundation

/// Recordings that look like copies of one broadcast.
public struct DuplicateSet: Sendable, Identifiable {
    /// How sure we are that these really are the same broadcast.
    public enum Confidence: String, Sendable {
        /// The title, the length and the programme text agree.
        case high
        /// They agree, but the text is one the programme carries every time, so it does not tell one episode
        /// from another. See `Duplicates.fixedBlurbs`.
        case boilerplate
        /// The title and the length agree, and there is no text to compare.
        case low

        public var label: String {
            switch self {
            case .high: "番組内容も同じ"
            case .boilerplate: "説明文が毎回同じ（内容は未確認）"
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
    /// Everything but the one to keep, minus anything the recorder will not delete.
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
    /// the same broadcast for certain, unless the text is one the programme carries every time: shorter than
    /// `fixedBlurbLength`, or among `fixedBlurbs`, which the guide tells (see `fixedBlurbs(in:among:)`). With
    /// no text at all only the title and the length agree. Biggest first, since that is the reason to bother.
    public static func sets(candidates: [[RecordedTitle]], summaries: [String: String],
                            fixedBlurbs: Set<Blurb> = []) -> [DuplicateSet] {
        var found: [DuplicateSet] = []
        for members in candidates {
            // a candidate is made of one title key
            let titleKey = members.first.map { Series.sameTitleKey($0.title) } ?? ""
            var order: [String] = []
            var bySummary: [String: [RecordedTitle]] = [:]
            for title in members {
                let key = Series.summaryKey(summaries[title.id] ?? "")
                if bySummary[key] == nil { order.append(key) }
                bySummary[key, default: []].append(title)
            }
            for key in order {
                guard let same = bySummary[key], same.count > 1 else { continue }
                found.append(set(same, confidence: confidence(titleKey: titleKey, summaryKey: key,
                                                              fixedBlurbs: fixedBlurbs)))
            }
        }
        return stableSorted(found) { $0.sizeMB > $1.sizeMB }
    }

    /// A title and the programme text that goes with it, as they are compared: `Series.sameTitleKey` and
    /// `Series.summaryKey`.
    public struct Blurb: Hashable, Sendable {
        public var titleKey: String
        public var summaryKey: String

        public init(titleKey: String, summaryKey: String) {
            self.titleKey = titleKey
            self.summaryKey = summaryKey
        }
    }

    /// A programme text shorter than this, in characters of its `Series.summaryKey`, says what kind of
    /// programme it is (ニュース, 天気予報, a mini anime's one line) rather than what one broadcast was about, so
    /// two recordings sharing it may be any two episodes.
    public static let fixedBlurbLength = 20

    /// The titles whose programme text the guide repeats on two or more broadcast days.
    ///
    /// Some programmes carry one blurb every time -- a daily three-minute show, a mini anime -- and two
    /// recordings of them agree on the title, the length and the text without being the same broadcast. The
    /// guide is where that shows: the same title with the same text on different days. Two showings on one
    /// day do not count, since a programme shown again the same day is most likely the same episode. A re-run
    /// of one episode later in the week looks the same as a fixed blurb and is taken for one, which errs the
    /// safe way: it is left unticked. `titleKeys` narrows it to the titles asked about, so that the rest of the
    /// guide's text is not normalised.
    public static func fixedBlurbs(in guide: [(title: String, summary: String, start: Date)],
                                   among titleKeys: Set<String>? = nil) -> Set<Blurb> {
        var keys: [String: String] = [:]
        var days: [Blurb: Set<Date>] = [:]
        for programme in guide {
            let titleKey = keys[programme.title] ?? Series.sameTitleKey(programme.title)
            keys[programme.title] = titleKey
            if let titleKeys, !titleKeys.contains(titleKey) { continue }
            let summaryKey = Series.summaryKey(programme.summary)
            guard !summaryKey.isEmpty else { continue }
            days[Blurb(titleKey: titleKey, summaryKey: summaryKey), default: []]
                .insert(GuideStore.broadcastDay(containing: programme.start))
        }
        return Set(days.filter { $0.value.count > 1 }.keys)
    }

    static func confidence(titleKey: String, summaryKey: String,
                           fixedBlurbs: Set<Blurb>) -> DuplicateSet.Confidence {
        if summaryKey.isEmpty { return .low }
        if summaryKey.unicodeScalars.count < fixedBlurbLength
            || fixedBlurbs.contains(Blurb(titleKey: titleKey, summaryKey: summaryKey)) {
            return .boilerplate
        }
        return .high
    }

    /// What comes up ticked for deletion. A tick is what deletes, so the copies left unticked are the ones
    /// kept, whichever the screen suggested.
    ///
    /// Only a set confirmed by its text is ticked for the reader. One that agrees on the title and the length
    /// alone may be two programmes the recorder has no text for, and one whose text the programme carries every
    /// time may be two episodes; whether to delete one of those is for the reader to decide. A set still made
    /// of the same recordings as one already on screen, and as sure, keeps the ticks the reader left it with:
    /// deleting or protecting something elsewhere must not tick again what the reader had unticked. One the
    /// guide has since shown to carry a fixed text is not that set any more, and loses the ticks it came up
    /// with. Nothing the recorder would refuse to delete is ticked.
    public static func picks(for sets: [DuplicateSet], shown: [DuplicateSet], picked: Set<String>) -> Set<String> {
        let onScreen = Dictionary(shown.map { ($0.id, $0.confidence) }) { first, _ in first }
        var picks: Set<String> = []
        for set in sets {
            if onScreen[set.id] == set.confidence {
                picks.formUnion(set.items.filter { deletable($0) && picked.contains($0.id) }.map(\.id))
            } else if set.confidence == .high {
                picks.formUnion(set.suggestDelete)
            }
        }
        return picks
    }

    /// The sets that would lose every copy if what is ticked were deleted. The screen is for thinning out
    /// copies of a broadcast, never for getting rid of it, so these are named before anything is deleted.
    public static func emptied(_ sets: [DuplicateSet], picked: Set<String>) -> [DuplicateSet] {
        sets.filter { set in set.items.allSatisfy { deletable($0) && picked.contains($0.id) } }
    }

    /// Whether the recorder would delete it at all: it refuses a protected recording, and one it is still
    /// writing to.
    public static func deletable(_ title: RecordedTitle) -> Bool {
        !title.protected && !title.recording
    }

    /// Which copy to keep: one the recorder will not part with (protected, or still being recorded), then
    /// one that is partway through, then the better recording mode, then the earlier broadcast.
    static func set(_ members: [RecordedTitle], confidence: DuplicateSet.Confidence) -> DuplicateSet {
        let members = stableSorted(members) { $0.start < $1.start }

        func rank(_ title: RecordedTitle) -> (Int, Int, Int, Date) {
            (title.protected || title.recording ? 0 : 1, (title.resumeSec ?? 0) > 0 ? 0 : 1,
             quality(title), title.start)
        }
        let keep = members.min { rank($0) < rank($1) } ?? members[0]
        let others = members.filter { $0.id != keep.id }

        var reasons: [String: String] = [:]
        for title in members {
            if title.id == keep.id {
                if title.protected {
                    reasons[title.id] = "保護中"
                } else if title.recording {
                    reasons[title.id] = "録画中"
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
            } else if title.recording {
                reasons[title.id] = "録画中"
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
                            suggestDelete: members.filter {
                                $0.id != keep.id && !$0.protected && !$0.recording
                            }.map(\.id),
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
