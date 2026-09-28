import Foundation

/// ARIB additional symbols, which the recorder delivers as private-use code points. Most phone fonts have no
/// glyphs for them, so they are spelled out. See docs/epg-format.md.
public enum Arib {
    public static let symbols: [Unicode.Scalar: String] = [
        scalar(0xE0FD): "[手]", scalar(0xE0FE): "[字]", scalar(0xE180): "[デ]", scalar(0xE182): "[二]",
        scalar(0xE183): "[多]", scalar(0xE184): "[解]", scalar(0xE185): "[SS]", scalar(0xE18C): "[映]",
        scalar(0xE192): "[再]", scalar(0xE193): "[新]", scalar(0xE195): "[終]", scalar(0xE196): "[生]",
        // Broadcast symbols that Unicode encodes at U+1F19B..U+1F1AC.
        scalar(0x1F19B): "[3D]", scalar(0x1F19C): "[2nd]", scalar(0x1F19D): "[2K]", scalar(0x1F19E): "[4K]",
        scalar(0x1F19F): "[8K]", scalar(0x1F1A0): "[5.1]", scalar(0x1F1A1): "[7.1]", scalar(0x1F1A2): "[22.2]",
        scalar(0x1F1A3): "[60P]", scalar(0x1F1A4): "[120P]", scalar(0x1F1A5): "[d]", scalar(0x1F1A6): "[HC]",
        scalar(0x1F1A7): "[HDR]", scalar(0x1F1A8): "[Hi-Res]", scalar(0x1F1A9): "[LOSSLESS]", scalar(0x1F1AA): "[SHV]",
        scalar(0x1F1AB): "[UHD]", scalar(0x1F1AC): "[VOD]",
    ]

    private static func scalar(_ value: UInt32) -> Unicode.Scalar {
        Unicode.Scalar(value)!
    }

    /// Text as it should be shown: NUL padding and C0 controls dropped, ARIB symbols spelled out, and any
    /// remaining private-use characters removed because no font would render them.
    public static func clean(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            if let replacement = symbols[scalar] {
                out += replacement
            } else if (0xE000...0xF8FF).contains(scalar.value) {
                continue
            } else if scalar.value < 32, scalar != "\n" {
                continue
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum Search {
    /// The form search text is stored and compared in: NFKC, then lower-cased, so that ＳＡＭＰＬＥ, SAMPLE and
    /// サンプルドラマ all match each other. The server case-folds instead, which differs only for a few Latin letters
    /// that do not appear in a Japanese guide.
    public static func normalise(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
    }

    /// Where the title ends and where the short description ends in a programme's search text. Control
    /// characters, because `Arib.clean` takes every one of them out of the guide's text except the newline,
    /// so neither can turn up inside a field, and words cannot be found straddling two fields.
    static let titleEnd = "\u{1E}"
    static let summaryEnd = "\u{1F}"

    /// What a programme is searched by: its title, its short description and its details, in that order and
    /// kept apart, so that the store can tell which of the three a word was found in. The details are where
    /// the broadcasters list the cast, and for most programmes that is the only place the names appear.
    static func text(title: String, summary: String, extended: String) -> String {
        normalise(title + titleEnd + summary + summaryEnd + extended)
    }

    /// The words a query is made of, normalised. A programme has to contain every one of them, anywhere in
    /// its text, so a word added narrows the results. Control characters are dropped: a separator typed in
    /// would otherwise let a word run from one field into the next.
    public static func terms(_ query: String) -> [String] {
        let cleaned = String(String.UnicodeScalarView(normalise(query).unicodeScalars.filter { $0.value >= 0x20 }))
        return cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Whether `text` has every word of `query` in it, compared the way the guide's search compares them, so
    /// that what matches in one of the app's lists matches in the others.
    public static func matches(_ query: String, in text: String) -> Bool {
        let normalised = normalise(text)
        return terms(query).allSatisfy { normalised.contains($0) }
    }

    /// A LIKE pattern that finds `term` as typed. `%` and `_` are LIKE's wildcards, and without the escape a
    /// search for 100% matched 1000 and a search for a_b matched anything with a and b one character apart.
    /// The statement has to say `ESCAPE '\'`.
    static func likePattern(_ term: String) -> String {
        var escaped = ""
        for character in term {
            if character == "\\" || character == "%" || character == "_" { escaped.append("\\") }
            escaped.append(character)
        }
        return "%" + escaped + "%"
    }

    /// The words around what a search found, as the programme's text has them, cut into three so that the
    /// part found can be set apart. `before` starts with an ellipsis when the text went on before it, and
    /// `after` ends with one when the text goes on.
    public struct Snippet: Sendable, Hashable {
        public var before: String
        public var match: String
        public var after: String

        public init(before: String, match: String, after: String) {
            self.before = before
            self.match = match
            self.after = after
        }
    }

    /// A line's worth of `text` around the first place `term` appears, for a programme found in its details:
    /// nothing else on a result's row would show why it is there. The details run to several lines, which are
    /// joined with spaces so that the snippet reads on one. The start of the line found in is kept when it is
    /// near, which is where a label such as 出演： sits, and so is a heading on the line before it, which is
    /// how 出演者 stands on its own. nil when the term is not in the text.
    ///
    /// The text is matched normalised, the way the search matched it, but what is given back is the text as
    /// broadcast: a query in half-width letters shows the full-width ones the broadcaster sent.
    public static func snippet(of term: String, in text: String, before: Int = 10,
                               after: Int = 40) -> Snippet? {
        let needle = normalise(term)
        let wanted = Array(needle)
        guard !wanted.isEmpty else { return nil }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { Array($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
        // Normalising a line at a time finds the line; only that one is walked a character at a time.
        guard let found = lines.firstIndex(where: { normalise(String($0)).contains(needle) }),
              let within = range(of: wanted, in: lines[found])
        else { return nil }

        var characters: [Character] = []
        var lineStart = 0
        for (index, line) in lines.enumerated() {
            if index > 0 { characters.append(" ") }
            if index == found { lineStart = characters.count }
            characters += line
        }
        let matchStart = lineStart + within.lowerBound
        let matchEnd = lineStart + within.upperBound
        var start = matchStart - before
        if matchStart - lineStart <= 2 * before {
            start = lineStart
            if found > 0, isHeading(lines[found - 1], within: before) { start -= lines[found - 1].count + 1 }
        }
        start = max(0, start)
        let end = min(characters.count, matchEnd + after)
        return Snippet(before: (start > 0 ? "…" : "") + String(characters[start..<matchStart]),
                       match: String(characters[matchStart..<matchEnd]),
                       after: String(characters[matchEnd..<end]) + (end < characters.count ? "…" : ""))
    }

    /// A line short enough to be a heading and not a sentence: 出演者 is one, 海辺の町の話。 is not.
    private static func isHeading(_ line: [Character], within length: Int) -> Bool {
        guard line.count <= length, let last = line.last else { return false }
        return !"。．.！!？?".contains(last)
    }

    /// Where `wanted`, already normalised, falls in `line`, counted in the line's own characters. Each
    /// character is normalised on its own and remembered as the owner of what it became, since NFKC can make
    /// one character of two (ｶﾞ is ガ) or two of one (㍻ is 平成), and the line as shown is the one not normalised.
    private static func range(of wanted: [Character], in line: [Character]) -> Range<Int>? {
        var normalised: [Character] = []
        var owner: [Int] = []
        for (index, character) in line.enumerated() {
            for piece in normalise(String(character)) {
                normalised.append(piece)
                owner.append(index)
            }
        }
        guard wanted.count <= normalised.count else { return nil }
        for offset in 0...(normalised.count - wanted.count)
        where normalised[offset..<offset + wanted.count].elementsEqual(wanted) {
            return owner[offset]..<(owner[offset + wanted.count - 1] + 1)
        }
        return nil
    }
}
