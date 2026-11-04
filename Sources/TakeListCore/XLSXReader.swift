import Foundation

public struct WorkbookSheetInfo: Identifiable, Equatable {
    public var id: String { path }
    public var name: String
    public var path: String
    public init(name: String, path: String) { self.name = name; self.path = path }
}

/// A loaded .xlsx package.
public struct Workbook {
    public let url: URL
    public let archive: ZipArchive
    public let sheets: [WorkbookSheetInfo]
    let sharedStrings: [String]

    public init(url: URL) throws {
        let data = try Data(contentsOf: url)
        try self.init(url: url, data: data)
    }

    public init(url: URL, data: Data) throws {
        self.url = url
        archive = try ZipArchive(data: data)
        let wbPath = Self.workbookPath(archive)
        guard let wbXML = archive[wbPath] else { throw ZipError.invalid("workbook.xml fehlt") }
        let relsPath = Self.relsPath(for: wbPath)
        var targets: [String: String] = [:]
        if let rels = archive[relsPath] {
            for el in SimpleXML.elements(named: "Relationship", in: rels) {
                if let id = el["Id"], let t = el["Target"] { targets[id] = Self.resolve(t, base: wbPath) }
            }
        }
        var list: [WorkbookSheetInfo] = []
        for el in SimpleXML.elements(named: "sheet", in: wbXML) {
            guard let name = el["name"] else { continue }
            let rid = el["r:id"] ?? el.first(where: { $0.key.hasSuffix(":id") })?.value
            if let rid, let path = targets[rid], archive[path] != nil {
                list.append(WorkbookSheetInfo(name: name, path: path))
            }
        }
        sheets = list
        let arc = archive
        if let ss = arc["xl/sharedStrings.xml"] ?? targets.values.first(where: { $0.hasSuffix("sharedStrings.xml") }).flatMap({ arc[$0] }) {
            sharedStrings = SharedStringsParser.parse(ss)
        } else {
            sharedStrings = []
        }
    }

    static func workbookPath(_ archive: ZipArchive) -> String {
        if let rels = archive["_rels/.rels"] {
            for el in SimpleXML.elements(named: "Relationship", in: rels)
            where (el["Type"] ?? "").hasSuffix("/officeDocument") {
                if let t = el["Target"] { return resolve(t, base: "") }
            }
        }
        return "xl/workbook.xml"
    }

    static func relsPath(for path: String) -> String {
        let url = URL(fileURLWithPath: "/" + path)
        let dir = url.deletingLastPathComponent().path
        let p = (dir == "/" ? "" : String(dir.dropFirst()) + "/") + "_rels/" + url.lastPathComponent + ".rels"
        return p
    }

    static func resolve(_ target: String, base: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = base.split(separator: "/").map(String.init)
        if !parts.isEmpty { parts.removeLast() }
        for comp in target.split(separator: "/") {
            if comp == ".." { if !parts.isEmpty { parts.removeLast() } } else if comp != "." { parts.append(String(comp)) }
        }
        return parts.joined(separator: "/")
    }

    /// Reads all rows of a worksheet.
    public func loadRows(_ info: WorkbookSheetInfo) throws -> [SheetRow] {
        guard let xml = archive[info.path] else { throw ZipError.invalid("Tabellenblatt fehlt") }
        let parser = SheetParser(shared: sharedStrings)
        return parser.parse(xml)
    }
}

// MARK: - XML helpers

/// Tiny helper that collects attributes of all elements with a given (prefix-less) name.
enum SimpleXML {
    final class Collector: NSObject, XMLParserDelegate {
        let name: String
        var found: [[String: String]] = []
        init(_ name: String) { self.name = name }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if localName(elementName) == name { found.append(attributeDict) }
        }
    }

    static func elements(named name: String, in data: Data) -> [[String: String]] {
        let c = Collector(name)
        let p = XMLParser(data: data)
        p.delegate = c
        p.parse()
        return c.found
    }
}

@inline(__always) func localName(_ s: String) -> Substring {
    if let i = s.lastIndex(of: ":") { return s[s.index(after: i)...] }
    return s[...]
}

final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    var current = ""
    var inT = false
    var inPhonetic = false

    static func parse(_ data: Data) -> [String] {
        let d = SharedStringsParser()
        let p = XMLParser(data: data)
        p.delegate = d
        p.parse()
        return d.strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch localName(elementName) {
        case "si": current = ""
        case "t": inT = true
        case "rPh": inPhonetic = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch localName(elementName) {
        case "si": strings.append(current)
        case "t": inT = false
        case "rPh": inPhonetic = false
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inT, !inPhonetic { current += string }
    }
}

final class SheetParser: NSObject, XMLParserDelegate {
    let shared: [String]
    var rows: [SheetRow] = []
    var row: SheetRow?
    var rowNumber = 0
    var colIndex = 0
    var cellType = ""
    var cellStyle: Int?
    var cellCol = 0
    var text = ""
    var capture = false
    var inInline = false
    var inPhonetic = false
    var value: String?
    var inlineText = ""

    init(shared: [String]) { self.shared = shared }

    func parse(_ data: Data) -> [SheetRow] {
        let p = XMLParser(data: data)
        p.delegate = self
        p.parse()
        return rows
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        switch localName(elementName) {
        case "row":
            let n = a["r"].flatMap(Int.init) ?? (rowNumber + 1)
            // Fill gaps so row indices stay aligned with the sheet.
            while rowNumber + 1 < n {
                rowNumber += 1
                rows.append(SheetRow(sourceRow: rowNumber, cells: []))
            }
            rowNumber = n
            let attrs = a.filter { $0.key != "r" && $0.key != "spans" && !$0.key.hasPrefix("x14ac") }
                .sorted { $0.key < $1.key }.map { XMLAttr($0.key, $0.value) }
            row = SheetRow(sourceRow: n, attrs: attrs, cells: [])
            colIndex = 0
        case "c":
            if let r = a["r"] {
                let letters = r.prefix { $0.isLetter }
                cellCol = columnIndex(letters: letters)
            } else {
                cellCol = colIndex
            }
            colIndex = cellCol + 1
            cellType = a["t"] ?? "n"
            cellStyle = a["s"].flatMap(Int.init)
            value = nil
            inlineText = ""
        case "v":
            capture = true; text = ""
        case "is":
            inInline = true
        case "t" where inInline:
            capture = true; text = ""
        case "rPh":
            inPhonetic = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch localName(elementName) {
        case "v":
            value = text; capture = false
        case "t" where inInline:
            if !inPhonetic { inlineText += text }
            capture = false
        case "is":
            inInline = false
        case "rPh":
            inPhonetic = false
        case "c":
            let v: CellValue
            switch cellType {
            case "s":
                if let idx = value.flatMap(Int.init), idx >= 0, idx < shared.count { v = .string(shared[idx]) } else { v = .empty }
            case "inlineStr": v = inlineText.isEmpty ? .empty : .string(inlineText)
            case "str": v = (value ?? "").isEmpty ? .empty : .string(value!)
            case "b": v = .bool(value == "1")
            case "e": v = .error(value ?? "#ERR")
            default:
                if let s = value, let d = Double(s) { v = .number(d) } else if let s = value, !s.isEmpty { v = .string(s) } else { v = .empty }
            }
            if v != .empty || cellStyle != nil {
                row?.set(cellCol, Cell(v, style: cellStyle))
            }
        case "row":
            if let r = row { rows.append(r) }
            row = nil
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture { text += string }
    }
}
