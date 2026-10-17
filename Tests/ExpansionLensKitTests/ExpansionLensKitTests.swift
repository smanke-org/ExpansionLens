import Foundation
import Testing
@testable import ExpansionLensKit

private let group = SnippetGroup(name: "Personal")

private func library(_ snippets: [Snippet], prefix: String = "") -> Library {
    var g = group
    g.prefix = prefix
    return Library(groups: [g], snippets: snippets)
}

private func snip(_ abbreviation: String, _ content: String, type: ContentType = .plainText, caseMode: CaseMode? = nil) -> Snippet {
    Snippet(groupID: group.id, abbreviation: abbreviation, type: type, content: content, caseMode: caseMode)
}

private let fixedDate: Date = {
    var c = DateComponents()
    c.year = 2026; c.month = 3; c.day = 9; c.hour = 14; c.minute = 5; c.second = 7
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: c)!
}()

private func renderer(_ lib: Library, values: FieldValues = FieldValues(), clipboard: String = "") -> Renderer {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return Renderer(library: lib, date: fixedDate, clipboard: clipboard, values: values, calendar: cal, locale: Locale(identifier: "en_US_POSIX"))
}

@Suite struct ParserTests {
    @Test func plainTextStaysText() {
        #expect(MacroParser.parse("Hello") == [.text("Hello", NSRange(location: 0, length: 5))])
    }

    @Test func percentEscapesAndUnknownMacros() {
        let r = renderer(library([]))
        #expect(r.render(content: "100%% sure, 50% off %q").text == "100% sure, 50% off %q")
    }

    @Test func dateParts() {
        let r = renderer(library([]))
        #expect(r.render(content: "%Y-%m-%d %H:%M:%S").text == "2026-03-09 14:05:07")
        #expect(r.render(content: "%A %e %B %y, %1I %p").text == "Monday 9 March 26, 2 PM")
        #expect(r.render(content: "%date:yyyy.MM.dd%").text == "2026.03.09")
    }

    @Test func dateMathAppliesToLaterParts() {
        let r = renderer(library([]))
        #expect(r.render(content: "%d %@+1D%d %@-1m%m").text == "09 10 02")
    }

    @Test func cursorKeysAndDelays() {
        let e = renderer(library([])).render(content: "a%|b%key:tab%%delay:250%c%\\")
        #expect(e.pieces == [.text("a", source: NSRange(location: 0, length: 1), anchor: nil), .cursor,
                             .text("b", source: NSRange(location: 3, length: 1), anchor: nil), .key(.tab), .delay(250),
                             .text("c", source: NSRange(location: 24, length: 1), anchor: nil), .selectEnd])
    }

    @Test func clipboardAndNestedSnippets() {
        let lib = library([snip("sig", "Cheers"), snip("loop", "%snippet:loop%")])
        let r = renderer(lib, clipboard: "pasted")
        #expect(r.render(content: "[%clipboard] %snippet:sig%").text == "[pasted] Cheers")
        #expect(r.render(content: "[%snippet:nope%]").text == "[(nope)]")
        let looped = r.render(lib.snippets[1])
        #expect(looped.text.isEmpty)
        #expect(!looped.errors.isEmpty)
    }

    @Test func groupPrefixLookup() {
        let lib = library([snip("lib", "X"), snip("'d1", "Y")], prefix: "'")
        #expect(lib.snippet(abbreviation: "'lib")?.content == "X")
        // An abbreviation that already includes the prefix still resolves.
        #expect(lib.snippet(abbreviation: "'d1")?.content == "Y")
    }

    @Test func fillInsUseDefaultsAndValues() {
        let content = "Hi %filltext:name=who:default=you%, %fillpopup:name=tone:warm:default=cool:dry% %fillpart:name=ps:default=no%P.S.%fillpartend%"
        let lib = library([])
        #expect(renderer(lib).render(content: content).text == "Hi you, cool ")
        var values = FieldValues()
        values.text["who"] = "Sam"
        values.text["tone"] = "dry"
        values.optionals["ps"] = true
        #expect(renderer(lib, values: values).render(content: content).text == "Hi Sam, dry P.S.")
        let items = FieldCollector.items(forContent: content, in: lib)
        #expect(items.map(\.name) == ["who", "tone", "ps"])
        if case .field(let popup) = items[1] { #expect(popup.options == ["warm", "cool", "dry"]) } else { Issue.record("not a popup") }
    }

    @Test func conditionalBranches() {
        let content = "%fillconditional:name=lang:default=1%%fillbranch:name=EN%Hello%fillbranchend%%fillbranch:name=FR%Bonjour%fillbranchend%%fillconditionalend%!"
        let lib = library([])
        #expect(renderer(lib).render(content: content).text == "Bonjour!")
        var values = FieldValues()
        values.branches["lang"] = 0
        #expect(renderer(lib, values: values).render(content: content).text == "Hello!")
        #expect(FieldCollector.items(forContent: content, in: lib) == [.conditional(name: "lang", defaultBranch: 1, branchNames: ["EN", "FR"])])
    }

    @Test func unnamedFieldsGetNames() {
        let items = FieldCollector.items(forContent: "%filltext%-%filltext:default=x%", in: library([]))
        #expect(items.map(\.name) == ["Field 1", "Field 2"])
    }

    @Test func modeOverrideAndFillTop() {
        let e = renderer(library([])).render(content: "x%filltop%%-")
        #expect(e.fillTop)
        #expect(e.modeOverride == .abandonDelimiter)
        #expect(e.text == "x")
    }

    @Test func scriptsRunWithMacrosExpandedFirst() {
        let lib = library([snip("lib", "function f(){return 'ok'}", type: .javaScript),
                           snip("go", "%snippet:lib%\nf()", type: .javaScript)])
        var r = renderer(lib)
        r.runScript = { _, source in
            #expect(source == "function f(){return 'ok'}\nf()")
            return "ran"
        }
        #expect(r.render(lib.snippets[1]).text == "ran")
        // Without permission to run, nothing is inserted and an error explains why.
        let blocked = renderer(lib).render(lib.snippets[1])
        #expect(blocked.text.isEmpty && !blocked.errors.isEmpty)
    }

    @Test func adaptCase() {
        var e = renderer(library([])).render(content: "cheers, me")
        e.adaptCase(typed: "Sig", abbreviation: "sig")
        #expect(e.text == "Cheers, me")
        e.adaptCase(typed: "SIG", abbreviation: "sig")
        #expect(e.text == "CHEERS, ME")
    }
}

@Suite struct MatcherTests {
    let lib = library([snip("sig", "Cheers"), snip("sigg", "Long"), snip("Brb", "be right back", caseMode: .ignoreCase)])

    func matcher(_ mode: ExpansionMode, after: ExpandAfter = .anyCharacter) -> Matcher {
        Matcher(triggers: Matcher.triggers(for: lib, settings: MatchSettings(mode: mode, expandAfter: after), bundleID: nil))
    }

    @Test func delimiterModes() {
        let keep = matcher(.keepDelimiter)
        #expect(keep.match(typed: "hi sig", key: "x", delimiters: MatchSettings.defaultDelimiters) == nil)
        let m = keep.match(typed: "hi sig", key: " ", delimiters: MatchSettings.defaultDelimiters)
        #expect(m?.snippetID == lib.snippets[0].id && m?.eraseCount == 3 && m?.delimiter == " ")
        let abandon = matcher(.abandonDelimiter).match(typed: "sigg", key: ".", delimiters: MatchSettings.defaultDelimiters)
        #expect(abandon?.snippetID == lib.snippets[1].id && abandon?.delimiter == nil)
    }

    @Test func immediateHoldsBackTheLastKey() {
        let m = matcher(.immediately).match(typed: "si", key: "g", delimiters: [])
        #expect(m?.snippetID == lib.snippets[0].id && m?.eraseCount == 2)
    }

    @Test func caseModes() {
        let d = MatchSettings.defaultDelimiters
        #expect(matcher(.keepDelimiter).match(typed: "SIG", key: " ", delimiters: d) == nil)
        let m = matcher(.keepDelimiter).match(typed: "BRB", key: " ", delimiters: d)
        #expect(m?.typed == "BRB")
    }

    @Test func expandAfterRules() {
        let d = MatchSettings.defaultDelimiters
        #expect(matcher(.keepDelimiter, after: .whitespace).match(typed: "xsig", key: " ", delimiters: d) == nil)
        #expect(matcher(.keepDelimiter, after: .whitespace).match(typed: "x sig", key: " ", delimiters: d) != nil)
        #expect(matcher(.keepDelimiter, after: .nonAlphanumeric).match(typed: "(sig", key: " ", delimiters: d) != nil)
        #expect(matcher(.keepDelimiter, after: .nonAlphanumeric).match(typed: "1sig", key: " ", delimiters: d) == nil)
    }

    @Test func scopesAndDisabledGroups() {
        var l = lib
        l.groups[0].scope = AppScope(mode: .only, bundleIDs: ["com.example.mail"])
        #expect(Matcher.triggers(for: l, settings: MatchSettings(), bundleID: "com.example.notes").isEmpty)
        #expect(!Matcher.triggers(for: l, settings: MatchSettings(), bundleID: "com.example.mail").isEmpty)
        l.groups[0].enabled = false
        #expect(Matcher.triggers(for: l, settings: MatchSettings(), bundleID: "com.example.mail").isEmpty)
    }

    @Test func conflicts() {
        let found = Conflict.find(in: library([snip("a1", "x"), snip("a1", "y")]), settings: MatchSettings())
        #expect(found.count == 1 && found[0].kind == .duplicate)
        let prefix = Conflict.find(in: library([snip("ab", "x"), snip("abc", "y")]), settings: MatchSettings(mode: .immediately))
        #expect(prefix.count == 1 && prefix[0].kind == .prefix)
    }
}

@Suite struct ImportTests {
    /// Builds WebKit's serialized form of a flat object of strings and integers.
    func serialized(_ fields: [(String, Any)]) -> Data {
        var d = Data([15, 0, 0, 0, 2])
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func latin1(_ s: String) { u32(UInt32(s.utf8.count) | 0x8000_0000); d.append(contentsOf: Array(s.utf8)) }
        func value(_ v: Any) {
            switch v {
            case let s as String:
                d.append(16)
                if s.allSatisfy(\.isASCII) { latin1(s) } else {
                    let units = Array(s.utf16)
                    u32(UInt32(units.count))
                    for u in units { withUnsafeBytes(of: u.littleEndian) { d.append(contentsOf: $0) } }
                }
            case let i as Int: d.append(5); u32(UInt32(bitPattern: Int32(i)))
            case let b as Bool: d.append(b ? 9 : 8)
            case let o as [(String, Any)]:
                d.append(2)
                for (k, v) in o { latin1(k); value(v) }
                u32(0xFFFF_FFFF)
            default: d.append(4)
            }
        }
        for (k, v) in fields { latin1(k); value(v) }
        u32(0xFFFF_FFFF)
        return d
    }

    @Test func decodesWebKitValues() throws {
        let data = serialized([("type", "x"), ("n", 42), ("ok", true), ("name", "Zoë")])
        let dict = try #require(WebKitValueDecoder.decode(data) as? [String: Any])
        #expect(dict["type"] as? String == "x")
        #expect(dict["n"] as? Int == 42)
        #expect(dict["ok"] as? Bool == true)
        #expect(dict["name"] as? String == "Zoë")
    }

    @Test func eventLogBecomesLibrary() throws {
        let groupID = UUID().uuidString, snippetID = UUID().uuidString
        let records: [[String: Any]] = [
            ["cause": ["type": "updated-group", "data": ["_id": groupID, "title": "Work", "groupPrefix": ";", "groupState": 0, "expandAfterMode": 0]]],
            ["cause": ["type": "updated-snippet", "data": ["_id": snippetID, "groupId": groupID, "abbreviation": "addr", "labelString": "Address",
                                                            "contents": "1 Main St", "snippetType": 0, "abbreviationMode": 2]]],
            ["cause": ["type": "updated-snippet", "data": ["_id": snippetID, "groupId": groupID, "abbreviation": "addr", "labelString": "Address",
                                                            "contents": "2 Main St", "snippetType": 0, "abbreviationMode": 2]]],
            ["cause": ["type": "updated-snippet", "data": ["_id": UUID().uuidString, "groupId": groupID, "abbreviation": "gone",
                                                            "contents": "x", "snippetType": 0, "deleted": true]]],
            ["cause": ["type": "updated-snippet", "data": ["_id": UUID().uuidString, "groupId": groupID, "abbreviation": "js",
                                                            "contents": "1+1", "snippetType": 4]]],
        ]
        let result = SnippetImport.fromEventRecords(records)
        #expect(result.groups.map(\.name) == ["Work"])
        #expect(result.groups[0].prefix == ";")
        #expect(result.snippets.count == 2)
        #expect(result.snippets[0].content == "2 Main St")
        #expect(result.snippets[0].caseMode == .adaptToCase)
        #expect(result.snippets[1].type == .javaScript)
    }

    @Test func csvAndPropertyList() throws {
        let csv = SnippetImport.fromCSV("abbreviation,content,label\naddr,\"1 Main St, Apt 2\",Address\nsig,\"Line 1\nLine \"\"2\"\"\",\n", groupName: "CSV")
        #expect(csv.snippets.count == 2)
        #expect(csv.snippets[0].content == "1 Main St, Apt 2")
        #expect(csv.snippets[1].content == "Line 1\nLine \"2\"")

        let plist: [String: Any] = ["groupInfo": ["groupName": "Shared"],
                                    "snippetsTE2": [["abbreviation": "hi", "plainText": "Hello", "label": "Greeting", "snippetType": 0]]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let result = SnippetImport.fromPropertyList(data, fallbackName: "File")
        #expect(result.groups.first?.name == "Shared")
        #expect(result.snippets.first?.content == "Hello")
    }
}

@Suite struct TypingTests {
    @Test func suggestionsAfterThreeTimes() {
        var tracker = PhraseTracker()
        let sentence = "Thanks for reaching out, I'll get back to you soon"
        #expect(tracker.record(sentence) == nil)
        #expect(tracker.record(sentence.uppercased()) == nil)
        let s = tracker.record(sentence)
        #expect(s?.text == sentence)
        #expect(tracker.counts.isEmpty)
        tracker.reject(s!.hash)
        for _ in 0..<5 { #expect(tracker.record(sentence) == nil) }
        #expect(tracker.record("too short") == nil)
    }

    @Test func capitalization() {
        #expect(AutoCapitalizer.fix(word: "THe", before: "x ", sentences: false, doubleCaps: true)?.replacement == "The")
        #expect(AutoCapitalizer.fix(word: "THE", before: "", sentences: false, doubleCaps: true) == nil)
        #expect(AutoCapitalizer.fix(word: "hello", before: "Done. ", sentences: true, doubleCaps: false)?.replacement == "Hello")
        #expect(AutoCapitalizer.fix(word: "hello", before: "e.g. ", sentences: true, doubleCaps: false) == nil)
        #expect(AutoCapitalizer.fix(word: "hello", before: "Done.", sentences: true, doubleCaps: false) == nil)
        #expect(AutoCapitalizer.fix(word: "don't", before: "Yes!\n", sentences: true, doubleCaps: false)?.replacement == "Don't")
    }
}

@Suite struct SyncTests {
    @Test func newestWinsAndTombstonesHold() throws {
        var lib = library([])
        var s = snip("a", "one")
        s.updatedAt = Date(timeIntervalSince1970: 100)
        lib.snippets = [s]
        var newer = s
        newer.content = "two"
        newer.updatedAt = Date(timeIntervalSince1970: 200)
        let record = SyncRecord(kind: .snippet, id: s.id.uuidString, updatedAt: newer.updatedAt, payload: try SyncRecord.encode(newer))
        #expect(LibrarySync.apply(record, to: &lib))
        #expect(lib.snippets[0].content == "two")
        // An older version doesn't overwrite.
        let old = SyncRecord(kind: .snippet, id: s.id.uuidString, updatedAt: s.updatedAt, payload: try SyncRecord.encode(s))
        #expect(!LibrarySync.apply(old, to: &lib))
        let delete = SyncRecord(kind: .snippet, id: s.id.uuidString, updatedAt: Date(timeIntervalSince1970: 300), deleted: true)
        #expect(LibrarySync.apply(delete, to: &lib))
        #expect(lib.snippets.isEmpty)
        #expect(!LibrarySync.apply(record, to: &lib))
    }

    @Test func sealing() throws {
        let (keyring, key) = try SyncCrypto.createKeyring(passphrase: "correct horse", iterations: 1_000)
        let sealed = try SyncCrypto.seal(Data("secret".utf8), using: key)
        #expect(try SyncCrypto.open(sealed, using: try SyncCrypto.unwrap(keyring, passphrase: "correct horse")) == Data("secret".utf8))
        #expect(throws: SyncCrypto.CryptoError.self) { try SyncCrypto.unwrap(keyring, passphrase: "wrong") }
    }
}

/// Reads a real IndexedDB copy when EXPANSIONLENS_IMPORT_DB points at one (never in CI).
@Suite struct LocalImportCheck {
    @Test func realDatabase() throws {
        guard let path = ProcessInfo.processInfo.environment["EXPANSIONLENS_IMPORT_DB"] else { return }
        let records = try SnippetImport.readRecords(database: URL(fileURLWithPath: path), store: "events")
        let result = SnippetImport.fromEventRecords(records)
        print("IMPORT:", result.summary)
        for s in result.snippets.prefix(40) {
            let lib = Library(groups: result.groups, snippets: result.snippets)
            print("  \(lib.trigger(for: s)) [\(s.type.rawValue)] \(s.displayName)")
        }
        #expect(!result.snippets.isEmpty)
    }
}
