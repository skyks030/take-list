import Foundation

public enum ColumnDetector {
    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de"))
            .replacingOccurrences(of: "ß", with: "ss")
            .filter { $0.isLetter || $0.isNumber || $0 == "/" }
    }

    // (keyword, score) – exact match scores ×2, contains scores ×1.
    static let tcInKeys: [(String, Int)] = [("timecodein", 10), ("tcin", 10), ("tcstart", 9), ("timecodestart", 9), ("in", 6),
                                             ("start", 6), ("startzeit", 7), ("von", 5), ("begin", 6), ("beginn", 6), ("tcein", 9), ("einsatz", 5)]
    static let tcOutKeys: [(String, Int)] = [("timecodeout", 10), ("tcout", 10), ("tcende", 9), ("tcend", 9), ("timecodeende", 9), ("out", 6),
                                              ("ende", 6), ("end", 5), ("endzeit", 7), ("bis", 5), ("tcaus", 9), ("aus", 4)]
    static let roleKeys: [(String, Int)] = [("rolle", 10), ("rollen", 9), ("rollenname", 10), ("role", 10), ("sprecher", 8), ("figur", 9),
                                             ("character", 9), ("charakter", 9), ("char", 6), ("speaker", 8), ("name", 5), ("person", 6)]
    static let textKeys: [(String, Int)] = [("sprechertext", 10), ("dialog", 9), ("dialogue", 9), ("dialogtext", 10), ("text", 8),
                                             ("deutsch", 7), ("deutschertext", 10), ("dttext", 9), ("ubersetzung", 8), ("synchrontext", 10),
                                             ("synchronbuch", 9), ("inhalt", 5), ("dialogzeile", 9), ("line", 5), ("script", 6)]
    static let takeKeys: [(String, Int)] = [("take", 9), ("takenr", 10), ("takenummer", 10), ("nr", 5), ("tk", 6), ("no", 4)]

    static func score(_ header: String, _ keys: [(String, Int)]) -> Int {
        let h = normalize(header)
        guard !h.isEmpty else { return 0 }
        var best = 0
        for (k, s) in keys {
            if h == k { best = max(best, s * 2) } else if k.count >= 3, h.contains(k) { best = max(best, s) }
        }
        return best
    }

    /// Picks the most plausible header row (first row with ≥ 2 filled cells within the first 15 rows,
    /// preferring rows that contain known keywords).
    public static func guessHeaderRow(_ rows: [SheetRow]) -> Int {
        var bestRow = 0, bestScore = -1
        for (i, row) in rows.prefix(15).enumerated() {
            let texts = row.cells.map { $0.text }
            let filled = texts.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            guard filled >= 2 else { continue }
            let kw = texts.map { t in [tcInKeys, tcOutKeys, roleKeys, textKeys].map { score(t, $0) }.max() ?? 0 }.filter { $0 > 0 }.count
            let s = kw * 10 + (filled >= 3 ? 1 : 0)
            if s > bestScore { bestScore = s; bestRow = i }
            if kw >= 3 { break }
        }
        return bestRow
    }

    public static func detect(rows: [SheetRow], headerRow: Int, fps: Int) -> ColumnMapping {
        let count = rows.map(\.cells.count).max() ?? 0
        let header = rows.indices.contains(headerRow) ? rows[headerRow] : SheetRow(cells: [])
        let headers = (0..<count).map { header.text($0) }
        let sample = Array(rows.dropFirst(headerRow + 1).prefix(200))
        var used = Set<Int>()
        var m = ColumnMapping()

        func pick(_ keys: [(String, Int)]) -> Int? {
            var best: (Int, Int)?
            for (i, h) in headers.enumerated() where !used.contains(i) {
                let s = score(h, keys)
                if s > 0, s > (best?.1 ?? 0) { best = (i, s) }
            }
            if let b = best { used.insert(b.0); return b.0 }
            return nil
        }

        // A single column "Timecode In / Timecode Out" or "TC" → combined.
        for (i, h) in headers.enumerated() {
            let n = normalize(h)
            if (n.contains("in/") && n.contains("out")) || n == "tc" || n == "timecode" {
                let tc = Timecode(fps: fps)
                let ranges = sample.filter { tc.parseRange($0.cell(i)) != nil }.count
                if ranges > 0 || n.contains("/") { m.tcIn = i; m.tcOut = i; used.insert(i) }
                break
            }
        }
        if m.tcIn == nil { m.tcIn = pick(tcInKeys) }
        if m.tcOut == nil { m.tcOut = pick(tcOutKeys) }
        m.text = pick(textKeys)
        m.role = pick(roleKeys)
        m.takeNumber = pick(takeKeys)

        // Content based fallback.
        let tc = Timecode(fps: fps)
        func ratio(_ col: Int, _ f: (Cell) -> Bool) -> Double {
            let cells = sample.map { $0.cell(col) }.filter { !$0.value.isBlank }
            guard !cells.isEmpty else { return 0 }
            return Double(cells.filter(f).count) / Double(cells.count)
        }
        let free = { (0..<count).filter { !used.contains($0) } }
        if m.tcIn == nil || m.tcOut == nil {
            let tcCols = free().filter { ratio($0) { tc.parse($0) != nil } > 0.6 }
            if m.tcIn == nil, let c = tcCols.first { m.tcIn = c; used.insert(c) }
            if m.tcOut == nil, let c = free().filter({ tcCols.contains($0) }).first { m.tcOut = c; used.insert(c) }
        }
        func avgLen(_ col: Int) -> Double {
            let t = sample.map { $0.text(col) }.filter { !$0.isEmpty }
            return t.isEmpty ? 0 : Double(t.reduce(0) { $0 + $1.count }) / Double(t.count)
        }
        if m.text == nil, let c = free().max(by: { avgLen($0) < avgLen($1) }), avgLen(c) > 15 { m.text = c; used.insert(c) }
        if m.role == nil {
            let candidates = free().filter { c in
                let t = sample.map { $0.text(c) }.filter { !$0.isEmpty }
                guard t.count >= 3 else { return false }
                let distinct = Set(t).count
                return avgLen(c) < 25 && Double(distinct) < Double(t.count) * 0.6 && ratio(c) { tc.parse($0) == nil } > 0.9
            }
            if let c = candidates.first { m.role = c; used.insert(c) }
        }
        return m
    }
}
