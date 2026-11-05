import SwiftUI
import TakeListCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @State private var columnVisibility: NavigationSplitViewVisibility = UserDefaults.standard.object(forKey: "showSidebar") as? Bool == false ? .detailOnly : .all
    @AppStorage("showInspector") private var showInspector = true
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
                if !model.sheets.isEmpty {
                    Button { model.showImportPanel() } label: { Label("Importieren", systemImage: "square.and.arrow.down") }
                        .help("Weitere Takeliste (Excel oder CSV) importieren (⌘O)")
                    Button { model.scan() } label: { Label("Scannen", systemImage: "text.magnifyingglass") }
                        .help("Alle Tabellen scannen (⌘R)")
                    Button { model.showMerge = true } label: { Label("Zusammenführen", systemImage: "arrow.triangle.merge") }
                        .help("Mehrere Listen zu einer Gesamtliste mit verschobenen Timecodes zusammenführen (⇧⌘M)")
                        .disabled(model.mergeableCount < 2)
                    Menu {
                        Button("Excel-Tabelle (.xlsx) …") { model.export() }
                        Divider()
                        Button("Marker-CSV für Nuendo / Cubase …") {
                            model.markerOptions.format = .nuendoCSV
                            model.showMarkerExport = true
                        }
                        Button("Marker-EDL für DaVinci Resolve …") {
                            model.markerOptions.format = .resolveEDL
                            model.showMarkerExport = true
                        }
                    } label: {
                        Label("Exportieren", systemImage: "square.and.arrow.up")
                            .labelStyle(.titleAndIcon)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .fixedSize()
                    .help("Als Excel-Tabelle oder als Marker-Spur exportieren")
                }
                Button { showInspector.toggle() } label: { Label("Einstellungen", systemImage: "sidebar.right") }
                    .help("Einstellungen ein-/ausblenden")
            }
        }
        .onChange(of: columnVisibility) { _, v in UserDefaults.standard.set(v != .detailOnly, forKey: "showSidebar") }
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
        // One sheet for the whole import flow; closing it (Esc / Abbrechen) always aborts the import.
        .sheet(isPresented: Binding(get: { model.importActive }, set: { if !$0 { model.cancelImport() } })) {
            ImportFlowView().environment(model)
        }
        .sheet(isPresented: $model.showMarkerExport) {
            MarkerExportView().environment(model)
        }
        .sheet(isPresented: $model.showMerge) {
            MergeView().environment(model)
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
            Text("Excel-Datei (.xlsx) oder CSV importieren oder hierher ziehen.")
                .foregroundStyle(.secondary)
            Button("Takeliste importieren …") { model.showImportPanel() }
                .accessibilityIdentifier("import-center")
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
                Button {
                    model.showImportPanel()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Weitere Tabelle oder weitere Blätter importieren")
                .accessibilityLabel("Tabelle hinzufügen")
                .accessibilityIdentifier("tab-add")
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
    @State private var closeHover = false

    var body: some View {
        let changes = model.proposals.filter { $0.sheetID == sheet.id }.count
        let warnings = model.issues.filter { $0.refs.first?.sheetID == sheet.id }.count
        // Two sibling buttons (no tap gesture on a parent) so the close button always gets its click.
        HStack(spacing: 4) {
            Button {
                model.selectedSheetID = sheet.id
            } label: {
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
                }
                .padding(.leading, 10).padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(sheet.title)
            .accessibilityIdentifier("tab-select")

            Button {
                model.closeSheet(sheet.id)
            } label: {
                Image(systemName: closeHover ? "xmark.circle.fill" : "xmark")
                    .font(.system(size: closeHover ? 13 : 9, weight: .bold))
                    .foregroundStyle(closeHover ? Color.primary : Color.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { closeHover = $0 }
            .padding(.trailing, 6)
            .help("Tabelle entfernen")
            .accessibilityLabel("Tabelle \(sheet.sheetName) entfernen")
            .accessibilityIdentifier("tab-close")
        }
        .frame(maxWidth: 280)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.18) : (hover ? Color.primary.opacity(0.06) : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear))
        .onHover { hover = $0 }
        .contextMenu {
            Button("Spaltenzuordnung ändern …") { model.remap(sheet.id) }
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([sheet.fileURL]) }
            Divider()
            Button("Tabelle entfernen …") { model.closeSheet(sheet.id) }
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
                          onEdit: { id in model.editingRow = RowRef(sheetID: sheet.id, rowID: id) },
                          onCommit: { id, col, text in model.updateCell(RowRef(sheetID: sheet.id, rowID: id), column: col, text: text) })
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
            Text("Doppelklick auf eine Zelle zum Bearbeiten · ⌥↩ = Zeilenumbruch · Esc = Abbrechen").foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
    }

    func col(_ c: Int?) -> String { c.map(columnLetters) ?? "–" }
}
