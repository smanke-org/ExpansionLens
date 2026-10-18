import AppKit
import ExpansionLensKit
import SwiftUI

struct GeneralSettings: View {
    @State private var prefs = Preferences.shared
    @State private var presence = PresenceSettings.shared
    @State private var login = LaunchAtLogin.shared
    @State private var engine = ExpansionEngine.shared
    @State private var bridge = PasteLensBridge.shared
    @State private var confirmReset = false
    #if !APPSTORE
    @State private var updater = AutoUpdater.shared
    #endif

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Open ExpansionLens") { MainWindow.shared.show() }
                } label: {
                    Text("Your snippets")
                    Text("Add, edit and organize snippets in the library window.").font(.caption)
                }
            }
            Section {
                Toggle("Expand abbreviations", isOn: $prefs.enabled)
                LabeledContent {
                    if ExpansionEngine.trusted { Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    else { Button("Allow…") { ExpansionEngine.requestAccess(); ExpansionEngine.openAccessibilitySettings() } }
                } label: {
                    Text("Accessibility")
                    Text("Needed to see abbreviations as you type and to put snippets in their place.").font(.caption)
                }
                if case .blockedBySecureInput(let app) = engine.state {
                    Label("\(app ?? "An app") has Secure Input on (a password field), so nothing can expand until it's off.", systemImage: "lock.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
            }
            if bridge.conflict {
                Section {
                    LabeledContent {
                        Button("Turn Off in PasteLens") { PasteLensBridge.askPasteLensToStopExpanding() }
                    } label: {
                        Label("PasteLens is also expanding abbreviations", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text("Abbreviations would expand twice. Keep your snippets here and turn expansion off in PasteLens.").font(.caption)
                    }
                }
            }
            Section("Where ExpansionLens appears") {
                Toggle("Show in Dock", isOn: $presence.showInDock)
                Toggle("Show in menu bar", isOn: $presence.showInMenuBar)
                if !presence.showInDock && !presence.showInMenuBar {
                    Text(AppPresence.hiddenEverywhereNote(appName: "ExpansionLens", settingsName: "Settings"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Open ExpansionLens at login", isOn: Binding(get: { login.isEnabled }, set: { login.set($0) }))
                if login.needsApproval { Button("Allow in Login Items…") { login.openLoginItemsSettings() } }
                if let error = login.lastError { Text(error).font(.callout).foregroundStyle(.red) }
                Toggle("Warn when PasteLens also expands abbreviations", isOn: $prefs.warnPasteLens)
            }
            #if !APPSTORE
            Section {
                Picker("When an update is available", selection: $updater.policy) {
                    ForEach(UpdatePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if updater.policy != .off {
                    UpdateIntervalPicker(interval: $updater.interval)
                }
                if let staged = updater.staged {
                    LabeledContent("Version \(staged.version) is ready") { Button("Install Now") { updater.installNow() } }
                }
                LabeledContent("Version \(AppInfo.displayVersion)") { Button("Check Now") { UpdateController.checkForUpdates() } }
                if let error = updater.lastError { Text(error).font(.callout).foregroundStyle(.red) }
                if updater.policy != .off && !updater.notificationsAllowed {
                    LabeledContent {
                        Button("Open Notification Settings") { AutoUpdater.openNotificationSettings() }
                    } label: {
                        Label("Notifications are off for ExpansionLens, so update news only shows in the menu.", systemImage: "bell.slash").foregroundStyle(.orange)
                    }
                }
            } header: { Text("Updates") } footer: {
                Text(updater.policy == .automatic
                     ? "ExpansionLens checks \(updater.interval.phrase). New versions install themselves when no fill-in window is open, nothing is being typed out, and your Mac has been idle for 2 minutes."
                     : updater.policy == .ask ? "ExpansionLens checks \(updater.interval.phrase) and tells you when a new version is out." : "Use Check Now whenever you like.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #endif
            Section("Snippets") {
                LabeledContent("Bring in snippets") {
                    HStack {
                        Button("From Other Apps…") { Importer.importFromApps() }
                        Button("From a File…") { Importer.importFile() }
                    }
                }
                LabeledContent("Back up your snippets") { Button("Export…") { Importer.export() } }
                LabeledContent("ExpansionLens data") { Button("Show in Finder") { NSWorkspace.shared.open(LibraryStore.shared.folder) } }
            }
            Section {
                LabeledContent("All ExpansionLens settings") { Button("Reset to Defaults…") { confirmReset = true } }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            login.refresh()
            #if !APPSTORE
            updater.refreshNotificationStatus()
            #endif
        }
        .confirmationDialog("Reset ExpansionLens settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                prefs.resetToDefaults()
                HotKeyCenter.shared.apply()
            }
        } message: {
            Text("Shortcuts and options go back to how ExpansionLens started. Your snippets stay.")
        }
    }
}

struct ExpansionSettings: View {
    @State private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section {
                Picker("Expand abbreviations", selection: $prefs.mode) {
                    ForEach(ExpansionMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Case", selection: $prefs.caseMode) {
                    ForEach(CaseMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Expand after", selection: $prefs.expandAfter) {
                    ForEach(ExpandAfter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Snippets and groups can override these. A snippet ending in %+, %- or %! picks its own moment to expand.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Delimiters") {
                // Checkboxes, each with its label right beside it: switches in a row read as
                // belonging to the label on their right.
                LabeledContent("Keys") {
                    HStack(spacing: 16) {
                        Toggle("Space", isOn: delimiter(" "))
                        Toggle("Tab", isOn: delimiter("\t"))
                        Toggle("Return", isOn: delimiter("\n"))
                    }
                    .toggleStyle(.checkbox)
                }
                LabeledContent("Punctuation") {
                    TextField("", text: Binding(
                        get: { prefs.delimiters.filter { !" \t\n\r".contains($0) } },
                        set: { typed in
                            let whitespace = prefs.delimiters.filter { " \t\n".contains($0) }
                            prefs.delimiters = whitespace + String(Set(typed.filter { !$0.isWhitespace }).sorted())
                        }
                    ))
                    .font(.system(.body, design: .monospaced))
                }
                Button("Restore Default Delimiters") { prefs.delimiters = Preferences.defaultDelimiters }
            }
            Section {
                Toggle("Play a sound when a snippet expands", isOn: $prefs.sound)
                Toggle("Put the clipboard back after pasting a snippet", isOn: $prefs.restoreClipboard)
                if prefs.restoreClipboard {
                    LabeledContent("After") {
                        HStack {
                            TextField("", value: $prefs.restoreDelay, format: .number.precision(.fractionLength(0...2)))
                                .multilineTextAlignment(.trailing).frame(width: 60)
                            Text("seconds")
                        }
                    }
                }
            } footer: {
                Text("Snippets go in by pasting, which is quick and keeps formatting. Raise the delay if an app sometimes pastes your old clipboard instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Expand in") {
                AppScopeEditor(scope: $prefs.scope)
            }
            Section {
                Toggle("Run AppleScript, shell and JavaScript snippets", isOn: $prefs.scriptsAllowed)
                LabeledContent("Stop a script after") {
                    HStack {
                        TextField("", value: $prefs.scriptTimeout, format: .number).multilineTextAlignment(.trailing).frame(width: 60)
                        Text("seconds")
                    }
                }
            } header: { Text("Scripts") } footer: {
                Text("Script snippets run as you, with your permissions. Only turn this on for scripts you wrote or trust.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func delimiter(_ c: Character) -> Binding<Bool> {
        Binding(get: { prefs.delimiters.contains(c) },
                set: { on in
                    var set = Array(prefs.delimiters).filter { $0 != c }
                    if on { set.insert(c, at: 0) }
                    prefs.delimiters = String(set)
                })
    }
}

struct TypingSettings: View {
    @State private var prefs = Preferences.shared
    @State private var store = LibraryStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Capitalize the first word of a sentence", isOn: $prefs.capSentences)
                Toggle("Fix DOuble CApitals", isOn: $prefs.capDoubleCaps)
                LabeledContent("Extra characters inside words") {
                    TextField("", text: $prefs.capContraction, prompt: Text("e.g. -")).frame(width: 80)
                }
                if prefs.capSentences || prefs.capDoubleCaps { AppScopeEditor(scope: $prefs.capScope) }
            } header: { Text("Capitalization") }
            Section {
                Toggle("Suggest snippets for sentences I type often", isOn: $prefs.suggestions)
                Toggle("Notify me about new suggestions", isOn: $prefs.suggestionsNotify).disabled(!prefs.suggestions)
                Toggle("Tell me the abbreviation when I type out a snippet by hand", isOn: $prefs.tutor)
                if prefs.suggestions { AppScopeEditor(scope: $prefs.suggestScope) }
                LabeledContent("Counted sentences") {
                    Button("Forget") { store.clearSuggestionHistory() }
                }
            } header: { Text("Suggestions") } footer: {
                Text("ExpansionLens keeps only a count for each sentence, under a one-way hash. A sentence's text is kept only once it has come up three times and is offered as a suggestion. Nothing you type leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutSettings: View {
    @State private var prefs = Preferences.shared
    @State private var warning: String?

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(hotKey: Binding(
                            get: { prefs.hotKey(action) },
                            set: { key in
                                if let key, let owner = HotKeyCenter.shared.owner(of: key, except: action) {
                                    warning = "\(key.display) was already used for “\(owner)”."
                                } else { warning = nil }
                                prefs.setHotKey(key, for: action)
                            }))
                    }
                }
                if let warning { Text(warning).font(.callout).foregroundStyle(.orange) }
            } footer: {
                Text("Click a shortcut, then press the keys. Delete clears it. These work in every app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PrivacySettings: View {
    var body: some View {
        Form {
            Section("What you type") {
                PrivacyPoint(symbol: "keyboard", title: "Only on this Mac",
                             text: "ExpansionLens watches keys to spot abbreviations, keeping just the last few hundred characters in memory. It never saves or sends what you type, and it sees nothing while a password field has Secure Input on.")
                PrivacyPoint(symbol: "lightbulb", title: "Suggestions are counts",
                             text: "With suggestions on, each sentence is counted under a one-way hash. Its text is kept only once you've typed it three times, and only on this Mac.")
            }
            Section("Your snippets") {
                PrivacyPoint(symbol: "icloud", title: "Encrypted in iCloud",
                             text: "With sync on, snippets and settings are sealed with AES-256-GCM on your Mac before upload. The key is protected by your sync passphrase, so neither Apple nor the developer can read them.")
                PrivacyPoint(symbol: "doc.on.clipboard", title: "The clipboard",
                             text: "Snippets are pasted, so they pass through the clipboard for a moment. They're marked so clipboard managers skip them, and your previous clipboard is put back.")
            }
            Section("The developer") {
                PrivacyPoint(symbol: "chart.bar.xaxis", title: "No analytics",
                             text: "ExpansionLens has no tracking, accounts or ads. The only network requests are iCloud sync (when on) and the update check to GitHub.")
            }
        }
        .formStyle(.grouped)
    }
}

struct PrivacyPoint: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
