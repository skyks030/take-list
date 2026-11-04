import Foundation

public enum CellValue: Equatable, Hashable {
    case empty
    case string(String)
    case number(Double)
    case bool(Bool)
    case error(String)

    public var text: String {
        switch self {
        case .empty: return ""
        case .string(let s): return s
        case .number(let d):
            if d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        case .bool(let b): return b ? "WAHR" : "FALSCH"
        case .error(let e): return e
        }
    }

    public var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public struct Cell: Equatable, Hashable {
    public var value: CellValue
    /// Style index (`s` attribute) from the original workbook, kept for export.
    public var style: Int?
    public init(_ value: CellValue = .empty, style: Int? = nil) { self.value = value; self.style = style }
    public var text: String { value.text }
}

public struct XMLAttr: Equatable, Hashable {
    public var name: String
    public var value: String
    public init(_ name: String, _ value: String) { self.name = name; self.value = value }
}

public struct SheetRow: Identifiable, Equatable {
    public var id = UUID()
    /// 1-based row number in the source sheet (nil for rows created by the app).
    public var sourceRow: Int?
    /// For rows created by splitting: the source row they were derived from.
    public var origin: Int?
    /// Row-level attributes (height, style …) without `r`/`spans`.
    public var attrs: [XMLAttr] = []
    public var cells: [Cell]

    public init(id: UUID = UUID(), sourceRow: Int? = nil, origin: Int? = nil, attrs: [XMLAttr] = [], cells: [Cell]) {
        self.id = id; self.sourceRow = sourceRow; self.origin = origin; self.attrs = attrs; self.cells = cells
    }

    /// Row label as shown to the user: "12" for original rows, "12+" for rows created from row 12.
    public var label: String {
        if let sourceRow { return String(sourceRow) }
        if let origin { return "\(origin)+" }
        return "neu"
    }

    public func cell(_ col: Int?) -> Cell {
        guard let col, col >= 0, col < cells.count else { return Cell() }
        return cells[col]
    }

    public func text(_ col: Int?) -> String { cell(col).text.trimmingCharacters(in: .whitespacesAndNewlines) }

    public mutating func set(_ col: Int?, _ cell: Cell) {
        guard let col, col >= 0 else { return }
        while cells.count <= col { cells.append(Cell()) }
        cells[col] = cell
    }
}

public struct ColumnMapping: Equatable, Codable {
    public var tcIn: Int?
    public var tcOut: Int?
    public var role: Int?
    public var text: Int?
    public var takeNumber: Int?
    public init(tcIn: Int? = nil, tcOut: Int? = nil, role: Int? = nil, text: Int? = nil, takeNumber: Int? = nil) {
        self.tcIn = tcIn; self.tcOut = tcOut; self.role = role; self.text = text; self.takeNumber = takeNumber
    }
    /// One column holding "IN - OUT".
    public var combinedTimecode: Bool { tcIn != nil && tcIn == tcOut }
    public var isComplete: Bool { tcIn != nil && tcOut != nil && role != nil && text != nil }

    public func label(for col: Int) -> String? {
        var parts: [String] = []
        if col == tcIn { parts.append(combinedTimecode ? "TC In/Out" : "TC In") }
        if col == tcOut, !combinedTimecode { parts.append("TC Out") }
        if col == role { parts.append("Rolle") }
        if col == text { parts.append("Text") }
        if col == takeNumber { parts.append("Take-Nr.") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// One imported worksheet.
public struct TakeSheet: Identifiable, Equatable {
    public var id = UUID()
    public var fileURL: URL
    public var sheetName: String
    /// Path of the worksheet XML inside the package, e.g. `xl/worksheets/sheet1.xml`.
    public var sheetPath: String
    /// All rows of the sheet, including rows above the header and the header row itself.
    public var rows: [SheetRow]
    public var headerRowIndex: Int
    public var mapping: ColumnMapping
    /// Columns hidden in Excel.
    public var hiddenColumns: [ClosedRange<Int>]
    /// Columns that actually contain something (formatted-but-empty cells don't count) and are not hidden.
    public var usedColumns: [Int]
    /// Set whenever the content diverges from the file on disk.
    public var isModified = false

    public init(fileURL: URL, sheetName: String, sheetPath: String, rows: [SheetRow], headerRowIndex: Int, mapping: ColumnMapping,
                hiddenColumns: [ClosedRange<Int>] = []) {
        self.fileURL = fileURL; self.sheetName = sheetName; self.sheetPath = sheetPath
        self.rows = rows; self.headerRowIndex = headerRowIndex; self.mapping = mapping
        self.hiddenColumns = hiddenColumns
        self.usedColumns = SheetColumns.used(rows, hidden: hiddenColumns)
    }

    /// Columns shown in the app: used columns plus every mapped column.
    public var displayColumns: [Int] {
        let mapped = [mapping.tcIn, mapping.tcOut, mapping.role, mapping.text, mapping.takeNumber].compactMap { $0 }
        return Array(Set(usedColumns).union(mapped)).sorted()
    }

    /// Width of the column index space that is shown (indices into `headers`).
    public var columnCount: Int { (displayColumns.last ?? 0) + 1 }

    public var title: String { "\(fileURL.deletingPathExtension().lastPathComponent) – \(sheetName)" }

    public var headers: [String] {
        let header = rows.indices.contains(headerRowIndex) ? rows[headerRowIndex] : SheetRow(cells: [])
        return (0..<columnCount).map { col in
            let t = header.text(col)
            return t.isEmpty ? "Spalte \(columnLetters(col))" : t
        }
    }

    /// Indices into `rows` of everything below the header.
    public var dataRange: Range<Int> { min(rows.count, headerRowIndex + 1)..<rows.count }

    /// A row counts as an actual take once any of the mapped columns has content.
    public func isTake(_ row: SheetRow) -> Bool {
        [mapping.tcIn, mapping.tcOut, mapping.role, mapping.text].contains { !row.text($0).isEmpty }
    }
}

public enum SheetColumns {
    /// Indices of columns with at least one non-blank cell, excluding columns hidden in Excel.
    public static func used(_ rows: [SheetRow], hidden: [ClosedRange<Int>] = []) -> [Int] {
        var used = Set<Int>()
        for row in rows {
            for (c, cell) in row.cells.enumerated() where !used.contains(c) && !cell.value.isBlank { used.insert(c) }
        }
        return used.filter { c in !hidden.contains { $0.contains(c) } }.sorted()
    }
}

public func columnLetters(_ index: Int) -> String {
    var n = index + 1
    var s = ""
    while n > 0 {
        let r = (n - 1) % 26
        s = String(UnicodeScalar(65 + r)!) + s
        n = (n - 1) / 26
    }
    return s
}

public func columnIndex(letters: Substring) -> Int {
    var n = 0
    for ch in letters.uppercased().unicodeScalars { n = n * 26 + Int(ch.value) - 64 }
    return n - 1
}
