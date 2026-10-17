import AppKit
import ExpansionLensKit
import Observation

/// The global shortcuts ExpansionLens offers.
enum HotKeyAction: String, CaseIterable {
    case toggleExpansion, quickSearch, openMain, newSnippet, newFromClipboard, editLast

    var title: String {
        switch self {
        case .toggleExpansion: "Turn expansion on or off"
        case .quickSearch: "Quick Search"
        case .openMain: "Open ExpansionLens"
        case .newSnippet: "New snippet"
        case .newFromClipboard: "New snippet from clipboard"
        case .editLast: "Edit last expanded snippet"
        }
    }
}

/// Every setting, backed by UserDefaults. Settings in `syncedKeys` follow you to your other
/// Macs (encrypted, like everything else ExpansionLens syncs).
@Observable
@MainActor
final class Preferences {
    static let shared = Preferences()
    private let defaults = AppDefaults.store
    /// While true, changes come from another Mac and aren't stamped as local edits.
    @ObservationIgnored var applyingRemote = false
    /// False while the first values are read, when the engine (which reads these) can't be told yet.
    @ObservationIgnored private var loaded = false

    enum Key {
        static let enabled = "expansion.enabled"
        static let mode = "expansion.mode"
        static let caseMode = "expansion.caseMode"
        static let expandAfter = "expansion.expandAfter"
        static let delimiters = "expansion.delimiters"
        static let sound = "expansion.sound"
        static let restoreClipboard = "expansion.restoreClipboard"
        static let restoreDelay = "expansion.restoreDelay"
        static let scope = "expansion.scope"
        static let scripts = "scripts.allowed"
        static let scriptTimeout = "scripts.timeout"
        static let capSentences = "autocap.sentences"
        static let capDoubleCaps = "autocap.doubleCaps"
        static let capScope = "autocap.scope"
        static let capContraction = "autocap.contraction"
        static let suggestions = "suggestions.enabled"
        static let suggestionsNotify = "suggestions.notify"
        static let tutor = "suggestions.tutor"
        static let suggestScope = "suggestions.scope"
        static let newType = "editor.newType"
        static let warnPasteLens = "pastelens.warn"
        static let hotKeyPrefix = "hotkey."
    }

    /// Settings that sync between Macs. Whether expansion is on, sync's own switches and the
    /// Dock and menu bar choices stay per Mac.
    static let syncedKeys: [String] = [
        Key.mode, Key.caseMode, Key.expandAfter, Key.delimiters, Key.sound, Key.restoreClipboard, Key.restoreDelay, Key.scope,
        Key.scripts, Key.scriptTimeout, Key.capSentences, Key.capDoubleCaps, Key.capScope, Key.capContraction,
        Key.suggestions, Key.suggestionsNotify, Key.tutor, Key.suggestScope, Key.newType,
        "updatePolicy", UpdateInterval.valueKey, UpdateInterval.unitKey,
    ] + HotKeyAction.allCases.map { Key.hotKeyPrefix + $0.rawValue }

    // MARK: Expansion

    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Key.enabled)
            if loaded { ExpansionEngine.shared.settingsChanged() }
        }
    }
    var mode: ExpansionMode { didSet { save(Key.mode, mode.rawValue) } }
    var caseMode: CaseMode { didSet { save(Key.caseMode, caseMode.rawValue) } }
    var expandAfter: ExpandAfter { didSet { save(Key.expandAfter, expandAfter.rawValue) } }
    /// Delimiter characters; "\t", "\n" and " " stand for Tab, Return and Space.
    var delimiters: String { didSet { save(Key.delimiters, delimiters) } }
    var sound: Bool { didSet { save(Key.sound, sound) } }
    var restoreClipboard: Bool { didSet { save(Key.restoreClipboard, restoreClipboard) } }
    /// Seconds before the clipboard is put back after an expansion pastes.
    var restoreDelay: Double { didSet { save(Key.restoreDelay, restoreDelay) } }
    var scope: AppScope { didSet { saveCoded(Key.scope, scope) } }

    // MARK: Scripts

    var scriptsAllowed: Bool { didSet { save(Key.scripts, scriptsAllowed) } }
    var scriptTimeout: Double { didSet { save(Key.scriptTimeout, scriptTimeout) } }

    // MARK: Capitalization

    var capSentences: Bool { didSet { save(Key.capSentences, capSentences) } }
    var capDoubleCaps: Bool { didSet { save(Key.capDoubleCaps, capDoubleCaps) } }
    var capScope: AppScope { didSet { saveCoded(Key.capScope, capScope) } }
    var capContraction: String { didSet { save(Key.capContraction, capContraction) } }

    // MARK: Suggestions

    var suggestions: Bool { didSet { save(Key.suggestions, suggestions) } }
    var suggestionsNotify: Bool { didSet { save(Key.suggestionsNotify, suggestionsNotify) } }
    var tutor: Bool { didSet { save(Key.tutor, tutor) } }
    var suggestScope: AppScope { didSet { saveCoded(Key.suggestScope, suggestScope) } }

    // MARK: Other

    var newType: ContentType { didSet { save(Key.newType, newType.rawValue) } }
    var warnPasteLens: Bool { didSet { defaults.set(warnPasteLens, forKey: Key.warnPasteLens) } }

    var hotKeys: [HotKeyAction: HotKey] = [:]

    func hotKey(_ action: HotKeyAction) -> HotKey? { hotKeys[action] }

    func setHotKey(_ key: HotKey?, for action: HotKeyAction) {
        hotKeys[action] = key
        let k = Key.hotKeyPrefix + action.rawValue
        if let key, let data = try? JSONEncoder().encode(key) { defaults.set(data, forKey: k) } else { defaults.set(Data(), forKey: k) }
        stamp(k)
    }

    static let defaultDelimiters = String(MatchSettings.defaultDelimiters.filter { $0 != "\r" }.sorted())

    /// Default shortcuts: Quick Search on ⌃⌥Space, clear of Spotlight's ⌘Space.
    static let defaultHotKeys: [HotKeyAction: HotKey] = [
        .quickSearch: HotKey(keyCode: 49, modifiers: UInt32(0x1000 | 0x0800), display: "⌃⌥Space"),
    ]

    var matchSettings: MatchSettings {
        MatchSettings(mode: mode, caseMode: caseMode, expandAfter: expandAfter, delimiters: Set(delimiters))
    }

    private init() {
        defaults.register(defaults: [
            Key.enabled: true, Key.mode: ExpansionMode.keepDelimiter.rawValue, Key.caseMode: CaseMode.caseSensitive.rawValue,
            Key.expandAfter: ExpandAfter.anyCharacter.rawValue, Key.delimiters: Self.defaultDelimiters, Key.sound: false,
            Key.restoreClipboard: true, Key.restoreDelay: 0.5, Key.scripts: false, Key.scriptTimeout: 5.0,
            Key.capSentences: false, Key.capDoubleCaps: false, Key.capContraction: "",
            Key.suggestions: false, Key.suggestionsNotify: true, Key.tutor: false,
            Key.newType: ContentType.plainText.rawValue, Key.warnPasteLens: true,
        ])
        enabled = true; mode = .keepDelimiter; caseMode = .caseSensitive; expandAfter = .anyCharacter
        delimiters = ""; sound = false; restoreClipboard = true; restoreDelay = 0.5; scope = .all
        scriptsAllowed = false; scriptTimeout = 5; capSentences = false; capDoubleCaps = false; capScope = .all; capContraction = ""
        suggestions = false; suggestionsNotify = true; tutor = false; suggestScope = .all; newType = .plainText; warnPasteLens = true
        load()
        loaded = true
    }

    /// Reads every value from UserDefaults (at launch, and after another Mac changed one).
    private func load() {
        let wasApplying = applyingRemote
        applyingRemote = true
        defer { applyingRemote = wasApplying }
        let d = defaults
        if enabled != d.bool(forKey: Key.enabled) { enabled = d.bool(forKey: Key.enabled) }
        mode = ExpansionMode(rawValue: d.string(forKey: Key.mode) ?? "") ?? .keepDelimiter
        caseMode = CaseMode(rawValue: d.string(forKey: Key.caseMode) ?? "") ?? .caseSensitive
        expandAfter = ExpandAfter(rawValue: d.string(forKey: Key.expandAfter) ?? "") ?? .anyCharacter
        delimiters = d.string(forKey: Key.delimiters) ?? Self.defaultDelimiters
        sound = d.bool(forKey: Key.sound)
        restoreClipboard = d.bool(forKey: Key.restoreClipboard)
        restoreDelay = d.double(forKey: Key.restoreDelay)
        scope = coded(Key.scope) ?? .all
        scriptsAllowed = d.bool(forKey: Key.scripts)
        scriptTimeout = d.double(forKey: Key.scriptTimeout)
        capSentences = d.bool(forKey: Key.capSentences)
        capDoubleCaps = d.bool(forKey: Key.capDoubleCaps)
        capScope = coded(Key.capScope) ?? .all
        capContraction = d.string(forKey: Key.capContraction) ?? ""
        suggestions = d.bool(forKey: Key.suggestions)
        suggestionsNotify = d.bool(forKey: Key.suggestionsNotify)
        tutor = d.bool(forKey: Key.tutor)
        suggestScope = coded(Key.suggestScope) ?? .all
        newType = ContentType(rawValue: d.string(forKey: Key.newType) ?? "") ?? .plainText
        warnPasteLens = d.bool(forKey: Key.warnPasteLens)
        var keys: [HotKeyAction: HotKey] = [:]
        for action in HotKeyAction.allCases {
            let k = Key.hotKeyPrefix + action.rawValue
            if let data = d.data(forKey: k) {
                // Empty data means the shortcut was cleared on purpose.
                if !data.isEmpty, let key = try? JSONDecoder().decode(HotKey.self, from: data) { keys[action] = key }
            } else if let fallback = Self.defaultHotKeys[action] {
                keys[action] = fallback
            }
        }
        hotKeys = keys
    }

    /// Follows settings that arrived from another Mac.
    func reloadFromDefaults() {
        load()
        HotKeyCenter.shared.apply()
        ExpansionEngine.shared.settingsChanged()
    }

    func resetToDefaults() {
        for key in Self.syncedKeys { defaults.removeObject(forKey: key); stamp(key) }
        load()
        ExpansionEngine.shared.settingsChanged()
    }

    private func coded<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save(_ key: String, _ value: Any) {
        guard !applyingRemote else { return }
        defaults.set(value, forKey: key)
        stamp(key)
        ExpansionEngine.shared.settingsChanged()
    }

    private func saveCoded<T: Encodable>(_ key: String, _ value: T) {
        guard !applyingRemote, let data = try? JSONEncoder().encode(value) else { return }
        save(key, data)
    }

    private func stamp(_ key: String) {
        guard !applyingRemote, Self.syncedKeys.contains(key) else { return }
        SyncEngine.shared.settingChanged(key)
    }
}
