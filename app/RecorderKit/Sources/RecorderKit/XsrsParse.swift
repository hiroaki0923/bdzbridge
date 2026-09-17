import Foundation

/// Turns the `<item>` elements inside a SOAP `Result` into values.
public enum XsrsParse {
    /// The items of a `Result` payload; an empty or absent result gives an empty list.
    public static func items(inResult result: String) throws -> [XmlNode] {
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return try XmlNode.parse(result).descendants("item")
    }

    /// The `<object>` elements of a `Result` payload, which is how the recorder lists its own conditions.
    public static func objects(inResult result: String) throws -> [XmlNode] {
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return try XmlNode.parse(result).descendants("object")
    }

    /// `0x50` is level 5, sub-genre 0; `0x5*` (the recorder's type="3") is level 5, any sub-genre.
    static func genreLevels(_ text: String) -> (Int?, Int?) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.hasPrefix("0x") else { return Int(t).map { ($0 >> 4, $0 & 0xF) } ?? (nil, nil) }
        t.removeFirst(2)
        if t.hasSuffix("*") { return (Int(t.dropLast(), radix: 16), nil) }
        guard let code = Int(t, radix: 16) else { return (nil, nil) }
        return (code >> 4, code & 0xF)
    }

    public static func recorderRule(_ object: XmlNode) -> RecorderRule {
        let setting = object.child("searchSetting")
        let (level1, level2) = genreLevels(setting?.childText("genreID") ?? "")
        let quality = object.childText("desiredQualityMode")
        let quality4K = object.childText("desiredQualityModeForAdvanced")
        return RecorderRule(
            id: object.attributes["id"] ?? "",
            name: setting?.childText("name") ?? "",
            keywords: setting?.descendants("keyword").map(\.strippedText) ?? [],
            excluded: setting?.descendants("excludeKeyword").map(\.strippedText) ?? [],
            logic: setting?.attributes["logic"] ?? "OR",
            genreLevel1: level1,
            genreLevel2: level2,
            timeScope: setting?.childText("timeScope", default: "ALL") ?? "ALL",
            broadcastingScope: setting?.childText("broadcastTypeScope", default: "ALL") ?? "ALL",
            qualityCode: quality.isEmpty ? nil : Int(quality),
            qualityCode4K: quality4K.isEmpty ? nil : Int(quality4K),
            destination: object.childText("recordDestinationID", default: "HDD")
        )
    }

    public static func reservation(_ item: XmlNode) -> Reservation? {
        guard let start = RecorderTime.parse(item.childText("scheduledStartDateTime")) else { return nil }
        let channel = item.child("scheduledChannelID")
        let size = item.childText("recordSize")
        return Reservation(
            id: item.attributes["id"] ?? "",
            title: item.childText("title"),
            start: start,
            durationSec: Int(item.childText("scheduledDuration", default: "0")) ?? 0,
            repeatCode: item.childText("scheduledConditionID", default: "1"),
            broadcastingType: channel.flatMap { Int($0.attributes["broadcastingType"] ?? "0") } ?? 0,
            serviceID: channel.flatMap { hexInt($0.text) } ?? 0,
            eventID: matchingID(item.childText("desiredMatchingID")),
            qualityCode: Int(item.childText("desiredQualityMode", default: "0")) ?? 0,
            recording: item.childText("recordingFlag", default: "0") == "1",
            conflict: item.childText("conflictID", default: "0") != "0",
            destination: item.childText("recordDestinationID", default: "HDD"),
            sizeMB: size.isEmpty ? nil : Int(size),
            creator: item.childText("reservationCreatorID").isEmpty ? nil : item.childText("reservationCreatorID"),
            genreCode: genreCode(item)
        )
    }

    public static func title(_ item: XmlNode) -> RecordedTitle? {
        guard let start = RecorderTime.parse(item.childText("scheduledStartDateTime")) else { return nil }
        let channel = item.child("scheduledChannelID")
        let size = item.childText("recordSize")
        let playback = item.child("lastPlaybackTime")
        let playbackText = playback?.strippedText ?? ""
        let resume = playback?.attributes["resumePoint"] ?? ""
        return RecordedTitle(
            id: item.attributes["id"] ?? "",
            title: item.childText("title"),
            start: start,
            durationSec: Int(item.childText("scheduledDuration", default: "0")) ?? 0,
            broadcastingType: channel.flatMap { Int($0.attributes["broadcastingType"] ?? "0") } ?? 0,
            serviceID: channel.flatMap { hexInt($0.text) } ?? 0,
            qualityCode: Int(item.childText("desiredQualityMode", default: "0")) ?? 0,
            protected: item.childText("titleProtectFlag", default: "0") == "1",
            isNew: item.childText("titleNewFlag", default: "0") == "1",
            recording: item.childText("recordingFlag", default: "0") == "1",
            destination: item.childText("recordDestinationID", default: "HDD"),
            sizeMB: size.isEmpty ? nil : Int(size),
            genreCode: genreCode(item),
            // "notplayed" is what a recording that was never opened carries here.
            lastPlayed: playbackText.first?.isNumber == true ? RecorderTime.parse(playbackText) : nil,
            resumeSec: resume.allSatisfy(\.isNumber) && !resume.isEmpty ? Int(resume) : nil
        )
    }

    /// `,,0x400,0x3798` carries the programme id in its last field.
    static func matchingID(_ text: String) -> Int? {
        guard !text.isEmpty, let last = text.split(separator: ",", omittingEmptySubsequences: false).last else { return nil }
        return hexInt(String(last))
    }

    static func genreCode(_ item: XmlNode) -> Int? {
        let text = item.childText("genreID")
        guard !text.isEmpty, text.allSatisfy(\.isNumber) else { return nil }
        return Int(text)
    }
}
