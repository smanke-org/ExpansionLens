import AppKit
import ExpansionLensKit
import SwiftUI

/// Asks for a snippet's fill-ins, with a live preview, then hands focus back to the app it came from.
@MainActor
enum FillInWindow {
    private static var panel: NSPanel?
    private static var completion: ((FieldValues?) -> Void)?
    private static var previous: NSRunningApplication?

    static var isOpen: Bool { panel != nil }

    static func show(snippet: Snippet, items: [FieldCollector.Item], atTop: Bool, completion: @escaping (FieldValues?) -> Void) {
        close(with: nil)
        previous = NSWorkspace.shared.frontmostApplication
        Self.completion = completion
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300), styleMask: [.titled, .closable, .resizable],
                            backing: .buffered, defer: false)
        panel.title = snippet.displayName
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let view = FillInView(snippet: snippet, items: items) { values in close(with: values) }
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        let size = hosting.fittingSize
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        panel.setContentSize(NSSize(width: max(size.width, 420), height: min(size.height, screen.height - 80)))
        if atTop {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.midX - panel.frame.width / 2, y: screen.maxY - 20))
        } else {
            panel.center()
        }
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { if Self.panel != nil { close(with: nil) } }
        }
    }

    private static func close(with values: FieldValues?) {
        guard let panel else { return }
        Self.panel = nil
        panel.orderOut(nil)
        let done = completion
        completion = nil
        previous?.activate()
        previous = nil
        done?(values)
    }
}

struct FillInView: View {
    let snippet: Snippet
    let items: [FieldCollector.Item]
    let done: (FieldValues?) -> Void
    @State private var values = FieldValues()
    @State private var dates: [String: Date] = [:]
    @FocusState private var focused: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(items, id: \.name) { item in row(item) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            GroupBox("Preview") {
                ScrollView {
                    Text(preview.isEmpty ? " " : preview)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 50, maxHeight: 160)
            }
            .padding(.horizontal)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("OK") { done(finalValues) }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 420)
        .onAppear {
            focused = items.first(where: { if case .field = $0 { return true }; return false })?.name
        }
    }

    @ViewBuilder private func row(_ item: FieldCollector.Item) -> some View {
        switch item {
        case .field(let field):
            switch field.kind {
            case .text:
                TextField(field.name, text: text(field))
                    .focused($focused, equals: field.name)
            case .area:
                LabeledContent(field.name) {
                    TextEditor(text: text(field))
                        .font(.body)
                        .frame(minHeight: CGFloat(field.height.map { max(min($0, 400), 40) } ?? 80))
                        .focused($focused, equals: field.name)
                }
            case .popup:
                Picker(field.name, selection: text(field)) {
                    ForEach(Array(field.options.enumerated()), id: \.offset) { Text($0.element.isEmpty ? "(empty)" : $0.element).tag($0.element) }
                }
            case .date:
                DatePicker(field.name, selection: Binding(
                    get: { dates[field.name] ?? Date() },
                    set: { dates[field.name] = $0; values.text[field.name] = Renderer(library: Library()).format($0, pattern: field.format ?? "yyyy-MM-dd") }
                ), displayedComponents: [.date])
            }
        case .optional(let name, let include, let preview):
            Toggle(isOn: Binding(get: { values.optionals[name] ?? include }, set: { values.optionals[name] = $0 })) {
                Text(name)
                if !preview.isEmpty { Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
        case .conditional(let name, let defaultBranch, let names):
            Picker(name, selection: Binding(get: { values.branches[name] ?? defaultBranch }, set: { values.branches[name] = $0 })) {
                ForEach(Array(names.enumerated()), id: \.offset) { Text($0.element).tag($0.offset) }
            }
        }
    }

    private func text(_ field: FillField) -> Binding<String> {
        Binding(get: { values.text[field.name] ?? Renderer(library: LibraryStore.shared.library).value(of: field) },
                set: { values.text[field.name] = $0 })
    }

    /// Fields left untouched keep their defaults.
    private var finalValues: FieldValues { values }

    private var preview: String {
        if snippet.type.isScript { return "The script runs when you click OK." }
        return Renderer(library: LibraryStore.shared.library, values: values).render(snippet).text
    }
}
