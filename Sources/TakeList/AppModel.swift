import AppKit
import Observation
import SwiftUI
import TakeListCore
import UniformTypeIdentifiers

struct PendingFile: Identifiable {
    let id = UUID()
    let url: URL
    let workbook: Workbook
    let data: Data
    var selection: Set<String>
}

struct PendingSheet: Identifiable {
    let id = UUID()
    let url: URL
    let info: WorkbookSheetInfo
    let rows: [SheetRow]
    var headerRow: Int
    var mapping: ColumnMapping
    /// Set when re-mapping an already imported sheet.
    var existingSheetID: UUID?
}

enum DisplayKind { case normal, removed, added }

struct DisplayRow {
    let row: SheetRow
    let kind: DisplayKind
    let proposalID: UUID?
}

struct Focus: Equatable {
    var sheetID: UUID
    var rowIDs: Set<UUID>
    var proposalID: UUID?
    var scrollTo: UUID
    var token = UUID()
}

enum SidebarFilter: String, CaseIterable, Identifiable {
    case all, current
    var id: String { rawValue }
    var label: String { self == .all ? "Alle Tabellen" : "Aktuelle Tabelle" }
}

@Observable
@MainActor
final class AppModel {
    static let shared = AppModel()

    var sheets: [TakeSheet] = [] { didSet { version += 1 } }
    var proposals: [SplitProposal] = [] { didSet { version += 1 } }
    private(set) var version = 0
    var sources: [URL: Data] = [:]
    var selectedSheetID: UUID?
    var integrityIssues: [Issue] = []
    var splitIssues: [Issue] = []
    var dismissedIssueKeys: Set<String> = []
    var dirtyFiles: Set<URL> = []
    var settings: ScanSettings { didSet { saveSettings() } }
    var settingsAtScan: ScanSettings?
    var lastScan: Date?

    var pendingFiles: [PendingFile] = []
    var pendingSheets: [PendingSheet] = []
    var focus: Focus?
    var sidebarSelection: UUID?
    var sidebarFilter: SidebarFilter = .all
    var editingRow: RowRef?
    var hiddenKinds: Set<IssueKind> = []
    var showMarkerExport = false
    var markerOptions: MarkerOptions {
        didSet { if let d = try? JSONEncoder().encode(markerOptions) { UserDefaults.standard.set(d, forKey: "markerOptions") } }
    }
    var errorMessage: String?
    var infoMessage: String?
    @ObservationIgnored var undoManager: UndoManager?
    @ObservationIgnored private var refCycle: [UUID: Int] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: "scanSettings"),
           let s = try? JSONDecoder().decode(ScanSettings.self, from: data) {
            settings = s
        } else {
            settings = ScanSettings()
        }
        if let data = UserDefaults.standard.data(forKey: "markerOptions"),
           let o = try? JSONDecoder().decode(MarkerOptions.self, from: data) {
            markerOptions = o
        } else {
            markerOptions = MarkerOptions()
        }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "scanSettings") }
    }

    // MARK: Derived

    var selectedSheet: TakeSheet? { sheets.first { $0.id == selectedSheetID } }
    var isDirty: Bool { !dirtyFiles.isEmpty }
    var issues: [Issue] { (integrityIssues + splitIssues).filter { !dismissedIssueKeys.contains($0.key) } }
    var acceptedCount: Int { proposals.filter(\.accepted).count }
    var settingsChangedSinceScan: Bool { settingsAtScan != nil && settingsAtScan != settings }

    func sheet(_ id: UUID) -> TakeSheet? { sheets.first { $0.id == id } }

    func visibleProposals() -> [SplitProposal] {
        sidebarFilter == .current ? proposals.filter { $0.sheetID == selectedSheetID } : proposals
    }

    func visibleIssues() -> [Issue] {
        let all = issues.filter { !hiddenKinds.contains($0.kind) }
        guard sidebarFilter == .current, let sel = selectedSheetID else { return all }
        return all.filter { $0.refs.contains { $0.sheetID == sel } }
    }

    func row(_ ref: RowRef) -> SheetRow? {
        sheet(ref.sheetID)?.rows.first { $0.id == ref.rowID }
    }

    func displayRows(for sheet: TakeSheet) -> [DisplayRow] {
        var byRow: [UUID: SplitProposal] = [:]
        for p in proposals where p.sheetID == sheet.id { byRow[p.rowID] = p }
        var out: [DisplayRow] = []
        out.reserveCapacity(sheet.rows.count)
        for i in sheet.dataRange {
            let row = sheet.rows[i]
            if let p = byRow[row.id], p.accepted {
                out.append(DisplayRow(row: row, kind: .removed, proposalID: p.id))
                for r in Scanner.rows(for: p, original: row, mapping: sheet.mapping, settings: settings) {
                    out.append(DisplayRow(row: r, kind: .added, proposalID: p.id))
                }
            } else {
                out.append(DisplayRow(row: row, kind: .normal, proposalID: byRow[row.id]?.id))
            }
        }
        return out
    }

    // MARK: Import

    func showImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = "Excel-Takelisten (.xlsx) auswählen"
        panel.prompt = "Importieren"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// True while the import dialog (sheet selection or column mapping) is open.
    var importActive: Bool { !pendingFiles.isEmpty || !pendingSheets.isEmpty }

    /// Aborts the whole import: closes the dialog and discards everything that was not imported yet.
    func cancelImport() {
        let urls = Set(pendingFiles.map(\.url) + pendingSheets.filter { $0.existingSheetID == nil }.map(\.url))
        pendingFiles.removeAll()
        pendingSheets.removeAll()
        for url in urls where !sheets.contains(where: { $0.fileURL == url }) { sources[url] = nil }
    }

    func importFiles(_ urls: [URL]) {
        for url in urls where !pendingFiles.contains(where: { $0.url == url }) {
            guard url.pathExtension.lowercased() == "xlsx" else {
                errorMessage = "„\(url.lastPathComponent)“ ist keine .xlsx-Datei. Bitte alte .xls-Dateien in Excel als .xlsx sichern."
                continue
            }
            do {
                let data = try sources[url] ?? Data(contentsOf: url)
                let wb = try Workbook(url: url, data: data)
                guard !wb.sheets.isEmpty else { errorMessage = "„\(url.lastPathComponent)“ enthält keine Tabellenblätter."; continue }
                let already = Set(sheets.filter { $0.fileURL == url }.map(\.sheetPath))
                let selection = Set(wb.sheets.map(\.path).filter { !already.contains($0) })
                pendingFiles.append(PendingFile(url: url, workbook: wb, data: data, selection: selection))
            } catch {
                errorMessage = "„\(url.lastPathComponent)“ konnte nicht gelesen werden: \(error.localizedDescription)"
            }
        }
    }

    func isImported(_ url: URL, _ path: String) -> Bool {
        sheets.contains { $0.fileURL == url && $0.sheetPath == path }
    }

    func confirmSheetSelection(_ file: PendingFile) {
        pendingFiles.removeAll { $0.id == file.id }
        if sources[file.url] == nil { sources[file.url] = file.data }
        for info in file.workbook.sheets where file.selection.contains(info.path) {
            do {
                let rows = try file.workbook.loadRows(info)
                let header = ColumnDetector.guessHeaderRow(rows)
                let mapping = ColumnDetector.detect(rows: rows, headerRow: header, fps: settings.fps)
                pendingSheets.append(PendingSheet(url: file.url, info: info, rows: rows, headerRow: header, mapping: mapping))
            } catch {
                errorMessage = "Tabellenblatt „\(info.name)“: \(error.localizedDescription)"
            }
        }
    }

    func cancelSheetSelection(_ file: PendingFile) {
        pendingFiles.removeAll { $0.id == file.id }
        if !sheets.contains(where: { $0.fileURL == file.url }), !pendingSheets.contains(where: { $0.url == file.url }) {
            sources[file.url] = nil
        }
    }

    func confirmMapping(_ pending: PendingSheet) {
        pendingSheets.removeAll { $0.id == pending.id }
        if let existing = pending.existingSheetID, let idx = sheets.firstIndex(where: { $0.id == existing }) {
            registerUndo("Spaltenzuordnung ändern")
            sheets[idx].mapping = pending.mapping
            sheets[idx].headerRowIndex = pending.headerRow
            proposals.removeAll { $0.sheetID == existing }
            splitIssues.removeAll { $0.refs.contains { $0.sheetID == existing } }
        } else {
            let sheet = TakeSheet(fileURL: pending.url, sheetName: pending.info.name, sheetPath: pending.info.path,
                                  rows: pending.rows, headerRowIndex: pending.headerRow, mapping: pending.mapping)
            sheets.append(sheet)
            selectedSheetID = sheet.id
        }
        runIntegrity()
    }

    func skipMapping(_ pending: PendingSheet) {
        pendingSheets.removeAll { $0.id == pending.id }
        if pending.existingSheetID == nil, !sheets.contains(where: { $0.fileURL == pending.url }),
           !pendingSheets.contains(where: { $0.url == pending.url }) {
            sources[pending.url] = nil
        }
    }

    func remap(_ sheetID: UUID) {
        guard let s = sheet(sheetID) else { return }
        pendingSheets.append(PendingSheet(url: s.fileURL, info: WorkbookSheetInfo(name: s.sheetName, path: s.sheetPath),
                                          rows: s.rows, headerRow: s.headerRowIndex, mapping: s.mapping, existingSheetID: s.id))
    }

    func closeSheet(_ id: UUID) {
        guard let s = sheet(id) else { return }
        if s.isModified, dirtyFiles.contains(s.fileURL) {
            let alert = NSAlert()
            alert.messageText = "„\(s.title)“ schließen?"
            alert.informativeText = "Die Tabelle enthält Änderungen, die noch nicht exportiert wurden."
            alert.addButton(withTitle: "Schließen")
            alert.addButton(withTitle: "Abbrechen")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let idx = sheets.firstIndex { $0.id == id } ?? 0
        sheets.removeAll { $0.id == id }
        proposals.removeAll { $0.sheetID == id }
        splitIssues.removeAll { $0.refs.contains { $0.sheetID == id } }
        if !sheets.contains(where: { $0.fileURL == s.fileURL }) {
            sources[s.fileURL] = nil
            dirtyFiles.remove(s.fileURL)
        }
        if selectedSheetID == id { selectedSheetID = sheets.isEmpty ? nil : sheets[min(idx, sheets.count - 1)].id }
        if focus?.sheetID == id { focus = nil }
        undoManager?.removeAllActions()
        runIntegrity()
    }

    // MARK: Scan

    func scan() {
        let result = Scanner.proposals(for: sheets, settings: settings)
        proposals = result.proposals
        splitIssues = result.issues
        settingsAtScan = settings
        lastScan = Date()
        focus = nil
        sidebarSelection = nil
        runIntegrity()
    }

    func runIntegrity() {
        integrityIssues = Scanner.integrity(sheets, settings: settings)
        let ids = Set(sheets.map(\.id))
        splitIssues.removeAll { issue in issue.refs.contains { !ids.contains($0.sheetID) } }
    }

    // MARK: Proposals

    func setAccepted(_ id: UUID, _ accepted: Bool) {
        guard let i = proposals.firstIndex(where: { $0.id == id }) else { return }
        proposals[i].accepted = accepted
        if sidebarSelection == id { navigate(toProposal: proposals[i]) }
    }

    func setAll(_ accepted: Bool) {
        let visible = Set(visibleProposals().map(\.id))
        for i in proposals.indices where visible.contains(proposals[i].id) { proposals[i].accepted = accepted }
        if let f = focus, let pid = f.proposalID, let p = proposals.first(where: { $0.id == pid }) { navigate(toProposal: p) }
    }

    func applyAccepted() {
        let accepted = proposals.filter(\.accepted)
        guard !accepted.isEmpty else { return }
        registerUndo("Änderungen übernehmen")
        let byRow = Dictionary(accepted.map { ($0.rowID, $0) }, uniquingKeysWith: { a, _ in a })
        for s in sheets.indices {
            let sheet = sheets[s]
            guard accepted.contains(where: { $0.sheetID == sheet.id }) else { continue }
            var newRows: [SheetRow] = []
            newRows.reserveCapacity(sheet.rows.count + accepted.count * 2)
            for (i, row) in sheet.rows.enumerated() {
                if i > sheet.headerRowIndex, let p = byRow[row.id], p.sheetID == sheet.id {
                    newRows += Scanner.rows(for: p, original: row, mapping: sheet.mapping, settings: settings)
                } else {
                    newRows.append(row)
                }
            }
            sheets[s].rows = newRows
            if settings.takeNumberMode == .renumber { Scanner.renumber(&sheets[s]) }
            sheets[s].isModified = true
            dirtyFiles.insert(sheet.fileURL)
        }
        let appliedIDs = Set(accepted.map(\.id))
        proposals.removeAll { appliedIDs.contains($0.id) }
        splitIssues.removeAll { issue in issue.refs.contains { byRow[$0.rowID] != nil } }
        focus = nil
        sidebarSelection = nil
        runIntegrity()
        infoMessage = "\(accepted.count) Änderung\(accepted.count == 1 ? "" : "en") übernommen."
    }

    // MARK: Navigation

    func navigate(to itemID: UUID?) {
        guard let itemID else { focus = nil; return }
        if let p = proposals.first(where: { $0.id == itemID }) {
            navigate(toProposal: p)
        } else if let issue = issues.first(where: { $0.id == itemID }) {
            navigate(toIssue: issue, advance: false)
        }
    }

    func navigate(toProposal p: SplitProposal) {
        selectedSheetID = p.sheetID
        focus = Focus(sheetID: p.sheetID, rowIDs: [p.rowID], proposalID: p.id, scrollTo: p.rowID)
    }

    func navigate(toIssue issue: Issue, advance: Bool) {
        guard !issue.refs.isEmpty else { return }
        var n = refCycle[issue.id] ?? 0
        if advance { n = (n + 1) % issue.refs.count }
        refCycle[issue.id] = n
        let target = issue.refs[n]
        selectedSheetID = target.sheetID
        let ids = Set(issue.refs.filter { $0.sheetID == target.sheetID }.map(\.rowID))
        focus = Focus(sheetID: target.sheetID, rowIDs: ids, proposalID: nil, scrollTo: target.rowID)
    }

    func refPosition(_ issue: Issue) -> Int { refCycle[issue.id] ?? 0 }

    // MARK: Editing

    func dismiss(_ issue: Issue) { dismissedIssueKeys.insert(issue.key) }

    func restoreDismissed() { dismissedIssueKeys.removeAll() }

    func unifyRole(_ issue: Issue, to target: String) {
        let names = Set(issue.variants.map(\.name)).subtracting([target])
        let scope = Set(issue.scopeSheets)
        registerUndo("Rollennamen vereinheitlichen")
        var changed = 0
        for s in sheets.indices where scope.contains(sheets[s].id) {
            guard let col = sheets[s].mapping.role else { continue }
            var touched = false
            for i in sheets[s].dataRange where names.contains(sheets[s].rows[i].text(col)) {
                let style = sheets[s].rows[i].cell(col).style
                sheets[s].rows[i].set(col, Cell(.string(target), style: style))
                touched = true
                changed += 1
            }
            if touched {
                sheets[s].isModified = true
                dirtyFiles.insert(sheets[s].fileURL)
            }
        }
        runIntegrity()
        infoMessage = "\(changed) Take\(changed == 1 ? "" : "s") auf „\(target)“ umbenannt."
    }

    func updateRow(_ ref: RowRef, texts: [Int: String]) {
        guard let s = sheets.firstIndex(where: { $0.id == ref.sheetID }),
              let r = sheets[s].rows.firstIndex(where: { $0.id == ref.rowID }) else { return }
        registerUndo("Take bearbeiten")
        var row = sheets[s].rows[r]
        var changed = false
        for (col, newText) in texts {
            let old = row.cell(col)
            guard old.text != newText else { continue }
            let value: CellValue
            if newText.isEmpty { value = .empty } else if case .number = old.value, let d = Double(newText.replacingOccurrences(of: ",", with: ".")) { value = .number(d) } else { value = .string(newText) }
            row.set(col, Cell(value, style: old.style))
            changed = true
        }
        guard changed else { return }
        sheets[s].rows[r] = row
        sheets[s].columnCount = max(sheets[s].columnCount, row.cells.count)
        sheets[s].isModified = true
        dirtyFiles.insert(sheets[s].fileURL)
        proposals.removeAll { $0.rowID == ref.rowID }
        splitIssues.removeAll { $0.refs.contains { $0.rowID == ref.rowID } }
        runIntegrity()
    }

    /// Inline edit of a single cell from the table.
    func updateCell(_ ref: RowRef, column: Int, text: String) {
        guard let sheet = sheet(ref.sheetID), let row = row(ref) else { return }
        let m = sheet.mapping
        let old = row.cell(column)
        let tc = Timecode(fps: settings.fps)
        if (column == m.tcIn || column == m.tcOut), !m.combinedTimecode, case .number = old.value, let p = tc.parse(old) {
            // Excel time value shown as timecode: keep it a time value if the new text is a valid timecode.
            if text == tc.string(p.frames, style: .frames(separator: ":")) { return }
            if let n = tc.parse(text) {
                replaceCell(ref, column: column, with: Cell(tc.cellValue(n.frames, style: .excel), style: old.style), name: "Zelle bearbeiten")
                return
            }
        }
        updateRow(ref, texts: [column: text])
    }

    private func replaceCell(_ ref: RowRef, column: Int, with cell: Cell, name: String) {
        guard let s = sheets.firstIndex(where: { $0.id == ref.sheetID }),
              let r = sheets[s].rows.firstIndex(where: { $0.id == ref.rowID }) else { return }
        registerUndo(name)
        sheets[s].rows[r].set(column, cell)
        markChanged(s, rowID: ref.rowID)
    }

    private func markChanged(_ s: Int, rowID: UUID?) {
        sheets[s].isModified = true
        dirtyFiles.insert(sheets[s].fileURL)
        if let rowID {
            proposals.removeAll { $0.rowID == rowID }
            splitIssues.removeAll { $0.refs.contains { $0.rowID == rowID } }
        }
        runIntegrity()
    }

    enum CharacterFix: String, CaseIterable, Identifiable {
        case typographic, transliterate, repair
        var id: String { rawValue }
        var label: String {
            switch self {
            case .typographic: return "Typografische & unsichtbare Zeichen ersetzen („“ – … → \" - ...)"
            case .transliterate: return "Alles in reines ASCII umschreiben (ä → ae, ß → ss, é → e)"
            case .repair: return "Kodierungsfehler reparieren (FÃ¼r → Für)"
            }
        }
        func apply(_ s: String) -> String {
            switch self {
            case .typographic: return CharacterCheck.replacingTypographic(s)
            case .transliterate: return CharacterCheck.transliterated(s)
            case .repair: return CharacterCheck.repairedMojibake(s) ?? s
            }
        }
    }

    /// Applies a character fix to the role/text/take columns of the given rows (nil = all takes in all tables).
    func fixCharacters(_ refs: [RowRef]?, _ fix: CharacterFix) {
        let wanted = refs.map { Set($0.map(\.rowID)) }
        var updated = sheets
        var changed = 0
        var files: Set<URL> = []
        for s in updated.indices {
            let cols = Scanner.textColumns(updated[s].mapping).map(\.0)
            var touched = false
            for i in updated[s].dataRange {
                let row = updated[s].rows[i]
                if let wanted, !wanted.contains(row.id) { continue }
                for c in cols {
                    let cell = row.cell(c)
                    guard case .string(let old) = cell.value else { continue }
                    let new = fix.apply(old)
                    if new != old {
                        updated[s].rows[i].set(c, Cell(.string(new), style: cell.style))
                        touched = true
                        changed += 1
                    }
                }
            }
            if touched { updated[s].isModified = true; files.insert(updated[s].fileURL) }
        }
        guard changed > 0 else { infoMessage = "Keine passenden Zeichen gefunden."; return }
        registerUndo("Sonderzeichen ersetzen")
        sheets = updated
        dirtyFiles.formUnion(files)
        runIntegrity()
        infoMessage = "\(changed) Zelle\(changed == 1 ? "" : "n") korrigiert."
    }

    // MARK: Undo

    private struct Snapshot {
        var sheets: [TakeSheet]
        var proposals: [SplitProposal]
        var splitIssues: [Issue]
        var dirtyFiles: Set<URL>
    }

    private func registerUndo(_ name: String) {
        let snap = Snapshot(sheets: sheets, proposals: proposals, splitIssues: splitIssues, dirtyFiles: dirtyFiles)
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(snap, name: name) }
        }
        undoManager?.setActionName(name)
    }

    private func restore(_ snap: Snapshot, name: String) {
        registerUndo(name)
        sheets = snap.sheets
        proposals = snap.proposals
        splitIssues = snap.splitIssues
        dirtyFiles = snap.dirtyFiles
        if let sel = selectedSheetID, sheet(sel) == nil { selectedSheetID = sheets.first?.id }
        focus = nil
        runIntegrity()
    }

    // MARK: Export

    func export() {
        guard !sheets.isEmpty, resolvePendingAccepted() else { return }
        var files: [URL] = []
        for s in sheets where !files.contains(s.fileURL) { files.append(s.fileURL) }
        if files.count == 1 {
            let url = files[0]
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
            panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " (bearbeitet).xlsx"
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            write(url, to: dest)
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Hier exportieren"
            panel.message = "Ordner für die \(files.count) bearbeiteten Excel-Dateien wählen"
            panel.directoryURL = files[0].deletingLastPathComponent()
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            var written = 0
            for url in files {
                var dest = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + " (bearbeitet).xlsx")
                var n = 2
                while FileManager.default.fileExists(atPath: dest.path) {
                    dest = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + " (bearbeitet \(n)).xlsx")
                    n += 1
                }
                if write(url, to: dest) { written += 1 }
            }
            infoMessage = "\(written) Datei\(written == 1 ? "" : "en") exportiert."
        }
    }

    @discardableResult
    private func write(_ source: URL, to dest: URL) -> Bool {
        guard let data = sources[source] else { errorMessage = "Originaldaten für „\(source.lastPathComponent)“ fehlen."; return false }
        do {
            let out = try XLSXExporter.export(original: data, sheets: sheets.filter { $0.fileURL == source })
            try out.write(to: dest, options: .atomic)
            dirtyFiles.remove(source)
            // `sources` keeps the bytes as imported: rows reference its row numbers, so it stays the export baseline.
            infoMessage = "Exportiert: \(dest.lastPathComponent)"
            return true
        } catch {
            errorMessage = "Export von „\(source.lastPathComponent)“ fehlgeschlagen: \(error.localizedDescription)"
            return false
        }
    }

    /// Asks to apply accepted proposals first. Returns false if the user cancelled.
    private func resolvePendingAccepted() -> Bool {
        guard acceptedCount > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = "\(acceptedCount) angenommene Änderung\(acceptedCount == 1 ? " ist" : "en sind") noch nicht übernommen."
        alert.informativeText = "Sollen sie vor dem Export übernommen werden?"
        alert.addButton(withTitle: "Übernehmen und exportieren")
        alert.addButton(withTitle: "Ohne sie exportieren")
        alert.addButton(withTitle: "Abbrechen")
        switch alert.runModal() {
        case .alertFirstButtonReturn: applyAccepted(); return true
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func exportMarkers(allSheets: Bool) {
        showMarkerExport = false
        guard resolvePendingAccepted() else { return }
        let targets = allSheets ? sheets : (selectedSheet.map { [$0] } ?? [])
        guard !targets.isEmpty else { return }
        let opts = markerOptions
        let ext = opts.format.fileExtension
        func baseName(_ s: TakeSheet) -> String {
            (s.fileURL.deletingPathExtension().lastPathComponent + " – " + s.sheetName).replacingOccurrences(of: "/", with: "-")
        }
        var dests: [(TakeSheet, URL)] = []
        if targets.count == 1 {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
            panel.directoryURL = targets[0].fileURL.deletingLastPathComponent()
            panel.nameFieldStringValue = baseName(targets[0]) + "." + ext
            guard panel.runModal() == .OK, let url = panel.url else { return }
            dests = [(targets[0], url)]
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Hier exportieren"
            panel.message = "Ordner für \(targets.count) Marker-Dateien wählen (eine pro Tabelle)"
            panel.directoryURL = targets[0].fileURL.deletingLastPathComponent()
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            dests = targets.map { ($0, dir.appendingPathComponent(baseName($0) + "." + ext)) }
        }
        var total = 0, skipped = 0
        for (sheet, url) in dests {
            let r = MarkerExporter.export(sheet, fps: settings.fps, options: opts)
            do { try r.data.write(to: url, options: .atomic) } catch {
                errorMessage = "„\(url.lastPathComponent)“ konnte nicht geschrieben werden: \(error.localizedDescription)"
                return
            }
            total += r.markers
            skipped += r.skipped
        }
        infoMessage = "\(total) Marker in \(dests.count) Datei\(dests.count == 1 ? "" : "en") exportiert"
            + (skipped > 0 ? " – \(skipped) Takes ohne TC In übersprungen." : ".")
    }

    func confirmDiscard() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Nicht exportierte Änderungen verwerfen?"
        alert.informativeText = "Einige Tabellen wurden geändert, aber noch nicht als Excel-Datei exportiert."
        alert.addButton(withTitle: "Verwerfen und beenden")
        alert.addButton(withTitle: "Abbrechen")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
