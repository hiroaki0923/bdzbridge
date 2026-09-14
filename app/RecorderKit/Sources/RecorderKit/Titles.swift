import Foundation

/// How far into a recording the reader has got, as the recorder reports it.
public enum WatchState: String, Sendable, CaseIterable {
    case unwatched, partway, watched

    public var label: String {
        switch self {
        case .unwatched: "未視聴"
        case .partway: "途中"
        case .watched: "視聴済み"
        }
    }
}

public extension RecordedTitle {
    /// New until the recording has been played; partway while the recorder holds a resume point for it.
    var watchState: WatchState {
        if isNew { return .unwatched }
        return (resumeSec ?? 0) > 0 ? .partway : .watched
    }

    /// The programme this recording belongs to, and the key episodes of it share.
    var seriesName: String { Series.name(title) }
    var seriesKey: String { Series.key(title) }

    var genre: Genre? { genreCode.map(Genre.init(code:)) }

    /// Where playback would carry on from, as a fraction of the recording.
    var resumeFraction: Double {
        guard durationSec > 0, let resumeSec, resumeSec > 0 else { return 0 }
        return min(1, Double(resumeSec) / Double(durationSec))
    }
}

/// Recordings of one programme, as the recordings screen lists them.
public struct TitleGroup: Sendable, Equatable, Identifiable {
    public var key: String
    public var name: String
    public var count: Int
    public var sizeMB: Int
    public var latest: Date
    public var earliest: Date
    public var protectedCount: Int
    public var newCount: Int

    public var id: String { key }
    public var sizeGB: Double { Double(sizeMB) / 1024 }

    /// Recordings grouped into programmes by their titles, newest group first.
    ///
    /// One programme can be spelled more than one way, in full width and half width, and those share a key
    /// but not a name. The commonest spelling is the one shown, and the first one seen wins a tie, which is
    /// why the names are counted in the order they arrive. `genre` is an ARIB level-1 code; a recording the
    /// recorder gave no genre for is left out when one is asked for.
    public static func group(_ titles: [RecordedTitle], genre: Int? = nil) -> [TitleGroup] {
        var order: [String] = []
        var building: [String: Building] = [:]

        for title in titles {
            if let genre, title.genre?.level1 != genre { continue }
            let key = title.seriesKey
            if building[key] == nil {
                order.append(key)
                building[key] = Building(title)
            } else {
                building[key]?.add(title)
            }
        }

        var found: [(index: Int, group: TitleGroup)] = []
        for (index, key) in order.enumerated() {
            guard let building = building[key] else { continue }
            found.append((index, building.group(key: key)))
        }
        // newest first, and ties keep the order they were found in, the way the server's sort does
        found.sort { left, right in
            left.group.latest == right.group.latest
                ? left.index < right.index
                : left.group.latest > right.group.latest
        }
        return found.map(\.group)
    }

    private struct Building {
        /// (spelling, how many times) in the order the spellings turned up.
        private var names: [(name: String, count: Int)] = []
        private var count = 0
        private var sizeMB = 0
        private var protectedCount = 0
        private var newCount = 0
        private var latest: Date
        private var earliest: Date

        init(_ title: RecordedTitle) {
            latest = title.start
            earliest = title.start
            add(title)
        }

        mutating func add(_ title: RecordedTitle) {
            let name = title.seriesName
            if let index = names.firstIndex(where: { $0.name == name }) {
                names[index].count += 1
            } else {
                names.append((name, 1))
            }
            count += 1
            sizeMB += title.sizeMB ?? 0
            latest = max(latest, title.start)
            earliest = min(earliest, title.start)
            if title.protected { protectedCount += 1 }
            if title.isNew { newCount += 1 }
        }

        func group(key: String) -> TitleGroup {
            TitleGroup(key: key, name: names.max { $0.count < $1.count }?.name ?? "", count: count,
                       sizeMB: sizeMB, latest: latest, earliest: earliest, protectedCount: protectedCount,
                       newCount: newCount)
        }
    }
}
