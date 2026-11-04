import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.importFiles(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppModel.shared.isDirty, !AppModel.shared.confirmDiscard() { return .terminateCancel }
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
            CommandGroup(replacing: .newItem) {
                Button("Excel-Tabelle importieren …") { model.showImportPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Exportieren …") { model.export() }
                    .keyboardShortcut("e")
                    .disabled(model.sheets.isEmpty)
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
                Button("Ausgeblendete Warnungen wieder anzeigen") { model.restoreDismissed() }
                    .disabled(model.dismissedIssueKeys.isEmpty)
            }
        }
    }
}
