import SwiftUI
import TakeListCore

/// Shows and parses frame counts as HH:MM:SS:FF.
struct TimecodeFormat: ParseableFormatStyle {
    var fps: Int
    struct Strategy: ParseStrategy {
        var fps: Int
        func parse(_ value: String) throws -> Int {
            let t = value.trimmingCharacters(in: .whitespaces)
            if let p = Timecode(fps: fps).parse(t) { return p.frames }
            // Shorthand: "1" or "01" = full hour.
            if let h = Int(t), (0..<100).contains(h) { return h * 3600 * fps }
            throw CocoaError(.formatting)
        }
    }
    var parseStrategy: Strategy { Strategy(fps: fps) }
    func format(_ value: Int) -> String { Timecode(fps: fps).string(value, style: .frames(separator: ":")) }
}

struct MergeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    struct Entry: Identifiable {
        let id: UUID
        var include: Bool
        var baseOverride: Int?
        var startOverride: Int?
    }

    struct Plan {
        var span: TimecodeSpan?
        var base: Int = 0
        var start: Int = 0
        var newFirst: Int { start + (span?.first ?? 0) - base }
        var newLast: Int { start + (span?.last ?? 0) - base }
        var offset: Int { start - base }
        var negative = false
        var overlaps = false
    }

    @State private var entries: [Entry] = []
    @State private var name = "Gesamt"

    var body: some View {
        let fps = model.settings.fps
        let plans = computePlans(fps: fps)
        let included = entries.filter { $0.include && plans[$0.id]?.span != nil }
        let problems = included.contains { plans[$0.id]!.negative || plans[$0.id]!.overlaps }
        let fpsLabel = SettingsInspector.frameRates.first { $0.fps == fps }?.label ?? "\(fps) fps"

        VStack(alignment: .leading, spacing: 14) {
            Text("Listen zusammenführen").font(.title2.weight(.semibold))
            Text("Für jede Liste gibt der Basis-Timecode an, zu welcher Stunde sie beginnt (vorgeschlagen: die volle Stunde vor dem ersten Take). Er wird in der neuen Gesamtliste auf den Start-Timecode gelegt – alle Takes der Liste werden um denselben Betrag verschoben, ihre Abstände bleiben exakt gleich.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("")
                        Text("Liste")
                        Text("Erster Take")
                        Text("Ende")
                        Text("Basis")
                        Text("Neuer Start")
                        Text("In der Gesamtliste")
                        Text("")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        row(index: index, entry: entry, plan: plans[entry.id] ?? Plan(), fps: fps)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 120, maxHeight: 360)

            Form {
                TextField("Name der Gesamtliste", text: $name)
                LabeledContent("Framerate", value: fpsLabel)
            }
            .formStyle(.grouped)
            .frame(height: 110)

            Group {
                if included.count < 2 {
                    Label("Mindestens zwei Listen mit Timecodes auswählen.", systemImage: "info.circle")
                } else if problems {
                    Label("Die rot markierten Listen überschneiden sich oder beginnen vor 00:00:00:00 – bitte Start-Timecodes anpassen.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else {
                    Label("\(included.count) Listen werden in Timecode-Reihenfolge zu einer neuen Tabelle zusammengeführt. Spalten und Formatierung kommen von der ersten Liste; die Originale bleiben unverändert.",
                          systemImage: "checkmark.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Zusammenführen") {
                    let inputs = included
                        .compactMap { e in model.sheet(e.id).map { (MergeInput(sheet: $0, offset: plans[e.id]!.offset), plans[e.id]!.newFirst) } }
                        .sorted { $0.1 < $1.1 }
                        .map(\.0)
                    let n = name.trimmingCharacters(in: .whitespaces)
                    dismiss()
                    model.merge(inputs, name: n.isEmpty ? "Gesamt" : n)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(included.count < 2 || problems)
            }
        }
        .padding(20)
        .frame(width: 900)
        .onAppear {
            entries = model.sheets.map { Entry(id: $0.id, include: true) }
        }
    }

    @ViewBuilder
    private func row(index: Int, entry: Entry, plan: Plan, fps: Int) -> some View {
        let tc = Timecode(fps: fps)
        let sheet = model.sheet(entry.id)
        let usable = plan.span != nil
        let bad = entry.include && usable && (plan.negative || plan.overlaps)
        GridRow {
            Toggle("", isOn: $entries[index].include)
                .labelsHidden()
                .disabled(!usable)
            VStack(alignment: .leading, spacing: 0) {
                Text(sheet?.sheetName ?? "–").lineLimit(1)
                Text(sheet?.fileURL.deletingPathExtension().lastPathComponent ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 170, alignment: .leading)
            if let span = plan.span {
                Text(tc.string(span.first, style: .frames(separator: ":"))).monospacedDigit()
                Text(tc.string(span.last, style: .frames(separator: ":"))).monospacedDigit()
                tcField(Binding(get: { entries[index].baseOverride ?? plan.base }, set: { entries[index].baseOverride = $0 }),
                        edited: entry.baseOverride != nil, reset: { entries[index].baseOverride = nil }, fps: fps)
                tcField(Binding(get: { entries[index].startOverride ?? plan.start }, set: { entries[index].startOverride = $0 }),
                        edited: entry.startOverride != nil, reset: { entries[index].startOverride = nil }, fps: fps)
                Text(plan.negative ? "beginnt vor 00:00:00:00"
                     : "\(tc.string(plan.newFirst, style: .frames(separator: ":"))) – \(tc.string(plan.newLast, style: .frames(separator: ":")))")
                    .monospacedDigit()
                    .foregroundStyle(bad ? Color.red : (entry.include ? Color.primary : Color.secondary))
                    .help(plan.overlaps ? "Überschneidet sich mit einer anderen Liste" : "")
            } else {
                Text("keine gültigen Timecodes").foregroundStyle(.secondary).gridCellColumns(5)
            }
            HStack(spacing: 2) {
                Button { move(index, -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                Button { move(index, 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == entries.count - 1)
            }
            .buttonStyle(.borderless)
            .help("Reihenfolge für die vorgeschlagenen Start-Timecodes")
        }
        .opacity(entry.include || !usable ? 1 : 0.55)
    }

    private func tcField(_ value: Binding<Int>, edited: Bool, reset: @escaping () -> Void, fps: Int) -> some View {
        HStack(spacing: 2) {
            TextField("", value: value, format: TimecodeFormat(fps: fps))
                .monospacedDigit()
                .frame(width: 96)
                .help("HH:MM:SS:FF – eine einzelne Zahl steht für die volle Stunde")
            Button(action: reset) { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless)
                .help("Vorschlag wiederherstellen")
                .opacity(edited ? 1 : 0)
                .disabled(!edited)
        }
    }

    private func move(_ index: Int, _ delta: Int) {
        let target = index + delta
        guard entries.indices.contains(target) else { return }
        entries.swapAt(index, target)
    }

    /// Effective base and start per list: overrides win, everything else follows the suggestion chain.
    private func computePlans(fps: Int) -> [UUID: Plan] {
        var plans: [UUID: Plan] = [:]
        var previousEnd: Int?
        for e in entries {
            var p = Plan()
            guard let sheet = model.sheet(e.id), let span = ListMerger.span(of: sheet, fps: fps) else { plans[e.id] = p; continue }
            p.span = span
            p.base = e.baseOverride ?? ListMerger.hourFloor(span.first, fps: fps)
            p.start = e.startOverride ?? ListMerger.suggestedStart(base: p.base, previousEnd: e.include ? previousEnd : nil, fps: fps)
            p.negative = p.newFirst < 0
            if e.include { previousEnd = max(previousEnd ?? p.newLast, p.newLast) }
            plans[e.id] = p
        }
        // Overlap check over the included lists in timecode order.
        let active = entries.filter { $0.include && plans[$0.id]?.span != nil }.map(\.id).sorted { plans[$0]!.newFirst < plans[$1]!.newFirst }
        var reach: (id: UUID, last: Int)?
        for id in active {
            let p = plans[id]!
            if let r = reach, p.newFirst <= r.last {
                plans[id]!.overlaps = true
                plans[r.id]!.overlaps = true
            }
            if reach == nil || p.newLast > reach!.last { reach = (id, p.newLast) }
        }
        return plans
    }
}
