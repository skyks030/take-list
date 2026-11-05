import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the updater, which already asked about unexported changes before quitting.
    @MainActor static var skipTerminationPrompt = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Look for a new version on every launch (quietly – only a found update shows up).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated { Updater.shared.check(userInitiated: false) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !Self.skipTerminationPrompt, AppModel.shared.isDirty, !AppModel.shared.confirmDiscard() { return .terminateCancel }
        return .terminateNow
    }
}

@main
struct TakeListApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Take-Liste", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .defaultSize(width: 1500, height: 900)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Nach Updates suchen …") { Updater.shared.check(userInitiated: true) }
            }
            CommandGroup(replacing: .newItem) {
                Button("Takeliste importieren (Excel / CSV) …") { model.showImportPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Als Excel exportieren …") { model.export() }
                    .keyboardShortcut("e")
                    .disabled(model.sheets.isEmpty)
                Button("Als Marker exportieren (Nuendo / Resolve) …") { model.showMarkerExport = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.sheets.isEmpty)
                Button("Listen zusammenführen …") { model.showMerge = true }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(model.mergeableCount < 2)
                Button("Tabelle schließen") { if let id = model.selectedSheetID { model.closeSheet(id) } }
                    .keyboardShortcut("w")
                    .disabled(model.selectedSheetID == nil)
            }
            CommandMenu("Takes") {
                Button("Scannen") { model.scan() }
                    .keyboardShortcut("r")
                    .disabled(model.sheets.isEmpty)
                Button("Angenommene Änderungen übernehmen") { model.applyAccepted() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.acceptedCount == 0)
                Divider()
                Button("Alle annehmen") { model.setAll(true) }
                    .disabled(model.proposals.isEmpty)
                Button("Alle ablehnen") { model.setAll(false) }
                    .disabled(model.proposals.isEmpty)
                Divider()
                Button("Spaltenzuordnung ändern …") { if let id = model.selectedSheetID { model.remap(id) } }
                    .disabled(model.selectedSheetID == nil)
                Menu("Sonderzeichen in allen Tabellen") {
                    ForEach(AppModel.CharacterFix.allCases) { fix in
                        Button(fix.label) { model.fixCharacters(nil, fix) }
                    }
                }
                .disabled(model.sheets.isEmpty)
                Button("Ausgeblendete Warnungen wieder anzeigen") { model.restoreDismissed() }
                    .disabled(model.dismissedIssueKeys.isEmpty)
            }
        }
    }
}
