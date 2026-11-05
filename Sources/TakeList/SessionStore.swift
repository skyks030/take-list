import Foundation
import TakeListCore

/// Keeps the open tables in ~/Library/Application Support/Take-Liste/Session so they reopen on the next launch –
/// with all edits, independent of the original files (which may have moved or changed since).
struct SessionStore {
    struct Snapshot: Codable {
        var format = 1
        var sheets: [TakeSheet]
        /// Imported file URL → name of the stored package (the bytes as imported, the export baseline).
        var sources: [URL: String]
        var dirtyFiles: [URL]
        var selectedSheetID: UUID?
        var dismissedIssueKeys: [String]
    }

    let directory: URL
    var sourcesDirectory: URL { directory.appendingPathComponent("sources", isDirectory: true) }
    var sessionFile: URL { directory.appendingPathComponent("session.json") }

    static let shared: SessionStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SessionStore(directory: base.appendingPathComponent("Take-Liste/Session", isDirectory: true))
    }()

    /// Loads the last session. Sheets whose stored package is missing are dropped.
    func load() -> (snapshot: Snapshot, data: [URL: Data])? {
        guard let json = try? Data(contentsOf: sessionFile),
              var snap = try? JSONDecoder().decode(Snapshot.self, from: json) else { return nil }
        var data: [URL: Data] = [:]
        for (url, name) in snap.sources {
            if let d = try? Data(contentsOf: sourcesDirectory.appendingPathComponent(name)) { data[url] = d }
        }
        snap.sheets.removeAll { data[$0.fileURL] == nil }
        snap.sources = snap.sources.filter { data[$0.key] != nil }
        return (snap, data)
    }

    /// Writes the session. `fileNames` maps each source to its stored package; missing packages are written,
    /// packages no longer referenced are deleted.
    func save(_ snap: Snapshot, data: [URL: Data]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        for (url, name) in snap.sources {
            let file = sourcesDirectory.appendingPathComponent(name)
            if !fm.fileExists(atPath: file.path), let d = data[url] { try d.write(to: file, options: .atomic) }
        }
        let json = try JSONEncoder().encode(snap)
        try json.write(to: sessionFile, options: .atomic)
        let keep = Set(snap.sources.values)
        for file in (try? fm.contentsOfDirectory(atPath: sourcesDirectory.path)) ?? [] where !keep.contains(file) {
            try? fm.removeItem(at: sourcesDirectory.appendingPathComponent(file))
        }
    }
}
