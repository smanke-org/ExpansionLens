import AppKit
import SwiftUI

// MARK: - Content

/// One page of Help. `Help.resolve` swaps `{…}` tokens for the user's own settings, such
/// as their shortcuts, so the text matches what they've set up.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let blocks: [HelpBlock]

    static func == (a: HelpTopic, b: HelpTopic) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
enum HelpBlock {
    case text(String)
    case heading(String)
    /// Keys on the left, what they do on the right.
    case keys([(String, String)])
    case tip(String)

    var searchText: String {
        switch self {
        case .text(let s), .heading(let s), .tip(let s): Help.resolve(s)
        case .keys(let rows): rows.map { Help.resolve($0.0) + " " + Help.resolve($0.1) }.joined(separator: " ")
        }
    }
}

@MainActor
enum Help {
    /// `{hotkey:<HotKeyAction>}` shows the user's own shortcut for that action.
    static func resolve(_ text: String) -> String {
        guard text.contains("{hotkey:") else { return text }
        var out = text
        for action in HotKeyAction.allCases {
            out = out.replacingOccurrences(of: "{hotkey:\(action.rawValue)}",
                                           with: Preferences.shared.hotKey(action)?.display ?? "(no shortcut set)")
        }
        return out
    }

    static var debugTokens: String { resolve(HotKeyAction.allCases.map { "{hotkey:\($0.rawValue)}" }.joined(separator: " ")) }
    static let testTabs = ["General", "Expansion", "Typing", "Shortcuts", "Sync", "Privacy"]

    /// The topic each Settings tab's Help button opens.
    static func topic(forSettingsTab tab: String) -> String {
        switch tab {
        case "Expansion": "expansion"
        case "Typing": "typing"
        case "Shortcuts": "shortcuts"
        case "Sync": "sync"
        case "Privacy": "privacy"
        default: "getting-started"
        }
    }

    static var topics: [HelpTopic] { [
        HelpTopic(id: "getting-started", title: "Getting Started", symbol: "sparkles", blocks: [
            .text("ExpansionLens types snippets for you. Give a snippet an abbreviation, such as ;sig, and whenever you type that abbreviation in any app, ExpansionLens replaces it with the snippet."),
            .keys([
                ("{hotkey:quickSearch}", "Quick Search: find any snippet by name or content and insert it"),
                ("{hotkey:openMain}", "Open the library to add and edit snippets"),
                ("{hotkey:toggleExpansion}", "Turn expansion on or off"),
                ("Menu bar icon", "Quick Search, Insert Snippet, New Snippet and more"),
            ]),
            .heading("Allow Accessibility"),
            .text("ExpansionLens needs Accessibility permission (macOS 27 calls it Device Control) to see what you type and put snippets in place. If the menu bar menu shows \"Allow Accessibility to Expand…\", choose it."),
            .tip("Already using another text expander? File › Import from Other Apps… brings its snippets in."),
            .tip("While ToolHUD is running, ExpansionLens's menu moves into ToolHUD's menu bar menu as a submenu, and the icon here steps aside until ToolHUD quits. To keep the icon, turn off \"Put in ToolHUD's menu while ToolHUD is running\" in Settings."),
        ]),

        HelpTopic(id: "snippets", title: "Snippets and Groups", symbol: "text.append", blocks: [
            .text("The library window lists your groups on the left and their snippets in the middle. A snippet has a label, an abbreviation and its content, which can be plain text, formatted text, or a script."),
            .keys([
                ("⌘N", "New snippet"),
                ("⇧⌘N", "New snippet from what's on the clipboard"),
                ("{hotkey:editLast}", "Edit the snippet that expanded last, handy to fix one right after using it"),
            ]),
            .text("Groups keep snippets tidy and can carry their own expansion settings. Insert Snippet in the menu bar menu lists every snippet to insert by hand."),
            .heading("Script snippets"),
            .text("A snippet can be AppleScript, a shell script or JavaScript; what it returns is typed in. Scripts only run when \"Run AppleScript, shell and JavaScript snippets\" is on in Settings › Expansion. They run as you, so only use scripts you wrote or trust."),
        ]),

        HelpTopic(id: "macros", title: "Placeholders", symbol: "percent", blocks: [
            .text("Snippet content can include placeholders that fill in as it expands. Anything ExpansionLens doesn't recognize stays as plain text, so a stray % is harmless."),
            .keys([
                ("%clipboard", "What's on the clipboard"),
                ("%|", "Where the insertion point ends up"),
                ("%\\", "With %|, select the text between them after expanding"),
                ("%Y %m %d", "Year, month, day (also %B month name, %A weekday, %y, %b, %a, %e, %j)"),
                ("%H %M %S %p", "Hour, minute, second, AM/PM (%I for 12-hour)"),
                ("%date:pattern%", "A date in any format, such as %date:yyyy-MM-dd%"),
                ("%@+1D", "Shift the date for the parts after it: D days, m months, Y years, h hours, M minutes, s seconds (+ or -)"),
                ("%snippet:abbr%", "Insert another snippet"),
                ("%key:tab%", "Press a key, such as tab, return or enter"),
                ("%< %> %^ %v", "Press the left, right, up or down arrow"),
                ("%delay:500%", "Wait 500 milliseconds"),
                ("%%", "A literal percent sign"),
            ]),
            .heading("Fill-ins"),
            .text("Fill-ins ask for values before the snippet goes in: %filltext% (one line), %fillarea% (several lines), %fillpopup% (a menu of choices), %filldatepicker% (a date), %fillpart% (an optional section) and %fillconditional% (a section that depends on another field). Give fields names so the same value appears in several places."),
            .heading("Choosing the moment"),
            .keys([
                ("%+ at the end", "Expand at a delimiter and keep it"),
                ("%- at the end", "Expand at a delimiter and remove it"),
                ("%! at the end", "Expand immediately"),
            ]),
        ]),

        HelpTopic(id: "expansion", title: "How Expansion Works", symbol: "text.cursor", blocks: [
            .text("Settings › Expansion decides when an abbreviation counts. Snippets and groups can override these."),
            .keys([
                ("Expand abbreviations", "Only after whitespace, after anything but letters and numbers, or after any character"),
                ("Case", "Case sensitive; ignore case; or adapt the snippet to how you capitalized the abbreviation"),
                ("Expand after", "Immediately, or at a delimiter, keeping or removing it"),
                ("Delimiters", "Space, Tab, Return and the punctuation you choose"),
                ("Put the clipboard back", "Restore what you had copied after a snippet is pasted in"),
            ]),
            .text("Snippets go in by pasting, which is quick and keeps formatting. If an app sometimes pastes your old clipboard instead, raise the paste delay in Settings › Expansion."),
        ]),

        HelpTopic(id: "quick-search", title: "Quick Search", symbol: "magnifyingglass", blocks: [
            .text("Press {hotkey:quickSearch} anywhere to search every snippet by label, abbreviation or content."),
            .keys([
                ("↑ ↓", "Choose a snippet"),
                ("Return", "Insert it into the app you were using"),
                ("Esc", "Close"),
            ]),
        ]),

        HelpTopic(id: "typing", title: "Typing Helpers and Suggestions", symbol: "textformat", blocks: [
            .keys([
                ("Capitalize sentences", "Capitalize the first word of a sentence as you type"),
                ("Fix DOuble CApitals", "Correct two capitals at the start of a word"),
                ("Suggestions", "Offer to make snippets for sentences you type often"),
                ("Tutor", "Remind you of the abbreviation when you type out a snippet by hand"),
            ]),
            .text("For suggestions, ExpansionLens keeps only a count for each sentence, under a one-way hash. A sentence's text is kept only once it has come up three times."),
        ]),

        HelpTopic(id: "shortcuts", title: "Keyboard Shortcuts", symbol: "keyboard", blocks: [
            .keys(HotKeyAction.allCases.map { ("{hotkey:\($0.rawValue)}", $0.title) } + [
                ("⌘N / ⇧⌘N", "New snippet / from the clipboard (in ExpansionLens)"),
                ("⌘?", "This Help, from ExpansionLens's menus"),
            ]),
            .text("Change the shortcuts in Settings › Shortcuts. They work in every app."),
        ]),

        HelpTopic(id: "sync", title: "Sync", symbol: "icloud", blocks: [
            .text("Turn on sync in Settings › Sync to share snippets, groups and settings with your other Macs through iCloud, encrypted with a passphrase only you know. Use the same passphrase on each Mac. Whether expansion is on, suggestions, and the Dock and menu bar choices stay on each Mac."),
        ]),

        HelpTopic(id: "privacy", title: "Privacy", symbol: "hand.raised", blocks: [
            .text("Keystrokes are only compared with your abbreviations as you type; nothing you type is recorded or sent anywhere. Expansion pauses when an app turns on Secure Input, such as a password field, and the menu bar menu says which app it was."),
        ]),

        HelpTopic(id: "automation", title: "Automation", symbol: "gearshape.2", blocks: [
            .keys([
                ("expansionlens://quicksearch", "Quick Search"),
                ("expansionlens://open", "Open the library"),
                ("expansionlens://new", "New snippet"),
                ("expansionlens://newfromclipboard", "New snippet from the clipboard"),
                ("expansionlens://editlast", "Edit the last expanded snippet"),
                ("expansionlens://toggle", "Turn expansion on or off (also on and off)"),
                ("expansionlens://settings", "Open Settings"),
            ]),
            .text("Use these links from Shortcuts, scripts or a launcher. ToolHUD's ExpansionLens buttons use them."),
        ]),

        HelpTopic(id: "troubleshooting", title: "Troubleshooting", symbol: "wrench.and.screwdriver", blocks: [
            .heading("Abbreviations don't expand"),
            .text("Check that expansion is on (the menu bar menu) and that ExpansionLens has Accessibility permission. If the menu says \"Expansion Blocked\", another app has Secure Input on; close its password field, or quit that app."),
            .heading("A snippet expands twice"),
            .text("PasteLens may be expanding abbreviations too. Choose \"PasteLens Is Also Expanding — Turn It Off\" in the menu bar menu, or turn it off in PasteLens's Settings › Snippets."),
            .heading("The old clipboard gets pasted"),
            .text("Raise the paste delay in Settings › Expansion; some apps are slow to read the clipboard."),
            .heading("A script snippet does nothing"),
            .text("Turn on \"Run AppleScript, shell and JavaScript snippets\" in Settings › Expansion."),
        ]),
    ] }
}

// MARK: - Window

@Observable
@MainActor
final class HelpState {
    var selection: String? = "getting-started"
    var query = ""
}

@MainActor
final class HelpWindow: NSObject, NSWindowDelegate {
    static let shared = HelpWindow()

    let state = HelpState()
    private(set) var window: NSWindow?

    /// Opens Help, on `topic` when given.
    func show(topic: String? = nil) {
        if let topic { state.query = ""; state.selection = topic }
        if window == nil {
            let hosting = NSHostingController(rootView: HelpView(state: state))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "\(AppInfo.name) Help"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            let screen = NSScreen.main?.visibleFrame.height ?? 800
            window.setContentSize(NSSize(width: 820, height: min(600, screen - 80)))
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("ExpansionLensHelp")
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HelpView: View {
    @Bindable var state: HelpState

    private var matches: [HelpTopic] {
        let query = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Help.topics }
        return Help.topics.filter { topic in
            topic.title.lowercased().contains(query) || topic.blocks.contains { $0.searchText.lowercased().contains(query) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(matches, selection: $state.selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .overlay {
                if matches.isEmpty { Text("No matches").foregroundStyle(.secondary) }
            }
        } detail: {
            if let topic = Help.topics.first(where: { $0.id == state.selection }) {
                HelpPage(topic: topic, query: state.query)
            } else {
                Text("Choose a topic").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $state.query, placement: .sidebar, prompt: "Search Help")
        .onChange(of: state.query) {
            // Keep a matching topic on screen while searching.
            if let first = matches.first, !matches.contains(where: { $0.id == state.selection }) { state.selection = first.id }
        }
    }
}

struct HelpPage: View {
    let topic: HelpTopic
    let query: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(topic.title, systemImage: topic.symbol)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.bottom, 4)
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func view(for block: HelpBlock) -> some View {
        switch block {
        case .text(let s):
            Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true)
        case .heading(let s):
            Text(Help.resolve(s)).font(.title3.weight(.semibold)).padding(.top, 8)
        case .tip(let s):
            Label { Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .keys(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let keys = Help.resolve(row.0), what = Help.resolve(row.1)
                    let hit = !query.isEmpty && (keys + " " + what).lowercased().contains(query.lowercased())
                    GridRow {
                        Text(keys)
                            .font(.body.monospaced().weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            // The same key column width in every table on every page.
                            .frame(width: 210, alignment: .leading)
                        Text(what).fixedSize(horizontal: false, vertical: true)
                    }
                    .background(hit ? Color.yellow.opacity(0.25) : .clear)
                }
            }
        }
    }
}

/// The round "?" button macOS puts in the corner of settings panes.
struct HelpButton: NSViewRepresentable {
    let topic: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open))
        button.bezelStyle = .helpButton
        button.toolTip = "\(AppInfo.name) Help"
        button.setAccessibilityLabel("Help")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.topic = topic }

    func makeCoordinator() -> Coordinator { Coordinator(topic: topic) }

    @MainActor
    final class Coordinator: NSObject {
        var topic: String
        init(topic: String) { self.topic = topic }
        @objc func open() { HelpWindow.shared.show(topic: topic) }
    }
}
