import AppKit
import Carbon.HIToolbox
import ExpansionLensKit
import Observation

/// Watches what you type everywhere and expands abbreviations.
///
/// A keyboard event tap (needs Accessibility) sees each key before the app in front does. The
/// typed characters go into a short buffer; when a key completes an abbreviation, that key is
/// held back (so a delimiter like Return never reaches the app), the abbreviation is erased
/// and the snippet goes in its place. Clicks, arrow keys, ⌘/⌃ shortcuts and switching apps
/// clear the buffer, since the cursor may have moved.
@Observable
@MainActor
final class ExpansionEngine {
    static let shared = ExpansionEngine()

    enum State: Equatable {
        case off
        case needsAccessibility
        case running
        /// Another app turned on Secure Input (a password field), which hides typing from every app.
        case blockedBySecureInput(String?)
    }

    private(set) var state: State = .off

    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var buffer = ""
    @ObservationIgnored private var matcher = Matcher(triggers: [])
    @ObservationIgnored private var matcherBundle: String?? = .none
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var secureTimer: Timer?
    @ObservationIgnored private var observersInstalled = false
    /// Snippets whose content changes when they expand (`%+`, `%-`, `%!`).
    @ObservationIgnored private var modeOverrides: [UUID: ExpansionMode] = [:]
    /// Plain snippets' text, for "you could have typed …".
    @ObservationIgnored private var tutorTexts: [String: UUID] = [:]

    /// Marks events ExpansionLens posts itself, so the tap lets them through untouched.
    static let syntheticMarker: Int64 = 0x454C_454E // "ELEN"

    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Lifecycle

    func start() {
        installObserversOnce()
        libraryChanged()
        settingsChanged()
        secureTimer?.invalidate()
        secureTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { ExpansionEngine.shared.checkSecureInput() }
        }
    }

    func settingsChanged() {
        matcherBundle = .none
        guard Preferences.shared.enabled else { stopTap(); state = .off; return }
        guard Self.trusted else {
            stopTap()
            state = .needsAccessibility
            waitForPermission()
            return
        }
        startTap()
        checkSecureInput()
    }

    func libraryChanged() {
        matcherBundle = .none
        var overrides: [UUID: ExpansionMode] = [:]
        var tutor: [String: UUID] = [:]
        for snippet in LibraryStore.shared.library.snippets where !snippet.type.isScript {
            if snippet.content.contains("%+") || snippet.content.contains("%-") || snippet.content.contains("%!") {
                for node in MacroParser.parse(snippet.content) { if case .modeOverride(let m) = node { overrides[snippet.id] = m } }
            }
            if !snippet.content.contains("%"), snippet.content.count >= 12 {
                tutor[snippet.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = snippet.id
            }
        }
        modeOverrides = overrides
        tutorTexts = tutor
        HotKeyCenter.shared.apply()
    }

    func toggle() {
        Preferences.shared.enabled.toggle()
    }

    private func waitForPermission() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard ExpansionEngine.trusted else { return }
                timer.invalidate()
                ExpansionEngine.shared.permissionTimer = nil
                ExpansionEngine.shared.settingsChanged()
            }
        }
    }

    private func startTap() {
        guard tap == nil else { state = .running; return }
        let mask = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: engineTapCallback, userInfo: nil) else {
            state = .needsAccessibility
            waitForPermission()
            return
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        state = .running
    }

    private func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        buffer = ""
    }

    private func installObserversOnce() {
        guard !observersInstalled else { return }
        observersInstalled = true
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                ExpansionEngine.shared.reset()
                ExpansionEngine.shared.matcherBundle = .none
            }
        }
    }

    func reset() { buffer = "" }

    private func checkSecureInput() {
        guard tap != nil else { return }
        if IsSecureEventInputEnabled() {
            // The process holding Secure Input isn't public; the front app is almost always it.
            let name = NSWorkspace.shared.frontmostApplication?.localizedName
            if state != .blockedBySecureInput(name) { state = .blockedBySecureInput(name) }
        } else if state != .running {
            state = .running
        }
    }

    // MARK: Keys

    private var frontBundleID: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    private func currentMatcher() -> Matcher {
        let bundle = frontBundleID
        if case .some(let cached) = matcherBundle, cached == bundle { return matcher }
        matcher = Matcher(triggers: Matcher.triggers(for: LibraryStore.shared.library, settings: Preferences.shared.matchSettings,
                                                     bundleID: bundle, modeOverrides: modeOverrides))
        matcherBundle = .some(bundle)
        return matcher
    }

    /// Returns false to hold the event back from the app.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return true }
        guard type == .keyDown else { buffer = ""; return true }
        // Our own windows (the editor, Quick Search) type normally; so does everything while an expansion is going in.
        if NSApp.isActive || Inserter.shared.busy || IsSecureEventInputEnabled() { buffer = ""; return true }
        let prefs = Preferences.shared
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { buffer = ""; return true }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch code {
        case kVK_Delete:
            if !buffer.isEmpty { buffer.removeLast() }
            return true
        case kVK_Escape, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End,
             kVK_PageUp, kVK_PageDown, kVK_ForwardDelete, kVK_Help:
            buffer = ""
            return true
        default: break
        }
        let key: Character
        switch code {
        case kVK_Return, kVK_ANSI_KeypadEnter: key = "\n"
        case kVK_Tab: key = "\t"
        default:
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
            guard length > 0, let c = String(utf16CodeUnits: chars, count: length).first,
                  !c.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) else { return true }
            key = c
        }
        let bundle = frontBundleID
        guard prefs.scope.allows(bundle) else { buffer = ""; return true }

        if let match = currentMatcher().match(typed: buffer, key: key, delimiters: Set(prefs.delimiters)) {
            buffer = ""
            Inserter.shared.expand(match, heldKey: key)
            return false
        }

        let delimiter = prefs.delimiters.contains(key) || key.isWhitespace
        if delimiter, prefs.capSentences || prefs.capDoubleCaps, prefs.capScope.allows(bundle) {
            let word = String(buffer.reversed().prefix(while: { !$0.isWhitespace && !prefs.delimiters.contains($0) }).reversed())
            let before = String(buffer.dropLast(word.count))
            if let fix = AutoCapitalizer.fix(word: word, before: before, sentences: prefs.capSentences, doubleCaps: prefs.capDoubleCaps,
                                             contraction: Set(prefs.capContraction)) {
                buffer = before + fix.replacement + String(key)
                Inserter.shared.replace(erase: fix.eraseCount, with: fix.replacement, heldKey: key)
                return false
            }
        }

        buffer.append(key)
        if buffer.count > 400 { buffer = String(buffer.suffix(300)) }
        if ".!?\n".contains(key) { sentenceEnded(bundle: bundle) }
        return true
    }

    /// Feeds the sentence just finished to suggestions and the tutor.
    private func sentenceEnded(bundle: String?) {
        let prefs = Preferences.shared
        guard prefs.suggestions || prefs.tutor else { return }
        var body = buffer.dropLast()
        if let start = body.lastIndex(where: { ".!?\n".contains($0) }) { body = body[body.index(after: start)...] }
        let sentence = String(body).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return }
        if prefs.tutor, let id = tutorTexts[sentence.lowercased()] ?? tutorTexts[(sentence + String(buffer.last!)).lowercased()],
           let snippet = LibraryStore.shared.snippet(id) {
            Notifier.tutor(abbreviation: LibraryStore.shared.library.trigger(for: snippet), label: snippet.displayName)
        }
        if prefs.suggestions, prefs.suggestScope.allows(bundle), let made = LibraryStore.shared.recordSentence(sentence + String(buffer.last!)) {
            if prefs.suggestionsNotify { Notifier.suggestion(made) }
        }
    }
}

private func engineTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let pass = MainActor.assumeIsolated { ExpansionEngine.shared.handle(type, event) }
    return pass ? Unmanaged.passUnretained(event) : nil
}
