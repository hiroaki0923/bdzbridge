import Foundation

/// The invented stations and their days, which the demo's guide shows, its recorder holds and records from, and
/// its television receives: six terrestrial stations and three BS ones, each with one day of programmes placed by
/// the clock from 04:00, repeated over the days the guide covers. Every name in it is invented.
///
/// Reservations are built from it by name (`slot`) and recordings are placed on its broadcast days (`moment`),
/// so the guide and the recorder's lists cannot drift apart; the app writes the guide into its cache
/// (`services`), and the demo's television is made from it (`television()`).
public enum DemoLineUp {
    // MARK: - the stations

    /// Invented stations. Nothing here names a real broadcaster: a real line-up would say which prefecture
    /// the recorder is in and which pay channels the household takes.
    public struct Station: Sendable {
        public var serviceID: Int
        var name: String
        /// The two characters on the invented logo. Spelled out rather than taken from the name, because
        /// three of the stations begin with the same two.
        public var logo: String
        var schedule: [Slot]
    }

    /// One programme in a station's day, placed by the clock from 04:00, where a broadcast day starts.
    struct Slot: Sendable {
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

    public static let terrestrial: [Station] = [
        Station(serviceID: 1024, name: "サンプルテレビ", logo: "サン", schedule: [
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
        Station(serviceID: 1032, name: "サンプル教育", logo: "教育", schedule: [
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
        Station(serviceID: 1040, name: "みほんテレビ", logo: "みほ", schedule: [
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
        Station(serviceID: 1048, name: "テレビみほん", logo: "テレ", schedule: [
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
        Station(serviceID: 1056, name: "サンプル放送", logo: "放送", schedule: [
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
        Station(serviceID: 1064, name: "ひなたテレビ", logo: "ひな", schedule: [
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

    public static let satellite: [Station] = [
        Station(serviceID: 2048, name: "サンプルBS", logo: "サＢ", schedule: [
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
        Station(serviceID: 2056, name: "みほんBS", logo: "みＢ", schedule: [
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
        Station(serviceID: 2064, name: "BSみほん", logo: "Ｂみ", schedule: [
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

    // MARK: - the guide

    /// How many days the invented guide covers: enough that stepping a day forward is not an empty screen.
    public static let guideDays = 4

    /// The guide's days of these stations, as the demo's cache holds them: every programme of each station on
    /// every day the guide covers, by its station's service id and name.
    public static func services(_ stations: [Station]) -> [GuideService] {
        var services: [GuideService] = []
        for station in stations {
            var programs: [GuideProgram] = []
            for day in 0..<guideDays {
                programs += station.schedule.enumerated().map { index, slot in
                    program(slot, on: day, of: station, index: index)
                }
            }
            services.append(GuideService(serviceID: station.serviceID, name: station.name,
                                         programs: programs))
        }
        return services
    }

    private static func program(_ slot: Slot, on day: Int, of station: Station, index: Int) -> GuideProgram {
        let start = at(slot.at, dayOffset: day)
        return GuideProgram(serviceID: station.serviceID,
                            eventID: eventID(day: day, index: index),
                            start: start,
                            end: start.addingTimeInterval(TimeInterval(slot.minutes * 60)),
                            title: slot.title,
                            summary: slot.summary,
                            extended: details(of: slot),
                            genres: [Genre(level1: slot.level1, level2: slot.level2)],
                            copyControl: 2)
    }

    /// The programme id of a station's `index`th programme on the guide's `day`th day.
    private static func eventID(day: Int, index: Int) -> Int {
        1000 + day * 100 + index
    }

    /// The details, laid out as a broadcaster's are: the description again, and for a drama the cast, which
    /// is where a search by a name finds it. The names are invented, the same two a recording's text gives.
    private static func details(of slot: Slot) -> String {
        var lines: [String] = []
        if !slot.summary.isEmpty { lines.append(slot.summary) }
        if slot.level1 == 3 { lines.append("出演　サンプル太郎、みほん花子") }
        guard !lines.isEmpty else { return "" }
        return (lines + ["（これはサンプルの番組情報です）"]).joined(separator: "\n")
    }

    /// A time of day on the broadcast day that began at the last 04:00. Anything before 04:00 belongs to the
    /// night at the end of that day, which is how the recorder's own guide reads. The first day is the same
    /// as the guide's day strip's, which until four in the morning is yesterday's date: started from the
    /// calendar date, the day the guide opens on would be empty between midnight and four.
    private static func at(_ hhmm: String, dayOffset: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        let hour = parts.first ?? 0
        let minute = parts.count > 1 ? parts[1] : 0
        let today = GuideStore.broadcastDay(containing: Date())
        let base = hour < 4 ? calendar.date(byAdding: .day, value: 1, to: today)! : today
        let start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
        return calendar.date(byAdding: .day, value: dayOffset, to: start)!
    }

    // MARK: - what the recorder is going to record

    /// A time of day on the broadcast day on air, for the reservations and the recordings.
    static func moment(_ hhmm: String, dayOffset: Int = 0) -> Date {
        at(hhmm, dayOffset: dayOffset)
    }

    /// Every station, of every broadcasting type, for looking a programme up by name.
    static var stations: [Station] { terrestrial + satellite }

    /// One programme of the invented guide, found by the name it was given in the schedule: its id, when it
    /// is on, how long it runs and its genre. **Reservations are built from this.** A reservation that
    /// points at an id the guide does not have is one the guide cannot mark as reserved.
    static func slot(_ title: String, at serviceID: Int,
                     dayOffset: Int = 0) -> (eventID: Int, start: Date, minutes: Int, genre: Int)? {
        guard let station = stations.first(where: { $0.serviceID == serviceID }),
              let index = station.schedule.firstIndex(where: { $0.title == title }) else { return nil }
        let slot = station.schedule[index]
        return (eventID(day: dayOffset, index: index), at(slot.at, dayOffset: dayOffset), slot.minutes,
                slot.level1 * 16 + slot.level2)
    }

    // MARK: - the television

    /// The demo's television, whole as it is made, since the app makes it where nothing can be awaited (in its
    /// transport): on, so that it is registered as a real one is with its panel on, by its number; receiving
    /// every station of the guide, terrestrial and BS, by the same service ids and names, so that any programme
    /// of the guide can be reserved on it; listing what it records under the guide's titles, as a real one
    /// lists its own guide's; holding one recording from the start (`heldOnTheTelevision`); and with recordings of
    /// its own on a disk that adds up (`recordedOnTheTelevision`). It answers at once.
    public static func television() -> DemoTV {
        DemoTV(power: "active", stations: tvStations, holding: [heldOnTheTelevision].compactMap { $0 },
               titles: tvTitles, recordings: recordedOnTheTelevision, diskMB: 500_000)
    }

    private static var tvStations: [DemoTV.Station] {
        terrestrial.map { DemoTV.Station(scheme: "isdbt", serviceID: $0.serviceID, name: $0.name) }
            + satellite.map { DemoTV.Station(scheme: "isdbbs", serviceID: $0.serviceID, name: $0.name) }
    }

    /// Every programme of the guide, on every day it covers, by its station and its id, with its title.
    private static var tvTitles: [DemoTV.Programme: String] {
        var titles: [DemoTV.Programme: String] = [:]
        for station in stations {
            for day in 0..<guideDays {
                for (index, slot) in station.schedule.enumerated() {
                    titles[DemoTV.Programme(serviceID: station.serviceID, eventId: eventID(day: day, index: index))]
                        = slot.title
                }
            }
        }
        return titles
    }

    /// What is on the television's disk when the reader adds it, in the order it came into its list, which a real
    /// one's was not by date: programmes of the guide some days back, one watched and protected, one with no text.
    private static var recordedOnTheTelevision: [DemoTV.Recording] {
        [recorded(1, "サンプルドラマ「みなとの灯」第７話", at: 1040, daysAgo: 3, watched: true),
         recorded(2, "サンプルクイズ王", at: 1040, daysAgo: 1),
         recorded(3, "サンプル映画劇場「遠い灯台」", at: 1048, daysAgo: 5),
         recorded(4, "みほんスポーツニュース", at: 1048, daysAgo: 2)].compactMap { $0 }
    }

    /// A programme of the guide as the television's disk holds it, at the size an hour of DR comes to. Its text is
    /// the guide's, as a real one's is the broadcast's, and none where the guide has none.
    private static func recorded(_ contentID: Int, _ title: String, at serviceID: Int, daysAgo: Int,
                                 watched: Bool = false) -> DemoTV.Recording? {
        guard let station = stations.first(where: { $0.serviceID == serviceID }),
              let slot = station.schedule.first(where: { $0.title == title }) else { return nil }
        let details = details(of: slot)
        return DemoTV.Recording(contentID: contentID, title: title, station: station.name,
                                start: at(slot.at, dayOffset: -daysAgo), durationSec: slot.minutes * 60,
                                sizeMB: slot.minutes * 100, protected: watched, played: watched,
                                summary: slot.summary.isEmpty ? nil : slot.summary,
                                details: details.isEmpty ? nil : details, genre: slot.level1 * 16 + slot.level2)
    }

    /// What the television holds when the reader adds it, as if set with its remote: a programme of the guide
    /// two days ahead that the demo's recorder does not hold, once, so that the reservations tab has a row of
    /// the television's to show before anything is made on it.
    private static var heldOnTheTelevision: DemoTV.Schedule? {
        let (title, serviceID, dayOffset) = ("みほんBS特集　港の一年", 2056, 2)
        guard let station = stations.first(where: { $0.serviceID == serviceID }),
              let found = slot(title, at: serviceID, dayOffset: dayOffset) else { return nil }
        return DemoTV.Schedule(id: "recording.1", scheme: "isdbbs", serviceID: serviceID, station: station.name,
                               title: title, start: found.start, durationSec: found.minutes * 60,
                               eventId: found.eventID)
    }
}
