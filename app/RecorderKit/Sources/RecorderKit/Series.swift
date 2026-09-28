import Foundation
import os

/// Groups recordings into programmes by their titles.
///
/// The recorder never says which reservation produced a recording, so episodes of one programme can only be
/// recognised from their names: broadcast marks are dropped, the text is cut at the first episode marker
/// (第３話, ＃１２, （３５）, 後編, and for sport 第３戦, １０日目, 決勝 …) or, failing that, at the first subtitle
/// separator, and what is left is normalised into a key. Ported from the server; docs/port/series.json pins
/// down every case.
public enum Series {
    /// The part of a title that names the programme, for showing to the reader.
    public static func name(_ title: String) -> String { remembered(title).name }

    /// The grouping key: NFKC, lower-cased, without spaces, so サンプルドラマ and サンプルドラマ group together.
    public static func key(_ title: String) -> String { remembered(title).key }

    /// What `name` and `key` are made from, worked out afresh.
    private static func programmeName(_ title: String) -> String {
        let cleaned = clean(title)
        var text = cleaned

        if let episode = firstRange(of: episodeMarker, in: text) {
            // a title that begins with its episode number names nothing else, so it is kept whole
            if episode.lowerBound != text.startIndex {
                text = String(text[text.startIndex..<episode.lowerBound])
                // ▽ and ▼ introduce a subtitle; what sits between it and the number is not the name either
                if let topic = firstRange(of: topics, in: text) {
                    text = String(text[text.startIndex..<topic.lowerBound])
                }
            }
        } else {
            let pieces = split(text, by: separators)
            if pieces.count >= 2, !trimmed(String(text[pieces[0]])).isEmpty {
                var head = String(text[pieces[0]])
                // a generic prefix (アニメ, 映画 …) names nothing on its own: keep the next segment too
                if trimmed(head).unicodeScalars.count <= 4, !trimmed(String(text[pieces[1]])).isEmpty {
                    head = String(text[text.startIndex..<pieces[1].upperBound])
                }
                text = head
            }
            text = dropSubtitleBrackets(text)
        }

        text = trimmed(replacingMatches(of: trailing, in: text))
        // an opener without its closer means the cut landed inside a bracket: drop that bracket
        for (opener, closer) in openers where text.filter({ $0 == opener }).count > text.filter({ $0 == closer }).count {
            if let last = text.lastIndex(of: opener) {
                let candidate = trimmed(String(text[text.startIndex..<last]))
                if !candidate.isEmpty { text = candidate }
            }
        }

        if !text.isEmpty { return text }
        return cleaned.isEmpty ? title : cleaned
    }

    /// Key for "the same programme title", ignoring marks and spacing. Copies of one broadcast share it.
    public static func sameTitleKey(_ title: String) -> String {
        replacingMatches(of: allSpaces, in: Search.normalise(clean(title)))
    }

    /// Programme descriptions compared loosely: marks, spaces and re-broadcast notes ignored.
    public static func summaryKey(_ summary: String?) -> String {
        var text = Search.normalise(clean(summary ?? ""))
        text = replacingMatches(of: rebroadcastNote, in: text)
        text = replacingMatches(of: allSpaces, in: text)
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(200)))
    }

    /// Broadcast marks and private-use characters removed.
    static func clean(_ title: String) -> String {
        trimmed(replacingMatches(of: marks, in: replacingMatches(of: privateUse, in: title)))
    }

    // MARK: - remembering

    /// A title's name and key, worked out once.
    ///
    /// They are asked for far more often than titles change: the recordings screen groups every recording
    /// each time it is drawn, and a programme's sheet picks its episodes out of all of them each time it is,
    /// which is every tick in its selection. Each answer is half a dozen regular expressions and an NFKC
    /// pass; for 1,300 recordings that came to 35 ms a grouping and 20 ms a sheet's picking out, on a Mac.
    /// The answer depends on nothing but the title, so it can be kept.
    private struct Remembered: Sendable {
        let name: String
        let key: String
    }

    /// Titles are the recorder's list of recordings, a few thousand at most, and a title deleted there stays
    /// here. Starting again at the limit keeps that from growing for as long as the app runs, at the cost of
    /// working the rest out again once.
    static let rememberLimit = 8192

    private static let memo = OSAllocatedUnfairLock(initialState: [String: Remembered]())

    private static func remembered(_ title: String) -> Remembered {
        if let known = memo.withLock({ $0[title] }) { return known }
        // Worked out outside the lock, so that two threads grouping at once do not queue behind each other's
        // expressions. Both may work out the same title; they arrive at the same answer.
        let name = programmeName(title)
        let found = Remembered(name: name, key: replacingMatches(of: anyWhitespace, in: Search.normalise(name)))
        memo.withLock { memo in
            if memo.count >= rememberLimit { memo.removeAll(keepingCapacity: true) }
            memo[title] = found
        }
        return found
    }

    /// For the tests: whether a title's answer is being kept, and how many are kept.
    static func isRemembered(_ title: String) -> Bool { memo.withLock { $0[title] != nil } }
    static var rememberedCount: Int { memo.withLock { $0.count } }

    // MARK: - the pieces

    /// Frames whose 「…」 part is the programme itself, as in 日曜劇場「ＳＡＭＰＬＥ」, not an episode subtitle.
    static let frames: Set<String> = [
        "日曜劇場", "土曜ドラマ", "金曜ドラマ", "木曜劇場", "火曜ドラマ", "水曜ドラマ", "月曜ドラマ", "連続テレビ小説",
        "大河ドラマ", "夜ドラ", "ドラマ１０", "ドラマ10", "プレミアムドラマ", "土曜時代ドラマ", "アニメ", "映画", "シネマ",
        "特集ドラマ", "スペシャルドラマ",
    ]

    static let openers: [(Character, Character)] = [
        ("「", "」"), ("『", "』"), ("【", "】"), ("（", "）"), ("(", ")"), ("〔", "〕"),
    ]

    private static let privateUse = pattern("[\u{E000}-\u{F8FF}]")
    private static let marks = pattern(
        #"\[(?:字|解|再|新|終|デ|二|多|SS|映|生|手|4K|HDR|5\.1|7\.1|22\.2|3D|2K|8K)\]"#
        + "|[［【＜（](?:字|解|再|新|終|初|デ|二|多|双|映|生|手|吹|声|無料|無|料|鍵|天|交|販|演|他|前|後|HV|SD|SS|PPV|MV|W|[SBNPＳＢＮＰ])[］】＞）]")
    private static let episodeMarker = pattern(
        "(?:"
        + "第\\s*[0-9０-９〇一二三四五六七八九十百]+\\s*(?:話|回|夜|章|部|集|弾|幕|箱|日目|日|週|戦)"
        + "|[#＃♯]\\s*[0-9０-９]+"
        + "|[（(]\\s*[0-9０-９]+\\s*[)）]"
        + "|(?<![0-9０-９])[0-9０-９]{1,3}\\s*(?:話|回戦|回目?|日目)(?![0-9０-９])"
        + "|(?<![a-zA-Z])(?:ep|episode|season)(?![a-zA-Z])|シーズン|前[編篇]|後[編篇]|総集[編篇]|最終[回話戦節日]"
        + "|初戦|初回|初日(?!の出)|開幕戦|千秋楽|準々決勝|準決勝|決勝"
        + ")",
        caseInsensitive: true)
    private static let separators = pattern("[\u{3000}▽▼▲△◆◇■□●○★☆※…：／｜～〜]")
    private static let topics = pattern("[▽▼]")
    private static let trailing = pattern(#"[\s\#(spaceIdeographic)\-－‐–—・･、,，。．.「『【〔（(\[]+$"#)
    private static let anyWhitespace = pattern(#"\s+"#)
    private static let allSpaces = pattern("[\\s\u{3000}]+")
    private static let rebroadcastNote = pattern(#"[（(]?再放送[)）]?|\[再\]"#)
    private static let spaceIdeographic = "\u{3000}"

    // MARK: - regex plumbing

    /// The patterns are constants that the tests exercise, so a bad one is a programming error, not input.
    private static func pattern(_ source: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: source, options: caseInsensitive ? [.caseInsensitive] : [])
        } catch {
            preconditionFailure("bad pattern \(source): \(error)")
        }
    }

    private static func firstRange(of regex: NSRegularExpression, in text: String) -> Range<String.Index>? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return Range(match.range, in: text)
    }

    private static func replacingMatches(of regex: NSRegularExpression, in text: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// The pieces between matches, including the empty ones, the way a split does.
    private static func split(_ text: String, by regex: NSRegularExpression) -> [Range<String.Index>] {
        var pieces: [Range<String.Index>] = []
        var start = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            pieces.append(start..<range.lowerBound)
            start = range.upperBound
        }
        pieces.append(start..<text.endIndex)
        return pieces
    }

    private static func dropSubtitleBrackets(_ text: String) -> String {
        guard let opener = text.firstIndex(of: "「"),
              text.distance(from: text.startIndex, to: opener) >= 2 else { return text }
        let head = trimmed(String(text[text.startIndex..<opener]))
        let lastSegment = head.components(separatedBy: spaceIdeographic).last ?? head
        guard frames.contains(head) || frames.contains(lastSegment) else { return head }
        guard let closer = text[opener...].firstIndex(of: "」"), closer != text.startIndex else { return text }
        return String(text[text.startIndex...closer])
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
