import Foundation

/// What a snippet's content is and how it turns into text.
public enum ContentType: String, Codable, CaseIterable, Sendable {
    case plainText, formattedText, appleScript, shellScript, javaScript

    public var title: String {
        switch self {
        case .plainText: "Plain Text"
        case .formattedText: "Formatted Text"
        case .appleScript: "AppleScript"
        case .shellScript: "Shell Script"
        case .javaScript: "JavaScript"
        }
    }

    public var isScript: Bool { self == .appleScript || self == .shellScript || self == .javaScript }
}

/// How the typed abbreviation is compared with the snippet's.
public enum CaseMode: String, Codable, CaseIterable, Sendable {
    /// `aB`, `Ab` and `ab` are different abbreviations.
    case caseSensitive
    /// Any capitalization matches; the content is inserted as written.
    case ignoreCase
    /// Any capitalization matches, and the content follows it: `Sig` capitalizes the first
    /// letter, `SIG` the whole expansion.
    case adaptToCase

    public var title: String {
        switch self {
        case .caseSensitive: "Case Sensitive (aB, Ab, ab differ)"
        case .ignoreCase: "Ignore Case (aB, Ab, ab same)"
        case .adaptToCase: "Adapt to Case of Abbreviation"
        }
    }
}

/// When a typed abbreviation expands.
public enum ExpansionMode: String, Codable, CaseIterable, Sendable {
    case immediately
    /// At a delimiter key, which stays after the expansion.
    case keepDelimiter
    /// At a delimiter key, which is removed.
    case abandonDelimiter

    public var title: String {
        switch self {
        case .immediately: "Immediately when typed"
        case .keepDelimiter: "At a delimiter (keep the delimiter)"
        case .abandonDelimiter: "At a delimiter (remove the delimiter)"
        }
    }
}

/// What may come right before an abbreviation for it to count.
public enum ExpandAfter: String, Codable, CaseIterable, Sendable {
    case whitespace, nonAlphanumeric, anyCharacter

    public var title: String {
        switch self {
        case .whitespace: "Whitespace precedes the abbreviation"
        case .nonAlphanumeric: "All but letters & numbers precede the abbreviation"
        case .anyCharacter: "Any character precedes the abbreviation"
        }
    }

    /// Whether `previous` (nil at the start of what was typed) allows an expansion.
    public func allows(previous: Character?) -> Bool {
        guard let previous else { return true }
        switch self {
        case .whitespace: return previous.isWhitespace || previous.isNewline
        case .nonAlphanumeric: return !(previous.isLetter || previous.isNumber)
        case .anyCharacter: return true
        }
    }
}

/// Which apps a group (or the whole app) works in.
public struct AppScope: Codable, Equatable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case all, allExcept, only
        public var title: String {
            switch self {
            case .all: "All applications"
            case .allExcept: "All applications except…"
            case .only: "Only these applications…"
            }
        }
    }

    public var mode: Mode
    public var bundleIDs: [String]

    public init(mode: Mode = .all, bundleIDs: [String] = []) {
        self.mode = mode
        self.bundleIDs = bundleIDs
    }

    public static let all = AppScope()

    public func allows(_ bundleID: String?) -> Bool {
        switch mode {
        case .all: return true
        case .allExcept: return bundleID.map { !bundleIDs.contains($0) } ?? true
        case .only: return bundleID.map { bundleIDs.contains($0) } ?? false
        }
    }
}

public struct Snippet: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var groupID: UUID
    public var abbreviation: String
    public var label: String
    public var type: ContentType
    /// Plain text with `%` macros, or script source. For formatted text, the plain version.
    public var content: String
    /// Formatted text as RTF, with the same macros inline.
    public var rtf: Data?
    /// nil follows the default in Settings.
    public var caseMode: CaseMode?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsed: Date?
    public var useCount: Int

    public init(id: UUID = UUID(), groupID: UUID, abbreviation: String, label: String = "", type: ContentType = .plainText,
                content: String, rtf: Data? = nil, caseMode: CaseMode? = nil, createdAt: Date = Date(), updatedAt: Date = Date(),
                lastUsed: Date? = nil, useCount: Int = 0) {
        self.id = id
        self.groupID = groupID
        self.abbreviation = abbreviation
        self.label = label
        self.type = type
        self.content = content
        self.rtf = rtf
        self.caseMode = caseMode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsed = lastUsed
        self.useCount = useCount
    }

    /// The label, or the first line of the content when there's none.
    public var displayName: String {
        if !label.isEmpty { return label }
        let first = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.isEmpty ? "(Untitled)" : String(first.prefix(60))
    }
}

public struct SnippetGroup: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var notes: String
    /// Typed before every abbreviation in the group.
    public var prefix: String
    /// nil follows the default in Settings.
    public var expandAfter: ExpandAfter?
    public var scope: AppScope
    public var enabled: Bool
    public var sortIndex: Double
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, notes: String = "", prefix: String = "", expandAfter: ExpandAfter? = nil,
                scope: AppScope = .all, enabled: Bool = true, sortIndex: Double = 0, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.notes = notes
        self.prefix = prefix
        self.expandAfter = expandAfter
        self.scope = scope
        self.enabled = enabled
        self.sortIndex = sortIndex
        self.updatedAt = updatedAt
    }
}

/// A phrase you type often, offered as a new snippet.
public struct Suggestion: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String { hash }
    /// SHA-256 of the phrase, so a rejected one is remembered without keeping its text.
    public var hash: String
    public var text: String
    public var count: Int
    public var lastSeen: Date

    public init(hash: String, text: String, count: Int, lastSeen: Date) {
        self.hash = hash
        self.text = text
        self.count = count
        self.lastSeen = lastSeen
    }
}

/// Everything ExpansionLens stores about your snippets.
public struct Library: Codable, Equatable, Sendable {
    public var groups: [SnippetGroup]
    public var snippets: [Snippet]
    /// Deleted records ("group:<id>" or "snippet:<id>") and when, so sync can't bring them back.
    public var tombstones: [String: Date]

    public init(groups: [SnippetGroup] = [], snippets: [Snippet] = [], tombstones: [String: Date] = [:]) {
        self.groups = groups
        self.snippets = snippets
        self.tombstones = tombstones
    }

    public func group(_ id: UUID) -> SnippetGroup? { groups.first { $0.id == id } }

    public func snippets(in group: UUID) -> [Snippet] { snippets.filter { $0.groupID == group } }

    /// The full abbreviation you type: the group's prefix plus the snippet's own.
    public func trigger(for snippet: Snippet) -> String {
        (group(snippet.groupID)?.prefix ?? "") + snippet.abbreviation
    }

    /// Finds a snippet by what you'd type for it (used by `%snippet:` and scripts).
    public func snippet(abbreviation: String) -> Snippet? {
        snippets.first { trigger(for: $0) == abbreviation }
            ?? snippets.first { $0.abbreviation == abbreviation }
            ?? snippets.first { trigger(for: $0).lowercased() == abbreviation.lowercased() }
    }

    public var sortedGroups: [SnippetGroup] {
        groups.sorted { $0.sortIndex == $1.sortIndex ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.sortIndex < $1.sortIndex }
    }
}
