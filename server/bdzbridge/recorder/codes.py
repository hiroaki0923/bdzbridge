"""Code tables of the recorder's XSRS API, verified on BDZ-FBT4100 (docs/xsrs-api.md)."""
from __future__ import annotations

# broadcastingType as used in scheduledChannelID and in the EPG file names.
BROADCASTING = {
    "td": 2,    # 地上デジタル
    "bs": 3,    # BSデジタル
    "cs": 4,    # 110度CS
    "bs4k": 23,
    "cs4k": 24,
}
BROADCASTING_BY_CODE = {v: k for k, v in BROADCASTING.items()}
BROADCASTING_LABEL = {"td": "地上デジタル", "bs": "BS", "cs": "CS", "bs4k": "BS4K", "cs4k": "CS4K"}

EPG_FILES = {
    "td": "EPG_TRDEPG_FILE.dat",
    "bs": "EPG_BSEPG_FILE.dat",
    "cs": "EPG_CSEPG_FILE.dat",
    "bs4k": "EPG_ADVBSDEPG_FILE.dat",
    "cs4k": "EPG_ADVCSDEPG_FILE.dat",
}
LOGO_FILES = {
    "td": "EPG_TRDLOGO_FILE.dat",
    "bs": "EPG_BSLOGO_FILE.dat",
    "cs": "EPG_CSLOGO_FILE.dat",
    "bs4k": "EPG_ADVBSDLOGO_FILE.dat",
    "cs4k": "EPG_ADVCSDLOGO_FILE.dat",
}

# desiredQualityMode (録画モード)
# desiredQualityMode (録画モード): what this recorder offers, in menu order. The API accepts these names.
QUALITY = {"DR": 100, "XR": 210, "XSR": 220, "SR": 230, "LSR": 240, "LR": 250, "ER": 260, "EER": 270}
# Modes other generations report, from the official client's table: 3倍 on early machines, AVC for dubbed
# titles. Decoded when a recorder sends them, never offered, because this recorder has no such mode.
QUALITY_ELSEWHERE = {"3x": 101, "AVC": 500}
QUALITY_CODE = {**QUALITY, **QUALITY_ELSEWHERE}
QUALITY_BY_CODE = {v: k for k, v in QUALITY_CODE.items()}
QUALITY_LABEL = {"DR": "DR(高画質)", "XR": "XR", "XSR": "XSR", "SR": "SR(標準)", "LSR": "LSR", "LR": "LR", "ER": "ER", "EER": "EER(長時間)",
                 "3x": "3倍", "AVC": "AVC"}

# scheduledConditionID (毎回録画)
REPEAT = {
    "none": "1",       # しない
    "title": "S001",   # 番組名（シリーズ追従）
    "daily": "d",      # 毎日
    "mon": "w1", "tue": "w2", "wed": "w3", "thu": "w4", "fri": "w5", "sat": "w6", "sun": "w7",
    "mon-fri": "w15",
    "mon-sat": "w16",
}
REPEAT_BY_CODE = {v: k for k, v in REPEAT.items()}
REPEAT_LABEL = {
    "none": "しない", "title": "番組名", "daily": "毎日", "mon": "毎週(月)", "tue": "毎週(火)", "wed": "毎週(水)",
    "thu": "毎週(木)", "fri": "毎週(金)", "sat": "毎週(土)", "sun": "毎週(日)", "mon-fri": "月−金", "mon-sat": "月−土",
}
WEEKDAY_REPEAT = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]  # index = datetime.weekday()

# ARIB STD-B10 content_nibble_level_1
GENRE_LABEL = {
    0x0: "ニュース／報道", 0x1: "スポーツ", 0x2: "情報／ワイドショー", 0x3: "ドラマ", 0x4: "音楽", 0x5: "バラエティ",
    0x6: "映画", 0x7: "アニメ／特撮", 0x8: "ドキュメンタリー／教養", 0x9: "劇場／公演", 0xA: "趣味／教育", 0xB: "福祉",
    0xE: "拡張", 0xF: "その他",
}

# おまかせ・まる録, the recorder's own keyword conditions: the vocabularies seen on a real recorder. Anything else the
# recorder reports is shown as it is, since only these values have been observed (docs/xsrs-api.md).
RULE_LOGIC_LABEL = {"OR": "いずれかのキーワードを含む", "AND": "すべてのキーワードを含む"}
TIME_SCOPE_LABEL = {"ALL": "すべての時間帯", "MORNING": "朝", "AFTERNOON": "昼", "NIGHT": "夜", "MIDNIGHT": "深夜"}
BROADCASTING_SCOPE_LABEL = {"ALL": "すべての放送", "TRD": "地上放送", "BSD": "BS放送", "CSD": "CS放送",
                            "ADVBSD": "BS4K放送", "ADVCSD": "CS4K放送"}
