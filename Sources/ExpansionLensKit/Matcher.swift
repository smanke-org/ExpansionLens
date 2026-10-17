import Foundation

/// One abbreviation that can expand right now, with its settings worked out.
public struct Trigger: Equatable, Sendable {
    public var snippetID: UUID
    /// Group prefix plus abbreviation.
    public var abbreviation: String
    public var caseMode: CaseMode
    public var expandAfter: ExpandAfter
    public var mode: ExpansionMode

    public init(snippetID: UUID, abbreviation: String, caseMode: CaseMode, expandAfter: ExpandAfter, mode: ExpansionMode) {
        self.snippetID = snippetID
        self.abbreviation = abbreviation
        self.caseMode = caseMode
        self.expandAfter = expandAfter
        self.mode = mode
    }
}

/// Settings the matcher needs from Settings.
public struct MatchSettings: Equatable, Sendable {
    public var mode: ExpansionMode
    public var caseMode: CaseMode
    public var expandAfter: ExpandAfter
    public var delimiters: Set<Character>

    public init(mode: ExpansionMode = .keepDelimiter, caseMode: CaseMode = .caseSensitive,
                expandAfter: ExpandAfter = .anyCharacter, delimiters: Set<Character> = MatchSettings.defaultDelimiters) {
        self.mode = mode
        self.caseMode = caseMode
        self.expandAfter = expandAfter
        self.delimiters = delimiters
    }

    /// Space, Tab, Return and common punctuation. Characters often used inside
    /// abbreviations (' - _ ; # @ etc.) aren't delimiters.
    public static let defaultDelimiters: Set<Character> = [" ", "\t", "\n", "\r", ".", ",", "!", "?", ":", "(", ")", "[", "]", "{", "}", "\"", "/"]
}

/// A typed abbreviation that should expand.
public struct Match: Equatable, Sendable {
    public var snippetID: UUID
    /// What was actually typed for the abbreviation (for adapt-to-case).
    public var typed: String
    public var abbreviation: String
    /// Characters to erase. The key just pressed isn't counted: it's held back, never reaching the app.
    public var eraseCount: Int
    /// The delimiter to type again after the expansion, if it's kept.
    public var delimiter: Character?
}

/// Decides, as each key is typed, whether an abbreviation was just completed.
public struct Matcher {
    private var triggers: [Trigger]

    /// Longest abbreviations first, so `sigg` wins over `sig` when both could expand.
    public init(triggers: [Trigger]) {
        self.triggers = triggers.filter { !$0.abbreviation.isEmpty }.sorted { $0.abbreviation.count > $1.abbreviation.count }
    }

    /// Builds triggers from the library for the app in front.
    public static func triggers(for library: Library, settings: MatchSettings, bundleID: String?,
                                modeOverrides: [UUID: ExpansionMode] = [:]) -> [Trigger] {
        var groups: [UUID: SnippetGroup] = [:]
        for group in library.groups where group.enabled && group.scope.allows(bundleID) { groups[group.id] = group }
        return library.snippets.compactMap { snippet in
            guard let group = groups[snippet.groupID], !snippet.abbreviation.isEmpty else { return nil }
            return Trigger(snippetID: snippet.id, abbreviation: group.prefix + snippet.abbreviation,
                           caseMode: snippet.caseMode ?? settings.caseMode,
                           expandAfter: group.expandAfter ?? settings.expandAfter,
                           mode: modeOverrides[snippet.id] ?? settings.mode)
        }
    }

    /// `typed` is what has been typed since the last reset, not including `key`, the
    /// character just pressed. Returns the match, if `key` completes one.
    public func match(typed: String, key: Character, delimiters: Set<Character>) -> Match? {
        let withKey = typed + String(key)
        for trigger in triggers where trigger.mode == .immediately {
            if let m = check(trigger, in: withKey, eraseFrom: typed) { return m }
        }
        guard delimiters.contains(key) else { return nil }
        for trigger in triggers where trigger.mode != .immediately {
            if var m = check(trigger, in: typed, eraseFrom: typed) {
                m.eraseCount = trigger.abbreviation.count
                m.delimiter = trigger.mode == .keepDelimiter ? key : nil
                return m
            }
        }
        return nil
    }

    private func check(_ trigger: Trigger, in text: String, eraseFrom typed: String) -> Match? {
        let abbreviation = trigger.abbreviation
        guard text.count >= abbreviation.count else { return nil }
        let tail = String(text.suffix(abbreviation.count))
        let same = trigger.caseMode == .caseSensitive ? tail == abbreviation : tail.lowercased() == abbreviation.lowercased()
        guard same else { return nil }
        let before = text.dropLast(abbreviation.count).last
        guard trigger.expandAfter.allows(previous: before) else { return nil }
        // Immediate: the last character of the abbreviation is the key being held back.
        return Match(snippetID: trigger.snippetID, typed: tail, abbreviation: abbreviation,
                     eraseCount: abbreviation.count - 1, delimiter: nil)
    }
}

/// Abbreviations that get in each other's way.
public struct Conflict: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case duplicate, prefix, contains

        public var title: String {
            switch self {
            case .duplicate: "has the same abbreviation as"
            case .prefix: "begins with"
            case .contains: "contains"
            }
        }
    }

    public var snippet: UUID
    public var other: UUID
    public var kind: Kind

    /// Finds conflicts among enabled groups' snippets. An abbreviation that ends with another
    /// can never reach its end when the shorter one expands immediately, so that's a conflict too.
    public static func find(in library: Library, settings: MatchSettings) -> [Conflict] {
        let enabled = Set(library.groups.filter(\.enabled).map(\.id))
        let items = library.snippets.filter { enabled.contains($0.groupID) && !$0.abbreviation.isEmpty }
            .map { ($0.id, library.trigger(for: $0), $0.caseMode ?? settings.caseMode) }
        var out: [Conflict] = []
        for (i, a) in items.enumerated() {
            for b in items[(i + 1)...] {
                let insensitive = a.2 != .caseSensitive || b.2 != .caseSensitive
                let x = insensitive ? a.1.lowercased() : a.1
                let y = insensitive ? b.1.lowercased() : b.1
                if x == y {
                    out.append(Conflict(snippet: a.0, other: b.0, kind: .duplicate))
                } else if settings.mode == .immediately {
                    if x.hasPrefix(y) || x.hasSuffix(y) { out.append(Conflict(snippet: a.0, other: b.0, kind: x.hasPrefix(y) ? .prefix : .contains)) }
                    else if y.hasPrefix(x) || y.hasSuffix(x) { out.append(Conflict(snippet: b.0, other: a.0, kind: y.hasPrefix(x) ? .prefix : .contains)) }
                }
            }
        }
        return out
    }
}
