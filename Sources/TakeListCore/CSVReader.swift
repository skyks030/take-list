import Foundation

/// Reads CSV/TSV take lists (as exported from Excel, Numbers, Google Sheets, Nuendo …).
public enum CSVReader {
    public static let fileExtensions = ["csv", "tsv", "txt"]

    /// Decodes the bytes: UTF-8 (with or without BOM), UTF-16 with BOM, otherwise Windows-1252 / Mac Roman.
    public static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            if let s = String(data: data, encoding: .utf16) { return s }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return String(data: data, encoding: .macOSRoman) ?? String(decoding: data, as: UTF8.self)
    }

    /// Picks the separator that splits the first lines most consistently: `;`, `,`, tab or `|`.
    public static func detectDelimiter(_ text: String) -> Character {
        let sample = String(text.prefix(20_000))
        var best: (Character, Int) = (",", -1)
        for d in [";", ",", "\t", "|"] as [Character] {
            let rows = parse(sample, delimiter: d).prefix(30).filter { !($0.count == 1 && $0[0].isEmpty) }
            guard let first = rows.first, first.count > 1 else { continue }
            // Score: columns of the header, but only if most rows agree with it.
            let agreeing = rows.filter { $0.count == first.count }.count
            let score = agreeing * 2 >= rows.count ? first.count * 1000 + agreeing : agreeing
            if score > best.1 { best = (d, score) }
        }
        return best.0
    }

    /// RFC 4180 parsing: quoted fields may contain separators, line breaks and doubled quotes.
    public static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var atFieldStart = true
        var it = text.makeIterator()
        var pending: Character?
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return it.next()
        }
        while let ch = next() {
            if quoted {
                if ch == "\"" {
                    if let n = next() {
                        if n == "\"" { field.append("\"") } else { quoted = false; pending = n }
                    } else { quoted = false }
                } else {
                    field.append(ch)
                }
                continue
            }
            switch ch {
            case "\"" where atFieldStart:
                quoted = true
                atFieldStart = false
            case delimiter:
                row.append(field); field = ""; atFieldStart = true
            case "\n", "\r", "\r\n":
                row.append(field); field = ""; atFieldStart = true
                rows.append(row); row = []
            default:
                field.append(ch)
                atFieldStart = false
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        // Drop trailing empty lines.
        while let last = rows.last, last.allSatisfy({ $0.isEmpty }) { rows.removeLast() }
        return rows
    }

    /// Converts a CSV file into a single-sheet .xlsx package that the rest of the app works with.
    public static func xlsxPackage(_ data: Data, sheetName: String) -> Data {
        let text = decode(data)
        let rows = parse(text, delimiter: detectDelimiter(text))
        let values: [[CellValue]] = rows.map { $0.map { $0.isEmpty ? .empty : .string($0) } }
        // Excel limits sheet names to 31 characters without : \ / ? * [ ]
        var name = sheetName.filter { !":\\/?*[]".contains($0) }
        if name.isEmpty { name = "CSV" }
        return XLSXBuilder.build(sheets: [(String(name.prefix(31)), values)])
    }
}
