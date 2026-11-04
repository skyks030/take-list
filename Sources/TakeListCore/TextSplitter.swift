import Foundation
import NaturalLanguage

public enum TextSplitter {
    private static let bracketRegex = try! NSRegularExpression(pattern: #"\([^)]*\)|\[[^\]]*\]|\{[^}]*\}|<[^>]*>"#)

    /// Removes stage directions such as "(lacht)" or "[atmet]".
    public static func strippingDirections(_ s: String) -> String {
        bracketRegex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
    }

    /// Counts spoken words: whitespace separated tokens that contain a letter or digit.
    public static func wordCount(_ s: String, ignoreDirections: Bool) -> Int {
        let t = ignoreDirections ? strippingDirections(s) : s
        return t.split(whereSeparator: { $0.isWhitespace }).filter { tok in
            tok.contains { $0.isLetter || $0.isNumber }
        }.count
    }

    public static func letterCount(_ s: String, ignoreDirections: Bool) -> Int {
        let t = ignoreDirections ? strippingDirections(s) : s
        return t.filter { $0.isLetter || $0.isNumber }.count
    }

    static let abbreviations: Set<String> = [
        "z.b", "d.h", "u.a", "usw", "bzw", "ca", "dr", "prof", "hr", "fr", "frl", "nr", "st", "vgl", "evtl", "ggf",
        "inkl", "bzgl", "u.s.w", "o.ä", "etc", "mr", "mrs", "ms", "jr", "sr", "bspw", "sog", "z.t", "v.a", "s", "abs",
    ]

    /// Splits text into sentences, never inside a sentence. Uses the system's sentence tokenizer with
    /// German rules and repairs typical false breaks (abbreviations, ordinals, lowercase continuations).
    public static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.setLanguage(.german)
        var raw: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { raw.append(s) }
            return true
        }
        var merged: [String] = []
        for s in raw {
            if let last = merged.last, shouldMerge(last, s) {
                merged[merged.count - 1] = last + " " + s
            } else {
                merged.append(s)
            }
        }
        return merged
    }

    static func shouldMerge(_ prev: String, _ next: String) -> Bool {
        // A sentence must end with terminal punctuation (optionally followed by quotes/brackets).
        let trimmedEnd = prev.trimmingCharacters(in: CharacterSet(charactersIn: "\"'»«“”„‘’)]* "))
        guard let lastChar = trimmedEnd.last else { return true }
        if !".!?…".contains(lastChar) { return true }
        // Next starts lowercase → continuation (German sentences start uppercase).
        if let first = strippingDirections(next).first(where: { $0.isLetter || $0.isNumber }), first.isLowercase { return true }
        if lastChar == "." {
            let word = trimmedEnd.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
            let core = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".(\"'„“"))
            if abbreviations.contains(core) { return true }
            // Ordinals like "3." or dates like "12.03."
            if !core.isEmpty, core.allSatisfy({ $0.isNumber || $0 == "." }) { return true }
        }
        return false
    }

    /// Splits a sentence into clauses at , ; : – — (only used when the user explicitly allows it).
    public static func clauses(_ sentence: String) -> [String] {
        var out: [String] = []
        var cur = ""
        let chars = Array(sentence)
        for (i, ch) in chars.enumerated() {
            cur.append(ch)
            let isBreak = ",;:".contains(ch) || ((ch == "–" || ch == "—") && i > 0 && chars[i - 1] == " ")
            let nextIsSpace = i + 1 < chars.count && chars[i + 1].isWhitespace
            if isBreak, nextIsSpace {
                let t = cur.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
                cur = ""
            }
        }
        let t = cur.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { out.append(t) }
        // Do not produce tiny fragments: merge clauses with < 3 words into the neighbour.
        var merged: [String] = []
        for c in out {
            if let last = merged.last, wordCount(last, ignoreDirections: false) < 3 || wordCount(c, ignoreDirections: false) < 3 {
                merged[merged.count - 1] = last + " " + c
            } else {
                merged.append(c)
            }
        }
        return merged
    }

    /// Minimal number of contiguous groups so that every group stays ≤ `cap` (units above the cap stand alone).
    public static func minimalGroups(_ weights: [Int], cap: Int) -> Int {
        var groups = 0
        var cur = 0
        for w in weights {
            if cur > 0, cur + w <= cap { cur += w } else { groups += 1; cur = w }
        }
        return groups
    }

    /// Partitions `weights` into exactly `k` contiguous groups minimising the largest group,
    /// then the sum of squares (balanced lengths). Returns group start indices.
    public static func partition(_ weights: [Int], into k: Int) -> [Range<Int>] {
        let n = weights.count
        let k = max(1, min(k, n))
        var prefix = [0]
        for w in weights { prefix.append(prefix.last! + w) }
        struct Cost: Comparable {
            var maxW: Int, sq: Int
            static func < (a: Cost, b: Cost) -> Bool { a.maxW != b.maxW ? a.maxW < b.maxW : a.sq < b.sq }
        }
        let inf = Cost(maxW: .max, sq: .max)
        var dp = Array(repeating: Array(repeating: inf, count: k + 1), count: n + 1)
        var cut = Array(repeating: Array(repeating: 0, count: k + 1), count: n + 1)
        dp[0][0] = Cost(maxW: 0, sq: 0)
        if n > 0 {
            for i in 1...n {
                for j in 1...min(i, k) {
                    for p in (j - 1)..<i where dp[p][j - 1] != inf {
                        let w = prefix[i] - prefix[p]
                        let c = Cost(maxW: max(dp[p][j - 1].maxW, w), sq: dp[p][j - 1].sq + w * w)
                        if c < dp[i][j] { dp[i][j] = c; cut[i][j] = p }
                    }
                }
            }
        }
        var ranges: [Range<Int>] = []
        var i = n, j = k
        while j > 0 {
            let p = cut[i][j]
            ranges.insert(p..<i, at: 0)
            i = p; j -= 1
        }
        return ranges
    }
}

public struct SplitResult {
    public var chunks: [String]
    /// Chunks that still exceed the word limit because a single sentence is longer than the limit.
    public var oversizedChunks: [Int]
}

extension TextSplitter {
    /// Splits `text` into chunks at sentence boundaries.
    /// - Parameters:
    ///   - maxWords: word limit per take, or nil.
    ///   - minChunks: lower bound on the number of chunks (e.g. derived from a duration limit).
    /// - Returns: nil if the text cannot be split (single sentence).
    public static func split(_ text: String, maxWords: Int?, minChunks: Int, ignoreDirections: Bool, allowClauses: Bool) -> SplitResult? {
        var units = sentences(text)
        if allowClauses, let maxWords {
            units = units.flatMap { wordCount($0, ignoreDirections: ignoreDirections) > maxWords ? clauses($0) : [$0] }
        }
        guard units.count >= 2 else { return nil }
        let weights = units.map { max(1, wordCount($0, ignoreDirections: ignoreDirections)) }
        var k = minChunks
        if let maxWords { k = max(k, minimalGroups(weights, cap: maxWords)) }
        k = min(max(k, 2), units.count)
        let ranges = partition(weights, into: k)
        let chunks = ranges.map { units[$0].joined(separator: " ") }
        let oversized = maxWords.map { cap in ranges.indices.filter { ranges[$0].reduce(0) { $0 + weights[$1] } > cap } } ?? []
        return SplitResult(chunks: chunks, oversizedChunks: oversized)
    }
}
