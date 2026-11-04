import Foundation

/// Finds characters that commonly get lost or garbled when a list travels through CSV/EDL/marker imports.
public enum CharacterCheck {
    public static let umlauts: Set<Character> = ["ä", "ö", "ü", "Ä", "Ö", "Ü", "ß"]

    public struct Finding: Equatable {
        public var umlauts: [Character] = []
        public var special: [Character] = []
        public var damaged = false
        public var isEmpty: Bool { umlauts.isEmpty && special.isEmpty && !damaged }
    }

    private static let mojibake = try! NSRegularExpression(pattern: "Ã[\\u0080-\\u00BF\\u0152-\\u0178\\u201A-\\u203A]|â€|Â[\\u00A0-\\u00BF]")

    public static func analyze(_ s: String) -> Finding {
        var f = Finding()
        var seenU = Set<Character>(), seenS = Set<Character>()
        for ch in s {
            if umlauts.contains(ch) {
                if seenU.insert(ch).inserted { f.umlauts.append(ch) }
                continue
            }
            if ch == "\u{FFFD}" { f.damaged = true }
            let isPlain = ch.unicodeScalars.allSatisfy { ($0.value >= 0x20 && $0.value < 0x7F) || $0 == "\n" || $0 == "\t" }
            if !isPlain, seenS.insert(ch).inserted { f.special.append(ch) }
        }
        if mojibake.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil { f.damaged = true }
        return f
    }

    /// Human readable name for a character, making invisible ones visible.
    public static func describe(_ ch: Character) -> String {
        let scalars = ch.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
        switch ch {
        case "\u{00A0}": return "geschütztes Leerzeichen (\(scalars))"
        case "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{2060}": return "unsichtbares Zeichen (\(scalars))"
        case "\u{FFFD}": return "Ersatzzeichen � (\(scalars))"
        case "\r", "\r\n": return "Wagenrücklauf (\(scalars))"
        default:
            if ch.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7F..<0xA0).contains($0.value) }) { return "Steuerzeichen (\(scalars))" }
            if ch.isWhitespace { return "Sonder-Leerzeichen (\(scalars))" }
            return "„\(ch)“"
        }
    }

    static let typographic: [Character: String] = [
        "„": "\"", "“": "\"", "”": "\"", "«": "\"", "»": "\"", "‚": "'", "‘": "'", "’": "'", "‹": "'", "›": "'",
        "–": "-", "—": "-", "‒": "-", "−": "-", "…": "...", "\u{00A0}": " ", "\u{2009}": " ", "\u{202F}": " ", "\u{2002}": " ", "\u{2003}": " ",
        "\u{200B}": "", "\u{200C}": "", "\u{200D}": "", "\u{FEFF}": "", "\u{2060}": "", "\r": "", "\r\n": "\n",
    ]

    /// Replaces typographic quotes, dashes, ellipsis, special spaces and removes invisible/control characters.
    public static func replacingTypographic(_ s: String) -> String {
        var out = ""
        for ch in s {
            if let r = typographic[ch] { out += r; continue }
            if ch.unicodeScalars.contains(where: { ($0.value < 0x20 && $0 != "\n" && $0 != "\t") || (0x7F..<0xA0).contains($0.value) }) { continue }
            out.append(ch)
        }
        return out
    }

    /// ä → ae, ß → ss, é → e … (full ASCII transliteration).
    public static func transliterated(_ s: String) -> String {
        var t = replacingTypographic(s)
        for (a, b) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("Ä", "Ae"), ("Ö", "Oe"), ("Ü", "Ue"), ("ß", "ss")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? t
    }

    /// Repairs UTF-8 text that was decoded as Windows-1252/Latin-1 ("FÃ¼r" → "Für"). Returns nil if not applicable.
    public static func repairedMojibake(_ s: String) -> String? {
        for enc in [String.Encoding.windowsCP1252, .isoLatin1] {
            if let data = s.data(using: enc), let fixed = String(data: data, encoding: .utf8), fixed != s { return fixed }
        }
        return nil
    }
}
