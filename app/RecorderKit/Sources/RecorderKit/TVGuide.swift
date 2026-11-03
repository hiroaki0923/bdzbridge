import Foundation

/// The guide a BRAVIA keeps, read through the helper that runs on the television (`helper/`): the helper hands
/// the rows over as they are in Android's guide store, and this turns them into the same `GuideService` the
/// recorder's files decode to (`Epg.decode`), so that the cache, the screens and the search tell no difference.
///
/// What the helper serves, and the shape of each row, is set out in `helper/README.md`. Nothing here asks a
/// network: the client (`TVHelperClient`) fetches, this decodes.
public enum TVGuideDecoder {
    /// The broadcasting types a television has, in the order the app keeps them.
    public static let broadcastingTypes = ["td", "bs", "cs", "bs4k", "cs4k"]

    /// One channel of the television's tuner, as `/v1/channels` lists it.
    public struct Channel: Sendable, Equatable {
        public var broadcasting: String
        public var serviceID: Int
        public var originalNetworkID: Int
        public var transportStreamID: Int
        /// The number the television shows, as the television has it: "011", "101". Nil where it has none.
        public var number: String?
        /// The name as the television has it, which for some CS channels is a dash or nothing at all.
        public var name: String
        public var browsable: Bool
        public var hasPrograms: Bool

        public init(broadcasting: String, serviceID: Int, originalNetworkID: Int = 0, transportStreamID: Int = 0,
                    number: String? = nil, name: String, browsable: Bool = true, hasPrograms: Bool = true) {
            self.broadcasting = broadcasting
            self.serviceID = serviceID
            self.originalNetworkID = originalNetworkID
            self.transportStreamID = transportStreamID
            self.number = number
            self.name = name
            self.browsable = browsable
            self.hasPrograms = hasPrograms
        }

        /// The number as the logos are keyed by (`StationLogo.channelNo`): 11 for "011", 0 where there is none.
        public var channelNo: Int { number.flatMap { Int($0) } ?? 0 }
    }

    /// The channels, by `/v1/channels`. Each type's in the ascending order of service id, as the recorder's
    /// files have them, so that the two guides put the stations in the same order.
    public static func decodeChannels(_ json: Data) throws -> [Channel] {
        let top = try object(json)
        guard let rows = top["channels"] as? [[String: Any]] else { throw TVGuideError.badShape("channels") }
        return rows.compactMap { row -> Channel? in
            guard let broadcasting = row["bt"] as? String, let serviceID = int(row["sid"]) else { return nil }
            return Channel(broadcasting: broadcasting, serviceID: serviceID,
                           originalNetworkID: int(row["onid"]) ?? 0, transportStreamID: int(row["tsid"]) ?? 0,
                           number: row["number"] as? String, name: row["name"] as? String ?? "",
                           browsable: row["browsable"] as? Bool ?? true, hasPrograms: row["hasPrograms"] as? Bool ?? false)
        }.sorted { ($0.broadcasting, $0.serviceID) < ($1.broadcasting, $1.serviceID) }
    }

    /// One type's guide, by `/v1/guide/{bt}`, with the channels of that type: the rows have only a service id
    /// each, and a service's name comes from the channel list. A channel with no programme is left out: the
    /// television lists every service it tunes -- data broadcasts, the standby services of a station, the
    /// guide's own channel -- and none of them has a programme, where the recorder's file lists the stations it
    /// records from, each with its programmes. Services come out in the ascending order of service id.
    ///
    /// A sub-channel's row is a full copy of its parent's on the television, marked by `flag2` and a sibling
    /// list of one, the parent; the recorder's file has a reference there instead, with no text of its own, which
    /// the cache resolves to the parent's. Such a row is made into that reference, so that the guide lists a
    /// programme once and the search finds it once.
    public static func decodeGuide(_ json: Data, channels: [Channel]) throws -> [GuideService] {
        let top = try object(json)
        guard let broadcasting = top["bt"] as? String, let rows = top["programs"] as? [[String: Any]] else {
            throw TVGuideError.badShape("guide")
        }
        var programs: [Int: [GuideProgram]] = [:]
        for row in rows {
            guard let program = decodeProgram(row) else { continue }
            programs[program.serviceID, default: []].append(program)
        }
        let named = channels.filter { $0.broadcasting == broadcasting }
        let names = Dictionary(named.map { ($0.serviceID, $0.name) }, uniquingKeysWith: { first, _ in first })
        return programs.keys.sorted().map { serviceID in
            GuideService(serviceID: serviceID, name: names[serviceID] ?? "",
                         programs: programs[serviceID]!.sorted { $0.start < $1.start })
        }
    }

    /// One row of a type's guide. Nil for a row with no service id, event id or times, which says nothing the
    /// cache could hold.
    static func decodeProgram(_ row: [String: Any]) -> GuideProgram? {
        guard let serviceID = int(row["sid"]), let eventID = int(row["eid"]),
              let startMs = int(row["startMs"]), let endMs = int(row["endMs"]) else { return nil }
        var program = GuideProgram(serviceID: serviceID, eventID: eventID,
                                   start: Date(timeIntervalSince1970: TimeInterval(startMs) / 1000),
                                   end: Date(timeIntervalSince1970: TimeInterval(endMs) / 1000),
                                   title: "")
        let siblings = (row["siblings"] as? [Any])?.compactMap(int) ?? []
        if int(row["flag2"]) == 1, siblings.count == 1, let parent = siblings.first, parent != serviceID {
            program.referenceServiceID = parent
            program.referenceEventID = eventID
            return program
        }
        program.title = Arib.clean(row["title"] as? String ?? "")
        program.summary = Arib.clean(row["short"] as? String ?? "")
        program.extended = Arib.clean(row["longTail"] as? String ?? row["long"] as? String ?? "")
        program.genres = TVGenres.decode(row["genre"] as? String ?? "")
        program.parentalRating = rating(row["rating"] as? String)
        return program
    }

    /// The age in the television's rating string, `com.android.tv/ISDB/ISDB_15` and the like: 15; 0 for
    /// `ISDB_NONE`, for nothing, and for anything else.
    static func rating(_ value: String?) -> Int {
        guard let value, let range = value.range(of: "ISDB_", options: .backwards) else { return 0 }
        return Int(value[range.upperBound...]) ?? 0
    }

    /// One type's station logos, by `/v1/logos/{bt}`, keyed by the channel numbers in `channels`. A logo of a
    /// service that is not among the channels is kept with channel number 0.
    public static func decodeLogos(_ json: Data, channels: [Channel]) throws -> [StationLogo] {
        let top = try object(json)
        guard let broadcasting = top["bt"] as? String, let rows = top["logos"] as? [[String: Any]] else {
            throw TVGuideError.badShape("logos")
        }
        let numbers = Dictionary(channels.filter { $0.broadcasting == broadcasting }.map { ($0.serviceID, $0.channelNo) },
                                 uniquingKeysWith: { first, _ in first })
        return rows.compactMap { row -> StationLogo? in
            guard let serviceID = int(row["sid"]), let png = (row["png"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  png.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return nil }
            return StationLogo(channelNo: numbers[serviceID] ?? 0, serviceID: serviceID, png: png)
        }.sorted { $0.serviceID < $1.serviceID }
    }

    private static func object(_ json: Data) throws -> [String: Any] {
        guard let top = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw TVGuideError.badShape("json")
        }
        return top
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: n
        case let n as Double: Int(n)
        case let n as NSNumber: n.intValue
        case let s as String: Int(s)
        default: nil
        }
    }
}

public enum TVGuideError: Error, Equatable, Sendable {
    /// The helper's answer was not of the shape its API promises; which part says where.
    case badShape(String)
}

/// The genres as Android's guide store spells them -- ARIB STD-B10's labels in English, `level1:level2`, joined
/// by commas with a quote escaping the next character -- back to the ARIB nibbles the recorder's guide has.
/// The 129 labels seen on a BRAVIA were matched to the recorder's codes one for one; a label not in the table
/// gives its level alone, with the sub-genre "other", and a level not in the table gives nothing.
public enum TVGenres {
    public static func decode(_ encoded: String) -> [Genre] {
        labels(encoded).compactMap(genre)
    }

    /// The labels in an encoded value, as `TvContract.Programs.Genres.decode` reads them.
    static func labels(_ encoded: String) -> [String] {
        var out: [String] = []
        var current = ""
        var escaped = false
        for character in encoded {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\"" {
                escaped = true
            } else if character == "," {
                out.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty || !out.isEmpty { out.append(current) }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func genre(_ label: String) -> Genre? {
        if label == "other" { return Genre(level1: 0xF, level2: 0xF) }
        // The CS extension: `cs-sports:…`, `cs-movie,overseas movies:…`. The recorder's decoder keeps the
        // extension's nibbles alone and not the sub-genre after them, and so does this.
        if label.hasPrefix("cs-") { return Genre(level1: 0xE, level2: 0x1) }
        guard let colon = label.firstIndex(of: ":") else { return nil }
        let level1Label = String(label[..<colon])
        let level2Label = String(label[label.index(after: colon)...])
        guard let level1 = level1Labels.firstIndex(of: level1Label) else { return nil }
        let level2 = level2Labels[level1].firstIndex(of: level2Label) ?? 0xF
        return Genre(level1: level1, level2: level2 == 0xF ? 0xF : level2)
    }

    static let level1Labels = [
        "news", "sports", "information/tabloid show", "drama", "music", "variety", "movie", "animation/special effect",
        "documentary/education", "theater/performance", "hobby/education", "weal",
    ]

    /// Each level's sub-genres by nibble, "" where ARIB assigns none; "other" is 0xF for every level.
    static let level2Labels: [[String]] = [
        ["regular/general", "weather report", "special program/documentary", "politics/national assembly",
         "economics/market report", "overseas/international report", "news analysis", "discussion/conference",
         "special report", "local program", "traffic report"],
        ["sports news", "baseball", "soccer", "golf", "other ball games", "sumo/combative sports",
         "olympic/international games", "marathon/athletic sports/swimming", "motor sports",
         "marine sports/winter sports", "horse race/public race"],
        ["gossip/tabloid show", "fashion", "living/home", "health/medical treatment", "shopping/mail-order business",
         "gourmet/cooking", "events", "event introduction/information"],
        ["japanese dramas", "overseas dramas", "period dramas"],
        ["japanese rock/pop music", "overseas rock/pop music", "classic/opera", "jazz/fusion",
         "popular songs/japanese popular songs (enka songs)", "live concert", "ranking/request music",
         "karaoke/amateur singing contests", "japanese ballad/japanese traditional music", "children's song",
         "folk music/world music"],
        ["quiz", "game", "talk variety", "comedy program", "music variety", "tour variety", "cooking variety"],
        ["overseas movies", "japanese movies", "animation"],
        ["japanese animation", "overseas animation", "special effects"],
        ["society/current affairs", "history/travels", "natures/animals/environments", "space/science/medical science",
         "culture/traditional culture", "literature", "sports documentaries", "general documentaries",
         "interviews/discussions"],
        ["modern drama/western-style drama", "musical", "dance/ballet", "comic story/entertainment",
         "kabuki/classical drama"],
        ["trip/fishing/outdoor entertainment", "gardening/pet/handicrafts", "music/art/industrial art",
         "japanese chess (shogi) and \"go\"", "mah-jong/pinball games", "automobile", "computer/tv games",
         "conversation/languages", "little children/schoolchildren", "junior high school and high school students",
         "university students/examinations", "lifelong education/qualifications", "educational problem"],
        ["elders", "disability persons", "social welfare", "volunteers", "sign languages", "captions", "audio descriptions"],
    ]
}
