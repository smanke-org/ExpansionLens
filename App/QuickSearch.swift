import AppKit
import ExpansionLensKit
import SwiftUI

/// A floating search over every snippet. Return inserts the chosen one into the app you were
/// typing in, which stays in front the whole time (the panel never activates ExpansionLens).
@MainActor
final class QuickSearchPanel {
    static let shared = QuickSearchPanel()
    private var panel: NSPanel?
    let model = QuickSearchModel()

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        if panel == nil {
            let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                                 styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: QuickSearchView(model: model))
            self.panel = panel
        }
        model.query = ""
        model.selected = 0
        AppActivity.touch()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame, let panel {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - frame.height * 0.22 - panel.frame.height))
        }
        panel?.makeKeyAndOrderFront(nil)
        model.focusToken += 1
    }

    func hide() { panel?.orderOut(nil) }

    func choose(_ snippet: Snippet) {
        hide()
        // Let the app underneath take keyboard focus back before typing into it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Inserter.shared.insert(snippet) }
    }

    /// From the main window: step out of the way, then insert into whatever's in front.
    static func insertAfterHiding(_ snippet: Snippet) {
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { Inserter.shared.insert(snippet) }
    }
}

/// A panel that can take typing without activating the app.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

@Observable
@MainActor
final class QuickSearchModel {
    var query = "" { didSet { selected = 0 } }
    var selected = 0
    var focusToken = 0

    var results: [Snippet] {
        let library = LibraryStore.shared.library
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let enabled = Set(library.groups.filter(\.enabled).map(\.id))
        let all = library.snippets.filter { enabled.contains($0.groupID) }
        guard !q.isEmpty else {
            return all.sorted { ($0.lastUsed ?? .distantPast, $0.useCount) > ($1.lastUsed ?? .distantPast, $1.useCount) }.prefix(50).map { $0 }
        }
        // Abbreviation matches first, then labels, then content.
        func score(_ s: Snippet) -> Int? {
            let trigger = library.trigger(for: s).lowercased()
            if trigger == q { return 0 }
            if trigger.hasPrefix(q) { return 1 }
            if s.label.lowercased().hasPrefix(q) { return 2 }
            if trigger.contains(q) || s.label.lowercased().contains(q) { return 3 }
            if s.content.lowercased().contains(q) { return 4 }
            return nil
        }
        var scored: [(snippet: Snippet, score: Int)] = []
        for s in all { if let score = score(s) { scored.append((s, score)) } }
        scored.sort { a, b in a.score == b.score ? a.snippet.useCount > b.snippet.useCount : a.score < b.score }
        return scored.prefix(50).map(\.snippet)
    }
}

struct QuickSearchView: View {
    @Bindable var model: QuickSearchModel
    @FocusState private var focused: Bool

    var body: some View {
        let results = model.results
        let library = LibraryStore.shared.library
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search snippets", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { if results.indices.contains(model.selected) { QuickSearchPanel.shared.choose(results[model.selected]) } }
                    .onKeyPress(.downArrow) { model.selected = min(model.selected + 1, max(results.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { model.selected = max(model.selected - 1, 0); return .handled }
                    .onKeyPress(.escape) { QuickSearchPanel.shared.hide(); return .handled }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, snippet in
                            HStack {
                                Text(library.trigger(for: snippet)).font(.system(.body, design: .monospaced)).frame(width: 130, alignment: .leading).lineLimit(1)
                                VStack(alignment: .leading) {
                                    Text(snippet.displayName).lineLimit(1)
                                    if !snippet.label.isEmpty, !snippet.type.isScript {
                                        Text(snippet.content.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(index == model.selected ? Color.accentColor.opacity(0.25) : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { QuickSearchPanel.shared.choose(snippet) }
                            .onTapGesture { model.selected = index }
                            .id(index)
                        }
                    }
                }
                .onChange(of: model.selected) { proxy.scrollTo(model.selected) }
            }
            if results.isEmpty {
                Text("No snippets match.").foregroundStyle(.secondary).padding().frame(maxHeight: .infinity)
            }
            Divider()
            Text("Return inserts  ·  ↑↓ choose  ·  Esc closes").font(.caption).foregroundStyle(.secondary).padding(6)
        }
        .frame(width: 560, height: 380)
        .background(.regularMaterial)
        .onChange(of: model.focusToken) { focused = true }
        .onAppear { focused = true }
    }
}
