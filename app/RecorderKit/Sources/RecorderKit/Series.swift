import Foundation

/// Groups recordings into programmes by their titles.
///
/// The recorder never says which reservation produced a recording, so episodes of one programme can only be
/// recognised from their names: broadcast marks are dropped, the text is cut at the first episode marker
/// (第３話, ＃１２, （３５）, 後編 …) or, failing that, at the first subtitle separator, and what is left is
/// normalised into a key. Ported from the server; docs/port/series.json pins down every case.
public enum Series {
    /// The part of a title that names the programme, for showing to the reader.
    public static func name(_ title: String) -> String {
        let cleaned = clean(title)
        var text = cleaned

        if let episode = firstRange(of: episodeMarker, in: text) {
            // a title that begins with its episode number names nothing else, so it is kept whole
            if episode.lowerBound != text.startIndex {
                text = String(text[text.startIndex..<episode.lowerBound])
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

    /// The grouping key: NFKC, lower-cased, without spaces, so ＳＡＭＰＬＥ and SAMPLE group together.
    public static func key(_ title: String) -> String {
        replacingMatches(of: anyWhitespace, in: Search.normalise(name(title)))
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

    // MARK: - the pieces

    /// Frames whose 「…」 part is the programme itself, as in 日曜劇場「サンプルドラマ」, not an episode subtitle.
    static let frames: Set<String> = [
        "日曜劇場", "土曜ドラマ", "金曜ドラマ", "木曜劇場", "火曜ドラマ", "水曜ドラマ", "月曜ドラマ", "連続テレビ小説",
        "大河ドラマ", "夜ドラ", "ドラマ１０", "ドラマ10", "プレミアムドラマ", "土曜時代ドラマ", "アニメ", "映画", "シネマ",
        "特集ドラマ", "スペシャルドラマ",
    ]

    static let openers: [(Character, Character)] = [
        ("「", "」"), ("『", "』"), ("【", "】"), ("（", "）"), ("(", ")"), ("〔", "〕"),
    ]

    private static let privateUse = pattern("[\u{E000}-\u{F8FF}]")
    private static let marks = pattern(#"\[(?:字|解|再|新|終|デ|二|多|SS|映|生|手|4K|HDR|5\.1|7\.1|22\.2|3D|2K|8K)\]"#)
    private static let episodeMarker = pattern(
        "(?:"
        + "第\\s*[0-9０-９〇一二三四五六七八九十百]+\\s*(?:話|回|夜|章|部|集|弾|幕|日目|週)"
        + "|[#＃]\\s*[0-9０-９]+"
        + "|[（(]\\s*[0-9０-９]+\\s*[)）]"
        + "|(?<![0-9０-９])[0-9０-９]{1,3}\\s*(?:話|回目?)(?![0-9０-９])"
        + "|(?<![a-zA-Z])(?:ep|episode|season)(?![a-zA-Z])|シーズン|前編|後編|総集編|最終回"
        + ")",
        caseInsensitive: true)
    private static let separators = pattern("[\u{3000}▽▼▲△◆◇■□●○★☆※…：／｜～〜]")
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
