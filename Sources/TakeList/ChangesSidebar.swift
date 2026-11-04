import SwiftUI
import TakeListCore

struct ChangesSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var showWarnings = true
    @State private var showChanges = true

    var body: some View {
        @Bindable var model = model
        let proposals = model.visibleProposals()
        let issues = model.visibleIssues()
        VStack(spacing: 0) {
            Picker("", selection: $model.sidebarFilter) {
                ForEach(SidebarFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10).padding(.vertical, 8)

            HStack {
                Spacer()
                WarningTypesButton()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            if model.settingsChangedSinceScan {
                Label("Einstellungen geändert – erneut scannen", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.bottom, 6)
            }

            List(selection: $model.sidebarSelection) {
                Section(isExpanded: $showChanges) {
                    if model.lastScan == nil {
                        Text("Noch nicht gescannt. Rechts die Einstellungen festlegen und „Scannen“ drücken.")
                            .font(.callout).foregroundStyle(.secondary)
                            .selectionDisabled()
                    } else if proposals.isEmpty {
                        Label("Keine Änderungen nötig", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                    ForEach(proposals) { p in
                        ProposalRow(proposal: p).tag(p.id)
                    }
                } header: {
                    Text("Änderungen (\(proposals.count))")
                }

                Section(isExpanded: $showWarnings) {
                    if issues.isEmpty, !model.sheets.isEmpty {
                        Label("Keine Warnungen", systemImage: "checkmark.seal")
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                    ForEach(issues) { issue in
                        IssueRow(issue: issue).tag(issue.id)
                    }
                } header: {
                    Text("Warnungen (\(issues.count))")
                }
            }
            .listStyle(.sidebar)
            .onChange(of: model.sidebarSelection) { _, new in model.navigate(to: new) }

            Divider()
            VStack(spacing: 8) {
                HStack {
                    Button("Alle annehmen") { model.setAll(true) }
                    Button("Alle ablehnen") { model.setAll(false) }
                }
                .controlSize(.small)
                .disabled(proposals.isEmpty)
                Button {
                    model.applyAccepted()
                } label: {
                    Text("\(model.acceptedCount) angenommene Änderung\(model.acceptedCount == 1 ? "" : "en") übernehmen")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.acceptedCount == 0)
            }
            .padding(10)
        }
    }
}

struct ProposalRow: View {
    @Environment(AppModel.self) private var model
    let proposal: SplitProposal

    var body: some View {
        let sheet = model.sheet(proposal.sheetID)
        let row = model.row(RowRef(sheetID: proposal.sheetID, rowID: proposal.rowID))
        let role = row?.text(sheet?.mapping.role) ?? ""
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "scissors").foregroundStyle(proposal.accepted ? .green : .secondary)
                Text("Zeile \(row?.label ?? "?")").font(.callout.weight(.semibold))
                if !role.isEmpty { Text(role).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 0)
            }
            if model.sidebarFilter == .all, let sheet {
                Text(sheet.title).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Text("\(proposal.reason) → \(proposal.parts.count) Takes")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(proposal.parts.map { "\($0.words)" }.joined(separator: " / ") + " Wörter")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            ForEach(proposal.notes, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
            }
            Picker("", selection: Binding(get: { proposal.accepted }, set: { model.setAccepted(proposal.id, $0) })) {
                Text("Ablehnen").tag(false)
                Text("Annehmen").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

struct IssueRow: View {
    @Environment(AppModel.self) private var model
    let issue: Issue

    var color: Color {
        switch issue.kind {
        case .missingRole, .missingTimecode, .invalidTimecode, .reversedTimecode: return .red
        case .overlap, .cannotSplit: return .orange
        case .roleSpelling: return .yellow
        case .encodingDamage: return .red
        case .specialCharacters: return .purple
        case .umlauts: return .teal
        }
    }

    var body: some View {
        let sheet = issue.refs.first.flatMap { model.sheet($0.sheetID) }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: issue.kind.symbol).foregroundStyle(color)
                Text(issue.kind.title).font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                Button { model.dismiss(issue) } label: { Image(systemName: "eye.slash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help("Warnung ausblenden")
            }
            Text(issue.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.sidebarFilter == .all, let sheet {
                Text(sheet.title).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            HStack(spacing: 10) {
                if issue.refs.count > 1 {
                    Button("Stelle \(model.refPosition(issue) + 1)/\(issue.refs.count) – nächste") {
                        model.sidebarSelection = issue.id
                        model.navigate(toIssue: issue, advance: true)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                if [.umlauts, .specialCharacters, .encodingDamage].contains(issue.kind) {
                    Menu("Beheben") {
                        ForEach(AppModel.CharacterFix.allCases) { fix in
                            Button(fix.label) { model.fixCharacters(issue.refs, fix) }
                        }
                        Divider()
                        Button("Zeile bearbeiten …") { if let r = issue.refs.first { model.editingRow = r } }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.caption)
                }
                if issue.kind == .roleSpelling {
                    Menu("Vereinheitlichen") {
                        ForEach(issue.variants, id: \.name) { v in
                            Button("Alle zu „\(v.name)“ (\(v.count)×)") { model.unifyRole(issue, to: v.name) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Warnung ausblenden") { model.dismiss(issue) }
        }
    }
}

/// Popover with checkboxes that stays open while several warning types are toggled.
/// Disabled types are not checked at all – no sidebar entries, no ⚠︎ marks in the tables.
struct WarningTypesButton: View {
    @Environment(AppModel.self) private var model
    @State private var open = false

    var body: some View {
        let disabled = model.settings.disabledIssueKinds.count
        Button {
            open.toggle()
        } label: {
            Label(disabled == 0 ? "Warnungstypen" : "Warnungstypen (\(disabled) aus)", systemImage: "line.3.horizontal.decrease.circle")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Geprüfte Warnungstypen").font(.headline)
                ForEach(IssueKind.allCases) { kind in
                    Toggle(isOn: Binding(get: { model.settings.isEnabled(kind) },
                                         set: { model.settings.setGroup([kind], $0) })) {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                    .toggleStyle(.checkbox)
                }
                Divider()
                HStack {
                    Button("Alle an") { model.settings.disabledIssueKinds.removeAll() }
                    Button("Alle aus") { model.settings.disabledIssueKinds = Set(IssueKind.allCases) }
                }
                .controlSize(.small)
                Text("Abgewählte Typen werden gar nicht mehr geprüft.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(width: 260)
        }
    }
}
