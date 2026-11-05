import Foundation

/// First TC In and last TC Out (or In) over all takes of a sheet, in frames.
public struct TimecodeSpan: Equatable {
    public var first: Int
    public var last: Int
    public init(first: Int, last: Int) { self.first = first; self.last = last }
}

/// One table going into a merge, with the offset (in frames) that is added to every timecode.
public struct MergeInput {
    public var sheet: TakeSheet
    public var offset: Int
    public init(sheet: TakeSheet, offset: Int) { self.sheet = sheet; self.offset = offset }
}

public struct MergeResult {
    public var sheet: TakeSheet
    public var takes: Int
    /// Timecode cells that could not be read and were copied unchanged.
    public var unparsedTimecodes: Int
    /// Headers of columns that only exist in later tables and were appended.
    public var addedColumns: [String]
}

/// Merges several take lists into one, shifting each list's timecodes by a constant offset.
public enum ListMerger {
    public static func span(of sheet: TakeSheet, fps: Int) -> TimecodeSpan? {
        let tc = Timecode(fps: fps)
        var first: Int?, last: Int?
        for i in sheet.dataRange where sheet.isTake(sheet.rows[i]) {
            let info = Scanner.takeInfo(sheet.rows[i], sheet.mapping, tc)
            guard let a = info.inF ?? info.outF else { continue }
            let b = max(info.outF ?? a, a)
            first = min(first ?? a, a)
            last = max(last ?? b, b)
        }
        guard let first, let last else { return nil }
        return TimecodeSpan(first: first, last: last)
    }

    /// The full hour at or before `frames` (00:00:00:12 → 00:00:00:00, 10:00:00:13 → 10:00:00:00).
    public static func hourFloor(_ frames: Int, fps: Int) -> Int {
        let hour = 3600 * max(1, fps)
        return max(0, frames) / hour * hour
    }

    /// The first full hour strictly after `frames`.
    public static func hourAfter(_ frames: Int, fps: Int) -> Int {
        hourFloor(frames, fps: fps) + 3600 * max(1, fps)
    }

    /// Suggested start in the merged list: keep the list's own base hour unless that collides
    /// with the previous list, then move to the next free full hour.
    public static func suggestedStart(base: Int, previousEnd: Int?, fps: Int) -> Int {
        guard let previousEnd else { return base }
        return max(base, hourAfter(previousEnd, fps: fps))
    }

    /// Builds the merged sheet. `inputs` must be in merged order; the first sheet is the layout template
    /// (columns, header rows, cell styles, timecode format).
    public static func merge(_ inputs: [MergeInput], name: String, fileURL: URL, fps: Int) -> MergeResult? {
        guard let template = inputs.first?.sheet, template.rows.indices.contains(template.headerRowIndex) else { return nil }
        let tc = Timecode(fps: fps)
        let tm = template.mapping
        let tcColumns = Set([tm.tcIn, tm.tcOut].compactMap { $0 })

        // Template rows down to the header row are kept as they are.
        var rows: [SheetRow] = template.rows[0...template.headerRowIndex].map { var r = $0; r.id = UUID(); return r }
        let headerIndex = template.headerRowIndex
        let headers = template.headers

        // Layout taken from the first take of the template.
        let firstTake = template.dataRange.lazy.map { template.rows[$0] }.first { template.isTake($0) }
        var columnStyle: [Int: Int] = [:]
        if let firstTake {
            for (c, cell) in firstTake.cells.enumerated() { if let s = cell.style { columnStyle[c] = s } }
        }
        let firstInfo = firstTake.map { Scanner.takeInfo($0, tm, tc) }
        let inStyle = firstInfo?.inStyle ?? .frames(separator: ":")
        let outStyle = firstInfo?.outStyle ?? inStyle

        var nextColumn = max(
            template.rows.map(\.cells.count).max() ?? 0,
            template.hiddenColumns.map { $0.upperBound + 1 }.filter { $0 < 16_384 }.max() ?? 0,
            template.columnCount)
        var added: [String: Int] = [:]
        var addedOrder: [String] = []
        func key(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        var takes = 0, unparsed = 0
        for input in inputs {
            let s = input.sheet
            let m = s.mapping
            let isTemplate = s.id == template.id
            // Styles are indices into the workbook's style table: only valid within the same file.
            let sameFile = s.fileURL == template.fileURL
            let sourceTC = Set([m.tcIn, m.tcOut].compactMap { $0 })

            var columnMap: [Int: Int] = [:]
            if isTemplate {
                for c in 0..<(s.rows.map(\.cells.count).max() ?? 0) where !tcColumns.contains(c) { columnMap[c] = c }
            } else {
                for (src, dst) in [(m.role, tm.role), (m.text, tm.text), (m.takeNumber, tm.takeNumber)] {
                    if let src, let dst, !sourceTC.contains(src) { columnMap[src] = dst }
                }
                let taken = Set(columnMap.values).union(tcColumns)
                let sourceHeaders = s.headers
                for c in s.displayColumns where columnMap[c] == nil && !sourceTC.contains(c) {
                    let h = sourceHeaders.indices.contains(c) ? sourceHeaders[c] : "Spalte \(columnLetters(c))"
                    if let d = template.displayColumns.first(where: { !taken.contains($0) && key(headers[$0]) == key(h) }) {
                        columnMap[c] = d
                    } else if let d = added[key(h)] {
                        columnMap[c] = d
                    } else {
                        let d = nextColumn
                        nextColumn += 1
                        added[key(h)] = d
                        addedOrder.append(h)
                        let headerStyle = rows[headerIndex].cell(tm.text ?? tm.role ?? 0).style
                        rows[headerIndex].set(d, Cell(.string(h), style: headerStyle))
                        columnMap[c] = d
                    }
                }
            }

            for i in s.dataRange {
                let row = s.rows[i]
                guard !row.cells.allSatisfy({ $0.value.isBlank }) else { continue }
                var out: SheetRow
                if isTemplate {
                    out = row
                    out.id = UUID()
                    for c in tcColumns where c < out.cells.count { out.cells[c].value = .empty }
                } else {
                    out = SheetRow(attrs: row.attrs.filter { ["ht", "customHeight"].contains($0.name) }, cells: [])
                }
                if !isTemplate {
                    for (c, cell) in row.cells.enumerated() where !cell.value.isBlank {
                        guard let d = columnMap[c] else { continue }
                        out.set(d, Cell(cell.value, style: sameFile ? cell.style : columnStyle[d]))
                    }
                }
                func style(_ d: Int?) -> Int? {
                    guard let d else { return nil }
                    return isTemplate ? row.cell(d).style : columnStyle[d]
                }

                let info = Scanner.takeInfo(row, m, tc)
                if info.inInvalid || info.outInvalid {
                    // Keep unreadable timecodes verbatim instead of losing them.
                    unparsed += 1
                    if m.combinedTimecode || tm.combinedTimecode {
                        let raw = m.combinedTimecode ? row.text(m.tcIn) : [row.text(m.tcIn), row.text(m.tcOut)].filter { !$0.isEmpty }.joined(separator: " - ")
                        out.set(tm.tcIn, Cell(.string(raw), style: style(tm.tcIn)))
                    } else {
                        if !row.text(m.tcIn).isEmpty {
                            let v: CellValue = info.inF.map { tc.cellValue($0 + input.offset, style: inStyle) } ?? row.cell(m.tcIn).value
                            out.set(tm.tcIn, Cell(v, style: style(tm.tcIn)))
                        }
                        if !row.text(m.tcOut).isEmpty {
                            let v: CellValue = info.outF.map { tc.cellValue($0 + input.offset, style: outStyle) } ?? row.cell(m.tcOut).value
                            out.set(tm.tcOut, Cell(v, style: style(tm.tcOut)))
                        }
                    }
                } else {
                    let a = info.inF.map { $0 + input.offset }
                    let b = info.outF.map { $0 + input.offset }
                    if tm.combinedTimecode {
                        let st: TimecodeStyle = inStyle == .excel ? .frames(separator: ":") : inStyle
                        let text = [a, b].compactMap { $0 }.map { tc.string($0, style: st) }.joined(separator: " - ")
                        if !text.isEmpty { out.set(tm.tcIn, Cell(.string(text), style: style(tm.tcIn))) }
                    } else {
                        if let a { out.set(tm.tcIn, Cell(tc.cellValue(a, style: inStyle), style: style(tm.tcIn))) }
                        if let b { out.set(tm.tcOut, Cell(tc.cellValue(b, style: outStyle), style: style(tm.tcOut))) }
                    }
                }
                if s.isTake(row) { takes += 1 }
                rows.append(out)
            }
        }

        var sheet = TakeSheet(fileURL: fileURL, sheetName: name, sheetPath: template.sheetPath, rows: rows,
                              headerRowIndex: headerIndex, mapping: tm, hiddenColumns: template.hiddenColumns)
        sheet.isModified = true
        return MergeResult(sheet: sheet, takes: takes, unparsedTimecodes: unparsed, addedColumns: addedOrder)
    }
}

extension XLSXExporter {
    /// A copy of the package that lists only the given worksheet (renamed), used as the base for a merged list.
    /// The other worksheet parts stay in the package but are no longer part of the workbook.
    public static func singleSheetPackage(original: Data, sheetPath: String, name: String) throws -> Data {
        var archive = try ZipArchive(data: original)
        let wbPath = Workbook.workbookPath(archive)
        guard let wbData = archive[wbPath] else { throw ZipError.invalid("workbook.xml fehlt") }
        var targets: [String: String] = [:]
        if let rels = archive[Workbook.relsPath(for: wbPath)] {
            for el in SimpleXML.elements(named: "Relationship", in: rels) {
                if let id = el["Id"], let t = el["Target"] { targets[id] = Workbook.resolve(t, base: wbPath) }
            }
        }
        var xml = String(decoding: wbData, as: UTF8.self)
        let sheetRegex = try! NSRegularExpression(pattern: #"<((?:[A-Za-z0-9_]+:)?)sheet\b[^>]*?/>"#)
        let ridRegex = try! NSRegularExpression(pattern: #"\b[A-Za-z0-9_]+:id="([^"]*)""#)
        let nameRegex = try! NSRegularExpression(pattern: #"\bname="[^"]*""#)
        let stateRegex = try! NSRegularExpression(pattern: #"\sstate="[^"]*""#)
        var keep: String?
        let ns = xml as NSString
        for m in sheetRegex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let el = ns.substring(with: m.range)
            let ens = el as NSString
            guard let r = ridRegex.firstMatch(in: el, range: NSRange(location: 0, length: ens.length)),
                  targets[ens.substring(with: r.range(at: 1))] == sheetPath else { continue }
            var renamed = nameRegex.stringByReplacingMatches(in: el, range: NSRange(location: 0, length: ens.length),
                                                              withTemplate: NSRegularExpression.escapedTemplate(for: "name=\"\(escape(name))\""))
            renamed = stateRegex.stringByReplacingMatches(in: renamed, range: NSRange(location: 0, length: (renamed as NSString).length), withTemplate: "")
            keep = renamed
            break
        }
        guard let keep else { throw ZipError.invalid("Tabellenblatt nicht gefunden") }
        let sheetsRegex = try! NSRegularExpression(pattern: #"(<(?:[A-Za-z0-9_]+:)?sheets\b[^>]*>)[\s\S]*?(</(?:[A-Za-z0-9_]+:)?sheets>)"#)
        let xns = xml as NSString
        guard let sm = sheetsRegex.firstMatch(in: xml, range: NSRange(location: 0, length: xns.length)) else {
            throw ZipError.invalid("workbook.xml ohne Blattliste")
        }
        xml = xns.substring(to: sm.range.location) + xns.substring(with: sm.range(at: 1)) + keep + xns.substring(with: sm.range(at: 2))
            + xns.substring(from: sm.range.location + sm.range.length)
        // Defined names (print areas, filters …) and the active tab may point at sheets that are gone.
        xml = xml.replacingOccurrences(of: #"<((?:[A-Za-z0-9_]+:)?)definedNames\b[^>]*>[\s\S]*?</\1definedNames>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s(activeTab|firstSheet)="\d+""#, with: "", options: .regularExpression)
        archive[wbPath] = Data(xml.utf8)
        // The tab of the remaining sheet must be the selected one.
        if let sheetXML = archive[sheetPath] {
            let s = String(decoding: sheetXML, as: UTF8.self)
                .replacingOccurrences(of: #"(<(?:[A-Za-z0-9_]+:)?sheetView\b[^>]*?)\stabSelected="[^"]*""#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"<((?:[A-Za-z0-9_]+:)?)sheetView\b"#, with: "<$1sheetView tabSelected=\"1\"", options: .regularExpression)
            archive[sheetPath] = Data(s.utf8)
        }
        dropCalcChain(&archive)
        return archive.serialized()
    }
}
