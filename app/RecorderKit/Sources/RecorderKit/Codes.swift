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

    /// `desiredQualityMode` (録画モード).
    public static let quality: [String: Int] = [
        "DR": 100, "XR": 210, "XSR": 220, "SR": 230, "LSR": 240, "LR": 250, "ER": 260, "EER": 270,
    ]
    public static let qualityLabel: [String: String] = [
        "DR": "DR(高画質)", "XR": "XR", "XSR": "XSR", "SR": "SR(標準)", "LSR": "LSR", "LR": "LR", "ER": "ER",
        "EER": "EER(長時間)",
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

    public static func broadcasting(code: Int) -> String? {
        broadcasting.first { $0.value == code }?.key
    }

    public static func quality(code: Int) -> String? {
        quality.first { $0.value == code }?.key
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
