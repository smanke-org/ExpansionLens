import AppKit
import ExpansionLensKit
import UniformTypeIdentifiers

/// Bringing snippets in from other apps on this Mac, and from files; exporting a backup.
@MainActor
enum Importer {
    struct Found {
        var appName: String
        var database: URL
        var result: ImportResult
    }

    /// Looks through every app's WebKit storage for a snippet library kept in IndexedDB.
    /// Only copies are read, so the other app is never disturbed.
    nonisolated static func findLibraries() -> [(app: String, database: URL, result: ImportResult)] {
        let webKit = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/WebKit")
        let folders = (try? FileManager.default.contentsOfDirectory(at: webKit, includingPropertiesForKeys: nil)) ?? []
        var out: [(String, URL, ImportResult)] = []
        for folder in folders where folder.lastPathComponent != Bundle.main.bundleIdentifier {
            for database in SnippetImport.findEventLogDatabases(under: folder.appendingPathComponent("WebsiteData")) {
                guard let records = try? SnippetImport.readRecords(database: database, store: "events") else { continue }
                let result = SnippetImport.fromEventRecords(records)
                guard !result.snippets.isEmpty else { continue }
                out.append((appName(forBundleID: folder.lastPathComponent), database, result))
            }
        }
        return out
    }

    nonisolated static func appName(forBundleID id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Finds libraries from other apps and offers to import each.
    static func importFromApps() {
        Task {
            let found = await Task.detached { findLibraries() }.value
            guard !found.isEmpty else {
                alert("No snippet libraries found", "ExpansionLens didn't find another app's snippet library on this Mac. You can import a CSV or snippet group file instead.")
                return
            }
            for item in found {
                let a = NSAlert()
                a.messageText = "Import from \(item.app)?"
                a.informativeText = "Found \(item.result.summary): \(item.result.groups.map(\.name).joined(separator: ", ")).\n\nImporting again later updates these groups rather than adding copies."
                a.addButton(withTitle: "Import")
                a.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn {
                    LibraryStore.shared.add(item.result)
                    MainWindow.shared.show(section: .all)
                }
            }
        }
    }

    static func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .propertyList, .json, .xml, .data]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose CSV files (abbreviation, content, label), snippet group property lists, or an ExpansionLens export."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        var total = ImportResult()
        for url in panel.urls {
            let name = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url) else { continue }
            var result: ImportResult
            if let library = try? SyncRecord.decode(Library.self, from: data) {
                result = ImportResult()
                result.groups = library.groups
                result.snippets = library.snippets
            } else if url.pathExtension.lowercased() == "csv" || url.pathExtension.lowercased() == "txt" {
                result = SnippetImport.fromCSV(String(decoding: data, as: UTF8.self), groupName: name)
            } else {
                result = SnippetImport.fromPropertyList(data, fallbackName: name)
                if result.snippets.isEmpty { result = SnippetImport.fromCSV(String(decoding: data, as: UTF8.self), groupName: name) }
            }
            total.groups += result.groups
            total.snippets += result.snippets
            total.skipped += result.skipped
        }
        guard !total.snippets.isEmpty else { alert("Nothing to import", "No snippets were found in that file."); return }
        LibraryStore.shared.add(total)
        alert("Imported", "Added \(total.summary).")
        MainWindow.shared.show(section: .all)
    }

    static func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ExpansionLens Snippets.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try LibraryStore.shared.export(to: url) } catch { alert("Couldn't export", error.localizedDescription) }
    }

    private static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
