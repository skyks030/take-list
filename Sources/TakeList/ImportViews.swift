import SwiftUI
import TakeListCore

/// Hosts the import steps in a single sheet so it can always be closed.
struct ImportFlowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let file = model.pendingFiles.first {
                SheetPickerView(file: file).id(file.id)
            } else if let pending = model.pendingSheets.first {
                MappingView(pending: pending).id(pending.id)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .onExitCommand { model.cancelImport() }
    }
}

struct SheetPickerView: View {
    @Environment(AppModel.self) private var model
    @State var file: PendingFile

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tabellenblätter importieren").font(.title2.weight(.semibold))
            Text(file.url.lastPathComponent).foregroundStyle(.secondary)
            List {
                ForEach(file.workbook.sheets) { info in
                    let imported = model.isImported(file.url, info.path)
                    Toggle(isOn: Binding(get: { file.selection.contains(info.path) },
                                         set: { on in if on { file.selection.insert(info.path) } else { file.selection.remove(info.path) } })) {
                        HStack {
                            Text(info.name)
                            if imported { Text("bereits geöffnet").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .frame(minHeight: 160)
            HStack {
                Button("Alle") { file.selection = Set(file.workbook.sheets.map(\.path)) }
                Button("Keine") { file.selection.removeAll() }
                Spacer()
                Button("Import abbrechen") { model.cancelImport() }
                    .keyboardShortcut(.cancelAction)
                Button("Weiter") { model.confirmSheetSelection(file) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(file.selection.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440, height: 400)
    }
}

struct MappingView: View {
    @Environment(AppModel.self) private var model
    @State var pending: PendingSheet

    private var columnCount: Int { pending.rows.map(\.cells.count).max() ?? 0 }

    private func header(_ c: Int) -> String {
        let t = pending.rows.indices.contains(pending.headerRow) ? pending.rows[pending.headerRow].text(c) : ""
        return t.isEmpty ? "(ohne Überschrift)" : t
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pending.existingSheetID == nil ? "Spalten zuordnen" : "Spaltenzuordnung ändern").font(.title2.weight(.semibold))
                Text("\(pending.url.lastPathComponent) – \(pending.info.name)").foregroundStyle(.secondary)
                if model.pendingSheets.count > 1 {
                    Text("Noch \(model.pendingSheets.count - 1) weitere Tabelle\(model.pendingSheets.count == 2 ? "" : "n") im Anschluss")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Überschriftenzeile")
                    Stepper(value: Binding(get: { pending.headerRow + 1 }, set: { v in
                        pending.headerRow = max(0, min(v - 1, max(0, pending.rows.count - 1)))
                        pending.mapping = ColumnDetector.detect(rows: pending.rows, headerRow: pending.headerRow, fps: model.settings.fps)
                    }), in: 1...max(1, min(50, pending.rows.count))) {
                        Text("Zeile \(pending.headerRow + 1)").monospacedDigit()
                    }
                }
                columnPicker("Timecode In", $pending.mapping.tcIn, required: true)
                columnPicker("Timecode Out", $pending.mapping.tcOut, required: true)
                columnPicker("Rolle / Sprecher", $pending.mapping.role, required: true)
                columnPicker("Text / Dialog", $pending.mapping.text, required: true)
                columnPicker("Take-Nr. (optional)", $pending.mapping.takeNumber, required: false)
            }

            if pending.mapping.combinedTimecode {
                Label("TC In und TC Out stehen in derselben Spalte – erwartet wird „IN - OUT“.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !pending.mapping.isComplete {
                Label("Nicht alle Pflichtspalten sind zugeordnet. Fehlende Spalten werden bei Prüfung und Aufteilung übersprungen.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            Text("Vorschau").font(.headline)
            preview
                .frame(minHeight: 180)

            HStack {
                Button("Import abbrechen") { model.cancelImport() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if pending.existingSheetID == nil {
                    Button("Diese Tabelle überspringen") { model.skipMapping(pending) }
                }
                Button(pending.existingSheetID == nil ? "Importieren" : "Übernehmen") { model.confirmMapping(pending) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pending.mapping.text == nil)
            }
        }
        .padding(20)
        .frame(width: 760, height: 620)
    }

    @ViewBuilder
    private func columnPicker(_ title: String, _ binding: Binding<Int?>, required: Bool) -> some View {
        GridRow {
            HStack(spacing: 4) {
                Text(title)
                if required, binding.wrappedValue == nil {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                }
            }
            Picker("", selection: binding) {
                Text("—").tag(Int?.none)
                ForEach(0..<columnCount, id: \.self) { c in
                    Text("\(columnLetters(c)) · \(header(c))").tag(Int?.some(c))
                }
            }
            .labelsHidden()
            .frame(width: 320)
        }
    }

    private var preview: some View {
        let dataRows = Array(pending.rows.dropFirst(pending.headerRow + 1).filter { !$0.cells.allSatisfy { $0.value.isBlank } }.prefix(8))
        let cols = Array(0..<columnCount)
        return ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .topLeading, horizontalSpacing: 1, verticalSpacing: 1) {
                GridRow {
                    ForEach(cols, id: \.self) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pending.mapping.label(for: c) ?? " ")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.accentColor)
                            Text("\(columnLetters(c)) · \(header(c))").font(.caption.weight(.semibold)).lineLimit(1)
                        }
                        .frame(width: width(c), alignment: .leading)
                        .padding(4)
                        .background(pending.mapping.label(for: c) != nil ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                    }
                }
                ForEach(dataRows) { row in
                    GridRow {
                        ForEach(cols, id: \.self) { c in
                            Text(row.text(c))
                                .font(.caption)
                                .lineLimit(3)
                                .frame(width: width(c), alignment: .topLeading)
                                .padding(4)
                                .background(pending.mapping.label(for: c) != nil ? Color.accentColor.opacity(0.05) : .clear)
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
    }

    private func width(_ c: Int) -> CGFloat { c == pending.mapping.text ? 260 : 110 }
}

struct EditRowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ref: RowRef
    @State private var texts: [Int: String] = [:]
    @State private var originals: [Int: String] = [:]

    var body: some View {
        let sheet = model.sheet(ref.sheetID)
        let row = model.row(ref)
        VStack(alignment: .leading, spacing: 14) {
            Text("Take bearbeiten – Zeile \(row?.label ?? "")").font(.title2.weight(.semibold))
            if let sheet {
                ScrollView {
                    Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 8) {
                        ForEach(0..<sheet.columnCount, id: \.self) { c in
                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(sheet.headers[c]).lineLimit(1)
                                    if let l = sheet.mapping.label(for: c) {
                                        Text(l).font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor)
                                    }
                                }
                                .frame(width: 150, alignment: .leading)
                                let binding = Binding(get: { texts[c] ?? "" }, set: { texts[c] = $0 })
                                if c == sheet.mapping.text {
                                    TextEditor(text: binding)
                                        .font(.body)
                                        .frame(minHeight: 110)
                                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
                                } else {
                                    TextField("", text: binding)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                    }
                    .padding(.trailing, 6)
                }
            }
            HStack {
                Spacer()
                Button("Abbrechen") { model.editingRow = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sichern") {
                    let changed = texts.filter { originals[$0.key] != $0.value }
                    model.undoManager?.beginUndoGrouping()
                    for (col, text) in changed.sorted(by: { $0.key < $1.key }) { model.updateCell(ref, column: col, text: text) }
                    model.undoManager?.endUndoGrouping()
                    model.editingRow = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .onAppear {
            guard let sheet, let row else { return }
            let tc = Timecode(fps: model.settings.fps)
            for c in 0..<sheet.columnCount {
                let cell = row.cell(c)
                if (c == sheet.mapping.tcIn || c == sheet.mapping.tcOut), !sheet.mapping.combinedTimecode,
                   case .number = cell.value, let p = tc.parse(cell) {
                    // Excel time values are shown as timecode; only rewritten if the user changes them.
                    texts[c] = tc.string(p.frames, style: .frames(separator: ":"))
                } else {
                    texts[c] = cell.text
                }
                originals[c] = texts[c]
            }
        }
    }
}
