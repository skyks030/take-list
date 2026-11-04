import Foundation

public enum TimeWeighting: String, Codable, CaseIterable, Identifiable {
    case words, characters
    public var id: String { rawValue }
    public var label: String { self == .words ? "Wörter" : "Zeichen" }
}

public enum TakeNumberMode: String, Codable, CaseIterable, Identifiable {
    case suffix, renumber, keep, empty
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .suffix: return "Buchstaben anhängen (12a, 12b …)"
        case .renumber: return "Alle Takes neu durchnummerieren"
        case .keep: return "Nummer übernehmen"
        case .empty: return "Leer lassen"
        }
    }
}

public enum RoleScope: String, Codable, CaseIterable, Identifiable {
    case sheet, file, all
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .sheet: return "Pro Tabelle"
        case .file: return "Pro Excel-Datei"
        case .all: return "Über alle Tabellen"
        }
    }
}

public struct ScanSettings: Codable, Equatable {
    public var fps = 25
    public var maxWordsEnabled = true
    public var maxWords = 30
    public var maxDurationEnabled = false
    public var maxDurationSeconds = 15.0
    public var ignoreDirections = true
    public var allowClauseSplit = false
    public var weighting = TimeWeighting.words
    public var gapFrames = 0
    public var takeNumberMode = TakeNumberMode.suffix

    public var checkMissingRole = true
    public var checkMissingTimecode = true
    public var checkOverlap = true
    public var overlapSameRoleOnly = false
    public var checkRoleSpelling = true
    public var roleTolerance = 1
    public var roleScope = RoleScope.file
    public var checkUmlauts = true
    public var checkSpecialCharacters = true

    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerant decoding so new settings never discard stored ones.
        let d = ScanSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fps = (try? c.decode(Int.self, forKey: .fps)) ?? d.fps
        maxWordsEnabled = (try? c.decode(Bool.self, forKey: .maxWordsEnabled)) ?? d.maxWordsEnabled
        maxWords = (try? c.decode(Int.self, forKey: .maxWords)) ?? d.maxWords
        maxDurationEnabled = (try? c.decode(Bool.self, forKey: .maxDurationEnabled)) ?? d.maxDurationEnabled
        maxDurationSeconds = (try? c.decode(Double.self, forKey: .maxDurationSeconds)) ?? d.maxDurationSeconds
        ignoreDirections = (try? c.decode(Bool.self, forKey: .ignoreDirections)) ?? d.ignoreDirections
        allowClauseSplit = (try? c.decode(Bool.self, forKey: .allowClauseSplit)) ?? d.allowClauseSplit
        weighting = (try? c.decode(TimeWeighting.self, forKey: .weighting)) ?? d.weighting
        gapFrames = (try? c.decode(Int.self, forKey: .gapFrames)) ?? d.gapFrames
        takeNumberMode = (try? c.decode(TakeNumberMode.self, forKey: .takeNumberMode)) ?? d.takeNumberMode
        checkMissingRole = (try? c.decode(Bool.self, forKey: .checkMissingRole)) ?? d.checkMissingRole
        checkMissingTimecode = (try? c.decode(Bool.self, forKey: .checkMissingTimecode)) ?? d.checkMissingTimecode
        checkOverlap = (try? c.decode(Bool.self, forKey: .checkOverlap)) ?? d.checkOverlap
        overlapSameRoleOnly = (try? c.decode(Bool.self, forKey: .overlapSameRoleOnly)) ?? d.overlapSameRoleOnly
        checkRoleSpelling = (try? c.decode(Bool.self, forKey: .checkRoleSpelling)) ?? d.checkRoleSpelling
        roleTolerance = (try? c.decode(Int.self, forKey: .roleTolerance)) ?? d.roleTolerance
        roleScope = (try? c.decode(RoleScope.self, forKey: .roleScope)) ?? d.roleScope
        checkUmlauts = (try? c.decode(Bool.self, forKey: .checkUmlauts)) ?? d.checkUmlauts
        checkSpecialCharacters = (try? c.decode(Bool.self, forKey: .checkSpecialCharacters)) ?? d.checkSpecialCharacters
    }
}

public struct ProposedTake: Equatable {
    public var text: String
    public var inFrames: Int
    public var outFrames: Int
    public var takeNumber: String?
    public var words: Int
}

public struct SplitProposal: Identifiable, Equatable {
    public var id = UUID()
    public var sheetID: UUID
    public var rowID: UUID
    public var originalWords: Int
    public var originalDuration: Int
    public var parts: [ProposedTake]
    public var reason: String
    public var notes: [String]
    public var accepted = false
}

public struct RowRef: Hashable {
    public var sheetID: UUID
    public var rowID: UUID
    public init(sheetID: UUID, rowID: UUID) { self.sheetID = sheetID; self.rowID = rowID }
}

public enum IssueKind: String, CaseIterable, Identifiable {
    case missingRole, missingTimecode, invalidTimecode, reversedTimecode, overlap, roleSpelling, cannotSplit
    case encodingDamage, specialCharacters, umlauts
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .missingRole: return "Keine Rolle"
        case .missingTimecode: return "Timecode fehlt"
        case .invalidTimecode: return "Ungültiger Timecode"
        case .reversedTimecode: return "TC Out vor TC In"
        case .overlap: return "Überlappung"
        case .roleSpelling: return "Mögliche Schreibvariante"
        case .cannotSplit: return "Nicht teilbar"
        case .encodingDamage: return "Kodierungsfehler"
        case .specialCharacters: return "Sonderzeichen"
        case .umlauts: return "Umlaute"
        }
    }
    public var symbol: String {
        switch self {
        case .missingRole: return "person.crop.circle.badge.questionmark"
        case .missingTimecode, .invalidTimecode, .reversedTimecode: return "clock.badge.exclamationmark"
        case .overlap: return "arrow.left.and.right.square"
        case .roleSpelling: return "textformat.abc.dottedunderline"
        case .cannotSplit: return "scissors"
        case .encodingDamage: return "exclamationmark.octagon"
        case .specialCharacters: return "character.cursor.ibeam"
        case .umlauts: return "character"
        }
    }
}

public struct Issue: Identifiable, Equatable {
    public var id = UUID()
    public var kind: IssueKind
    public var message: String
    public var refs: [RowRef]
    /// For role spelling: all variants with their counts, most frequent first.
    public var variants: [(name: String, count: Int)] = []
    /// Sheets that were compared for role spelling.
    public var scopeSheets: [UUID] = []
    /// Stable key used to remember dismissed warnings across scans.
    public var key: String

    public static func == (a: Issue, b: Issue) -> Bool { a.id == b.id }
}

public struct TakeInfo {
    public var inF: Int?
    public var outF: Int?
    public var inStyle: TimecodeStyle?
    public var outStyle: TimecodeStyle?
    public var inInvalid = false
    public var outInvalid = false
}

public enum Scanner {
    public static func takeInfo(_ row: SheetRow, _ m: ColumnMapping, _ tc: Timecode) -> TakeInfo {
        var info = TakeInfo()
        if m.combinedTimecode {
            let c = row.cell(m.tcIn)
            if c.value.isBlank { return info }
            if let r = tc.parseRange(c) {
                info.inF = r.inF; info.outF = r.outF; info.inStyle = r.style; info.outStyle = r.style
            } else { info.inInvalid = true; info.outInvalid = true }
            return info
        }
        let ci = row.cell(m.tcIn), co = row.cell(m.tcOut)
        if !ci.value.isBlank {
            if let p = tc.parse(ci) { info.inF = p.frames; info.inStyle = p.style } else { info.inInvalid = true }
        }
        if !co.value.isBlank {
            if let p = tc.parse(co) { info.outF = p.frames; info.outStyle = p.style } else { info.outInvalid = true }
        }
        return info
    }

    // MARK: Split proposals

    public static func proposals(for sheets: [TakeSheet], settings: ScanSettings) -> (proposals: [SplitProposal], issues: [Issue]) {
        var props: [SplitProposal] = []
        var issues: [Issue] = []
        let tc = Timecode(fps: settings.fps)
        for sheet in sheets {
            let m = sheet.mapping
            guard m.text != nil else { continue }
            for i in sheet.dataRange {
                let row = sheet.rows[i]
                guard sheet.isTake(row) else { continue }
                let text = row.text(m.text)
                guard !text.isEmpty else { continue }
                let words = TextSplitter.wordCount(text, ignoreDirections: settings.ignoreDirections)
                let info = takeInfo(row, m, tc)
                let duration = (info.inF != nil && info.outF != nil) ? info.outF! - info.inF! : nil
                let tooManyWords = settings.maxWordsEnabled && words > settings.maxWords
                let maxDur = Int(settings.maxDurationSeconds * Double(settings.fps))
                let tooLong = settings.maxDurationEnabled && (duration ?? 0) > maxDur && maxDur > 0
                guard tooManyWords || tooLong else { continue }
                let ref = [RowRef(sheetID: sheet.id, rowID: row.id)]
                let rowLabel = "Zeile \(row.label)"

                guard let inF = info.inF, let outF = info.outF, outF > inF else {
                    issues.append(Issue(kind: .cannotSplit, message: "\(rowLabel): \(words) Wörter, aber ohne gültige Timecodes kann der Take nicht aufgeteilt werden.",
                                        refs: ref, key: "split-tc-\(row.id)"))
                    continue
                }
                let minChunks = tooLong ? Int((Double(outF - inF) / Double(maxDur)).rounded(.up)) : 1
                guard let result = TextSplitter.split(text, maxWords: settings.maxWordsEnabled ? settings.maxWords : nil,
                                                      minChunks: minChunks, ignoreDirections: settings.ignoreDirections,
                                                      allowClauses: settings.allowClauseSplit) else {
                    issues.append(Issue(kind: .cannotSplit, message: "\(rowLabel): \(words) Wörter in einem einzigen Satz – Teilung nur innerhalb des Satzes möglich.",
                                        refs: ref, key: "split-one-\(row.id)"))
                    continue
                }
                let style = info.inStyle ?? .frames(separator: ":")
                let q = max(tc.quantum(for: style), tc.quantum(for: info.outStyle ?? style))
                guard let times = distribute(inF: inF, outF: outF, chunks: result.chunks, quantum: q, gap: settings.gapFrames, settings: settings) else {
                    issues.append(Issue(kind: .cannotSplit, message: "\(rowLabel): Take ist zu kurz, um ihn in \(result.chunks.count) Takes zu teilen.",
                                        refs: ref, key: "split-short-\(row.id)"))
                    continue
                }
                let baseNumber = row.text(m.takeNumber)
                var parts: [ProposedTake] = []
                for (n, chunk) in result.chunks.enumerated() {
                    var number: String?
                    if m.takeNumber != nil {
                        switch settings.takeNumberMode {
                        case .suffix: number = baseNumber.isEmpty ? "" : baseNumber + suffix(n)
                        case .keep, .renumber: number = baseNumber
                        case .empty: number = ""
                        }
                    }
                    parts.append(ProposedTake(text: chunk, inFrames: times[n].0, outFrames: times[n].1, takeNumber: number,
                                              words: TextSplitter.wordCount(chunk, ignoreDirections: settings.ignoreDirections)))
                }
                var reasons: [String] = []
                if tooManyWords { reasons.append("\(words) Wörter (max. \(settings.maxWords))") }
                if tooLong { reasons.append(String(format: "%.1f s (max. %.0f s)", tc.seconds(outF - inF), settings.maxDurationSeconds)) }
                var notes: [String] = []
                for idx in result.oversizedChunks {
                    notes.append("Teil \(idx + 1) bleibt mit \(parts[idx].words) Wörtern über dem Limit (Satz zu lang).")
                }
                props.append(SplitProposal(sheetID: sheet.id, rowID: row.id, originalWords: words, originalDuration: outF - inF,
                                           parts: parts, reason: reasons.joined(separator: " · "), notes: notes))
            }
        }
        return (props, issues)
    }

    static func suffix(_ n: Int) -> String {
        var n = n
        var s = ""
        repeat {
            s = String(UnicodeScalar(97 + n % 26)!) + s
            n = n / 26 - 1
        } while n >= 0
        return s
    }

    /// Distributes [inF, outF] over the chunks proportionally to their weight, snapping to `quantum`.
    /// The first take starts exactly at `inF`, the last ends exactly at `outF`.
    public static func distribute(inF: Int, outF: Int, chunks: [String], quantum: Int, gap: Int, settings: ScanSettings) -> [(Int, Int)]? {
        let n = chunks.count
        let total = outF - inF
        let q = max(1, quantum)
        guard total >= n * q + (n - 1) * max(0, gap) else { return nil }
        let weights = chunks.map { c -> Double in
            let w = settings.weighting == .words
                ? TextSplitter.wordCount(c, ignoreDirections: settings.ignoreDirections)
                : TextSplitter.letterCount(c, ignoreDirections: settings.ignoreDirections)
            return Double(max(1, w))
        }
        let sum = weights.reduce(0, +)
        var bounds = [inF]
        var acc = 0.0
        for i in 0..<(n - 1) {
            acc += weights[i]
            var b = inF + Int((Double(total) * acc / sum).rounded())
            b = inF + Int((Double(b - inF) / Double(q)).rounded()) * q
            bounds.append(b)
        }
        bounds.append(outF)
        // Enforce minimum length per take (quantum + gap), forward then backward.
        let g = max(0, gap)
        for i in 1..<n { bounds[i] = max(bounds[i], bounds[i - 1] + q + g) }
        for i in stride(from: n - 1, through: 1, by: -1) { bounds[i] = min(bounds[i], bounds[i + 1] - q - g) }
        var result: [(Int, Int)] = []
        for i in 0..<n {
            let start = bounds[i]
            let end = i == n - 1 ? outF : bounds[i + 1] - g
            guard end > start, start >= inF, end <= outF else { return nil }
            result.append((start, end))
        }
        return result
    }

    /// Builds the rows that replace the original row when a proposal is applied.
    public static func rows(for proposal: SplitProposal, original: SheetRow, mapping m: ColumnMapping, settings: ScanSettings) -> [SheetRow] {
        let tc = Timecode(fps: settings.fps)
        let info = takeInfo(original, m, tc)
        let inStyle = info.inStyle ?? .frames(separator: ":")
        let outStyle = info.outStyle ?? inStyle
        return proposal.parts.map { part in
            var r = SheetRow(sourceRow: nil, origin: original.sourceRow ?? original.origin, attrs: original.attrs, cells: original.cells)
            let textCell = original.cell(m.text)
            r.set(m.text, Cell(.string(part.text), style: textCell.style))
            if m.combinedTimecode {
                let c = original.cell(m.tcIn)
                let s = tc.string(part.inFrames, style: inStyle == .excel ? .frames(separator: ":") : inStyle) + " - " +
                    tc.string(part.outFrames, style: outStyle == .excel ? .frames(separator: ":") : outStyle)
                r.set(m.tcIn, Cell(.string(s), style: c.style))
            } else {
                r.set(m.tcIn, Cell(tc.cellValue(part.inFrames, style: inStyle), style: original.cell(m.tcIn).style))
                r.set(m.tcOut, Cell(tc.cellValue(part.outFrames, style: outStyle), style: original.cell(m.tcOut).style))
            }
            if let num = part.takeNumber, m.takeNumber != nil {
                let c = original.cell(m.takeNumber)
                let value: CellValue = num.isEmpty ? .empty : (num == c.text ? c.value : .string(num))
                r.set(m.takeNumber, Cell(value, style: c.style))
            }
            return r
        }
    }

    /// Renumbers all takes of a sheet consecutively, starting at the first numeric take number.
    public static func renumber(_ sheet: inout TakeSheet) {
        guard let col = sheet.mapping.takeNumber else { return }
        let range = sheet.dataRange
        let takeRows = range.filter { sheet.isTake(sheet.rows[$0]) }
        let rows = sheet.rows
        let start = takeRows.lazy.compactMap { Int(rows[$0].text(col)) }.first ?? 1
        for (n, i) in takeRows.enumerated() {
            let style = sheet.rows[i].cell(col).style
            sheet.rows[i].set(col, Cell(.number(Double(start + n)), style: style))
        }
    }

    // MARK: Integrity

    public static func integrity(_ sheets: [TakeSheet], settings: ScanSettings) -> [Issue] {
        var issues: [Issue] = []
        let tc = Timecode(fps: settings.fps)
        for sheet in sheets {
            let m = sheet.mapping
            var timed: [(row: SheetRow, inF: Int, outF: Int, role: String)] = []
            for i in sheet.dataRange {
                let row = sheet.rows[i]
                guard sheet.isTake(row) else { continue }
                let ref = [RowRef(sheetID: sheet.id, rowID: row.id)]
                let label = "Zeile \(row.label)"
                let role = row.text(m.role)
                if settings.checkMissingRole, role.isEmpty {
                    issues.append(Issue(kind: .missingRole, message: "\(label): Take ist keiner Rolle zugeordnet.", refs: ref, key: "role-\(row.id)"))
                }
                let info = takeInfo(row, m, tc)
                if settings.checkMissingTimecode {
                    var missing: [String] = []
                    if info.inF == nil, !info.inInvalid { missing.append("TC In") }
                    if info.outF == nil, !info.outInvalid { missing.append("TC Out") }
                    if !missing.isEmpty {
                        issues.append(Issue(kind: .missingTimecode, message: "\(label): \(missing.joined(separator: " und ")) fehlt.", refs: ref, key: "tcmiss-\(row.id)"))
                    }
                    var invalid: [String] = []
                    if info.inInvalid { invalid.append("TC In „\(row.text(m.tcIn))“") }
                    if info.outInvalid, !m.combinedTimecode { invalid.append("TC Out „\(row.text(m.tcOut))“") }
                    if !invalid.isEmpty {
                        issues.append(Issue(kind: .invalidTimecode, message: "\(label): \(invalid.joined(separator: ", ")) nicht lesbar (\(settings.fps) fps).", refs: ref, key: "tcinv-\(row.id)"))
                    }
                    if let a = info.inF, let b = info.outF, b <= a {
                        issues.append(Issue(kind: .reversedTimecode, message: "\(label): TC Out liegt nicht nach TC In.", refs: ref, key: "tcrev-\(row.id)"))
                    }
                }
                if let a = info.inF, let b = info.outF, b > a { timed.append((row, a, b, role.lowercased())) }
                if settings.checkUmlauts || settings.checkSpecialCharacters, let issue = characterIssue(row, sheet, settings, ref, label) {
                    issues.append(issue)
                }
            }
            if settings.checkOverlap {
                let groups: [[(row: SheetRow, inF: Int, outF: Int, role: String)]] =
                    settings.overlapSameRoleOnly ? Array(Dictionary(grouping: timed, by: { $0.role }).values) : [timed]
                for g in groups {
                    let sorted = g.enumerated().sorted { ($0.element.inF, $0.offset) < ($1.element.inF, $1.offset) }.map(\.element)
                    var maxOut: (row: SheetRow, outF: Int)?
                    for t in sorted {
                        if let prev = maxOut, t.inF < prev.outF {
                            let a = prev.row.label, b = t.row.label
                            let ov = tc.seconds(min(prev.outF, t.outF) - t.inF)
                            issues.append(Issue(kind: .overlap,
                                                message: String(format: "Zeile %@ überlappt mit Zeile %@ (%.2f s).", b, a, ov),
                                                refs: [RowRef(sheetID: sheet.id, rowID: t.row.id), RowRef(sheetID: sheet.id, rowID: prev.row.id)],
                                                key: "ov-\(prev.row.id)-\(t.row.id)"))
                        }
                        if t.outF > (maxOut?.outF ?? .min) { maxOut = (t.row, t.outF) }
                    }
                }
            }
        }
        if settings.checkRoleSpelling { issues += roleSpelling(sheets, settings: settings) }
        return issues
    }

    /// Columns that end up in markers/exports and are checked for special characters.
    public static func textColumns(_ m: ColumnMapping) -> [(Int, String)] {
        var cols: [(Int, String)] = []
        if let c = m.role { cols.append((c, "Rolle")) }
        if let c = m.text, c != m.role { cols.append((c, "Text")) }
        if let c = m.takeNumber, c != m.text, c != m.role { cols.append((c, "Take-Nr.")) }
        return cols
    }

    static func characterIssue(_ row: SheetRow, _ sheet: TakeSheet, _ settings: ScanSettings, _ ref: [RowRef], _ label: String) -> Issue? {
        var parts: [String] = []
        var damaged = false, special = false, umlaut = false
        for (col, name) in textColumns(sheet.mapping) {
            let f = CharacterCheck.analyze(row.cell(col).text)
            var bits: [String] = []
            if f.damaged { damaged = true; bits.append("vermutlich falsch kodiert") }
            if settings.checkSpecialCharacters, !f.special.isEmpty {
                special = true
                bits.append("Sonderzeichen " + f.special.prefix(8).map(CharacterCheck.describe).joined(separator: ", "))
            }
            if settings.checkUmlauts, !f.umlauts.isEmpty {
                umlaut = true
                bits.append("Umlaute " + f.umlauts.map { String($0) }.joined(separator: " "))
            }
            if !bits.isEmpty { parts.append("\(name): " + bits.joined(separator: "; ")) }
        }
        guard !parts.isEmpty else { return nil }
        let kind: IssueKind = damaged ? .encodingDamage : (special ? .specialCharacters : .umlauts)
        _ = umlaut
        return Issue(kind: kind, message: "\(label) – " + parts.joined(separator: " · "), refs: ref, key: "chars-\(kind.rawValue)-\(row.id)")
    }

    static func roleKey(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de"))
            .filter { !$0.isWhitespace && $0 != "." && $0 != "-" && $0 != "_" }
    }

    public static func roleSpelling(_ sheets: [TakeSheet], settings: ScanSettings) -> [Issue] {
        var scopes: [String: [TakeSheet]] = [:]
        for s in sheets {
            let key: String
            switch settings.roleScope {
            case .sheet: key = s.id.uuidString
            case .file: key = s.fileURL.path
            case .all: key = "all"
            }
            scopes[key, default: []].append(s)
        }
        var issues: [Issue] = []
        for (_, group) in scopes.sorted(by: { $0.key < $1.key }) {
            var counts: [String: Int] = [:]
            var refs: [String: [RowRef]] = [:]
            var order: [String] = []
            for sheet in group {
                for i in sheet.dataRange {
                    let row = sheet.rows[i]
                    let role = row.text(sheet.mapping.role)
                    guard !role.isEmpty else { continue }
                    if counts[role] == nil { order.append(role) }
                    counts[role, default: 0] += 1
                    refs[role, default: []].append(RowRef(sheetID: sheet.id, rowID: row.id))
                }
            }
            let names = order
            guard names.count > 1 else { continue }
            let keys = names.map(roleKey)
            var parent = Array(names.indices)
            func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
            for a in 0..<names.count {
                for b in (a + 1)..<names.count where isVariant(keys[a], keys[b], tolerance: settings.roleTolerance) {
                    parent[find(a)] = find(b)
                }
            }
            var clusters: [Int: [Int]] = [:]
            for i in names.indices { clusters[find(i), default: []].append(i) }
            for (_, members) in clusters where members.count > 1 {
                let variants = members.map { (name: names[$0], count: counts[names[$0]]!) }
                    .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
                let main = variants[0]
                let minorityRefs = variants.dropFirst().flatMap { refs[$0.name] ?? [] }
                let list = variants.map { "„\($0.name)“ (\($0.count)×)" }.joined(separator: ", ")
                issues.append(Issue(kind: .roleSpelling, message: "Rollennamen sehr ähnlich: \(list). Vermutlich „\(main.name)“ gemeint.",
                                    refs: minorityRefs, variants: variants, scopeSheets: group.map(\.id),
                                    key: "rs-" + variants.map(\.name).sorted().joined(separator: "|")))
            }
        }
        return issues
    }

    static func isVariant(_ a: String, _ b: String, tolerance: Int) -> Bool {
        if a == b { return true } // differ only in case/spaces/accents
        // "MANN 1" vs "MANN 2": numbered roles are distinct.
        let da = a.filter(\.isNumber), db = b.filter(\.isNumber)
        if da != db, (!da.isEmpty || !db.isEmpty) { return false }
        let shortest = min(a.count, b.count)
        guard shortest >= 3 else { return false }
        let tol = shortest < 5 ? min(1, tolerance) : tolerance
        guard abs(a.count - b.count) <= tol else { return false }
        return damerau(Array(a), Array(b), limit: tol) <= tol
    }

    static func damerau(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        let n = a.count, m = b.count
        if n == 0 { return m }
        if m == 0 { return n }
        var d = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        for i in 1...n {
            var rowMin = Int.max
            for j in 1...m {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
                rowMin = min(rowMin, d[i][j])
            }
            if rowMin > limit { return rowMin }
        }
        return d[n][m]
    }
}
