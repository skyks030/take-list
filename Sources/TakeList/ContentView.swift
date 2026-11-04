import SwiftUI
import TakeListCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = true
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ChangesSidebar()
                .navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 520)
        } detail: {
            VStack(spacing: 0) {
                if !model.sheets.isEmpty {
                    SheetTabBar()
                    Divider()
                }
                if let sheet = model.selectedSheet {
                    SheetDetail(sheet: sheet)
                } else {
                    EmptyStateView()
                }
            }
            .overlay(alignment: .bottom) { InfoToast() }
            .inspector(isPresented: $showInspector) {
                SettingsInspector()
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 460)
            }
        }
        .navigationTitle(model.selectedSheet?.title ?? "Take-Liste")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.showImportPanel() } label: { Label("Importieren", systemImage: "square.and.arrow.down") }
                    .help("Excel-Tabelle importieren (⌘O)")
                Button { model.scan() } label: { Label("Scannen", systemImage: "text.magnifyingglass") }
                    .help("Alle Tabellen scannen (⌘R)")
                    .disabled(model.sheets.isEmpty)
                Button { model.export() } label: { Label("Exportieren", systemImage: "square.and.arrow.up") }
                    .help("Bearbeitete Excel-Dateien exportieren (⌘E)")
                    .disabled(model.sheets.isEmpty)
                Button { showInspector.toggle() } label: { Label("Einstellungen", systemImage: "sidebar.right") }
                    .help("Einstellungen ein-/ausblenden")
            }
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.importFiles([url]) } }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 3).padding(4).allowsHitTesting(false)
            }
        }
        .sheet(item: Binding(get: { model.pendingFiles.first }, set: { _ in })) { file in
            SheetPickerView(file: file)
        }
        .sheet(item: Binding(get: { model.pendingFiles.isEmpty ? model.pendingSheets.first : nil }, set: { _ in })) { pending in
            MappingView(pending: pending)
        }
        .sheet(item: Binding(get: { model.editingRow.map(EditTarget.init) }, set: { if $0 == nil { model.editingRow = nil } })) { target in
            EditRowView(ref: target.ref)
        }
        .alert("Fehler", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct EditTarget: Identifiable {
    let ref: RowRef
    var id: UUID { ref.rowID }
}

struct InfoToast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let msg = model.infoMessage {
            Text(msg)
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: msg) {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { model.infoMessage = nil }
                }
        }
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tablecells.badge.ellipsis")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("Keine Takeliste geöffnet")
                .font(.title2.weight(.semibold))
            Text("Excel-Datei (.xlsx) importieren oder hierher ziehen.")
                .foregroundStyle(.secondary)
            Button("Excel-Tabelle importieren …") { model.showImportPanel() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SheetTabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.sheets) { sheet in
                    SheetTab(sheet: sheet, selected: sheet.id == model.selectedSheetID)
                }
                Button { model.showImportPanel() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 8)
                    .help("Weitere Tabelle importieren")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(.bar)
    }
}

struct SheetTab: View {
    @Environment(AppModel.self) private var model
    let sheet: TakeSheet
    let selected: Bool
    @State private var hover = false

    var body: some View {
        let changes = model.proposals.filter { $0.sheetID == sheet.id }.count
        let warnings = model.issues.filter { $0.refs.first?.sheetID == sheet.id }.count
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(sheet.sheetName).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
                Text(sheet.fileURL.deletingPathExtension().lastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if changes > 0 { Badge(count: changes, color: .blue) }
            if warnings > 0 { Badge(count: warnings, color: .orange) }
            if model.dirtyFiles.contains(sheet.fileURL), sheet.isModified {
                Circle().fill(.secondary).frame(width: 6, height: 6).help("Geändert, noch nicht exportiert")
            }
            Button { model.closeSheet(sheet.id) } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                .buttonStyle(.borderless)
                .opacity(hover || selected ? 1 : 0)
                .help("Tabelle schließen")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(maxWidth: 260)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.18) : (hover ? Color.primary.opacity(0.06) : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedSheetID = sheet.id }
        .onHover { hover = $0 }
        .help(sheet.title)
        .contextMenu {
            Button("Spaltenzuordnung ändern …") { model.remap(sheet.id) }
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([sheet.fileURL]) }
            Divider()
            Button("Tabelle schließen") { model.closeSheet(sheet.id) }
        }
    }
}

struct Badge: View {
    let count: Int
    let color: Color
    var body: some View {
        Text("\(count)")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.85)))
            .foregroundStyle(.white)
    }
}

struct SheetDetail: View {
    @Environment(AppModel.self) private var model
    let sheet: TakeSheet

    var body: some View {
        let rows = model.displayRows(for: sheet)
        let issueRows = Set(model.issues.flatMap { $0.refs }.filter { $0.sheetID == sheet.id }.map(\.rowID))
        VStack(spacing: 0) {
            TakeTableView(sheet: sheet, rows: rows, version: model.version, settings: model.settings,
                          focus: model.focus?.sheetID == sheet.id ? model.focus : nil,
                          issueRows: issueRows,
                          onEdit: { id in model.editingRow = RowRef(sheetID: sheet.id, rowID: id) })
            Divider()
            SheetStatusBar(sheet: sheet, rows: rows)
        }
    }
}

struct SheetStatusBar: View {
    @Environment(AppModel.self) private var model
    let sheet: TakeSheet
    let rows: [DisplayRow]

    var body: some View {
        let takes = sheet.dataRange.filter { sheet.isTake(sheet.rows[$0]) }.count
        let m = sheet.mapping
        HStack(spacing: 14) {
            Text("\(takes) Takes").monospacedDigit()
            Text("Zuordnung: TC In \(col(m.tcIn)) · TC Out \(col(m.tcOut)) · Rolle \(col(m.role)) · Text \(col(m.text))\(m.takeNumber.map { " · Take-Nr. \(columnLetters($0))" } ?? "")")
            Button("Ändern …") { model.remap(sheet.id) }.buttonStyle(.link)
            Spacer()
            Text("Doppelklick auf eine Zeile zum Bearbeiten").foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
    }

    func col(_ c: Int?) -> String { c.map(columnLetters) ?? "–" }
}
