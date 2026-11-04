import Foundation

public enum XLSXExporter {
    /// Writes `sheets` back into a copy of the original package. Only modified sheets are regenerated;
    /// all other parts (styles, other sheets, column widths, views …) are kept untouched.
    public static func export(original: Data, sheets: [TakeSheet]) throws -> Data {
        var archive = try ZipArchive(data: original)
        var regenerated = false
        for sheet in sheets where sheet.isModified {
            guard let xmlData = archive[sheet.sheetPath] else { continue }
            archive[sheet.sheetPath] = Data(rewrite(String(decoding: xmlData, as: UTF8.self), sheet: sheet).utf8)
            regenerated = true
        }
        if regenerated { dropCalcChain(&archive) }
        return archive.serialized()
    }

    static let sheetDataRegex = try! NSRegularExpression(pattern: #"<((?:[A-Za-z0-9_]+:)?)sheetData\b[^>]*?(/?)>"#)
    static let refAttrRegex = try! NSRegularExpression(pattern: #"\b(ref|sqref)="([^"]*)""#)
    static let cellRefRegex = try! NSRegularExpression(pattern: #"(:?)(\$?[A-Z]{1,3}\$?)(\d+)"#)

    static func rewrite(_ xml: String, sheet: TakeSheet) -> String {
        let ns = xml as NSString
        guard let m = sheetDataRegex.firstMatch(in: xml, range: NSRange(location: 0, length: ns.length)) else { return xml }
        let p = ns.substring(with: m.range(at: 1))
        let selfClosing = ns.substring(with: m.range(at: 2)) == "/"
        let start = m.range.location
        var end = m.range.location + m.range.length
        if !selfClosing {
            let close = ns.range(of: "</\(p)sheetData>", range: NSRange(location: end, length: ns.length - end))
            guard close.location != NSNotFound else { return xml }
            end = close.location + close.length
        }
        let mapper = RowMapper(sheet.rows)
        let prefix = remapRefs(ns.substring(to: start), mapper)
        let suffix = remapRefs(ns.substring(from: end), mapper)

        var out = prefix
        out.reserveCapacity(xml.count + 4096)
        out += "<\(p)sheetData>"
        for (i, row) in sheet.rows.enumerated() {
            let r = i + 1
            let cells = row.cells.enumerated().filter { $0.element.value != .empty || $0.element.style != nil }
            if cells.isEmpty, row.attrs.isEmpty { continue }
            out += "<\(p)row r=\"\(r)\""
            for a in row.attrs { out += " \(a.name)=\"\(escape(a.value))\"" }
            out += ">"
            for (c, cell) in cells {
                out += "<\(p)c r=\"\(columnLetters(c))\(r)\""
                if let s = cell.style { out += " s=\"\(s)\"" }
                switch cell.value {
                case .empty: out += "/>"
                case .string(let s): out += " t=\"inlineStr\"><\(p)is><\(p)t xml:space=\"preserve\">\(escape(s))</\(p)t></\(p)is></\(p)c>"
                case .number(let d): out += "><\(p)v>\(numberString(d))</\(p)v></\(p)c>"
                case .bool(let b): out += " t=\"b\"><\(p)v>\(b ? 1 : 0)</\(p)v></\(p)c>"
                case .error(let e): out += " t=\"e\"><\(p)v>\(escape(e))</\(p)v></\(p)c>"
                }
            }
            out += "</\(p)row>"
        }
        out += "</\(p)sheetData>"
        out += suffix
        return out
    }

    static func numberString(_ d: Double) -> String {
        if d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    /// Maps old (source) row numbers to new row numbers after rows were inserted.
    struct RowMapper {
        var first: [Int: Int] = [:]
        var last: [Int: Int] = [:]
        var known: [Int] = []

        init(_ rows: [SheetRow]) {
            for (i, row) in rows.enumerated() {
                guard let src = row.sourceRow ?? row.origin else { continue }
                if first[src] == nil { first[src] = i + 1 }
                last[src] = max(last[src] ?? 0, i + 1)
            }
            known = first.keys.sorted()
        }

        func map(_ r: Int, end: Bool) -> Int {
            if let v = end ? last[r] : first[r] { return v }
            // Unknown row: shift by the offset of the nearest known row above.
            var lo = 0, hi = known.count - 1, best: Int?
            while lo <= hi {
                let mid = (lo + hi) / 2
                if known[mid] <= r { best = known[mid]; lo = mid + 1 } else { hi = mid - 1 }
            }
            guard let b = best, let l = last[b] else { return r }
            return l + (r - b)
        }
    }

    static func remapRefs(_ s: String, _ mapper: RowMapper) -> String {
        let ns = s as NSString
        var result = ""
        var pos = 0
        for m in refAttrRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let vr = m.range(at: 2)
            result += ns.substring(with: NSRange(location: pos, length: vr.location - pos))
            let value = ns.substring(with: vr)
            let vns = value as NSString
            var mapped = ""
            var vp = 0
            for c in cellRefRegex.matches(in: value, range: NSRange(location: 0, length: vns.length)) {
                mapped += vns.substring(with: NSRange(location: vp, length: c.range.location - vp))
                let colon = vns.substring(with: c.range(at: 1))
                let row = Int(vns.substring(with: c.range(at: 3))) ?? 0
                mapped += colon + vns.substring(with: c.range(at: 2)) + String(mapper.map(row, end: !colon.isEmpty))
                vp = c.range.location + c.range.length
            }
            mapped += vns.substring(from: vp)
            result += mapped
            pos = vr.location + vr.length
        }
        result += ns.substring(from: pos)
        return result
    }

    static func dropCalcChain(_ archive: inout ZipArchive) {
        guard archive["xl/calcChain.xml"] != nil else { return }
        archive["xl/calcChain.xml"] = nil
        if let ct = archive["[Content_Types].xml"] {
            let s = String(decoding: ct, as: UTF8.self)
                .replacingOccurrences(of: #"<Override[^>]*PartName="/xl/calcChain\.xml"[^>]*/>"#, with: "", options: .regularExpression)
            archive["[Content_Types].xml"] = Data(s.utf8)
        }
        if let rels = archive["xl/_rels/workbook.xml.rels"] {
            let s = String(decoding: rels, as: UTF8.self)
                .replacingOccurrences(of: #"<Relationship[^>]*Target="[^"]*calcChain\.xml"[^>]*/>"#, with: "", options: .regularExpression)
            archive["xl/_rels/workbook.xml.rels"] = Data(s.utf8)
        }
    }

    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(u)
            default:
                if u.value < 0x20 || u.value == 0xFFFE || u.value == 0xFFFF { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }
}

/// Builds a minimal new .xlsx from scratch (used for tests and as a fallback).
public enum XLSXBuilder {
    public static func build(sheets: [(name: String, rows: [[CellValue]])]) -> Data {
        var a = ZipArchive()
        var overrides = ""
        var wbSheets = ""
        var rels = ""
        for (i, sheet) in sheets.enumerated() {
            let n = i + 1
            var x = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheetData>"#
            for (r, row) in sheet.rows.enumerated() {
                x += "<row r=\"\(r + 1)\">"
                for (c, v) in row.enumerated() {
                    let ref = "\(columnLetters(c))\(r + 1)"
                    switch v {
                    case .empty: break
                    case .string(let s): x += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(XLSXExporter.escape(s))</t></is></c>"
                    case .number(let d): x += "<c r=\"\(ref)\"><v>\(XLSXExporter.numberString(d))</v></c>"
                    case .bool(let b): x += "<c r=\"\(ref)\" t=\"b\"><v>\(b ? 1 : 0)</v></c>"
                    case .error(let e): x += "<c r=\"\(ref)\" t=\"e\"><v>\(e)</v></c>"
                    }
                }
                x += "</row>"
            }
            x += "</sheetData></worksheet>"
            a["xl/worksheets/sheet\(n).xml"] = Data(x.utf8)
            overrides += #"<Override PartName="/xl/worksheets/sheet\#(n).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
            wbSheets += "<sheet name=\"\(XLSXExporter.escape(sheet.name))\" sheetId=\"\(n)\" r:id=\"rId\(n)\"/>"
            rels += #"<Relationship Id="rId\#(n)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(n).xml"/>"#
        }
        a["[Content_Types].xml"] = Data((#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>"# + overrides + "</Types>").utf8)
        a["_rels/.rels"] = Data(#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#.utf8)
        a["xl/workbook.xml"] = Data((#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>"# + wbSheets + "</sheets></workbook>").utf8)
        a["xl/_rels/workbook.xml.rels"] = Data((#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"# + rels + "</Relationships>").utf8)
        return a.serialized()
    }
}
