import Foundation

public enum MarkerFormat: String, CaseIterable, Identifiable, Codable {
    case nuendoCSV, resolveEDL
    public var id: String { rawValue }
    public var label: String { self == .nuendoCSV ? "Nuendo / Cubase – Marker-CSV" : "DaVinci Resolve – Marker-EDL" }
    public var fileExtension: String { self == .nuendoCSV ? "csv" : "edl" }
}

public enum MarkerName: String, CaseIterable, Identifiable, Codable {
    case roleAndText, takeRoleText, role, text
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .roleAndText: return "Rolle: Text"
        case .takeRoleText: return "Take – Rolle: Text"
        case .role: return "Nur Rolle"
        case .text: return "Nur Text"
        }
    }
}

public struct MarkerOptions: Codable, Equatable {
    public var format = MarkerFormat.nuendoCSV
    public var name = MarkerName.takeRoleText
    public var semicolon = false
    public var byteOrderMark = true
    public var asciiOnly = false
    public var extraColumns = false
    public var colorByRole = true
    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerant decoding so new options never discard stored ones (e.g. after an update).
        let d = MarkerOptions()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = (try? c.decode(MarkerFormat.self, forKey: .format)) ?? d.format
        name = (try? c.decode(MarkerName.self, forKey: .name)) ?? d.name
        semicolon = (try? c.decode(Bool.self, forKey: .semicolon)) ?? d.semicolon
        byteOrderMark = (try? c.decode(Bool.self, forKey: .byteOrderMark)) ?? d.byteOrderMark
        asciiOnly = (try? c.decode(Bool.self, forKey: .asciiOnly)) ?? d.asciiOnly
        extraColumns = (try? c.decode(Bool.self, forKey: .extraColumns)) ?? d.extraColumns
        colorByRole = (try? c.decode(Bool.self, forKey: .colorByRole)) ?? d.colorByRole
    }
}

public struct MarkerResult {
    public var data: Data
    public var markers: Int
    public var skipped: Int
}

public enum MarkerExporter {
    struct Marker { var inF: Int; var outF: Int; var name: String; var role: String; var text: String; var take: String }

    static func markers(_ sheet: TakeSheet, fps: Int, options: MarkerOptions) -> ([Marker], Int) {
        let tc = Timecode(fps: fps)
        let m = sheet.mapping
        var out: [Marker] = []
        var skipped = 0
        for i in sheet.dataRange {
            let row = sheet.rows[i]
            guard sheet.isTake(row) else { continue }
            let info = Scanner.takeInfo(row, m, tc)
            guard let a = info.inF else { skipped += 1; continue }
            let b = max(info.outF ?? a + 1, a + 1)
            func clean(_ s: String) -> String {
                var t = s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
                if options.asciiOnly { t = CharacterCheck.transliterated(t) }
                return t.trimmingCharacters(in: .whitespaces)
            }
            let role = clean(row.text(m.role)), text = clean(row.text(m.text)), take = clean(row.text(m.takeNumber))
            var name: String
            switch options.name {
            case .roleAndText: name = role.isEmpty ? text : "\(role): \(text)"
            case .takeRoleText: name = [take, role.isEmpty ? text : "\(role): \(text)"].filter { !$0.isEmpty }.joined(separator: " – ")
            case .role: name = role
            case .text: name = text
            }
            if name.isEmpty { name = "Take \(row.label)" }
            out.append(Marker(inF: a, outF: b, name: name, role: role, text: text, take: take))
        }
        return (out.sorted { $0.inF < $1.inF }, skipped)
    }

    public static func export(_ sheet: TakeSheet, fps: Int, options: MarkerOptions) -> MarkerResult {
        let (list, skipped) = markers(sheet, fps: fps, options: options)
        let tc = Timecode(fps: fps)
        let fmt = TimecodeStyle.frames(separator: ":")
        var s = ""
        switch options.format {
        case .nuendoCSV:
            let sep = options.semicolon ? ";" : ","
            func q(_ v: String) -> String { "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            var header = ["#", "Name", "Start", "End", "Length"]
            if options.extraColumns { header += ["Character", "Dialog", "Take"] }
            s += header.map(q).joined(separator: sep) + "\r\n"
            for (n, mk) in list.enumerated() {
                var cols = [String(n + 1), mk.name, tc.string(mk.inF, style: fmt), tc.string(mk.outF, style: fmt), tc.string(mk.outF - mk.inF, style: fmt)]
                if options.extraColumns { cols += [mk.role, mk.text, mk.take] }
                s += cols.map(q).joined(separator: sep) + "\r\n"
            }
        case .resolveEDL:
            let colors = ["Blue", "Cyan", "Green", "Yellow", "Red", "Pink", "Purple", "Fuchsia", "Rose", "Lavender", "Sky", "Mint", "Lemon", "Sand", "Cocoa", "Cream"]
            var roleColor: [String: String] = [:]
            let title = options.asciiOnly ? CharacterCheck.transliterated(sheet.sheetName) : sheet.sheetName
            s += "TITLE: \(title)\nFCM: NON-DROP FRAME\n\n"
            for (n, mk) in list.enumerated() {
                let color: String
                if options.colorByRole {
                    if roleColor[mk.role] == nil { roleColor[mk.role] = colors[roleColor.count % colors.count] }
                    color = roleColor[mk.role]!
                } else { color = "Blue" }
                let a = tc.string(mk.inF, style: fmt), b = tc.string(mk.inF + 1, style: fmt)
                s += String(format: "%03d", (n + 1) % 1000) + "  001      V     C        \(a) \(b) \(a) \(b)  \n"
                let name = mk.name.replacingOccurrences(of: "|", with: "/")
                s += " |C:ResolveColor\(color) |M:\(name) |D:\(mk.outF - mk.inF)\n\n"
            }
        }
        var data = Data()
        if options.byteOrderMark, options.format == .nuendoCSV { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(Data(s.utf8))
        return MarkerResult(data: data, markers: list.count, skipped: skipped)
    }
}
