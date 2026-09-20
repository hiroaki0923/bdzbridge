import Foundation

/// The recorder's code tables, verified on a BDZ-FBT4100. See docs/xsrs-api.md; the values are checked
/// against docs/port/codes.json by the tests.
public enum Codes {
    /// `broadcastingType` as used in `scheduledChannelID` and in the EPG file names.
    public static let broadcasting: [String: Int] = ["td": 2, "bs": 3, "cs": 4, "bs4k": 23, "cs4k": 24]
    public static let broadcastingLabel: [String: String] = [
        "td": "地上デジタル", "bs": "BS", "cs": "CS", "bs4k": "BS4K", "cs4k": "CS4K",
    ]

    public static let epgFiles: [String: String] = [
        "td": "EPG_TRDEPG_FILE.dat",
        "bs": "EPG_BSEPG_FILE.dat",
        "cs": "EPG_CSEPG_FILE.dat",
        "bs4k": "EPG_ADVBSDEPG_FILE.dat",
        "cs4k": "EPG_ADVCSDEPG_FILE.dat",
    ]
    public static let logoFiles: [String: String] = [
        "td": "EPG_TRDLOGO_FILE.dat",
        "bs": "EPG_BSLOGO_FILE.dat",
        "cs": "EPG_CSLOGO_FILE.dat",
        "bs4k": "EPG_ADVBSDLOGO_FILE.dat",
        "cs4k": "EPG_ADVCSDLOGO_FILE.dat",
    ]

    /// `desiredQualityMode` (録画モード): what this recorder offers.
    public static let quality: [String: Int] = [
        "DR": 100, "XR": 210, "XSR": 220, "SR": 230, "LSR": 240, "LR": 250, "ER": 260, "EER": 270,
    ]
    /// Modes other generations report: 3倍 on early machines, AVC for dubbed titles. Decoded, never offered.
    public static let qualityElsewhere: [String: Int] = ["3x": 101, "AVC": 500]
    public static let qualityLabel: [String: String] = [
        "DR": "DR(高画質)", "XR": "XR", "XSR": "XSR", "SR": "SR(標準)", "LSR": "LSR", "LR": "LR", "ER": "ER",
        "EER": "EER(長時間)", "3x": "3倍", "AVC": "AVC",
    ]

    /// `scheduledConditionID` (毎回録画).
    public static let repeatCodes: [String: String] = [
        "none": "1", "title": "S001", "daily": "d",
        "mon": "w1", "tue": "w2", "wed": "w3", "thu": "w4", "fri": "w5", "sat": "w6", "sun": "w7",
        "mon-fri": "w15", "mon-sat": "w16",
    ]
    public static let repeatLabel: [String: String] = [
        "none": "しない", "title": "番組名", "daily": "毎日", "mon": "毎週(月)", "tue": "毎週(火)", "wed": "毎週(水)",
        "thu": "毎週(木)", "fri": "毎週(金)", "sat": "毎週(土)", "sun": "毎週(日)", "mon-fri": "月−金", "mon-sat": "月−土",
    ]
    /// Index matches the day of week, Monday first, as the weekly repeat codes do.
    public static let weekdayRepeat = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    /// ARIB STD-B10 content_nibble_level_1.
    public static let genreLabel: [Int: String] = [
        0x0: "ニュース／報道", 0x1: "スポーツ", 0x2: "情報／ワイドショー", 0x3: "ドラマ", 0x4: "音楽", 0x5: "バラエティ",
        0x6: "映画", 0x7: "アニメ／特撮", 0x8: "ドキュメンタリー／教養", 0x9: "劇場／公演", 0xA: "趣味／教育", 0xB: "福祉",
        0xE: "拡張", 0xF: "その他",
    ]

    /// ARIB STD-B10 content_nibble_level_2, the sub-genre within each level-1 genre.
    ///
    /// Checked entry by entry against ARIB STD-B10 version 5.13-E1, Annex H (2026-09-20): every one of the
    /// 104 codes the standard names is here and says the same thing. It also matches what the recorder
    /// does -- codes the standard leaves unused are absent here, and the recorder composes nothing for them
    /// either.
    public static let subGenreLabel: [Int: [Int: String]] = [
        0x0: [0x0: "定時・総合", 0x1: "天気", 0x2: "特集・ドキュメント", 0x3: "政治・国会", 0x4: "経済・市況", 0x5: "海外・国際", 0x6: "解説", 0x7: "討論・会談", 0x8: "報道特番", 0x9: "ローカル・地域", 0xA: "交通", 0xF: "その他"],
        0x1: [0x0: "スポーツニュース", 0x1: "野球", 0x2: "サッカー", 0x3: "ゴルフ", 0x4: "その他の球技", 0x5: "相撲・格闘技", 0x6: "オリンピック・国際大会", 0x7: "マラソン・陸上・水泳", 0x8: "モータースポーツ", 0x9: "マリン・ウィンタースポーツ", 0xA: "競馬・公営競技", 0xF: "その他"],
        0x2: [0x0: "芸能・ワイドショー", 0x1: "ファッション", 0x2: "暮らし・住まい", 0x3: "健康・医療", 0x4: "ショッピング・通販", 0x5: "グルメ・料理", 0x6: "イベント", 0x7: "番組紹介・お知らせ", 0xF: "その他"],
        0x3: [0x0: "国内ドラマ", 0x1: "海外ドラマ", 0x2: "時代劇", 0xF: "その他"],
        0x4: [0x0: "国内ロック・ポップス", 0x1: "海外ロック・ポップス", 0x2: "クラシック・オペラ", 0x3: "ジャズ・フュージョン", 0x4: "歌謡曲・演歌", 0x5: "ライブ・コンサート", 0x6: "ランキング・リクエスト", 0x7: "カラオケ・のど自慢", 0x8: "民謡・邦楽", 0x9: "童謡・キッズ", 0xA: "民族音楽・ワールドミュージック", 0xF: "その他"],
        0x5: [0x0: "クイズ", 0x1: "ゲーム", 0x2: "トークバラエティ", 0x3: "お笑い・コメディ", 0x4: "音楽バラエティ", 0x5: "旅バラエティ", 0x6: "料理バラエティ", 0xF: "その他"],
        0x6: [0x0: "洋画", 0x1: "邦画", 0x2: "アニメ", 0xF: "その他"],
        0x7: [0x0: "国内アニメ", 0x1: "海外アニメ", 0x2: "特撮", 0xF: "その他"],
        0x8: [0x0: "社会・時事", 0x1: "歴史・紀行", 0x2: "自然・動物・環境", 0x3: "宇宙・科学・医学", 0x4: "カルチャー・伝統文化", 0x5: "文学・文芸", 0x6: "スポーツ", 0x7: "ドキュメンタリー全般", 0x8: "インタビュー・討論", 0xF: "その他"],
        0x9: [0x0: "現代劇・新劇", 0x1: "ミュージカル", 0x2: "ダンス・バレエ", 0x3: "落語・演芸", 0x4: "歌舞伎・古典", 0xF: "その他"],
        0xA: [0x0: "旅・釣り・アウトドア", 0x1: "園芸・ペット・手芸", 0x2: "音楽・美術・工芸", 0x3: "囲碁・将棋", 0x4: "麻雀・パチンコ", 0x5: "車・オートバイ", 0x6: "コンピュータ・TVゲーム", 0x7: "会話・語学", 0x8: "幼児・小学生", 0x9: "中学生・高校生", 0xA: "大学生・受験", 0xB: "生涯教育・資格", 0xC: "教育問題", 0xF: "その他"],
        0xB: [0x0: "高齢者", 0x1: "障害者", 0x2: "社会福祉", 0x3: "ボランティア", 0x4: "手話", 0x5: "文字(字幕)", 0x6: "音声解説", 0xF: "その他"],
        // The extension area: the sub-genre says which kind of broadcast the user_nibble after it belongs
        // to. Not a genre anybody watches -- it is here so that the table is the whole table.
        0xE: [0x0: "BS/地上デジタル放送用番組付属情報", 0x1: "広帯域CSデジタル放送用拡張", 0x3: "サーバー型番組付属情報", 0x4: "IP放送用番組付属情報"],
    ]

    /// The sub-genre's name, or nil for a whole-genre condition or a code the standard does not use.
    public static func subGenre(level1: Int?, level2: Int?) -> String? {
        guard let level1, let level2 else { return nil }
        return subGenreLabel[level1]?[level2]
    }

    /// The order to offer these in. The vectors pin the codes; this is only how they are listed.
    /// おまかせ・まる録 vocabularies seen on a real recorder; anything else is shown as it is.
    public static let ruleLogicLabel: [String: String] = ["OR": "いずれかのキーワードを含む", "AND": "すべてのキーワードを含む"]
    public static let timeScopeLabel: [String: String] = [
        "ALL": "すべての時間帯", "MORNING": "朝", "AFTERNOON": "昼", "NIGHT": "夜", "MIDNIGHT": "深夜",
    ]
    public static let broadcastingScopeLabel: [String: String] = [
        "ALL": "すべての放送", "TRD": "地上放送", "BSD": "BS放送", "CSD": "CS放送",
        "ADVBSD": "BS4K放送", "ADVCSD": "CS4K放送",
    ]
    /// The 4K waves, whose recording quality lives in its own element on a condition.
    public static let advancedScopes = ["ADVBSD", "ADVCSD"]

    public static let broadcastingOrder = ["td", "bs", "cs", "bs4k", "cs4k"]
    public static let qualityOrder = ["DR", "XR", "XSR", "SR", "LSR", "LR", "ER", "EER"]

    /// The weekly repeat that matches a date. The recorder takes a weekday code, and the server refuses one
    /// that is not the programme's own weekday, so this is the only weekly option worth offering.
    public static func weekdayRepeat(for date: Date, timeZone: TimeZone = RecorderTime.timeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let weekday = calendar.component(.weekday, from: date)   // 1 = Sunday
        return weekdayRepeat[(weekday + 5) % 7]
    }

    public static func broadcasting(code: Int) -> String? {
        broadcasting.first { $0.value == code }?.key
    }

    public static func quality(code: Int) -> String? {
        (quality.first { $0.value == code } ?? qualityElsewhere.first { $0.value == code })?.key
    }

    public static func repeatName(code: String) -> String? {
        repeatCodes.first { $0.value == code }?.key
    }

    /// `genreID` on reservations and recordings: ARIB content nibbles as level1 * 16 + level2.
    public static func genreLevels(_ genreCode: Int) -> (level1: Int, level2: Int) {
        (genreCode / 16, genreCode % 16)
    }
}

/// Where the recorder listens and what its UPnP services are called.
public enum Upnp {
    public static let port = 64220
    public static let defaultStreamPort = 60151
    public static let ssdpAddress = "239.255.255.250"
    public static let ssdpPort = 1900

    public static let xsrsService = "urn:schemas-xsrs-org:service:X_ScheduledRecording:2"
    public static let pvrService = "urn:schemas-s-bras-org:service:X_PvrControl:1"
    public static let contentDirectoryService = "urn:schemas-upnp-org:service:ContentDirectory:1"
    public static let xsrsMetadataNamespace = "urn:schemas-xsrs-org:metadata-1-0/x_srs/"

    public static let xsrsControlURL = "/XSRS"
    public static let pvrControlURL = "/X_PvrControl"
    public static let contentDirectoryControlURL = "/DMSContentDirectory"
}
