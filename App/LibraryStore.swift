import AppKit
import ExpansionLensKit
import Observation

/// The snippet library on disk, and every change to it.
///
/// Everything lives in `~/Library/Application Support/ExpansionLens` (EXPANSIONLENS_DATA_FOLDER
/// moves it for test copies): Library.json for groups and snippets, Suggestions.json for typing
/// suggestions, and SyncState.plist for CloudKit's bookkeeping. Each change stamps the record's
/// `updatedAt` and queues it for sync.
@Observable
@MainActor
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var library = Library()
    private(set) var tracker = PhraseTracker()
    /// The snippet that expanded last, for "Edit last expanded".
    var lastExpanded: UUID?

    let folder: URL
    private var libraryURL: URL { folder.appendingPathComponent("Library.json") }
    private var suggestionsURL: URL { folder.appendingPathComponent("Suggestions.json") }
    @ObservationIgnored private var saveScheduled = false
    @ObservationIgnored private var trackerSaveScheduled = false

    private init() {
        if let custom = ProcessInfo.processInfo.environment["EXPANSIONLENS_DATA_FOLDER"] {
            folder = URL(fileURLWithPath: custom)
        } else {
            folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ExpansionLens")
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: libraryURL), let loaded = try? SyncRecord.decode(Library.self, from: data) {
            library = loaded
        } else {
            library = Self.starterLibrary()
            saveNow()
        }
        if let data = try? Data(contentsOf: suggestionsURL), let loaded = try? JSONDecoder().decode(PhraseTracker.self, from: data) {
            tracker = loaded
        }
    }

    /// A first library with a few examples, so there's something to try right away. The ids
    /// are fixed, so a second Mac's starter snippets merge with the first's instead of doubling.
    private static func starterLibrary() -> Library {
        let past = Date(timeIntervalSince1970: 1_790_000_000)
        let group = SnippetGroup(id: UUID(uuidString: "E1A00000-0000-4000-8000-000000000001")!, name: "My Snippets", updatedAt: past)
        func id(_ n: Int) -> UUID { UUID(uuidString: "E1A00000-0000-4000-8000-00000000010\(n)")! }
        let snippets = [
            Snippet(id: id(1), groupID: group.id, abbreviation: ";date", label: "Today's date", content: "%B %e, %Y", createdAt: past, updatedAt: past),
            Snippet(id: id(2), groupID: group.id, abbreviation: ";time", label: "The time", content: "%1I:%M %p", createdAt: past, updatedAt: past),
            Snippet(id: id(3), groupID: group.id, abbreviation: ";ty", label: "Thank-you note",
                    content: "Hi %filltext:name=Name%,\n\nThank you for %filltext:name=Reason:default=your help%. %fillpart:name=Follow-up:default=no%I'll follow up %fillpopup:name=When:default=tomorrow:next week:soon%.%fillpartend%\n\nBest,\n%|", createdAt: past, updatedAt: past),
        ]
        return Library(groups: [group], snippets: snippets)
    }

    // MARK: Saving

    func saveNow() {
        guard let data = try? SyncRecord.encode(library) else { return }
        try? data.write(to: libraryURL, options: .atomic)
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                LibraryStore.shared.saveScheduled = false
                LibraryStore.shared.saveNow()
            }
        }
    }

    private func saveTracker() {
        guard !trackerSaveScheduled else { return }
        trackerSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated {
                let store = LibraryStore.shared
                store.trackerSaveScheduled = false
                if let data = try? JSONEncoder().encode(store.tracker) { try? data.write(to: store.suggestionsURL, options: .atomic) }
            }
        }
    }

    /// The library changed: save it, rebuild the abbreviations, refresh the shortcuts.
    private func changed() {
        scheduleSave()
        ExpansionEngine.shared.libraryChanged()
    }

    // MARK: Groups

    @discardableResult
    func addGroup(name: String) -> SnippetGroup {
        let group = SnippetGroup(name: name, sortIndex: (library.groups.map(\.sortIndex).max() ?? 0) + 1)
        library.groups.append(group)
        SyncEngine.shared.mark(.group, group.id.uuidString)
        changed()
        return group
    }

    func updateGroup(_ group: SnippetGroup) {
        guard let i = library.groups.firstIndex(where: { $0.id == group.id }), library.groups[i] != group else { return }
        var g = group
        g.updatedAt = Date()
        library.groups[i] = g
        SyncEngine.shared.mark(.group, g.id.uuidString)
        changed()
    }

    func deleteGroup(_ id: UUID) {
        for snippet in library.snippets(in: id) { removeSnippet(snippet.id) }
        library.groups.removeAll { $0.id == id }
        library.tombstones["group:\(id.uuidString)"] = Date()
        SyncEngine.shared.mark(.group, id.uuidString)
        changed()
    }

    // MARK: Snippets

    @discardableResult
    func addSnippet(to groupID: UUID, abbreviation: String = "", label: String = "", content: String = "",
                    type: ContentType? = nil) -> Snippet {
        let snippet = Snippet(groupID: groupID, abbreviation: abbreviation, label: label,
                              type: type ?? Preferences.shared.newType, content: content)
        library.snippets.append(snippet)
        SyncEngine.shared.mark(.snippet, snippet.id.uuidString)
        changed()
        return snippet
    }

    func updateSnippet(_ snippet: Snippet) {
        guard let i = library.snippets.firstIndex(where: { $0.id == snippet.id }), library.snippets[i] != snippet else { return }
        var s = snippet
        s.updatedAt = Date()
        library.snippets[i] = s
        SyncEngine.shared.mark(.snippet, s.id.uuidString)
        changed()
    }

    func deleteSnippets(_ ids: Set<UUID>) {
        for id in ids { removeSnippet(id) }
        changed()
    }

    private func removeSnippet(_ id: UUID) {
        library.snippets.removeAll { $0.id == id }
        library.tombstones["snippet:\(id.uuidString)"] = Date()
        SyncEngine.shared.mark(.snippet, id.uuidString)
    }

    func duplicate(_ ids: Set<UUID>, to groupID: UUID) {
        for snippet in library.snippets where ids.contains(snippet.id) {
            var copy = snippet
            copy.id = UUID()
            copy.groupID = groupID
            copy.createdAt = Date()
            copy.updatedAt = Date()
            copy.useCount = 0
            copy.lastUsed = nil
            library.snippets.append(copy)
            SyncEngine.shared.mark(.snippet, copy.id.uuidString)
        }
        changed()
    }

    func move(_ ids: Set<UUID>, to groupID: UUID) {
        for i in library.snippets.indices where ids.contains(library.snippets[i].id) {
            library.snippets[i].groupID = groupID
            library.snippets[i].updatedAt = Date()
            SyncEngine.shared.mark(.snippet, library.snippets[i].id.uuidString)
        }
        changed()
    }

    /// Counts a use. Not a content change, so it doesn't sync or move `updatedAt`.
    func recordUse(_ id: UUID) {
        guard let i = library.snippets.firstIndex(where: { $0.id == id }) else { return }
        library.snippets[i].useCount += 1
        library.snippets[i].lastUsed = Date()
        lastExpanded = id
        scheduleSave()
    }

    func snippet(_ id: UUID) -> Snippet? { library.snippets.first { $0.id == id } }

    // MARK: Import

    /// Adds imported groups and snippets. A group already here (same id, from an earlier
    /// import) is updated rather than duplicated.
    func add(_ result: ImportResult) {
        let base = (library.groups.map(\.sortIndex).max() ?? 0) + 1
        for (offset, var group) in result.groups.enumerated() {
            group.sortIndex = base + Double(offset)
            group.updatedAt = Date()
            library.tombstones["group:\(group.id.uuidString)"] = nil
            if let i = library.groups.firstIndex(where: { $0.id == group.id }) { library.groups[i] = group } else { library.groups.append(group) }
            SyncEngine.shared.mark(.group, group.id.uuidString)
        }
        for var snippet in result.snippets {
            snippet.updatedAt = Date()
            library.tombstones["snippet:\(snippet.id.uuidString)"] = nil
            if let i = library.snippets.firstIndex(where: { $0.id == snippet.id }) { library.snippets[i] = snippet } else { library.snippets.append(snippet) }
            SyncEngine.shared.mark(.snippet, snippet.id.uuidString)
        }
        changed()
    }

    // MARK: Sync

    func localRecord(_ kind: SyncRecord.Kind, _ id: String) -> SyncRecord? {
        LibrarySync.record(kind, id, in: library)
    }

    func allRecordKeys() -> [(SyncRecord.Kind, String)] { LibrarySync.allKeys(in: library) }

    @discardableResult
    func applyRemote(_ record: SyncRecord) -> Bool {
        guard LibrarySync.apply(record, to: &library) else { return false }
        changed()
        return true
    }

    func pruneTombstones() {
        let before = library.tombstones.count
        LibrarySync.pruneTombstones(&library)
        if library.tombstones.count != before { scheduleSave() }
    }

    // MARK: Suggestions

    func recordSentence(_ sentence: String) -> Suggestion? {
        let made = tracker.record(sentence)
        saveTracker()
        return made
    }

    func rejectSuggestion(_ hash: String) {
        tracker.reject(hash)
        saveTracker()
    }

    func removeSuggestion(_ hash: String) {
        tracker.remove(hash)
        saveTracker()
    }

    func clearSuggestionHistory() {
        let rejected = tracker.rejected
        tracker = PhraseTracker()
        tracker.rejected = rejected
        saveTracker()
    }

    // MARK: Export

    /// Writes the library as JSON, which Import can read back.
    func export(to url: URL) throws {
        var copy = library
        copy.tombstones = [:]
        try SyncRecord.encode(copy).write(to: url, options: .atomic)
    }
}
