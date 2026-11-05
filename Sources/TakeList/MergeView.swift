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
    @State private var columns: TableColumnCustomization<Entry> = {
        guard let d = UserDefaults.standard.data(forKey: "mergeTableColumns"),
              let c = try? JSONDecoder().decode(TableColumnCustomization<Entry>.self, from: d) else { return TableColumnCustomization() }
        return c
    }()

    var body: some View {
        let fps = model.settings.fps
        let plans = computePlans(fps: fps)
        let included = entries.filter { $0.include && plans[$0.id]?.span != nil }
        let problems = included.contains { plans[$0.id]!.negative || plans[$0.id]!.overlaps }
        let fpsLabel = SettingsInspector.frameRates.first { $0.fps == fps }?.label ?? "\(fps) fps"

        VStack(alignment: .leading, spacing: 14) {
            Text("Für jede Liste gibt der Basis-Timecode an, zu welcher Stunde sie beginnt (vorgeschlagen: die volle Stunde vor dem ersten Take). Er wird in der neuen Gesamtliste auf den Start-Timecode gelegt – alle Takes der Liste werden um denselben Betrag verschoben, ihre Abstände bleiben exakt gleich.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            table(plans: plans, fps: fps)
                .frame(minHeight: 160, maxHeight: .infinity)

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
        .frame(minWidth: 820, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
        .onAppear { reset() }
        // Tables opened or closed while the window is open.
        .onChange(of: model.sheets.map(\.id)) { _, ids in
            entries.removeAll { !ids.contains($0.id) }
            for id in ids where !entries.contains(where: { $0.id == id }) { entries.append(Entry(id: id, include: true)) }
        }
    }

    private func binding(_ id: UUID) -> Binding<Entry>? {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return $entries[i]
    }

    private func table(plans: [UUID: Plan], fps: Int) -> some View {
        let tc = Timecode(fps: fps)
        func string(_ f: Int) -> String { tc.string(f, style: .frames(separator: ":")) }
        return Table(entries, columnCustomization: $columns) {
            TableColumn("") { (entry: Entry) in
                let usable = plans[entry.id]?.span != nil
                Toggle("", isOn: Binding(get: { entry.include && usable }, set: { v in binding(entry.id)?.wrappedValue.include = v }))
                    .labelsHidden()
                    .disabled(!usable)
            }
            .width(22)
            .customizationID("include")

            TableColumn("Liste") { (entry: Entry) in
                let sheet = model.sheet(entry.id)
                VStack(alignment: .leading, spacing: 0) {
                    Text(sheet?.sheetName ?? "–").lineLimit(1)
                    Text(sheet?.fileURL.deletingPathExtension().lastPathComponent ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .help(sheet?.title ?? "")
                .opacity(dim(entry, plans) ? 0.55 : 1)
            }
            .width(min: 100, ideal: 220)
            .customizationID("name")

            TableColumn("Erster Take") { (entry: Entry) in
                Text(plans[entry.id]?.span.map { string($0.first) } ?? "–").monospacedDigit()
                    .opacity(dim(entry, plans) ? 0.55 : 1)
            }
            .width(min: 80, ideal: 100)
            .customizationID("first")

            TableColumn("Ende") { (entry: Entry) in
                Text(plans[entry.id]?.span.map { string($0.last) } ?? "–").monospacedDigit()
                    .opacity(dim(entry, plans) ? 0.55 : 1)
            }
            .width(min: 80, ideal: 100)
            .customizationID("last")

            TableColumn("Basis") { (entry: Entry) in
                if let plan = plans[entry.id], plan.span != nil {
                    tcField(Binding(get: { entry.baseOverride ?? plan.base }, set: { v in binding(entry.id)?.wrappedValue.baseOverride = v }),
                            edited: entry.baseOverride != nil, reset: { binding(entry.id)?.wrappedValue.baseOverride = nil }, fps: fps)
                }
            }
            .width(min: 110, ideal: 130)
            .customizationID("base")

            TableColumn("Neuer Start") { (entry: Entry) in
                if let plan = plans[entry.id], plan.span != nil {
                    tcField(Binding(get: { entry.startOverride ?? plan.start }, set: { v in binding(entry.id)?.wrappedValue.startOverride = v }),
                            edited: entry.startOverride != nil, reset: { binding(entry.id)?.wrappedValue.startOverride = nil }, fps: fps)
                }
            }
            .width(min: 110, ideal: 130)
            .customizationID("start")

            TableColumn("In der Gesamtliste") { (entry: Entry) in
                let plan = plans[entry.id] ?? Plan()
                let bad = entry.include && plan.span != nil && (plan.negative || plan.overlaps)
                Group {
                    if plan.span == nil {
                        Text("keine gültigen Timecodes").foregroundStyle(.secondary)
                    } else if plan.negative {
                        Text("beginnt vor 00:00:00:00")
                    } else {
                        Text("\(string(plan.newFirst)) – \(string(plan.newLast))").monospacedDigit()
                    }
                }
                .foregroundStyle(bad ? Color.red : (entry.include ? Color.primary : Color.secondary))
                .help(plan.overlaps ? "Überschneidet sich mit einer anderen Liste" : "")
            }
            .width(min: 160, ideal: 210)
            .customizationID("result")

            TableColumn("") { (entry: Entry) in
                let index = entries.firstIndex { $0.id == entry.id } ?? 0
                HStack(spacing: 2) {
                    Button { move(index, -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0)
                    Button { move(index, 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == entries.count - 1)
                }
                .buttonStyle(.borderless)
                .help("Reihenfolge für die vorgeschlagenen Start-Timecodes")
            }
            .width(46)
            .customizationID("order")
        }
        .onChange(of: columns) { _, c in
            if let d = try? JSONEncoder().encode(c) { UserDefaults.standard.set(d, forKey: "mergeTableColumns") }
        }
    }

    private func dim(_ entry: Entry, _ plans: [UUID: Plan]) -> Bool {
        !entry.include && plans[entry.id]?.span != nil
    }

    private func tcField(_ value: Binding<Int>, edited: Bool, reset: @escaping () -> Void, fps: Int) -> some View {
        HStack(spacing: 2) {
            TextField("", value: value, format: TimecodeFormat(fps: fps))
                .monospacedDigit()
                .frame(minWidth: 86)
                .help("HH:MM:SS:FF – eine einzelne Zahl steht für die volle Stunde")
            Button(action: reset) { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless)
                .help("Vorschlag wiederherstellen")
                .opacity(edited ? 1 : 0)
                .disabled(!edited)
        }
    }

    private func reset() {
        entries = model.sheets.map { Entry(id: $0.id, include: true) }
        name = "Gesamt"
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
