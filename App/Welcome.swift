import AppKit
import Combine
import ExpansionLensKit
import SwiftUI

/// First launch: what ExpansionLens does, the one permission it needs, and bringing snippets in.
@MainActor
final class WelcomeWindow {
    static let shared = WelcomeWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: WelcomeView { [weak self] in self?.window?.close() }))
            window.title = "Welcome to ExpansionLens"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct WelcomeView: View {
    let close: () -> Void
    @State private var trusted = ExpansionEngine.trusted
    @State private var bridge = PasteLensBridge.shared
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading) {
                    Text("Type less with snippets").font(.title2).bold()
                    Text("Type an abbreviation such as ;date anywhere, and ExpansionLens replaces it with the snippet.")
                        .foregroundStyle(.secondary)
                }
            }
            step(1, "Allow Accessibility", "ExpansionLens needs it to notice abbreviations as you type and to put snippets in their place.") {
                if trusted { Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                else { Button("Allow…") { ExpansionEngine.requestAccess(); ExpansionEngine.openAccessibilitySettings() } }
            }
            step(2, "Bring in your snippets", "Import a library from another snippet app on this Mac, or a CSV or snippet group file.") {
                HStack {
                    Button("From Other Apps…") { Importer.importFromApps() }
                    Button("From a File…") { Importer.importFile() }
                }
            }
            step(3, "Try it", "Type ;date followed by a space in any app. Quick Search (⌃⌥Space) finds any snippet by name.") {
                Button("Open Snippets") { MainWindow.shared.show(); close() }
            }
            if bridge.conflict {
                Label("PasteLens is also expanding abbreviations. Turn that off so snippets don't expand twice.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout)
                Button("Turn Off in PasteLens") { PasteLensBridge.askPasteLensToStopExpanding() }
            }
            HStack {
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onReceive(timer) { _ in trusted = ExpansionEngine.trusted }
    }

    private func step(_ n: Int, _ title: String, _ text: String, @ViewBuilder action: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline).frame(width: 26, height: 26).background(Circle().fill(.tint.opacity(0.2)))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                action()
            }
        }
    }
}

/// Debug-only hooks for testing without driving the UI, set through environment variables:
/// `EXPANSIONLENS_DEBUG=main` opens the main window; `fill:<abbreviation>` shows its fill-in window; `settings:<tab>` opens Settings; `menus` writes the menus' titles; `render:<abbreviation>` writes the expansion (scripts run) to
/// `EXPANSIONLENS_DEBUG_OUT`; `scan` writes what Import would find (and imports it with
/// EXPANSIONLENS_DEBUG_IMPORT=1); `insert:<abbreviation>`
/// types the snippet into the front app after 2 seconds.
@MainActor
enum DebugHooks {
    static func runIfRequested() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let pass = env["EXPANSIONLENS_DEBUG_SYNC"] {
            // Sets up sync with a passphrase, then every 5 s writes "groups snippets status" to the out file.
            let out = URL(fileURLWithPath: env["EXPANSIONLENS_DEBUG_OUT"] ?? NSTemporaryDirectory() + "expansionlens-debug.txt")
            Task {
                do { try await SyncEngine.shared.setUp(passphrase: pass) } catch { try? "SETUP FAILED \(error)".write(to: out, atomically: true, encoding: .utf8); return }
                Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        let lib = LibraryStore.shared.library
                        let probe = env["EXPANSIONLENS_DEBUG_PROBE"].flatMap { lib.snippet(abbreviation: $0)?.content } ?? "-"
                        let line = "\(lib.groups.count) \(lib.snippets.count) \(SyncEngine.shared.status.summary) devices=\(SyncEngine.shared.devices.count) probe=\(probe)"
                        try? line.write(to: out, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        guard let command = env["EXPANSIONLENS_DEBUG"] else { return }
        let out = URL(fileURLWithPath: env["EXPANSIONLENS_DEBUG_OUT"] ?? NSTemporaryDirectory() + "expansionlens-debug.txt")
        func write(_ s: String) { try? s.write(to: out, atomically: true, encoding: .utf8) }
        if command.hasPrefix("render:") {
            let abbreviation = String(command.dropFirst(7))
            let library = LibraryStore.shared.library
            guard let snippet = library.snippet(abbreviation: abbreviation) else { write("NOT FOUND"); return }
            let e = Renderer(library: library, runScript: ScriptRunner.runner(timeout: 10)).render(snippet)
            write(e.text + (e.errors.isEmpty ? "" : "\nERRORS: " + e.errors.joined(separator: " | ")))
        } else if command == "scan" {
            Task {
                let found = await Task.detached { Importer.findLibraries() }.value
                write(found.map { "\($0.app): \($0.result.summary)" }.joined(separator: "\n"))
                if env["EXPANSIONLENS_DEBUG_IMPORT"] == "1" { for item in found { LibraryStore.shared.add(item.result) }; LibraryStore.shared.saveNow() }
            }
        } else if command.hasPrefix("edit:") || command.hasPrefix("delete:") {
            // edit:<abbreviation>=<new content>, delete:<abbreviation>, 15 s after launch (once sync is up).
            let body = command.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                let parts = body.split(separator: "=", maxSplits: 1).map(String.init)
                guard let snippet = LibraryStore.shared.library.snippet(abbreviation: parts[0]) else { return }
                if command.hasPrefix("delete:") { LibraryStore.shared.deleteSnippets([snippet.id]) } else {
                    var changed = snippet
                    changed.content = parts.count > 1 ? parts[1] : ""
                    LibraryStore.shared.updateSnippet(changed)
                }
            }
        } else if command.hasPrefix("fill:") {
            // Shows a snippet's fill-in window; OK or Cancel just closes it.
            let library = LibraryStore.shared.library
            if let snippet = library.snippet(abbreviation: String(command.dropFirst(5))) {
                FillInWindow.show(snippet: snippet, items: FieldCollector.items(for: snippet, in: library), atTop: false) { _ in }
            }
        } else if command.hasPrefix("settings:") {
            SettingsWindow.shared.show(tab: String(command.dropFirst(9)))
        } else if command == "menus" {
            // Writes the app menu and the menu bar menu, one title per line.
            let app = NSApp.mainMenu?.items.first?.submenu?.items.map { $0.isSeparatorItem ? "---" : $0.title } ?? []
            let status = NSMenu()
            (NSApp.delegate as? NSMenuDelegate)?.menuNeedsUpdate?(status)
            write((["[app menu]"] + app + ["", "[menu bar menu]"] + status.items.map { $0.isSeparatorItem ? "---" : $0.title }).joined(separator: "\n"))
        } else if command == "main" {
            MainWindow.shared.show()
        } else if command.hasPrefix("insert:") {
            let abbreviation = String(command.dropFirst(7))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let snippet = LibraryStore.shared.library.snippet(abbreviation: abbreviation) { Inserter.shared.insert(snippet) }
            }
        }
        #endif
    }
}
