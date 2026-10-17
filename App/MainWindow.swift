import AppKit
import ExpansionLensKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The library window: groups on the left, snippets in the middle, the editor on the right.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    static let shared = MainWindow()
    let model = MainModel()
    private var window: NSWindow?

    func show(section: MainModel.Section? = nil) {
        if window == nil {
            let hosting = NSHostingController(rootView: LibraryView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "ExpansionLens"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 1040, height: 640))
            window.setFrameAutosaveName("ExpansionLensMain")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        if let section { model.section = section }
        AppActivity.touch()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func show(snippet id: UUID) {
        guard let snippet = LibraryStore.shared.snippet(id) else { show(); return }
        show(section: .group(snippet.groupID))
        model.selection = [id]
    }

    func newSnippet(content: String = "") {
        let groupID: UUID
        if case .group(let id) = model.section { groupID = id } else {
            groupID = LibraryStore.shared.library.sortedGroups.first?.id ?? LibraryStore.shared.addGroup(name: "My Snippets").id
        }
        let snippet = LibraryStore.shared.addSnippet(to: groupID, content: content)
        show(snippet: snippet.id)
        model.focusAbbreviation = true
    }

    func newFromClipboard() {
        newSnippet(content: (NSPasteboard.general.string(forType: .string) ?? "").replacingOccurrences(of: "%", with: "%%"))
    }

    func editLast() {
        if let id = LibraryStore.shared.lastExpanded { show(snippet: id) } else { show() }
    }

    func createFromSuggestion(_ hash: String) {
        guard let suggestion = LibraryStore.shared.tracker.suggestions.first(where: { $0.hash == hash }) else { return }
        LibraryStore.shared.removeSuggestion(hash)
        newSnippet(content: suggestion.text.replacingOccurrences(of: "%", with: "%%"))
    }
}

@Observable
@MainActor
final class MainModel {
    enum Section: Hashable {
        case all, group(UUID), suggestions, conflicts
    }

    enum Sort: String, CaseIterable {
        case label = "Label", abbreviation = "Abbreviation", content = "Content", modified = "Date Modified", uses = "Most Used"
    }

    var section: Section = .all { didSet { if section != oldValue { selection = [] } } }
    var selection: Set<UUID> = []
    var search = ""
    var sort = Sort.label
    var ascending = true
    var focusAbbreviation = false
    var editingGroup: UUID?

    func visibleSnippets(_ library: Library) -> [Snippet] {
        var list: [Snippet]
        switch section {
        case .all, .suggestions: list = library.snippets
        case .group(let id): list = library.snippets(in: id)
        case .conflicts:
            let ids = Set(Conflict.find(in: library, settings: Preferences.shared.matchSettings).flatMap { [$0.snippet, $0.other] })
            list = library.snippets.filter { ids.contains($0.id) }
        }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            list = list.filter {
                library.trigger(for: $0).lowercased().contains(query) || $0.label.lowercased().contains(query) || $0.content.lowercased().contains(query)
            }
        }
        list.sort { a, b in
            let ordered: Bool = switch sort {
            case .label: a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            case .abbreviation: library.trigger(for: a).localizedStandardCompare(library.trigger(for: b)) == .orderedAscending
            case .content: a.content.localizedStandardCompare(b.content) == .orderedAscending
            case .modified: a.updatedAt < b.updatedAt
            case .uses: a.useCount < b.useCount
            }
            return ascending ? ordered : !ordered
        }
        return list
    }
}

// MARK: - Views

struct LibraryView: View {
    @Bindable var model: MainModel
    @State private var store = LibraryStore.shared
    @State private var engine = ExpansionEngine.shared
    @State private var bridge = PasteLensBridge.shared

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } content: {
            Group {
                if model.section == .suggestions { SuggestionList() } else { SnippetList(model: model) }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            detail
        }
        .safeAreaInset(edge: .top, spacing: 0) { banner }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search snippets")
        .toolbar {
            ToolbarItemGroup {
                Button { MainWindow.shared.newSnippet() } label: { Label("New Snippet", systemImage: "square.and.pencil") }
                    .help("New snippet (⌘N)")
                    .keyboardShortcut("n")
                Toggle(isOn: Binding(get: { Preferences.shared.enabled }, set: { Preferences.shared.enabled = $0 })) {
                    Label("Expansion", systemImage: Preferences.shared.enabled ? "bolt.fill" : "bolt.slash")
                }
                .help(Preferences.shared.enabled ? "Expansion is on" : "Expansion is off")
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if model.selection.count == 1, let id = model.selection.first, store.snippet(id) != nil {
            SnippetEditor(id: id, model: model).id(id)
        } else if model.selection.count > 1 {
            ContentUnavailableView("\(model.selection.count) Snippets Selected", systemImage: "square.stack.3d.up",
                                   description: Text("Use the right-click menu to move, copy or delete them."))
        } else if case .group(let id) = model.section, store.library.group(id) != nil {
            GroupEditor(id: id).id(id)
        } else {
            ContentUnavailableView("No Snippet Selected", systemImage: "text.cursor",
                                   description: Text("Choose a snippet, or press ⌘N to make one."))
        }
    }

    @ViewBuilder private var banner: some View {
        VStack(spacing: 0) {
            switch engine.state {
            case .needsAccessibility:
                BannerRow(text: "ExpansionLens needs Accessibility permission to expand abbreviations.", symbol: "lock.shield",
                          button: "Allow…") { ExpansionEngine.requestAccess(); ExpansionEngine.openAccessibilitySettings() }
            case .blockedBySecureInput(let app):
                BannerRow(text: "\(app ?? "An app") turned on Secure Input (a password field), so nothing can expand until it's off.",
                          symbol: "lock.fill", button: nil) {}
            default: EmptyView()
            }
            if bridge.conflict {
                BannerRow(text: "PasteLens is also expanding abbreviations. Turn it off there so they don't expand twice.",
                          symbol: "exclamationmark.triangle", button: "Turn Off in PasteLens") { PasteLensBridge.askPasteLensToStopExpanding() }
            }
        }
    }
}

struct BannerRow: View {
    let text: String
    let symbol: String
    let button: String?
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
            if let button { Button(button, action: action) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }
}

struct Sidebar: View {
    @Bindable var model: MainModel
    @State private var store = LibraryStore.shared
    @State private var confirmDelete: UUID?

    var conflicts: Int { Conflict.find(in: store.library, settings: Preferences.shared.matchSettings).count }

    var body: some View {
        List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) {
            Label("All Snippets", systemImage: "tray.full").tag(MainModel.Section.all)
                .badge(store.library.snippets.count)
            Section("Groups") {
                ForEach(store.library.sortedGroups) { group in
                    Label {
                        Text(group.name).foregroundStyle(group.enabled ? .primary : .secondary)
                    } icon: {
                        Image(systemName: group.enabled ? "folder" : "folder.badge.minus")
                    }
                    .badge(store.library.snippets(in: group.id).count)
                    .tag(MainModel.Section.group(group.id))
                    .contextMenu {
                        Button(group.enabled ? "Turn Off Group" : "Turn On Group") {
                            var g = group; g.enabled.toggle(); store.updateGroup(g)
                        }
                        Button("New Snippet in Group") { model.section = .group(group.id); MainWindow.shared.newSnippet() }
                        Divider()
                        Button("Delete Group…", role: .destructive) { confirmDelete = group.id }
                    }
                    .dropDestination(for: String.self) { ids, _ in
                        store.move(Set(ids.compactMap(UUID.init)), to: group.id)
                        return true
                    }
                }
            }
            Section("Assist") {
                Label("Suggestions", systemImage: "lightbulb").tag(MainModel.Section.suggestions)
                    .badge(store.tracker.suggestions.count)
                Label("Conflicts", systemImage: "exclamationmark.triangle").tag(MainModel.Section.conflicts)
                    .badge(conflicts)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { model.section = .group(store.addGroup(name: "New Group").id) } label: { Label("New Group", systemImage: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                Spacer()
            }
            .padding(8)
        }
        .confirmationDialog("Delete this group and its snippets?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete Group", role: .destructive) {
                if let id = confirmDelete { store.deleteGroup(id); model.section = .all }
            }
        } message: {
            Text("This can't be undone. With sync on, the group is deleted on your other Macs too.")
        }
    }
}

struct SnippetList: View {
    @Bindable var model: MainModel
    @State private var store = LibraryStore.shared

    var body: some View {
        let snippets = model.visibleSnippets(store.library)
        List(selection: $model.selection) {
            ForEach(snippets) { snippet in
                SnippetRow(snippet: snippet, trigger: store.library.trigger(for: snippet))
                    .tag(snippet.id)
                    .draggable(snippet.id.uuidString)
                    .contextMenu { menu(for: snippet) }
            }
        }
        .overlay {
            if snippets.isEmpty {
                ContentUnavailableView(model.search.isEmpty ? (model.section == .conflicts ? "No Conflicts" : "No Snippets") : "No Matches",
                                       systemImage: model.section == .conflicts ? "checkmark.circle" : "text.badge.plus")
            }
        }
        .onDeleteCommand { store.deleteSnippets(model.selection); model.selection = [] }
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort By", selection: $model.sort) { ForEach(MainModel.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Toggle("Ascending", isOn: $model.ascending)
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
            }
        }
    }

    @ViewBuilder private func menu(for snippet: Snippet) -> some View {
        let ids = model.selection.contains(snippet.id) ? model.selection : [snippet.id]
        Button("Insert Into Front App") { QuickSearchPanel.insertAfterHiding(snippet) }
        Menu("Move To") {
            ForEach(store.library.sortedGroups) { g in Button(g.name) { store.move(ids, to: g.id) } }
        }
        Menu("Copy To") {
            ForEach(store.library.sortedGroups) { g in Button(g.name) { store.duplicate(ids, to: g.id) } }
        }
        Divider()
        Button(ids.count > 1 ? "Delete \(ids.count) Snippets" : "Delete Snippet", role: .destructive) {
            store.deleteSnippets(ids)
            model.selection.subtract(ids)
        }
    }
}

struct SnippetRow: View {
    let snippet: Snippet
    let trigger: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(trigger.isEmpty ? "—" : trigger).font(.system(.body, design: .monospaced)).fontWeight(.medium)
                Spacer()
                if snippet.type != .plainText {
                    Text(snippet.type.title).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).background(.quaternary, in: Capsule())
                }
            }
            Text(snippet.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

struct SuggestionList: View {
    @State private var store = LibraryStore.shared
    @State private var prefs = Preferences.shared

    var body: some View {
        List {
            if !prefs.suggestions {
                Section {
                    Text("Turn on suggestions, and ExpansionLens offers a snippet for sentences you type again and again. It counts sentences without keeping them, until one comes up three times.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Turn On Suggestions") { prefs.suggestions = true }
                }
            }
            ForEach(store.tracker.suggestions.sorted { $0.lastSeen > $1.lastSeen }) { s in
                VStack(alignment: .leading, spacing: 6) {
                    Text(s.text).lineLimit(4)
                    HStack {
                        Text("Typed \(s.count) times").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Ignore") { store.removeSuggestion(s.hash) }
                        Button("Never Suggest") { store.rejectSuggestion(s.hash) }
                        Button("Create Snippet") { MainWindow.shared.createFromSuggestion(s.hash) }.buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            }
        }
        .overlay {
            if prefs.suggestions && store.tracker.suggestions.isEmpty {
                ContentUnavailableView("No Suggestions Yet", systemImage: "lightbulb", description: Text("They appear as you type."))
            }
        }
    }
}

// MARK: - Snippet editor

struct SnippetEditor: View {
    let id: UUID
    @Bindable var model: MainModel
    @State private var store = LibraryStore.shared
    @State private var previewScripts = false
    @State private var scriptOutput: String?
    @FocusState private var abbreviationFocused: Bool

    private var snippet: Binding<Snippet> {
        Binding(get: { store.snippet(id) ?? Snippet(groupID: UUID(), abbreviation: "", content: "") },
                set: { store.updateSnippet($0) })
    }

    var body: some View {
        let library = store.library
        let current = snippet.wrappedValue
        let conflicts = Conflict.find(in: library, settings: Preferences.shared.matchSettings).filter { $0.snippet == id || $0.other == id }
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Abbreviation") {
                        HStack(spacing: 4) {
                            if let prefix = library.group(current.groupID)?.prefix, !prefix.isEmpty {
                                Text(prefix).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary).help("The group's prefix")
                            }
                            TextField("Abbreviation", text: snippet.abbreviation)
                                .font(.system(.body, design: .monospaced))
                                .labelsHidden()
                                .focused($abbreviationFocused)
                        }
                    }
                    TextField("Label", text: snippet.label, prompt: Text("Helps you find it"))
                    HStack {
                        Picker("Content", selection: snippet.type) {
                            ForEach(ContentType.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Picker("Case", selection: snippet.caseMode) {
                            Text("Default").tag(CaseMode?.none)
                            ForEach(CaseMode.allCases, id: \.self) { Text($0.title).tag(CaseMode?.some($0)) }
                        }
                    }
                    Picker("Group", selection: snippet.groupID) {
                        ForEach(library.sortedGroups) { Text($0.name).tag($0.id) }
                    }
                    ForEach(conflicts, id: \.self) { c in
                        let otherID = c.snippet == id ? c.other : c.snippet
                        let other = library.snippets.first { $0.id == otherID }
                        Label("\(library.trigger(for: library.snippets.first { $0.id == c.snippet } ?? current)) \(c.kind.title) \(other.map(library.trigger(for:)) ?? "another snippet")",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.callout)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: conflicts.isEmpty ? 230 : 230 + CGFloat(conflicts.count) * 26)
            .scrollDisabled(true)

            HStack {
                MacroMenu { insert($0) }
                Spacer()
                if current.type.isScript {
                    Button("Run Preview") { runPreview() }.help("Runs the script now and shows what it returns")
                }
                Text("\(current.useCount) use\(current.useCount == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            Group {
                if current.type == .formattedText {
                    RichTextEditor(rtf: Binding(get: { snippet.wrappedValue.rtf }, set: { _ in }),
                                   plain: snippet.wrappedValue.content) { rtf, plain in
                        var s = snippet.wrappedValue
                        s.rtf = rtf
                        s.content = plain
                        snippet.wrappedValue = s
                    }
                } else {
                    TextEditor(text: snippet.content)
                        .font(current.type.isScript ? .system(.body, design: .monospaced) : .body)
                        .scrollContentBackground(.hidden)
                }
            }
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            .padding(.horizontal)
            .frame(minHeight: 140)

            GroupBox {
                ScrollView {
                    Text(previewText(current))
                        .font(current.type.isScript ? .system(.callout, design: .monospaced) : .callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 90)
            } label: {
                Text("Preview").font(.caption)
            }
            .padding()
        }
        .onAppear {
            if model.focusAbbreviation { abbreviationFocused = true; model.focusAbbreviation = false }
        }
    }

    private func previewText(_ snippet: Snippet) -> String {
        if snippet.type.isScript { return scriptOutput ?? "Click Run Preview to run the script." }
        let e = Renderer(library: store.library, clipboard: NSPasteboard.general.string(forType: .string) ?? "").render(snippet)
        let text = e.text
        return e.errors.isEmpty ? text : text + "\n\n⚠︎ " + e.errors.joined(separator: "\n⚠︎ ")
    }

    private func runPreview() {
        let library = store.library
        let current = snippet.wrappedValue
        let timeout = Preferences.shared.scriptTimeout
        scriptOutput = "Running…"
        Task.detached {
            let e = Renderer(library: library, runScript: ScriptRunner.runner(timeout: timeout)).render(current)
            let text = e.errors.isEmpty ? e.text : "⚠︎ " + e.errors.joined(separator: "\n")
            await MainActor.run { scriptOutput = text }
        }
    }

    private func insert(_ macro: String) {
        var s = snippet.wrappedValue
        if s.type == .formattedText {
            RichTextEditor.insertAtCursor(macro)
        } else {
            s.content += macro
            snippet.wrappedValue = s
        }
    }
}

/// The macros you can insert from the editor, grouped like the reference list in docs.
struct MacroMenu: View {
    let insert: (String) -> Void
    @State private var store = LibraryStore.shared

    var body: some View {
        Menu {
            Menu("Fill-ins") {
                Button("Single Line Field") { insert("%filltext:name=Field:default=%") }
                Button("Multi Line Field") { insert("%fillarea:name=Notes:default=:height=80%") }
                Button("Popup Menu") { insert("%fillpopup:name=Choice:default=First:Second:Third%") }
                Button("Date Picker") { insert("%filldatepicker:name=Date:format=MMMM d, yyyy%") }
                Button("Optional Section") { insert("%fillpart:name=Optional:default=yes%Optional text%fillpartend%") }
                Button("Conditional Section") {
                    insert("%fillconditional:name=Version:default=0%%fillbranch:name=One%First version%fillbranchend%%fillbranch:name=Two%Second version%fillbranchend%%fillconditionalend%")
                }
                Button("Show Fill-in Window at Top") { insert("%filltop%") }
            }
            Menu("Date") {
                Button("Year: 2001  (%Y)") { insert("%Y") }
                Button("Year: 01  (%y)") { insert("%y") }
                Button("Month: January  (%B)") { insert("%B") }
                Button("Month: Jan  (%b)") { insert("%b") }
                Button("Month: 01  (%m)") { insert("%m") }
                Button("Month: 1  (%1m)") { insert("%1m") }
                Button("Day: Monday  (%A)") { insert("%A") }
                Button("Day: Mon  (%a)") { insert("%a") }
                Button("Day: 01  (%d)") { insert("%d") }
                Button("Day: 1  (%e)") { insert("%e") }
                Button("Day of Year  (%j)") { insert("%j") }
                Button("Unicode Date Format…") { insert("%date:yyyy-MM-dd%") }
            }
            Menu("Time") {
                Button("Hour: 01 (00–23)  (%H)") { insert("%H") }
                Button("Hour: 1 (0–23)  (%1H)") { insert("%1H") }
                Button("Hour: 01 (01–12)  (%I)") { insert("%I") }
                Button("Hour: 1 (1–12)  (%1I)") { insert("%1I") }
                Button("Minute: 01  (%M)") { insert("%M") }
                Button("Second: 01  (%S)") { insert("%S") }
                Button("AM/PM  (%p)") { insert("%p") }
                Button("Time Zone  (%Z)") { insert("%Z") }
            }
            Menu("Date & Time Math") {
                ForEach([("Years", "Y"), ("Months", "m"), ("Days", "D"), ("Hours", "h"), ("Minutes", "M"), ("Seconds", "s")], id: \.1) { name, unit in
                    Button("Add 1 \(name.dropLast())") { insert("%@+1\(unit)") }
                    Button("Subtract 1 \(name.dropLast())") { insert("%@-1\(unit)") }
                }
            }
            Menu("Cursor") {
                Button("Position Cursor Here  (%|)") { insert("%|") }
                Button("Select To Here  (%\\)") { insert("%\\") }
            }
            Menu("Keys") {
                Button("Return") { insert("%key:return%") }
                Button("Enter") { insert("%key:enter%") }
                Button("Tab") { insert("%key:tab%") }
                Button("Escape") { insert("%key:esc%") }
                Button("Left Arrow") { insert("%<") }
                Button("Right Arrow") { insert("%>") }
                Button("Up Arrow") { insert("%^") }
                Button("Down Arrow") { insert("%v") }
                Button("Pause 500 ms") { insert("%delay:500%") }
            }
            Menu("When to Expand") {
                Button("Keep the Delimiter  (%+)") { insert("%+") }
                Button("Remove the Delimiter  (%-)") { insert("%-") }
                Button("Expand Immediately  (%!)") { insert("%!") }
            }
            Button("Clipboard  (%clipboard)") { insert("%clipboard") }
            Menu("Another Snippet") {
                ForEach(store.library.snippets.filter { !$0.abbreviation.isEmpty }.sorted { store.library.trigger(for: $0) < store.library.trigger(for: $1) }.prefix(200)) { s in
                    Button("\(store.library.trigger(for: s))  —  \(s.displayName)") { insert("%snippet:\(store.library.trigger(for: s))%") }
                }
            }
            Button("Percent Sign  (%%)") { insert("%%") }
        } label: {
            Label("Insert Macro", systemImage: "wand.and.stars")
        }
        .fixedSize()
    }
}

/// A formatted-text editor. It reports RTF and the plain text after each change.
struct RichTextEditor: NSViewRepresentable {
    @Binding var rtf: Data?
    let plain: String
    let changed: (Data?, String) -> Void

    @MainActor private static weak var current: NSTextView?

    static func insertAtCursor(_ text: String) {
        current?.insertText(text, replacementRange: current?.selectedRange() ?? NSRange(location: 0, length: 0))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isRichText = true
        view.allowsUndo = true
        view.usesFontPanel = true
        view.importsGraphics = false
        view.drawsBackground = false
        view.delegate = context.coordinator
        if let rtf, let text = try? NSAttributedString(data: rtf, options: [:], documentAttributes: nil) {
            view.textStorage?.setAttributedString(text)
        } else {
            view.string = plain
            view.font = .systemFont(ofSize: NSFont.systemFontSize)
        }
        Self.current = view
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        init(parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, let storage = view.textStorage else { return }
            let rtf = try? storage.data(from: NSRange(location: 0, length: storage.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            MainActor.assumeIsolated { parent.changed(rtf, storage.string) }
        }

        func textDidBeginEditing(_ notification: Notification) {
            MainActor.assumeIsolated { RichTextEditor.current = notification.object as? NSTextView }
        }
    }
}

// MARK: - Group editor

struct GroupEditor: View {
    let id: UUID
    @State private var store = LibraryStore.shared

    private var group: Binding<SnippetGroup> {
        Binding(get: { store.library.group(id) ?? SnippetGroup(name: "") }, set: { store.updateGroup($0) })
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: group.name)
                Toggle("Expand snippets in this group", isOn: group.enabled)
                TextField("Prefix", text: group.prefix, prompt: Text("None"))
                    .font(.system(.body, design: .monospaced))
                Text("A prefix goes before every abbreviation in the group, so ; with sig means you type ;sig.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Expand after", selection: group.expandAfter) {
                    Text("Default (in Settings)").tag(ExpandAfter?.none)
                    ForEach(ExpandAfter.allCases, id: \.self) { Text($0.title).tag(ExpandAfter?.some($0)) }
                }
            }
            Section("Expand in") {
                AppScopeEditor(scope: group.scope)
            }
            Section("Notes") {
                TextEditor(text: group.notes).frame(minHeight: 80)
            }
            Section {
                LabeledContent("\(store.library.snippets(in: id).count) snippets") {
                    Button("New Snippet") { MainWindow.shared.newSnippet() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// All apps / all except… / only… with a list of apps.
struct AppScopeEditor: View {
    @Binding var scope: AppScope

    var body: some View {
        Picker("Applications", selection: $scope.mode) {
            ForEach(AppScope.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        if scope.mode != .all {
            ForEach(scope.bundleIDs, id: \.self) { id in
                HStack {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                        Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                    } else {
                        Text(id)
                    }
                    Spacer()
                    Button { scope.bundleIDs.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            Button("Add Application…") { addApp() }
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !scope.bundleIDs.contains(id) { scope.bundleIDs.append(id) }
        }
    }
}
