import AppKit
import Carbon.HIToolbox
import ExpansionLensKit

/// Puts a snippet into the app in front: asks for fill-ins, erases the abbreviation, pastes
/// the text (and presses any keys the snippet asks for), places the cursor, then puts the
/// clipboard back.
@MainActor
final class Inserter {
    static let shared = Inserter()

    /// True from the moment an expansion starts until the clipboard is back.
    private(set) var busy = false

    // MARK: Entry points

    /// A typed abbreviation completed `match`; `heldKey` was kept from the app.
    func expand(_ match: Match, heldKey: Character) {
        guard let snippet = LibraryStore.shared.snippet(match.snippetID) else { return }
        insert(snippet, erase: match.eraseCount, typed: match.typed, abbreviation: match.abbreviation,
               trailing: match.delimiter, cancelKey: heldKey)
    }

    /// Inserts a snippet chosen in Quick Search or the menu, with nothing to erase.
    func insert(_ snippet: Snippet) {
        insert(snippet, erase: 0, typed: nil, abbreviation: nil, trailing: nil, cancelKey: nil)
    }

    /// Auto-capitalization: replaces the word just typed, then types the held-back key.
    func replace(erase count: Int, with text: String, heldKey: Character) {
        var expansion = Expansion()
        expansion.pieces = [.text(text, source: nil, anchor: nil)]
        perform(expansion, snippet: nil, erase: count, trailing: heldKey)
    }

    // MARK: Expanding

    private func insert(_ snippet: Snippet, erase: Int, typed: String?, abbreviation: String?, trailing: Character?, cancelKey: Character?) {
        let library = LibraryStore.shared.library
        let items = FieldCollector.items(for: snippet, in: library)
        let go: (FieldValues) -> Void = { values in
            self.render(snippet, values: values) { expansion in
                var expansion = expansion
                if let typed, let abbreviation, (snippet.caseMode ?? Preferences.shared.caseMode) == .adaptToCase {
                    expansion.adaptCase(typed: typed, abbreviation: abbreviation)
                }
                self.perform(expansion, snippet: snippet, erase: erase, trailing: trailing)
            }
        }
        guard !items.isEmpty else { go(FieldValues()); return }
        let fillTop = snippet.content.contains("%filltop%")
        busy = true
        FillInWindow.show(snippet: snippet, items: items, atTop: fillTop) { values in
            self.busy = false
            guard let values else {
                // Cancelled: the abbreviation stays, and the key that was held back goes through.
                if let cancelKey { self.type(String(cancelKey)) }
                return
            }
            // Give the app a moment to take focus back before typing into it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { go(values) }
        }
    }

    /// Renders off the main thread, since scripts can take a while.
    private func render(_ snippet: Snippet, values: FieldValues, done: @escaping (Expansion) -> Void) {
        let library = LibraryStore.shared.library
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        let runner: ScriptRunning? = Preferences.shared.scriptsAllowed ? ScriptRunner.runner(timeout: Preferences.shared.scriptTimeout) : nil
        busy = true
        Task.detached {
            let expansion = Renderer(library: library, clipboard: clipboard, values: values, runScript: runner).render(snippet)
            await MainActor.run { done(expansion) }
        }
    }

    // MARK: Typing it in

    private func perform(_ expansion: Expansion, snippet: Snippet?, erase: Int, trailing: Character?) {
        busy = true
        if !expansion.errors.isEmpty { Notifier.problem(expansion.errors.joined(separator: "\n"), snippet: snippet) }
        var pieces = expansion.pieces
        if let trailing {
            switch trailing {
            case "\n": pieces.append(.key(.return))
            case "\t": pieces.append(.key(.tab))
            default: pieces.append(.text(String(trailing), source: nil, anchor: nil))
            }
        }
        let rich = snippet.flatMap { $0.type == .formattedText ? $0.rtf : nil }.flatMap { try? NSAttributedString(data: $0, options: [:], documentAttributes: nil) }
        let saved = Preferences.shared.restoreClipboard ? ClipboardSnapshot.take() : nil
        Task { @MainActor in
            for _ in 0..<erase { postKey(CGKeyCode(kVK_Delete)) }
            if erase > 0 { try? await Task.sleep(for: .milliseconds(30)) }
            var chunk: [Expansion.Piece] = []
            var afterCursor = 0
            var selection = 0
            var sawCursor = false
            var sawSelect = false
            var keysAfterCursor = false
            var pasted = false
            var lastWrite = 0
            @MainActor func flush() async {
                guard !chunk.isEmpty else { return }
                let text = chunk.reduce(into: "") { if case .text(let s, _, _) = $1 { $0 += s } }
                guard !text.isEmpty else { chunk = []; return }
                write(chunk, rich: rich)
                lastWrite = NSPasteboard.general.changeCount
                postKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
                pasted = true
                chunk = []
                // Long text takes a moment to land; the next step waits for it.
                try? await Task.sleep(for: .milliseconds(min(80 + text.count / 50, 400)))
            }
            for piece in pieces {
                switch piece {
                case .text(let s, _, _):
                    chunk.append(piece)
                    if sawCursor && !sawSelect { afterCursor += s.count; selection += s.count }
                    else if sawSelect { afterCursor += s.count }
                case .key(let key):
                    await flush()
                    press(key)
                    if sawCursor { keysAfterCursor = true }
                    try? await Task.sleep(for: .milliseconds(30))
                case .delay(let ms):
                    await flush()
                    try? await Task.sleep(for: .milliseconds(ms))
                case .cursor:
                    if !sawCursor { sawCursor = true; afterCursor = 0; selection = 0 }
                case .selectEnd:
                    if sawCursor && !sawSelect { sawSelect = true; afterCursor = 0 }
                }
            }
            await flush()
            if sawCursor && !keysAfterCursor {
                let back = sawSelect ? afterCursor : selection
                for _ in 0..<back { postKey(CGKeyCode(kVK_LeftArrow)) }
                if sawSelect { for _ in 0..<selection { postKey(CGKeyCode(kVK_LeftArrow), flags: .maskShift) } }
            }
            if let snippet {
                LibraryStore.shared.recordUse(snippet.id)
                if Preferences.shared.sound { NSSound(named: "Pop")?.play() }
            }
            if pasted, let saved {
                try? await Task.sleep(for: .seconds(max(Preferences.shared.restoreDelay, 0.2)))
                saved.restore(ifStill: lastWrite)
            }
            busy = false
            ExpansionEngine.shared.reset()
        }
    }

    /// Types short text by posting it as key events (for a held-back key or a cancelled fill-in).
    private func type(_ text: String) {
        if text == "\n" { press(.return); return }
        if text == "\t" { press(.tab); return }
        let units = Array(text.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: Self.source, virtualKey: 0, keyDown: down) else { continue }
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.setIntegerValueField(.eventSourceUserData, value: ExpansionEngine.syntheticMarker)
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }

    /// Puts the chunk on the clipboard: plain text, plus RTF for formatted snippets.
    private func write(_ chunk: [Expansion.Piece], rich: NSAttributedString?) {
        let board = NSPasteboard.general
        board.clearContents()
        var plain = ""
        let out = NSMutableAttributedString()
        for piece in chunk {
            guard case .text(let s, let source, let anchor) = piece else { continue }
            plain += s
            guard let rich else { continue }
            if let source, source.location + source.length <= rich.length {
                out.append(rich.attributedSubstring(from: source))
            } else {
                let at = min(max(anchor ?? source?.location ?? 0, 0), max(rich.length - 1, 0))
                let attrs = rich.length > 0 ? rich.attributes(at: at, effectiveRange: nil) : [:]
                out.append(NSAttributedString(string: s, attributes: attrs))
            }
        }
        if rich != nil, out.length > 0,
           let rtf = try? out.data(from: NSRange(location: 0, length: out.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            board.declareTypes([.rtf, .string], owner: nil)
            board.setData(rtf, forType: .rtf)
        }
        board.setString(plain, forType: .string)
        // Clipboard managers (PasteLens among them) skip content marked as transient.
        board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }

    private func press(_ key: KeyMacro) {
        let code: Int = switch key {
        case .enter: kVK_ANSI_KeypadEnter
        case .return: kVK_Return
        case .tab: kVK_Tab
        case .escape: kVK_Escape
        case .left: kVK_LeftArrow
        case .right: kVK_RightArrow
        case .up: kVK_UpArrow
        case .down: kVK_DownArrow
        }
        postKey(CGKeyCode(code))
    }

    /// A private event source, so modifier keys still held from typing the abbreviation don't leak in.
    private static let source = CGEventSource(stateID: .privateState)

    private func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: Self.source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: ExpansionEngine.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}

/// Everything on the clipboard, every type of every item, to put back after pasting.
struct ClipboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func take() -> ClipboardSnapshot {
        let board = NSPasteboard.general
        let items = (board.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { types[type] = data } }
            return types
        }
        return ClipboardSnapshot(items: items)
    }

    /// Puts the old contents back, unless something was copied after the expansion's last
    /// write (`changeCount`), in which case the newer copy wins.
    func restore(ifStill changeCount: Int) {
        let board = NSPasteboard.general
        guard board.changeCount == changeCount else { return }
        board.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        board.writeObjects(restored)
    }
}
