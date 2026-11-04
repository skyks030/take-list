import SwiftUI
import TakeListCore

struct SettingsInspector: View {
    @Environment(AppModel.self) private var model

    static let frameRates: [(label: String, fps: Int)] = [
        ("23,976 / 24 fps", 24), ("25 fps", 25), ("29,97 / 30 fps (NDF)", 30), ("50 fps", 50), ("59,94 / 60 fps", 60),
    ]

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Max. Wörter pro Take", isOn: $model.settings.maxWordsEnabled)
                    if model.settings.maxWordsEnabled {
                        Stepper(value: $model.settings.maxWords, in: 3...500) {
                            HStack {
                                Text("Grenze")
                                Spacer()
                                TextField("", value: $model.settings.maxWords, format: .number)
                                    .frame(width: 50).multilineTextAlignment(.trailing)
                                Text("Wörter").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Toggle("Max. Dauer pro Take", isOn: $model.settings.maxDurationEnabled)
                    if model.settings.maxDurationEnabled {
                        Stepper(value: $model.settings.maxDurationSeconds, in: 1...600, step: 1) {
                            HStack {
                                Text("Grenze")
                                Spacer()
                                TextField("", value: $model.settings.maxDurationSeconds, format: .number.precision(.fractionLength(0...1)))
                                    .frame(width: 50).multilineTextAlignment(.trailing)
                                Text("Sek.").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Toggle("Regieanweisungen in ( ) [ ] nicht mitzählen", isOn: $model.settings.ignoreDirections)
                    Toggle("Notfalls an Kommas teilen (Teilsätze)", isOn: $model.settings.allowClauseSplit)
                } header: {
                    Text("Take-Aufteilung")
                } footer: {
                    Text("Takes werden nur an Satzgrenzen geteilt. Ist ein einzelner Satz länger als die Grenze, bleibt er zusammen – außer Teilsätze sind erlaubt.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Picker("Framerate", selection: $model.settings.fps) {
                        ForEach(Self.frameRates, id: \.fps) { Text($0.label).tag($0.fps) }
                    }
                    Picker("Zeit verteilen nach", selection: $model.settings.weighting) {
                        ForEach(TimeWeighting.allCases) { Text($0.label).tag($0) }
                    }
                    Stepper(value: $model.settings.gapFrames, in: 0...50) {
                        HStack {
                            Text("Lücke zwischen Teilen")
                            Spacer()
                            Text("\(model.settings.gapFrames) Frames").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                } header: {
                    Text("Timecodes")
                } footer: {
                    Text("Geteilte Takes bleiben immer innerhalb von TC In und TC Out des Originals; die Länge richtet sich nach dem Textanteil.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Take-Nummern") {
                    Picker("Bei geteilten Takes", selection: $model.settings.takeNumberMode) {
                        ForEach(TakeNumberMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                Section("Integritätsprüfung") {
                    Toggle("Rolle vorhanden", isOn: $model.settings.checkMissingRole)
                    Toggle("TC In / TC Out vorhanden und gültig", isOn: $model.settings.checkMissingTimecode)
                    Toggle("Überlappende Timecodes", isOn: $model.settings.checkOverlap)
                    if model.settings.checkOverlap {
                        Toggle("Nur innerhalb derselben Rolle", isOn: $model.settings.overlapSameRoleOnly)
                            .padding(.leading, 12)
                    }
                    Toggle("Schreibvarianten bei Rollennamen", isOn: $model.settings.checkRoleSpelling)
                    if model.settings.checkRoleSpelling {
                        Stepper(value: $model.settings.roleTolerance, in: 1...3) {
                            HStack {
                                Text("Toleranz")
                                Spacer()
                                Text("\(model.settings.roleTolerance) Buchstabe\(model.settings.roleTolerance == 1 ? "" : "n")")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, 12)
                        Picker("Vergleichen", selection: $model.settings.roleScope) {
                            ForEach(RoleScope.allCases) { Text($0.label).tag($0) }
                        }
                        .padding(.leading, 12)
                    }
                    Toggle("Umlaute (Ä Ö Ü ß)", isOn: $model.settings.checkUmlauts)
                        .help("Meldet Takes mit Umlauten – sie gehen bei falsch kodierten CSV/EDL-Importen gern verloren.")
                    Toggle("Sonder- & unsichtbare Zeichen, Kodierungsfehler", isOn: $model.settings.checkSpecialCharacters)
                        .help("Typografische Anführungszeichen, Gedankenstriche, …, geschützte Leerzeichen, Steuerzeichen sowie kaputte Kodierung wie „FÃ¼r“.")
                }
            }
            .formStyle(.grouped)
            .onChange(of: integrityKey) { _, _ in model.runIntegrity() }

            Divider()
            VStack(spacing: 6) {
                Button {
                    model.scan()
                } label: {
                    Label("Scannen", systemImage: "text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.sheets.isEmpty)
                Group {
                    if let last = model.lastScan {
                        Text("Letzter Scan \(last.formatted(date: .omitted, time: .shortened)) · \(model.proposals.count) Änderungen · \(model.issues.count) Warnungen")
                    } else {
                        Text("\(model.sheets.count) Tabelle\(model.sheets.count == 1 ? "" : "n") geöffnet")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }

    /// Integrity checks are cheap – re-run them live when their settings change.
    private var integrityKey: [String] {
        let s = model.settings
        return ["\(s.fps)", "\(s.checkMissingRole)", "\(s.checkMissingTimecode)", "\(s.checkOverlap)", "\(s.overlapSameRoleOnly)",
                "\(s.checkRoleSpelling)", "\(s.roleTolerance)", s.roleScope.rawValue, "\(s.checkUmlauts)", "\(s.checkSpecialCharacters)"]
    }
}
