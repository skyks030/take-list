import SwiftUI
import TakeListCore

struct MarkerExportView: View {
    @Environment(AppModel.self) private var model
    @State private var allSheets = true

    var body: some View {
        @Bindable var model = model
        let fpsLabel = SettingsInspector.frameRates.first { $0.fps == model.settings.fps }?.label ?? "\(model.settings.fps) fps"
        VStack(alignment: .leading, spacing: 14) {
            Text("Als Marker exportieren").font(.title2.weight(.semibold))
            Form {
                Picker("Format", selection: $model.markerOptions.format) {
                    ForEach(MarkerFormat.allCases) { Text($0.label).tag($0) }
                }
                Picker("Tabellen", selection: $allSheets) {
                    Text("Alle \(model.sheets.count) Tabellen (je eine Datei)").tag(true)
                    Text("Nur „\(model.selectedSheet?.sheetName ?? "–")“").tag(false)
                }
                Picker("Markername", selection: $model.markerOptions.name) {
                    ForEach(MarkerName.allCases) { Text($0.label).tag($0) }
                }
                if model.markerOptions.format == .nuendoCSV {
                    Picker("Trennzeichen", selection: $model.markerOptions.semicolon) {
                        Text("Komma ( , )").tag(false)
                        Text("Semikolon ( ; )").tag(true)
                    }
                    Toggle("UTF-8 mit BOM (damit Umlaute erkannt werden)", isOn: $model.markerOptions.byteOrderMark)
                    Toggle("Zusatzspalten Character / Dialog / Take anhängen", isOn: $model.markerOptions.extraColumns)
                } else {
                    Toggle("Farbe je Rolle", isOn: $model.markerOptions.colorByRole)
                }
                Toggle("Nur ASCII (ä → ae, „“ → \")", isOn: $model.markerOptions.asciiOnly)
                LabeledContent("Framerate", value: fpsLabel)
            }
            .formStyle(.grouped)

            Text(model.markerOptions.format == .nuendoCSV
                 ? "Nuendo: Marker-Fenster → Import → Marker aus CSV. Takes werden als Cycle-Marker mit Start, Ende und Länge (HH:MM:SS:FF) geschrieben."
                 : "Resolve: Timeline-Rechtsklick → Timelines → Importieren → Timeline-Marker aus EDL. Takes werden als Marker mit Dauer geschrieben.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Abbrechen") { model.showMarkerExport = false }
                    .keyboardShortcut(.cancelAction)
                Button("Exportieren …") {
                    let all = allSheets
                    model.showMarkerExport = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.exportMarkers(allSheets: all) }
                }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { allSheets = model.sheets.count > 1 }
    }
}
