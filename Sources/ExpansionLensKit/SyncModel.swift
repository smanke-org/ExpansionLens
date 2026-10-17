import Foundation

/// One synced item, sealed before it leaves the Mac: a group, a snippet or a setting.
public struct SyncRecord: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case group, snippet, setting }

    public var kind: Kind
    public var id: String
    public var updatedAt: Date
    public var deleted: Bool
    public var payload: Data?

    public init(kind: Kind, id: String, updatedAt: Date, deleted: Bool = false, payload: Data? = nil) {
        self.kind = kind
        self.id = id
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.payload = payload
    }

    public var key: String { "\(kind.rawValue):\(id)" }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    public static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder.encode(value) }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try decoder.decode(type, from: data) }
}

/// How library records travel and merge: newest change wins, deletions travel as tombstones.
public enum LibrarySync {
    /// Tombstones older than this are forgotten.
    public static let tombstoneLifetime: TimeInterval = 90 * 86_400

    /// The record for a group or snippet as it is here, or its tombstone.
    public static func record(_ kind: SyncRecord.Kind, _ id: String, in library: Library) -> SyncRecord? {
        let key = "\(kind.rawValue):\(id)"
        switch kind {
        case .group:
            if let g = library.groups.first(where: { $0.id.uuidString == id }) {
                return SyncRecord(kind: .group, id: id, updatedAt: g.updatedAt, payload: try? SyncRecord.encode(g))
            }
        case .snippet:
            if let s = library.snippets.first(where: { $0.id.uuidString == id }) {
                return SyncRecord(kind: .snippet, id: id, updatedAt: s.updatedAt, payload: try? SyncRecord.encode(s))
            }
        case .setting:
            return nil
        }
        if let date = library.tombstones[key] { return SyncRecord(kind: kind, id: id, updatedAt: date, deleted: true) }
        return nil
    }

    /// Every group and snippet here, plus tombstones, as (kind, id).
    public static func allKeys(in library: Library) -> [(SyncRecord.Kind, String)] {
        var out: [(SyncRecord.Kind, String)] = library.groups.map { (.group, $0.id.uuidString) } + library.snippets.map { (.snippet, $0.id.uuidString) }
        for key in library.tombstones.keys {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let kind = SyncRecord.Kind(rawValue: parts[0]) { out.append((kind, parts[1])) }
        }
        return out
    }

    /// Applies a record from another Mac if it's newer than what's here. Returns true if the library changed.
    @discardableResult
    public static func apply(_ record: SyncRecord, to library: inout Library) -> Bool {
        guard record.kind != .setting else { return false }
        let local: Date? = library.tombstones[record.key] ?? {
            switch record.kind {
            case .group: library.groups.first { $0.id.uuidString == record.id }?.updatedAt
            case .snippet: library.snippets.first { $0.id.uuidString == record.id }?.updatedAt
            case .setting: nil
            }
        }()
        if let local {
            if record.updatedAt < local { return false }
            if record.updatedAt == local && (library.tombstones[record.key] != nil || !record.deleted) { return false }
        }
        if record.deleted {
            library.tombstones[record.key] = record.updatedAt
            switch record.kind {
            case .group: library.groups.removeAll { $0.id.uuidString == record.id }
            case .snippet: library.snippets.removeAll { $0.id.uuidString == record.id }
            case .setting: break
            }
            return true
        }
        guard let payload = record.payload else { return false }
        library.tombstones[record.key] = nil
        switch record.kind {
        case .group:
            guard let g = try? SyncRecord.decode(SnippetGroup.self, from: payload) else { return false }
            upsert(g, into: &library.groups)
        case .snippet:
            guard let s = try? SyncRecord.decode(Snippet.self, from: payload) else { return false }
            upsert(s, into: &library.snippets)
        case .setting:
            return false
        }
        return true
    }

    static func upsert<T: Identifiable>(_ item: T, into array: inout [T]) {
        if let i = array.firstIndex(where: { $0.id == item.id }) { array[i] = item } else { array.append(item) }
    }

    public static func pruneTombstones(_ library: inout Library, now: Date = Date()) {
        library.tombstones = library.tombstones.filter { now.timeIntervalSince($0.value) < tombstoneLifetime }
    }
}
