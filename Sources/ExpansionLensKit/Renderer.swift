import Foundation

/// What a snippet expands to: text in order with the keys, pauses and cursor marks between.
public struct Expansion: Equatable, Sendable {
    public enum Piece: Equatable, Sendable {
        /// `source` is the range in the snippet the text came from, when it was literal text
        /// (formatted snippets copy that range's formatting); `anchor` is where a macro sat.
        case text(String, source: NSRange?, anchor: Int?)
        case key(KeyMacro)
        case delay(Int)
        case cursor
        case selectEnd
    }

    public var pieces: [Piece] = []
    /// Show the fill-in window at the top of the screen.
    public var fillTop = false
    /// The snippet's own choice of when to expand, overriding Settings.
    public var modeOverride: ExpansionMode?
    /// Problems worth showing (a missing nested snippet, a script error).
    public var errors: [String] = []

    public init() {}

    /// All the text, ignoring keys and marks.
    public var text: String {
        pieces.reduce(into: "") { if case .text(let s, _, _) = $1 { $0 += s } }
    }

    mutating func append(_ text: String, source: NSRange? = nil, anchor: Int? = nil) {
        guard !text.isEmpty else { return }
        pieces.append(.text(text, source: source, anchor: anchor))
    }

    /// Applies adapt-to-case: an all-capitals abbreviation capitalizes everything, one with a
    /// capital first letter capitalizes the first letter.
    public mutating func adaptCase(typed: String, abbreviation: String) {
        let letters = typed.filter(\.isLetter)
        guard !letters.isEmpty else { return }
        let allCaps = letters.count > 1 && letters.allSatisfy(\.isUppercase)
        let firstCap = letters.first?.isUppercase == true
        let abbreviationFirstCap = abbreviation.first(where: \.isLetter)?.isUppercase == true
        if allCaps {
            pieces = pieces.map {
                if case .text(let s, let src, let anchor) = $0 { return .text(s.uppercased(), source: src, anchor: anchor) }
                return $0
            }
        } else if firstCap && !abbreviationFirstCap {
            for i in pieces.indices {
                guard case .text(let s, let src, let anchor) = pieces[i], let first = s.firstIndex(where: { !$0.isWhitespace }) else { continue }
                var changed = s
                changed.replaceSubrange(first...first, with: String(s[first]).uppercased())
                pieces[i] = .text(changed, source: src, anchor: anchor)
                break
            }
        }
    }
}

/// Values chosen in the fill-in window. Fields with the same name share a value.
public struct FieldValues: Equatable, Sendable {
    public var text: [String: String] = [:]
    public var optionals: [String: Bool] = [:]
    public var branches: [String: Int] = [:]
    public init() {}
}

/// Runs script snippets for the renderer. Returns the script's output or throws.
public typealias ScriptRunning = @Sendable (_ type: ContentType, _ source: String) throws -> String

/// Turns parsed snippet content into an `Expansion`.
public struct Renderer {
    public var library: Library
    public var date: Date
    public var clipboard: String
    public var values: FieldValues
    public var calendar: Calendar
    public var locale: Locale
    public var runScript: ScriptRunning?

    public init(library: Library, date: Date = Date(), clipboard: String = "", values: FieldValues = FieldValues(),
                calendar: Calendar = .current, locale: Locale = .current, runScript: ScriptRunning? = nil) {
        self.library = library
        self.date = date
        self.clipboard = clipboard
        self.values = values
        self.calendar = calendar
        self.locale = locale
        self.runScript = runScript
    }

    /// Expands a snippet, running it if it's a script.
    public func render(_ snippet: Snippet) -> Expansion {
        var out = Expansion()
        var state = State(date: date, visiting: [snippet.id])
        renderSnippet(snippet, into: &out, state: &state, asSource: false)
        return out
    }

    /// Expands content that isn't a saved snippet (the editor's preview of unsaved text).
    public func render(content: String, type: ContentType = .plainText) -> Expansion {
        render(Snippet(groupID: UUID(), abbreviation: "", type: type, content: content))
    }

    struct State {
        var date: Date
        var visiting: Set<UUID>
    }

    private func renderSnippet(_ snippet: Snippet, into out: inout Expansion, state: inout State, asSource: Bool, scope: String = "") {
        let nodes = MacroParser.parse(snippet.content, scope: scope)
        if snippet.type.isScript {
            // Macros in a script expand into its source first, so `%snippet:library%` can pull in shared code.
            var source = Expansion()
            render(nodes, into: &source, state: &state, scriptType: snippet.type)
            out.errors += source.errors
            if asSource {
                out.append(source.text)
                return
            }
            guard let runScript else {
                out.errors.append("Scripts aren't allowed to run. Turn them on in Settings › Expansion.")
                return
            }
            do {
                out.append(try runScript(snippet.type, source.text))
            } catch {
                out.errors.append("\(snippet.displayName): \(error.localizedDescription)")
            }
        } else {
            render(nodes, into: &out, state: &state, scriptType: nil)
        }
    }

    /// `scriptType` is set while building a script's source: keys, pauses and cursor marks
    /// have no meaning there, and a nested script of the same language is included as source.
    private func render(_ nodes: [MacroNode], into out: inout Expansion, state: inout State, scriptType: ContentType?) {
        for node in nodes {
            switch node {
            case .text(let s, let range):
                out.append(s, source: range)
            case .cursor:
                if scriptType == nil { out.pieces.append(.cursor) }
            case .selectEnd:
                if scriptType == nil { out.pieces.append(.selectEnd) }
            case .clipboard(let range):
                out.append(clipboard, anchor: range.location)
            case .date(let pattern, let range):
                out.append(format(state.date, pattern: pattern), anchor: range.location)
            case .dateMath(let amount, let unit):
                state.date = calendar.date(byAdding: unit.component, value: amount, to: state.date) ?? state.date
            case .snippet(let abbreviation, let range):
                guard let nested = library.snippet(abbreviation: abbreviation) else {
                    // A missing snippet reads "(abbreviation)", which shared script libraries test
                    // for to fall back to their defaults; in text, it's also worth a warning.
                    out.append("(\(abbreviation))", anchor: range.location)
                    if scriptType == nil { out.errors.append("No snippet with the abbreviation \(abbreviation).") }
                    continue
                }
                guard !state.visiting.contains(nested.id) else {
                    out.errors.append("\(abbreviation) includes itself, so it was left out.")
                    continue
                }
                state.visiting.insert(nested.id)
                var inner = Expansion()
                let asSource = scriptType != nil && nested.type == scriptType
                renderSnippet(nested, into: &inner, state: &state, asSource: asSource, scope: abbreviation)
                state.visiting.remove(nested.id)
                out.errors += inner.errors
                // Nested text keeps the outer snippet's formatting at that spot.
                for piece in inner.pieces {
                    if case .text(let s, _, _) = piece { out.append(s, anchor: range.location) } else if scriptType == nil { out.pieces.append(piece) }
                }
            case .key(let key):
                if scriptType == nil { out.pieces.append(.key(key)) }
            case .delay(let ms):
                if scriptType == nil { out.pieces.append(.delay(ms)) }
            case .field(let field, let range):
                out.append(value(of: field), anchor: range.location)
            case .optional(let name, let include, let body):
                if values.optionals[name] ?? include { render(body, into: &out, state: &state, scriptType: scriptType) }
            case .conditional(let name, let defaultBranch, let branches):
                let index = values.branches[name] ?? defaultBranch
                if branches.indices.contains(index) { render(branches[index].body, into: &out, state: &state, scriptType: scriptType) }
            case .fillTop:
                out.fillTop = true
            case .modeOverride(let mode):
                out.modeOverride = mode
            }
        }
    }

    public func value(of field: FillField) -> String {
        if let chosen = values.text[field.name] { return chosen }
        if field.kind == .date {
            // A date picker's default is today, written in its format.
            return field.defaultValue.isEmpty ? format(date, pattern: field.format ?? "yyyy-MM-dd") : field.defaultValue
        }
        return field.defaultValue
    }

    public func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

/// Finds the fill-in fields a snippet will ask for, including those in nested snippets, in
/// the order they appear. A name used twice is asked for once.
public enum FieldCollector {
    public enum Item: Equatable, Sendable {
        case field(FillField)
        case optional(name: String, includeByDefault: Bool, preview: String)
        case conditional(name: String, defaultBranch: Int, branchNames: [String])

        public var name: String {
            switch self {
            case .field(let f): f.name
            case .optional(let n, _, _): n
            case .conditional(let n, _, _): n
            }
        }
    }

    public static func items(for snippet: Snippet, in library: Library) -> [Item] {
        var out: [Item] = []
        var seen = Set<String>()
        var visiting: Set<UUID> = [snippet.id]
        walk(MacroParser.parse(snippet.content), library: library, out: &out, seen: &seen, visiting: &visiting)
        return out
    }

    public static func items(forContent content: String, in library: Library) -> [Item] {
        items(for: Snippet(groupID: UUID(), abbreviation: "", content: content), in: library)
    }

    private static func walk(_ nodes: [MacroNode], library: Library, out: inout [Item], seen: inout Set<String>, visiting: inout Set<UUID>) {
        for node in nodes {
            switch node {
            case .field(let field, _):
                if seen.insert(field.name).inserted { out.append(.field(field)) }
            case .optional(let name, let include, let body):
                if seen.insert(name).inserted {
                    let preview = Renderer(library: library).render(content: plain(body)).text
                    out.append(.optional(name: name, includeByDefault: include, preview: String(preview.prefix(80))))
                }
                walk(body, library: library, out: &out, seen: &seen, visiting: &visiting)
            case .conditional(let name, let defaultBranch, let branches):
                if seen.insert(name).inserted {
                    out.append(.conditional(name: name, defaultBranch: defaultBranch, branchNames: branches.map(\.name)))
                }
                for branch in branches { walk(branch.body, library: library, out: &out, seen: &seen, visiting: &visiting) }
            case .snippet(let abbreviation, _):
                guard let nested = library.snippet(abbreviation: abbreviation), !visiting.contains(nested.id) else { continue }
                visiting.insert(nested.id)
                walk(MacroParser.parse(nested.content, scope: abbreviation), library: library, out: &out, seen: &seen, visiting: &visiting)
                visiting.remove(nested.id)
            default:
                break
            }
        }
    }

    /// Literal text of nodes, for a short preview of an optional section.
    private static func plain(_ nodes: [MacroNode]) -> String {
        nodes.reduce(into: "") { result, node in
            if case .text(let s, _) = node { result += s == "%" ? "%%" : s }
        }
    }
}
