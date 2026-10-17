import Foundation

/// A key a snippet presses as it expands.
public enum KeyMacro: String, Codable, Sendable, CaseIterable {
    case enter, `return`, tab, escape, left, right, up, down
}

/// One fill-in field: a single line, a multi-line area, a popup menu or a date picker.
public struct FillField: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable { case text, area, popup, date }
    public var kind: Kind
    public var name: String
    public var defaultValue: String
    public var width: Int?
    public var height: Int?
    /// Popup choices, in order.
    public var options: [String]
    /// Date picker: how the chosen date is written (a Unicode date pattern).
    public var format: String?

    public init(kind: Kind, name: String, defaultValue: String = "", width: Int? = nil, height: Int? = nil,
                options: [String] = [], format: String? = nil) {
        self.kind = kind
        self.name = name
        self.defaultValue = defaultValue
        self.width = width
        self.height = height
        self.options = options
        self.format = format
    }
}

/// A parsed piece of snippet content. `range` is where it came from in the content (UTF-16
/// offsets), so formatted snippets can carry each piece's formatting over.
public indirect enum MacroNode: Equatable, Sendable {
    case text(String, NSRange)
    case cursor
    case selectEnd
    case clipboard(NSRange)
    /// A date part: a Unicode date pattern such as "yyyy" or "EEEE".
    case date(String, NSRange)
    /// Moves the date used by the date parts that follow.
    case dateMath(Int, DateUnit)
    case snippet(String, NSRange)
    case key(KeyMacro)
    case delay(Int)
    case field(FillField, NSRange)
    case optional(name: String, includeByDefault: Bool, body: [MacroNode])
    case conditional(name: String, defaultBranch: Int, branches: [Branch])
    case fillTop
    case modeOverride(ExpansionMode)

    public struct Branch: Equatable, Sendable {
        public var name: String
        public var body: [MacroNode]
        public init(name: String, body: [MacroNode]) {
            self.name = name
            self.body = body
        }
    }
}

public enum DateUnit: String, Sendable, CaseIterable {
    case years = "Y", months = "m", days = "D", hours = "h", minutes = "M", seconds = "s"

    public var component: Calendar.Component {
        switch self {
        case .years: .year
        case .months: .month
        case .days: .day
        case .hours: .hour
        case .minutes: .minute
        case .seconds: .second
        }
    }
}

/// Reads snippet content written in the `%` macro language (see docs/FEATURE_MAP.md).
/// Anything it doesn't recognize stays as literal text, so a stray `%` is harmless.
public struct MacroParser {
    private let chars: [Character]
    private let utf16Offsets: [Int]
    private var pos = 0
    private var autoFieldCount = 0
    private let scope: String

    /// - Parameter scope: prefixes the names given to unnamed fields, so fields from a
    ///   nested snippet don't share values with the outer snippet's.
    public init(_ source: String, scope: String = "") {
        chars = Array(source)
        var offsets: [Int] = []
        offsets.reserveCapacity(chars.count + 1)
        var o = 0
        for c in chars {
            offsets.append(o)
            o += c.utf16.count
        }
        offsets.append(o)
        utf16Offsets = offsets
        self.scope = scope
    }

    public static func parse(_ source: String, scope: String = "") -> [MacroNode] {
        var parser = MacroParser(source, scope: scope)
        return parser.parseSequence(until: []).nodes
    }

    // MARK: Sequences

    private enum Terminator: String {
        case partEnd = "%fillpartend%"
        case branchEnd = "%fillbranchend%"
        case conditionalEnd = "%fillconditionalend%"
    }

    private mutating func parseSequence(until terminators: Set<Terminator>) -> (nodes: [MacroNode], ended: Terminator?) {
        var nodes: [MacroNode] = []
        var literal = ""
        var literalStart = pos

        func flush(_ nodes: inout [MacroNode], _ literal: inout String, _ start: Int, _ end: Int, _ offsets: [Int]) {
            guard !literal.isEmpty else { return }
            nodes.append(.text(literal, NSRange(location: offsets[start], length: offsets[end] - offsets[start])))
            literal = ""
        }

        while pos < chars.count {
            if chars[pos] == "%" {
                for terminator in terminators where matches(terminator.rawValue) {
                    flush(&nodes, &literal, literalStart, pos, utf16Offsets)
                    pos += terminator.rawValue.count
                    return (nodes, terminator)
                }
                let start = pos
                if let node = parseMacro() {
                    flush(&nodes, &literal, literalStart, start, utf16Offsets)
                    nodes.append(node)
                    literalStart = pos
                    continue
                }
                pos = start
            }
            if literal.isEmpty { literalStart = pos }
            literal.append(chars[pos])
            pos += 1
        }
        flush(&nodes, &literal, literalStart, pos, utf16Offsets)
        return (nodes, nil)
    }

    // MARK: Macros

    private func matches(_ s: String, caseInsensitive: Bool = true) -> Bool {
        let needle = Array(s)
        guard pos + needle.count <= chars.count else { return false }
        for i in 0..<needle.count {
            let a = chars[pos + i], b = needle[i]
            if caseInsensitive ? (a.lowercased() != b.lowercased()) : (a != b) { return false }
        }
        return true
    }

    private func range(from start: Int) -> NSRange {
        NSRange(location: utf16Offsets[start], length: utf16Offsets[pos] - utf16Offsets[start])
    }

    /// Reads up to the next `%`; nil if there isn't one.
    private mutating func readUntilPercent() -> String? {
        var s = ""
        var p = pos
        while p < chars.count, chars[p] != "%" {
            s.append(chars[p])
            p += 1
        }
        guard p < chars.count else { return nil }
        pos = p + 1
        return s
    }

    /// Parses the macro at `pos` (which is a `%`), or returns nil to leave it as text.
    private mutating func parseMacro() -> MacroNode? {
        let start = pos
        // Two-character forms first.
        let next: Character? = pos + 1 < chars.count ? chars[pos + 1] : nil
        switch next {
        case "%": pos += 2; return .text("%", range(from: start))
        case "|": pos += 2; return .cursor
        case "\\": pos += 2; return .selectEnd
        case "<": pos += 2; return .key(.left)
        case ">": pos += 2; return .key(.right)
        case "^": pos += 2; return .key(.up)
        case "+": pos += 2; return .modeOverride(.keepDelimiter)
        case "!": pos += 2; return .modeOverride(.immediately)
        case "@": return parseDateMath()
        default: break
        }
        if next == "-" {
            pos += 2
            return .modeOverride(.abandonDelimiter)
        }

        // Words, longest first where they share a beginning.
        let words: [(String, (inout MacroParser, Int) -> MacroNode?)] = [
            ("%clipboard", { p, s in .clipboard(p.range(from: s)) }),
            ("%pasteboard", { p, s in .clipboard(p.range(from: s)) }),
            ("%filltop%", { _, _ in .fillTop }),
            ("%fillpart", { p, _ in p.parseOptional() }),
            ("%fillconditional", { p, _ in p.parseConditional() }),
            ("%filltext", { p, s in p.parseField(.text, start: s) }),
            ("%fillarea", { p, s in p.parseField(.area, start: s) }),
            ("%fillpopup", { p, s in p.parseField(.popup, start: s) }),
            ("%filldatepicker", { p, s in p.parseField(.date, start: s) }),
            ("%fill", { p, s in p.parseField(.text, start: s) }),
            ("%key:", { p, _ in p.parseKey() }),
            ("%delay:", { p, _ in p.readUntilPercent().flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { .delay(min(max($0, 0), 60_000)) } }),
            ("%snippet:", { p, s in p.readUntilPercent().map { .snippet($0, p.range(from: s)) } }),
            ("%date:", { p, s in p.readUntilPercent().map { .date($0, p.range(from: s)) } }),
        ]
        for (word, handler) in words where matches(word) {
            pos += word.count
            if let node = handler(&self, start) { return node }
            pos = start
            return nil
        }

        // Date and time parts.
        let parts: [(String, String)] = [
            ("%1H", "H"), ("%1I", "h"), ("%1M", "m"), ("%1S", "s"), ("%1m", "M"),
            ("%H", "HH"), ("%I", "hh"), ("%M", "mm"), ("%S", "ss"), ("%p", "a"),
            ("%Y", "yyyy"), ("%y", "yy"), ("%B", "MMMM"), ("%b", "MMM"), ("%m", "MM"),
            ("%A", "EEEE"), ("%a", "EEE"), ("%d", "dd"), ("%e", "d"), ("%j", "DDD"),
            ("%z", "ZZZ"), ("%Z", "VVVV"),
        ]
        for (macro, pattern) in parts where matches(macro, caseInsensitive: false) {
            pos += macro.count
            return .date(pattern, range(from: start))
        }
        if next == "v" {
            pos += 2
            return .key(.down)
        }
        return nil
    }

    private mutating func parseDateMath() -> MacroNode? {
        // %@+1D, %@-12M
        pos += 2
        guard pos < chars.count, chars[pos] == "+" || chars[pos] == "-" else { return nil }
        let negative = chars[pos] == "-"
        pos += 1
        var digits = ""
        while pos < chars.count, chars[pos].isASCII, chars[pos].isNumber {
            digits.append(chars[pos])
            pos += 1
        }
        guard let n = Int(digits), pos < chars.count, let unit = DateUnit(rawValue: String(chars[pos])) else { return nil }
        pos += 1
        return .dateMath(negative ? -n : n, unit)
    }

    private mutating func parseKey() -> MacroNode? {
        guard let name = readUntilPercent()?.lowercased() else { return nil }
        switch name {
        case "enter": return .key(.enter)
        case "return": return .key(.return)
        case "tab": return .key(.tab)
        case "esc", "escape": return .key(.escape)
        case "left", "left-arrow": return .key(.left)
        case "right", "right-arrow": return .key(.right)
        case "up", "up-arrow": return .key(.up)
        case "down", "down-arrow": return .key(.down)
        default: return nil
        }
    }

    /// The `:key=value` segments after a fill keyword, up to its closing `%`.
    private mutating func readParams() -> [(key: String?, value: String)]? {
        guard let body = readUntilPercent() else { return nil }
        if body.isEmpty { return [] }
        guard body.hasPrefix(":") else { return nil }
        return body.dropFirst().split(separator: ":", omittingEmptySubsequences: false).map { segment in
            let s = String(segment)
            for key in ["name", "default", "width", "height", "format", "active"] where s.lowercased().hasPrefix(key + "=") {
                return (key, String(s.dropFirst(key.count + 1)))
            }
            return (nil, s)
        }
    }

    private mutating func nextAutoName() -> String {
        autoFieldCount += 1
        return scope.isEmpty ? "Field \(autoFieldCount)" : "\(scope) › Field \(autoFieldCount)"
    }

    private mutating func parseField(_ kind: FillField.Kind, start: Int) -> MacroNode? {
        guard let params = readParams() else { return nil }
        var field = FillField(kind: kind, name: "")
        for (key, value) in params {
            switch key {
            case "name": field.name = value
            case "default":
                field.defaultValue = value
                if kind == .popup { field.options.append(value) }
            case "width": field.width = Int(value)
            case "height": field.height = Int(value)
            case "format": field.format = value
            case nil:
                if kind == .popup { field.options.append(value) } else if field.name.isEmpty { field.name = value }
            default: break
            }
        }
        if kind == .popup, field.defaultValue.isEmpty { field.defaultValue = field.options.first ?? "" }
        if field.name.isEmpty { field.name = nextAutoName() }
        return .field(field, range(from: start))
    }

    private mutating func parseOptional() -> MacroNode? {
        guard let params = readParams() else { return nil }
        var name = ""
        var include = true
        for (key, value) in params {
            switch key {
            case "name": name = value
            case "default": include = ["yes", "true", "1", "y"].contains(value.lowercased())
            case nil where name.isEmpty: name = value
            default: break
            }
        }
        if name.isEmpty { name = nextAutoName() }
        let (body, _) = parseSequence(until: [.partEnd])
        return .optional(name: name, includeByDefault: include, body: body)
    }

    private mutating func parseConditional() -> MacroNode? {
        guard let params = readParams() else { return nil }
        var name = ""
        var defaultBranch = 0
        for (key, value) in params {
            switch key {
            case "name": name = value
            case "default": defaultBranch = Int(value) ?? 0
            case nil where name.isEmpty: name = value
            default: break
            }
        }
        if name.isEmpty { name = nextAutoName() }
        var branches: [MacroNode.Branch] = []
        while pos < chars.count {
            // Whitespace between branches is ignored.
            while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
            if matches(Terminator.conditionalEnd.rawValue) { pos += Terminator.conditionalEnd.rawValue.count; break }
            guard matches("%fillbranch") else {
                // Content outside a branch: treat the rest as one branch.
                let (body, _) = parseSequence(until: [.conditionalEnd])
                branches.append(.init(name: "Branch \(branches.count + 1)", body: body))
                break
            }
            pos += "%fillbranch".count
            var branchName = ""
            if let params = readParams() {
                for (key, value) in params where key == "name" || (key == nil && branchName.isEmpty) { branchName = value }
            }
            let (body, _) = parseSequence(until: [.branchEnd, .conditionalEnd])
            branches.append(.init(name: branchName.isEmpty ? "Branch \(branches.count + 1)" : branchName, body: body))
        }
        if branches.isEmpty { branches = [.init(name: "Branch 1", body: [])] }
        return .conditional(name: name, defaultBranch: min(max(defaultBranch, 0), branches.count - 1), branches: branches)
    }
}
