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
}
