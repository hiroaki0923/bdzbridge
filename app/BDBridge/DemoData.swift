#if DEBUG
import Foundation
import RecorderKit

/// A recorder made of canned answers, and a guide full of invented programmes.
///
/// This is how the App Store screenshots are taken. The screens show what is on the recorder's disk and what
/// it is going to record, which on a real box is a list of what somebody watches, where they live and what
/// they pay for. None of that belongs in a shop window, so everything here is made up: the stations, the
/// programmes, the recordings, the keyword conditions, the address and the MAC.
///
/// It is not a mock of the app. The answers are the XML a BDZ-FBT4100 really sends, parsed by the same code
/// that parses the real thing, so what the screenshots show is the app working -- with invented data.
///
/// `#if DEBUG`, so none of it is in the build that goes to the store. Turned on with `-demoData 1` on the
/// command line (see app/scripts/screenshots).
enum DemoData {
    static let enabled = UserDefaults.standard.bool(forKey: "demoData")

    static let host = "192.0.2.63"          // reserved for documentation (RFC 5737): never a real host
    static let mac = "f8:4e:17:00:00:00"    // Sony's OUI, the rest zeroed, as everywhere else in this repo
    static let firmware = "1.234"
    static let totalBytes = 2_000_000_000_000
    static let freeBytes = 412_300_000_000

    // MARK: - the stations

    /// Invented stations. Nothing here names a real broadcaster: a real line-up would say which prefecture
    /// the recorder is in and which pay channels the household takes.
    struct Station {
        var serviceID: Int
        var name: String
        var schedule: [Slot]
    }

    /// One programme in a station's day, placed by the clock from 04:00, which is where a broadcast day
    /// starts.
    struct Slot {
        var at: String
        var minutes: Int
        var title: String
        var level1: Int
        var level2: Int
        var summary: String

        init(_ at: String, _ minutes: Int, _ title: String, _ level1: Int, _ level2: Int = 0,
             _ summary: String = "") {
            self.at = at
            self.minutes = minutes
            self.title = title
            self.level1 = level1
            self.level2 = level2
            self.summary = summary
        }
    }

    static let terrestrial: [Station] = [
        Station(serviceID: 1024, name: "サンプルテレビ", schedule: [
            Slot("04:00", 60, "早朝サンプル便り", 0, 1),
            Slot("05:00", 90, "あさのサンプル", 2, 0, "暮らしと天気の情報番組。"),
            Slot("06:30", 30, "サンプル体操", 10, 2),
            Slot("07:00", 60, "サンプルニュース　モーニング", 0, 0),
            Slot("08:00", 120, "みほん劇場アンコール", 3, 0, "過去の名作を続けて放送します。"),
            Slot("10:00", 120, "サンプル国会中継", 0, 2),
            Slot("12:00", 30, "ひるのサンプルニュース", 0, 0),
            Slot("12:30", 90, "ひなたスポーツ「サンプル杯」", 1, 0, "サンプル杯・準決勝の中継。"),
            Slot("14:00", 120, "サンプルアーカイブ選", 8, 1),
            Slot("16:00", 90, "みほんタイム", 2, 1),
            Slot("17:30", 30, "こどもサンプル", 7, 0),
            Slot("18:00", 60, "サンプルニュース１８", 0, 0),
            Slot("19:00", 60, "サンプル特集　海の道", 8, 0, "海沿いの町をたずねる紀行。"),
            Slot("20:00", 45, "サンプル劇場「ひかりの街」第５話", 3, 0,
                 "港町にもどった主人公が、古い灯台の記録を読みはじめる。"),
            Slot("20:45", 15, "サンプル天気", 0, 5),
            Slot("21:00", 60, "みほんドキュメント　山の記憶", 8, 0),
            Slot("22:00", 30, "サンプルニュース２２", 0, 0),
            Slot("22:30", 60, "サンプル音楽館　夏の特集", 4, 0),
            Slot("23:30", 60, "サンプル討論", 0, 2),
            Slot("00:30", 60, "深夜サンプル劇場", 6, 1),
            Slot("01:30", 60, "サンプル深夜便", 4, 0),
            Slot("02:30", 60, "サンプルアーカイブ深夜", 8, 1),
            Slot("03:30", 30, "サンプル気象情報", 0, 5),
        ]),
        Station(serviceID: 1032, name: "サンプル教育", schedule: [
            Slot("04:00", 120, "サンプル語学　入門", 10, 1),
            Slot("06:00", 60, "みほんのりか", 10, 1),
            Slot("07:00", 60, "こどもみほん", 7, 0),
            Slot("08:00", 120, "サンプル手芸教室", 10, 0),
            Slot("10:00", 120, "みほん高校講座", 10, 1),
            Slot("12:00", 120, "サンプル趣味の園芸", 10, 0),
            Slot("14:00", 120, "みほん美術館", 9, 2),
            Slot("16:00", 90, "サンプル囲碁将棋", 11, 2),
            Slot("17:30", 30, "こどもサンプル工作", 7, 0),
            Slot("18:00", 120, "みほん自然紀行", 8, 2),
            Slot("20:00", 60, "サンプル古典芸能", 9, 0),
            Slot("21:00", 60, "みほんクラシック館", 4, 1, "夏の音楽祭から、管弦楽の夜。"),
            Slot("22:00", 60, "サンプル科学の時間", 8, 1),
            Slot("23:00", 60, "みほん語学　応用", 10, 1),
            Slot("00:00", 60, "サンプル教育　夜の講座", 10, 1),
            Slot("01:00", 60, "みほん語学　復習", 10, 1),
            Slot("02:00", 60, "サンプル手話ニュース", 11, 0),
            Slot("03:00", 60, "みほん音楽の時間", 4, 1),
        ]),
        Station(serviceID: 1040, name: "みほんテレビ", schedule: [
            Slot("04:00", 90, "みほん早朝便", 0, 1),
            Slot("05:30", 150, "みほんモーニングショー", 2, 0),
            Slot("08:00", 120, "サンプルワイド", 2, 1),
            Slot("10:00", 120, "みほん情報局", 2, 1),
            Slot("12:00", 120, "サンプル昼ドラ「なぎさ通り」", 3, 1),
            Slot("14:00", 120, "みほんサスペンス再放送", 3, 3),
            Slot("16:00", 120, "みほんニュース夕方版", 0, 0),
            Slot("18:00", 60, "サンプルクイズ王", 5, 1, "全国のサンプル名人が集まる大会。"),
            Slot("19:00", 120, "みほんバラエティ特大号", 5, 0),
            Slot("21:00", 60, "サンプルドラマ「みなとの灯」第７話", 3, 0),
            Slot("22:00", 60, "みほんニュース２２", 0, 0),
            Slot("23:00", 60, "サンプル深夜バラエティ", 5, 0),
            Slot("00:00", 60, "みほん通販", 2, 4),
            Slot("01:00", 60, "サンプル深夜ドラマ「かどの店」", 3, 0),
            Slot("02:00", 60, "みほんアーカイブ", 8, 1),
            Slot("03:00", 60, "みほん早朝ニュース", 0, 0),
        ]),
        Station(serviceID: 1048, name: "テレビみほん", schedule: [
            Slot("04:00", 120, "テレビみほん朝の顔", 2, 0),
            Slot("06:00", 120, "サンプル経済ニュース", 0, 1),
            Slot("08:00", 120, "みほんグルメ紀行", 11, 0),
            Slot("10:00", 120, "サンプル旅番組「各駅停車」", 11, 1, "各駅に降りながら、海まで行く。"),
            Slot("12:00", 120, "テレビみほん昼の映画劇場", 6, 0),
            Slot("14:00", 120, "みほん将棋道場", 11, 2),
            Slot("16:00", 120, "サンプルアニメ　空色パズル（７）", 7, 0,
                 "パズルの最後のひとかけらを探して、三人は港に向かう。"),
            Slot("18:00", 60, "みほんスポーツニュース", 1, 6),
            Slot("19:00", 120, "サンプル映画劇場「遠い灯台」", 6, 0,
                 "岬の灯台を守る一家の三代を描く。灯台守の祖父が残した日誌を、孫がたどりはじめる。"),
            Slot("21:00", 60, "テレビみほん特集", 8, 0),
            Slot("22:00", 120, "サンプル音楽ライブ", 4, 0),
            Slot("00:00", 30, "深夜アニメサンプル", 7, 1),
            Slot("00:30", 30, "サンプルアニメ　夜の便", 7, 1),
            Slot("01:00", 60, "テレビみほん深夜劇場", 6, 1),
            Slot("02:00", 60, "サンプル通販", 2, 4),
            Slot("03:00", 60, "みほん経済ニュース", 0, 1),
        ]),
        Station(serviceID: 1056, name: "サンプル放送", schedule: [
            Slot("04:00", 120, "サンプル放送　朝一番", 0, 1),
            Slot("06:00", 180, "みほんスタジオ", 2, 0),
            Slot("09:00", 180, "サンプルショッピング", 2, 4),
            Slot("12:00", 120, "みほん時代劇「はなれ島」", 3, 2),
            Slot("14:00", 120, "サンプル再放送劇場", 3, 0),
            Slot("16:00", 120, "サンプル夕方ニュース", 0, 0),
            Slot("18:00", 120, "みほんスポーツ中継「サンプルリーグ」", 1, 1),
            Slot("20:00", 120, "サンプルバラエティ祭", 5, 0),
            Slot("22:00", 60, "みほんドラマ「夜の停留所」第３話", 3, 0),
            Slot("23:00", 120, "サンプル深夜劇場", 6, 1),
            Slot("01:00", 60, "サンプル放送　深夜劇場", 6, 1),
            Slot("02:00", 60, "みほん歌謡アワー", 4, 2),
            Slot("03:00", 60, "サンプル放送　朝の準備", 0, 1),
        ]),
        Station(serviceID: 1064, name: "ひなたテレビ", schedule: [
            Slot("04:00", 180, "ひなた早朝サンプル", 0, 1),
            Slot("07:00", 120, "ひなたモーニング", 2, 0),
            Slot("09:00", 180, "サンプル再放送タイム", 3, 0),
            Slot("12:00", 120, "ひなたのお昼", 2, 1),
            Slot("14:00", 120, "サンプルドキュメント選", 8, 0),
            Slot("16:00", 120, "ひなたこどもアニメ", 7, 0),
            Slot("18:00", 120, "ひなたスポーツ特集", 1, 0, "サンプルリーグ第１２節をふりかえる。"),
            Slot("20:00", 120, "サンプル歌謡ショー", 4, 2),
            Slot("22:00", 120, "ひなた映画館「みほんの丘」", 6, 0),
            Slot("00:00", 60, "ひなた深夜便", 4, 0),
            Slot("01:00", 60, "ひなた深夜映画「みほん港」", 6, 0),
            Slot("02:00", 60, "サンプル音楽夜話", 4, 1),
            Slot("03:00", 60, "ひなた早朝便", 0, 1),
        ]),
    ]

    static let satellite: [Station] = [
        Station(serviceID: 2048, name: "サンプルBS", schedule: [
            Slot("04:00", 180, "BSサンプル早朝紀行", 11, 1),
            Slot("07:00", 180, "サンプルBSニュース", 0, 0),
            Slot("10:00", 180, "BS名画サンプル", 6, 0),
            Slot("13:00", 180, "サンプルBS自然紀行", 8, 2),
            Slot("16:00", 120, "BSサンプル大河「はまべ」", 3, 2),
            Slot("18:00", 120, "サンプルBSスポーツ", 1, 0),
            Slot("20:00", 120, "BSサンプル劇場「星空紀行」", 6, 0,
                 "夜の海辺をめぐる、静かなロードムービー。"),
            Slot("22:00", 120, "サンプルBS音楽祭", 4, 0),
            Slot("00:00", 60, "BSサンプル深夜便", 0, 1),
            Slot("01:00", 60, "BSサンプル名画座", 6, 0),
            Slot("02:00", 60, "サンプルBS音楽夜話", 4, 1),
            Slot("03:00", 60, "BSサンプル朝の紀行", 11, 1),
        ]),
        Station(serviceID: 2056, name: "みほんBS", schedule: [
            Slot("04:00", 240, "みほんBS朝の紀行", 11, 1),
            Slot("08:00", 240, "みほんBSドラマ再放送", 3, 0),
            Slot("12:00", 240, "みほんBS通販", 2, 4),
            Slot("16:00", 120, "みほんBS時代劇", 3, 2),
            Slot("18:00", 120, "みほんBSクイズ", 5, 1),
            Slot("20:00", 120, "みほんBS特集　港の一年", 8, 0),
            Slot("22:00", 120, "みほんBS歌謡", 4, 2),
            Slot("00:00", 60, "みほんBS夜間放送", 0, 1),
            Slot("01:00", 60, "みほんBS深夜劇場", 6, 1),
            Slot("02:00", 120, "みほんBS通販", 2, 4),
        ]),
        Station(serviceID: 2064, name: "BSみほん", schedule: [
            Slot("04:00", 240, "BSみほん朝の音楽", 4, 1),
            Slot("08:00", 240, "BSみほん紀行", 11, 1),
            Slot("12:00", 240, "BSみほん映画館", 6, 0),
            Slot("16:00", 240, "BSみほんドキュメント", 8, 0),
            Slot("20:00", 120, "BSみほんアニメ劇場", 7, 0),
            Slot("22:00", 120, "BSみほんライブ", 4, 0),
            Slot("00:00", 60, "BSみほん深夜", 0, 1),
            Slot("01:00", 60, "BSみほん映画「夜の岬」", 6, 0),
            Slot("02:00", 120, "BSみほん音楽夜話", 4, 1),
        ]),
    ]

    // MARK: - filling the guide cache

    /// Writes the invented guide into the app's own cache, which is where the screens read it from. Four
    /// days, so stepping a day forward in the guide is not an empty screen.
    static func seed(store: GuideStore) async throws {
        for (broadcasting, stations) in [("td", terrestrial), ("bs", satellite)] {
            var services: [GuideService] = []
            for station in stations {
                var programs: [GuideProgram] = []
                for day in 0..<4 {
                    programs += station.schedule.enumerated().map { index, slot in
                        program(slot, on: day, of: station, index: index)
                    }
                }
                services.append(GuideService(serviceID: station.serviceID, name: station.name,
                                             programs: programs))
            }
            _ = try await store.replace(services, broadcasting: broadcasting)
        }
    }

    private static func program(_ slot: Slot, on day: Int, of station: Station, index: Int) -> GuideProgram {
        let start = at(slot.at, dayOffset: day)
        return GuideProgram(serviceID: station.serviceID,
                            eventID: 1000 + day * 100 + index,
                            start: start,
                            end: start.addingTimeInterval(TimeInterval(slot.minutes * 60)),
                            title: slot.title,
                            summary: slot.summary,
                            extended: slot.summary.isEmpty ? "" : slot.summary + "\n（これはサンプルの番組情報です）",
                            genres: [Genre(level1: slot.level1, level2: slot.level2)],
                            copyControl: 2)
    }

    /// A time of day on the broadcast day that began at the last 04:00. Anything before 04:00 belongs to the
    /// night at the end of that day, which is how the recorder's own guide reads.
    private static func at(_ hhmm: String, dayOffset: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        let hour = parts.first ?? 0
        let minute = parts.count > 1 ? parts[1] : 0
        let today = calendar.startOfDay(for: Date())
        let base = hour < 4 ? calendar.date(byAdding: .day, value: 1, to: today)! : today
        let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
        return calendar.date(byAdding: .day, value: dayOffset, to: start)!
    }

    // MARK: - what the recorder is going to record

    /// Today's date at a time of day, for the reservations and the recordings.
    private static func moment(_ hhmm: String, dayOffset: Int = 0) -> Date {
        at(hhmm, dayOffset: dayOffset)
    }

    static var reservationsXml: String {
        var xml = "<xsrs xmlns=\"\(Upnp.xsrsMetadataNamespace)\">"
        xml += reservation(id: "0x00000000000a9431", title: "サンプルニュース",
                           start: Date().addingTimeInterval(-20 * 60), minutes: 60, service: 1024,
                           eventID: 0x3721, quality: 230, genre: 0, recording: true, size: 3800)
        xml += reservation(id: "0x00000000000a9432", title: "サンプル劇場「ひかりの街」第５話",
                           start: moment("20:00"), minutes: 45, service: 1024, eventID: 0x3798,
                           quality: 220, genre: 48, repeatCode: weekly(moment("20:00")), size: 2900)
        xml += reservation(id: "0x00000000000a9433", title: "みほんドキュメント　山の記憶",
                           start: moment("21:00"), minutes: 60, service: 1024, eventID: 0x379a,
                           quality: 100, genre: 128, size: 5900)
        xml += reservation(id: "0x00000000000a9434", title: "サンプルアニメ　空色パズル（７）",
                           start: moment("16:00", dayOffset: 1), minutes: 120, service: 1048,
                           eventID: 0x37b2, quality: 240, genre: 112,
                           repeatCode: weekly(moment("16:00", dayOffset: 1)), size: 1600)
        xml += reservation(id: "0x00000000000a9435", title: "ひなたスポーツ特集",
                           start: moment("18:00", dayOffset: 1), minutes: 120, service: 1064,
                           eventID: 0x37c0, quality: 220, genre: 16, conflict: true, size: 4200)
        // The recorder's own おまかせ・まる録 puts reservations in the same list, under its own creator id.
        xml += reservation(id: "0x00000000000b1101", title: "サンプル音楽館　夏の特集",
                           start: moment("22:30"), minutes: 60, service: 1024, eventID: 0x379e,
                           quality: 220, genre: 64, creator: "1000", size: 2700)
        xml += reservation(id: "0x00000000000b1102", title: "BSサンプル劇場「星空紀行」",
                           start: moment("20:00", dayOffset: 2), minutes: 120, service: 2048,
                           broadcastingType: 3, eventID: 0x37d4, quality: 220, genre: 96,
                           creator: "1000", size: 7400)
        return xml + "</xsrs>"
    }

    // swiftlint:disable:next function_parameter_count
    private static func reservation(id: String, title: String, start: Date, minutes: Int, service: Int,
                                    broadcastingType: Int = 2, eventID: Int, quality: Int, genre: Int,
                                    repeatCode: String = "1", recording: Bool = false,
                                    conflict: Bool = false, creator: String = "2200",
                                    size: Int) -> String {
        "<item id=\"\(id)\"><title>\(Soap.escape(title))</title>"
            + "<scheduledStartDateTime>\(RecorderTime.format(start))</scheduledStartDateTime>"
            + "<scheduledDuration>\(minutes * 60)</scheduledDuration>"
            + "<scheduledConditionID>\(repeatCode)</scheduledConditionID>"
            + "<scheduledChannelID broadcastingType=\"\(broadcastingType)\" channelType=\"2\">"
            + String(format: "0x%04x", service) + "</scheduledChannelID>"
            + "<desiredMatchingID type=\"SI_PROGRAMID\">,,0x0," + String(format: "0x%04x", eventID)
            + "</desiredMatchingID>"
            + "<desiredQualityMode>\(quality)</desiredQualityMode>"
            + "<genreID type=\"2\">\(genre)</genreID>"
            + "<conflictID>\(conflict ? 1 : 0)</conflictID><mediaRemainAlertID>0</mediaRemainAlertID>"
            + "<reservationCreatorID>\(creator)</reservationCreatorID>"
            + "<recordingFlag>\(recording ? 1 : 0)</recordingFlag>"
            + "<recordDestinationID>HDD</recordDestinationID><recordSize>\(size)</recordSize></item>"
    }

    /// The weekly repeat code for the day a programme falls on. The recorder refuses any other weekday.
    private static func weekly(_ start: Date) -> String {
        Codes.repeatCodes[Codes.weekdayRepeat(for: start)] ?? "1"
    }

    // MARK: - what is on the disk

    static var titlesXml: String {
        var xml = "<xsrs xmlns=\"\(Upnp.xsrsMetadataNamespace)\">"
        xml += title(0x8001, "サンプル劇場「ひかりの街」第４話", moment("20:00", dayOffset: -1), 45, 1024,
                     quality: 220, genre: 48, size: 2884, isNew: true)
        xml += title(0x8002, "サンプル劇場「ひかりの街」第３話", moment("20:00", dayOffset: -8), 45, 1024,
                     quality: 220, genre: 48, size: 2901, protected: true, resume: 0)
        xml += title(0x8003, "サンプル劇場「ひかりの街」第２話", moment("20:00", dayOffset: -15), 45, 1024,
                     quality: 220, genre: 48, size: 2877, resume: 1_240)
        xml += title(0x8004, "サンプル劇場「ひかりの街」第１話", moment("20:00", dayOffset: -22), 60, 1024,
                     quality: 220, genre: 48, size: 3810, resume: 0)
        xml += title(0x8005, "みほんドキュメント　海の記憶", moment("21:00", dayOffset: -2), 60, 1024,
                     quality: 100, genre: 128, size: 11_640, isNew: true)
        xml += title(0x8006, "サンプルアニメ　空色パズル（６）", moment("16:00", dayOffset: -2), 120, 1048,
                     quality: 240, genre: 112, size: 1_562, isNew: true)
        xml += title(0x8007, "サンプルアニメ　空色パズル（５）", moment("16:00", dayOffset: -9), 120, 1048,
                     quality: 240, genre: 112, size: 1_548, resume: 0)
        xml += title(0x8008, "サンプル映画劇場「遠い灯台」", moment("19:00", dayOffset: -3), 120, 1048,
                     quality: 220, genre: 96, size: 7_420, resume: 3_600)
        xml += title(0x8009, "ひなたスポーツ特集　サンプルリーグ第１２節", moment("18:00", dayOffset: -4),
                     120, 1064, quality: 220, genre: 16, size: 6_180, isNew: true)
        xml += title(0x800a, "サンプル音楽館　夏の特集", moment("22:30", dayOffset: -5), 60, 1024,
                     quality: 220, genre: 64, size: 2_640, resume: 0)
        xml += title(0x800b, "BSサンプル劇場「星空紀行」", moment("20:00", dayOffset: -6), 120, 2048,
                     broadcastingType: 3, quality: 220, genre: 96, size: 7_380, isNew: true)
        xml += title(0x800c, "みほんクラシック館", moment("21:00", dayOffset: -7), 60, 1032,
                     quality: 100, genre: 65, size: 10_920, resume: 0)
        xml += title(0x800d, "サンプルクイズ王", moment("18:00", dayOffset: -7), 60, 1040,
                     quality: 240, genre: 81, size: 890, isNew: true)
        xml += title(0x800e, "みほん自然紀行", moment("18:00", dayOffset: -10), 120, 1032,
                     quality: 220, genre: 130, size: 5_940, resume: 2_400)
        xml += title(0x800f, "サンプル旅番組「各駅停車」", moment("10:00", dayOffset: -11), 120, 1048,
                     quality: 240, genre: 177, size: 1_720, resume: 0)
        xml += title(0x8010, "サンプルアニメ　空色パズル（４）", moment("16:00", dayOffset: -16), 120, 1048,
                     quality: 240, genre: 112, size: 1_551, resume: 0)
        xml += title(0x8011, "サンプルアニメ　空色パズル（３）", moment("16:00", dayOffset: -23), 120, 1048,
                     quality: 240, genre: 112, size: 1_544, resume: 0)
        xml += title(0x8012, "みほんドキュメント　川の記憶", moment("21:00", dayOffset: -9), 60, 1024,
                     quality: 100, genre: 128, size: 11_580, resume: 900)
        xml += title(0x8013, "みほんドキュメント　町の記憶", moment("21:00", dayOffset: -16), 60, 1024,
                     quality: 100, genre: 128, size: 11_610, resume: 0)
        xml += title(0x8014, "ひなたスポーツ特集　サンプルリーグ第１１節", moment("18:00", dayOffset: -11),
                     120, 1064, quality: 220, genre: 16, size: 6_120, resume: 0)
        xml += title(0x8015, "ひなたスポーツ特集　サンプルリーグ第１０節", moment("18:00", dayOffset: -18),
                     120, 1064, quality: 220, genre: 16, size: 6_090, resume: 0)
        return xml + "</xsrs>"
    }

    private static func title(_ number: Int, _ name: String, _ start: Date, _ minutes: Int, _ service: Int,
                              broadcastingType: Int = 2, quality: Int, genre: Int, size: Int,
                              protected: Bool = false, isNew: Bool = false, resume: Int? = nil) -> String {
        let played: String
        if let resume {
            played = "<lastPlaybackTime resumePoint=\"\(resume)\">"
                + RecorderTime.format(start.addingTimeInterval(86_400)) + "</lastPlaybackTime>"
        } else {
            played = "<lastPlaybackTime resumePoint=\"0\">notplayed</lastPlaybackTime>"
        }
        return "<item id=\"" + String(format: "0x%016x", number) + "\">"
            + "<title>\(Soap.escape(name))</title>"
            + "<scheduledStartDateTime>\(RecorderTime.format(start))</scheduledStartDateTime>"
            + "<scheduledDuration>\(minutes * 60)</scheduledDuration>"
            + "<scheduledChannelID broadcastingType=\"\(broadcastingType)\" channelType=\"2\">"
            + String(format: "0x%04x", service) + "</scheduledChannelID>"
            + "<desiredQualityMode>\(quality)</desiredQualityMode>"
            + "<genreID type=\"2\">\(genre)</genreID>"
            + "<titleProtectFlag>\(protected ? 1 : 0)</titleProtectFlag>"
            + "<titleNewFlag>\(isNew ? 1 : 0)</titleNewFlag>"
            + "<recordDestinationID>HDD</recordDestinationID>"
            + "<recordSize>\(size)</recordSize>" + played + "</item>"
    }

    // MARK: - the recorder's own keyword conditions

    static let rulesXml = """
        <xsrs xmlns="\(Upnp.xsrsMetadataNamespace)">\
        <object type="SEARCH" id="0x0000470f"><desiredQualityMode>220</desiredQualityMode>\
        <recordDestinationID>HDD</recordDestinationID>\
        <searchSetting type="MULTIPLE" logic="OR"><name>サンプル劇場</name>\
        <genreID type="2">0x30</genreID><keyword>サンプル劇場</keyword><keyword>ひかりの街</keyword>\
        <excludeKeyword>再放送</excludeKeyword>\
        <timeScope>NIGHT</timeScope><broadcastTypeScope>TRD</broadcastTypeScope></searchSetting></object>\
        <object type="SEARCH" id="0x0000570b"><desiredQualityMode>226</desiredQualityMode>\
        <recordDestinationID>HDD</recordDestinationID>\
        <searchSetting type="MULTIPLE" logic="OR"><name>空色パズル</name>\
        <genreID type="3">0x7*</genreID><keyword>空色パズル</keyword>\
        <timeScope>ALL</timeScope><broadcastTypeScope>ALL</broadcastTypeScope></searchSetting></object>\
        <object type="SEARCH" id="0x00021703"><desiredQualityMode>100</desiredQualityMode>\
        <recordDestinationID>HDD</recordDestinationID>\
        <searchSetting type="MULTIPLE" logic="AND"><name>みほん/紀行</name>\
        <genreID type="2">0x82</genreID><keyword>みほん</keyword><keyword>紀行</keyword>\
        <timeScope>ALL</timeScope><broadcastTypeScope>BSD</broadcastTypeScope></searchSetting></object>\
        </xsrs>
        """

    // MARK: - the box itself

    static let descriptionXml = """
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:av="urn:schemas-sony-com:av">
          <device>
            <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
            <friendlyName>BDR - BDZ-FBT4100</friendlyName>
            <manufacturer>Sony Corporation</manufacturer>
            <modelDescription>BDZ-202105</modelDescription>
            <modelName>Sony-BDZ</modelName>
            <UDN>uuid:00000000-0000-0000-0000-000000000000</UDN>
            <av:X_ScalarWebAPI_DeviceInfo><av:EPG_CAP>03</av:EPG_CAP></av:X_ScalarWebAPI_DeviceInfo>
            <serviceList>
              <service>
                <serviceType>urn:schemas-xsrs-org:service:X_ScheduledRecording:2</serviceType>
                <controlURL>/XSRS</controlURL>
              </service>
            </serviceList>
          </device>
        </root>
        """
}

/// Answers the recorder's requests from `DemoData`, without a network.
///
/// It dispatches on the SOAP action, the way the recorder's own services do. Writes are accepted and
/// forgotten: the screenshots read, and a demo that remembered a deletion would need a recorder to delete
/// from.
struct DemoTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        // Slow enough that the screens are not caught mid-layout, fast enough not to wait about.
        try? await Task.sleep(for: .milliseconds(80))

        if request.url.path == "/description.xml" {
            return HTTPResponse(statusCode: 200, body: Data(DemoData.descriptionXml.utf8))
        }
        guard request.method == "POST" else {
            // A guide file: there is none, and the cache was filled directly. 404 is what a recorder that
            // has not built its files yet answers, and the app treats it as nothing to fetch.
            return HTTPResponse(statusCode: 404)
        }

        switch action(of: request) {
        case "X_GetRecordScheduleList":
            return soap(result: DemoData.reservationsXml, totalMatches: 7)
        case "X_GetTitleList":
            return soap(result: DemoData.titlesXml, totalMatches: 21)
        case "X_GetConflictList":
            return soap(result: "")
        case "X_GetPrefRecSettingList":
            return soap(result: DemoData.rulesXml)
        case "X_GetTitleDetail":
            return soap(result: "<detail><summary>これはサンプルの番組情報です。"
                        + "実在の番組・人物とは関係ありません。</summary>"
                        + "<detail1>出演　サンプル太郎、みほん花子</detail1></detail>")
        case "X_GetFirmwareVersion":
            return soap(result: "<firmware><version>\(DemoData.firmware)</version></firmware>")
        case "X_GetPrivateIp":
            return soap(result: "<network><macAddress>\(DemoData.mac)</macAddress>"
                        + "<wirelessMacAddress></wirelessMacAddress>"
                        + "<ipAddress>\(DemoData.host)</ipAddress><useDhcp>1</useDhcp></network>")
        case "X_GetPlayStatus":
            return soap(result: "<status><playStatus>stop</playStatus></status>")
        case "X_PowerControl":
            return soap(result: "<power><powerstatus>on</powerstatus></power>")
        case "X_HDLnkGetRecordDestinationInfo":
            let info = "<recordDestinationInfo totalCapacity=\"\(DemoData.totalBytes)\" "
                + "availableCapacity=\"\(DemoData.freeBytes)\" />"
            return soap(result: info, element: "RecordDestinationInfo")
        case "X_CreateRecordSchedule":
            return soap(inner: "<RecordScheduleID>0x00000000000affff</RecordScheduleID>")
        case "X_CreatePrefRecSetting":
            return soap(inner: "<SearchSettingID>0x0000ffff</SearchSettingID>")
        default:
            // Updates, deletions, playback: accepted, and nothing to say about them.
            return soap(inner: "")
        }
    }

    /// The action, from the `SOAPAction` header the client sends.
    private func action(of request: HTTPRequest) -> String {
        let header = request.headers.first { $0.key.lowercased() == "soapaction" }?.value ?? ""
        return String(header.split(separator: "#").last ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    private func soap(result: String, totalMatches: Int? = nil, element: String = "Result") -> HTTPResponse {
        var inner = "<\(element)>\(Soap.escape(result))</\(element)>"
        if let totalMatches { inner += "<TotalMatches>\(totalMatches)</TotalMatches>" }
        return soap(inner: inner)
    }

    private func soap(inner: String) -> HTTPResponse {
        let body = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">"
            + "<s:Body><u:Response xmlns:u=\"\(Upnp.xsrsService)\">\(inner)</u:Response></s:Body></s:Envelope>"
        return HTTPResponse(statusCode: 200, body: Data(body.utf8))
    }
}
#endif
