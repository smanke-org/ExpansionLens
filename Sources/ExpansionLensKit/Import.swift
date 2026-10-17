import AppKit
import Foundation
import SQLite3

/// Snippets read from somewhere else, ready to add to the library.
public struct ImportResult: Equatable, Sendable {
    public var groups: [SnippetGroup] = []
    public var snippets: [Snippet] = []
    public var skipped = 0
    public init() {}

    public var summary: String {
        let s = "\(snippets.count) snippet\(snippets.count == 1 ? "" : "s") in \(groups.count) group\(groups.count == 1 ? "" : "s")"
        return skipped > 0 ? s + " (\(skipped) couldn't be read)" : s
    }
}

public enum SnippetImport {
    // MARK: Event-log libraries in WebKit IndexedDB

    /// Builds a library from records of an event log ("events" store), where each record's
    /// `cause.data` is a snippet or group as it was last updated. Later records win, and
    /// records marked deleted drop out.
    public static func fromEventRecords(_ records: [[String: Any]]) -> ImportResult {
        var groups: [String: [String: Any]] = [:]
        var groupOrder: [String] = []
        var snippets: [String: [String: Any]] = [:]
        var snippetOrder: [String] = []
        var unreadable = 0
        for record in records {
            guard let cause = record["cause"] as? [String: Any], let data = cause["data"] as? [String: Any],
                  let id = data["_id"] as? String else { continue }
            if data["abbreviation"] != nil, data["contents"] != nil || data["snippetType"] != nil {
                if snippets[id] == nil { snippetOrder.append(id) }
                snippets[id] = data
            } else if data["title"] != nil, data["groupPrefix"] != nil || data["snippetsRevisionId"] != nil || data["groupState"] != nil {
                if groups[id] == nil { groupOrder.append(id) }
                groups[id] = data
            } else if (cause["type"] as? String)?.contains("snippet") == true, data["abbreviation"] != nil {
                unreadable += 1
            }
        }
        var result = ImportResult()
        var groupIDs: [String: UUID] = [:]
        for (index, key) in groupOrder.enumerated() {
            guard let g = groups[key], g["deleted"] as? Bool != true else { continue }
            let id = UUID(uuidString: key) ?? UUID()
            groupIDs[key] = id
            let expandAfter: ExpandAfter? = switch g["expandAfterMode"] as? Int {
            case 1: .nonAlphanumeric
            case 2: .anyCharacter
            default: nil
            }
            result.groups.append(SnippetGroup(id: id, name: (g["title"] as? String) ?? "Imported", notes: (g["notes"] as? String) ?? "",
                                              prefix: (g["groupPrefix"] as? String) ?? "", expandAfter: expandAfter,
                                              sortIndex: Double(index), updatedAt: date(g["dateUpdated"]) ?? Date()))
        }
        var fallbackGroup: UUID?
        for key in snippetOrder {
            guard let s = snippets[key], s["deleted"] as? Bool != true else { continue }
            let groupKey = (s["groupId"] as? String) ?? ""
            guard let groupID = groupIDs[groupKey] ?? {
                if fallbackGroup == nil {
                    let g = SnippetGroup(name: "Imported", sortIndex: Double(result.groups.count))
                    result.groups.append(g)
                    fallbackGroup = g.id
                }
                return fallbackGroup
            }() else { continue }
            guard let converted = convert(type: s["snippetType"] as? Int ?? 0, contents: s["contents"] as? String ?? "") else {
                result.skipped += 1
                continue
            }
            let caseMode: CaseMode? = switch s["abbreviationMode"] as? Int {
            case 1: .ignoreCase
            case 2: .adaptToCase
            default: .caseSensitive
            }
            result.snippets.append(Snippet(id: UUID(uuidString: key) ?? UUID(), groupID: groupID,
                                           abbreviation: (s["abbreviation"] as? String) ?? "", label: (s["labelString"] as? String) ?? "",
                                           type: converted.type, content: converted.content, rtf: converted.rtf, caseMode: caseMode,
                                           createdAt: date(s["dateCreated"]) ?? Date(), updatedAt: date(s["dateUpdated"]) ?? Date()))
        }
        result.skipped += unreadable
        return result
    }

    private static func date(_ value: Any?) -> Date? {
        if let ms = value as? Double { return Date(timeIntervalSince1970: ms / 1000) }
        if let d = value as? Date { return d }
        return nil
    }

    /// Stored content type numbers: 0 plain, 1 formatted (RTF), 2 AppleScript, 3 shell,
    /// 4 JavaScript, 5 HTML, 6 plain text as JSON, 7 formatted text as JSON.
    static func convert(type: Int, contents: String) -> (type: ContentType, content: String, rtf: Data?)? {
        switch type {
        case 0: return (.plainText, contents, nil)
        case 2: return (.appleScript, contents, nil)
        case 3: return (.shellScript, contents, nil)
        case 4: return (.javaScript, contents, nil)
        case 1:
            // RTF, sometimes base64-encoded.
            let data = Data(base64Encoded: contents) ?? Data(contents.utf8)
            if let rich = try? NSAttributedString(data: data, options: [:], documentAttributes: nil) {
                return (.formattedText, rich.string, data)
            }
            return (.plainText, contents, nil)
        case 5:
            if let rich = try? NSAttributedString(data: Data(contents.utf8), options: [.documentType: NSAttributedString.DocumentType.html,
                                                                                     .characterEncoding: String.Encoding.utf8.rawValue],
                                                  documentAttributes: nil),
               let rtf = try? rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                return (.formattedText, rich.string, rtf)
            }
            return (.plainText, contents, nil)
        case 6, 7:
            guard let json = try? JSONSerialization.jsonObject(with: Data(contents.utf8)) else { return (.plainText, contents, nil) }
            return (.plainText, textFromJSON(json), nil)
        default:
            return nil
        }
    }

    /// The text of a JSON document tree: every "text" value in order, blocks on their own lines.
    static func textFromJSON(_ json: Any) -> String {
        var out = ""
        func walk(_ node: Any, depth: Int) {
            if let dict = node as? [String: Any] {
                if let text = dict["text"] as? String { out += text }
                for key in ["children", "nodes", "content", "blocks"] {
                    if let kids = dict[key] as? [Any] {
                        for kid in kids { walk(kid, depth: depth + 1) }
                    }
                }
                if let type = dict["type"] as? String, ["div", "paragraph", "p", "li", "list-item", "br"].contains(type), !out.hasSuffix("\n") { out += "\n" }
            } else if let array = node as? [Any] {
                for kid in array { walk(kid, depth: depth + 1) }
            }
        }
        walk(json, depth: 0)
        return out.hasSuffix("\n") ? String(out.dropLast()) : out
    }

    // MARK: Finding IndexedDB libraries

    /// IndexedDB databases under a WebKit data folder that hold a snippet event log.
    public static func findEventLogDatabases(under root: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker where url.lastPathComponent == "IndexedDB.sqlite3" {
            if let records = try? readRecords(database: url, store: "events", limit: 400),
               records.contains(where: { (($0["cause"] as? [String: Any])?["data"] as? [String: Any])?["abbreviation"] != nil }) {
                found.append(url)
            }
        }
        return found
    }

    /// Reads one IndexedDB object store. The database (with its WAL) is copied to a temporary
    /// folder first, so the app that owns it is never disturbed.
    public static func readRecords(database: URL, store: String, limit: Int? = nil) throws -> [[String: Any]] {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("expansionlens-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let copy = temp.appendingPathComponent("db.sqlite3")
        try FileManager.default.copyItem(at: database, to: copy)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: database.path + suffix)
            if FileManager.default.fileExists(atPath: side.path) {
                try? FileManager.default.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_close(db) }
        let sql = "SELECT r.value FROM Records r JOIN ObjectStoreInfo o ON o.id = r.objectStoreID WHERE o.name = ? ORDER BY r.rowid"
            + (limit.map { " LIMIT \($0)" } ?? "")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, store, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var out: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
            if let dict = (try? WebKitValueDecoder.decode(data)) as? [String: Any] { out.append(dict) }
        }
        return out
    }

    // MARK: Files

    /// CSV with abbreviation, content and (optionally) label columns.
    public static func fromCSV(_ text: String, groupName: String) -> ImportResult {
        var result = ImportResult()
        let group = SnippetGroup(name: groupName)
        result.groups = [group]
        var rows = CSV.parse(text)
        if let first = rows.first, first.first?.lowercased() == "abbreviation" { rows.removeFirst() }
        for row in rows where row.count >= 2 {
            let abbreviation = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !abbreviation.isEmpty || !row[1].isEmpty else { continue }
            result.snippets.append(Snippet(groupID: group.id, abbreviation: abbreviation, label: row.count > 2 ? row[2] : "", content: row[1]))
        }
        return result
    }

    /// A property list snippet-group file: any array of dictionaries with an abbreviation and
    /// content ("plainText", "contents" or "content").
    public static func fromPropertyList(_ data: Data, fallbackName: String) -> ImportResult {
        var result = ImportResult()
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return result }
        var name = fallbackName
        if let dict = root as? [String: Any], let info = dict["groupInfo"] as? [String: Any], let n = info["groupName"] as? String { name = n }
        let group = SnippetGroup(name: name)
        var items: [[String: Any]] = []
        func collect(_ node: Any) {
            if let array = node as? [[String: Any]], array.contains(where: { $0["abbreviation"] != nil }) {
                items += array
            } else if let dict = node as? [String: Any] {
                dict.values.forEach(collect)
            } else if let array = node as? [Any] {
                array.forEach(collect)
            }
        }
        collect(root)
        for item in items {
            let content = (item["plainText"] ?? item["contents"] ?? item["content"]) as? String ?? ""
            let type = (item["snippetType"] as? Int) ?? 0
            guard let converted = convert(type: type, contents: content) else { result.skipped += 1; continue }
            let caseMode: CaseMode? = switch item["abbreviationMode"] as? Int {
            case 1: .ignoreCase
            case 2: .adaptToCase
            default: nil
            }
            result.snippets.append(Snippet(groupID: group.id, abbreviation: (item["abbreviation"] as? String) ?? "",
                                           label: (item["label"] as? String) ?? "", type: converted.type, content: converted.content,
                                           rtf: converted.rtf, caseMode: caseMode))
        }
        if !result.snippets.isEmpty { result.groups = [group] }
        return result
    }
}

/// A small RFC 4180 CSV reader: quoted fields, doubled quotes, newlines inside quotes.
public enum CSV {
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = text.makeIterator()
        var pending: Character?
        while let c = pending ?? chars.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else { field.append(c) }
                continue
            }
            switch c {
            case "\"": quoted = true
            case ",": row.append(field); field = ""
            case "\n", "\r\n", "\r":
                row.append(field); field = ""
                rows.append(row); row = []
            default: field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    public static func escape(_ s: String) -> String {
        s.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}
