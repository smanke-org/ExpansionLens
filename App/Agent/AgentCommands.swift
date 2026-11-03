import AppKit
import ExpansionLensKit

/// Everything an agent can do in ExpansionLens. Add a command here and the CLI, `help`, and the
/// MCP tools all get it. Each `run` is on the main actor and calls the same code as the library
/// window, the menus and the expansionlens:// actions, so the window updates live.
/// Nothing here types into other apps: `snippets expand` only returns the text.
enum AgentCommands {
    static let all: [AgentCommand] = [
        AgentCommand(name: "status", summary: "Show the version, whether expansion is on (`enabled`) and actually running (`engine`: running, off, needs-accessibility or blocked-by-secure-input), how many groups and snippets there are, sync, and whether PasteLens is expanding too.",
                     example: "expansionlens status --json", readOnly: true) { _ in
            let library = LibraryStore.shared.library
            let engine = ExpansionEngine.shared
            var result: JSONObject = [
                "app": AppInfo.name, "version": AppInfo.version,
                "enabled": Preferences.shared.enabled, "engine": stateName(engine.state),
                "accessibilityAllowed": ExpansionEngine.trusted,
                "groups": library.groups.count, "snippets": library.snippets.count,
                "conflicts": Conflict.find(in: library, settings: Preferences.shared.matchSettings).count,
                "scriptsAllowed": Preferences.shared.scriptsAllowed,
                "sync": SyncEngine.shared.enabled ? SyncEngine.shared.status.summary : "Off",
                "pasteLensAlsoExpanding": PasteLensBridge.shared.conflict,
                "libraryWindowOpen": NSApp.windows.contains { $0.title == "ExpansionLens" && $0.isVisible },
            ]
            if case .blockedBySecureInput(let app) = engine.state { result["secureInputApp"] = app ?? "" }
            if let last = LibraryStore.shared.lastExpanded.flatMap(LibraryStore.shared.snippet) { result["lastExpanded"] = summary(last) }
            return result
        },

        // MARK: Snippets

        AgentCommand(name: "snippets list", summary: "List snippets, narrowed like the library window's search. Returns `snippets` (id, abbreviation as typed with its group's prefix, name, group, type, uses, lastUsed, updated in UTC, preview), `total` (every match, whatever --limit is) and `nextOffset` when there are more.",
                     params: [.init(name: "search", help: "words in the abbreviation, label or content"),
                              .init(name: "group", help: "only this group (its id or name)"),
                              .init(name: "type", help: "only this type: \(typeNames.map(\.name).joined(separator: ", "))"),
                              .init(name: "conflicts", kind: .boolean, help: "only snippets whose abbreviations get in each other's way"),
                              .init(name: "sort", help: "label (default), abbreviation, content, modified or uses"),
                              .init(name: "descending", kind: .boolean, help: "reverse the order (modified and uses read newest or most first)"),
                              .init(name: "limit", kind: .integer, help: "at most this many (default 50)"),
                              .init(name: "offset", kind: .integer, help: "skip this many, for the next page")],
                     example: "expansionlens snippets list --search address --limit 10 --json", readOnly: true) { args in
            let library = LibraryStore.shared.library
            let model = MainModel()
            if try args.bool("conflicts") == true {
                model.section = .conflicts
            } else if let group = args.string("group") {
                model.section = .group(try findGroup(group).id)
            }
            model.search = args.string("search") ?? ""
            if let sort = args.string("sort") {
                guard let match = sorts.first(where: { $0.name == sort.lowercased() }) else {
                    throw AgentError.usage("--sort must be one of \(sorts.map(\.name).joined(separator: ", "))")
                }
                model.sort = match.sort
            }
            model.ascending = try args.bool("descending") != true
            var list = model.visibleSnippets(library)
            if let type = args.string("type") {
                let wanted = try contentType(type)
                list = list.filter { $0.type == wanted }
            }
            return try page(list, args, key: "snippets") { summary($0) }
        },
        AgentCommand(name: "snippets show", summary: "Show one snippet in full: its content (with % placeholders as written), group, type, case setting, fill-ins and any abbreviation conflicts.",
                     params: [snippetParam],
                     example: "expansionlens snippets show \";addr\" --json", readOnly: true) { args in
            detail(try findSnippet(args.required("snippet")))
        },
        AgentCommand(name: "snippets expand", summary: "Show what a snippet expands to, with dates, the clipboard, nested snippets and fill-ins worked out, as the editor's preview does. Nothing is typed or pasted, and script snippets aren't run. Returns `text`, the keys and cursor marks it would press (`keys`), and `fields` it asks for.",
                     params: [snippetParam,
                              .init(name: "fields", help: "fill-in values as a JSON object: {\"Name\":\"Alex\"} for a field, true or false for an optional part, a branch name or number for a conditional. Fields left out keep their defaults")],
                     example: "expansionlens snippets expand \";ty\" --fields '{\"Name\":\"Alex\"}' --json", readOnly: true) { args in
            try expand(try findSnippet(args.required("snippet")), fields: args.string("fields"))
        },
        AgentCommand(name: "snippets add", summary: "Add a snippet, as New Snippet does. Returns the new snippet, with `conflicts` if its abbreviation gets in another's way.",
                     params: [.init(name: "content", required: true, help: "what it expands to; % placeholders like %Y or %clipboard work (write %% for a percent sign)"),
                              .init(name: "abbreviation", help: "what you type to expand it, like ;addr (the group's prefix goes in front)"),
                              .init(name: "label", help: "a name for it"),
                              .init(name: "group", help: "its group, by id or name (default: the first group)"),
                              .init(name: "type", help: "plain (default), applescript, shell or javascript. Formatted text is made in the window")],
                     example: "expansionlens snippets add --abbreviation \";sig\" --label Signature --content \"Best regards, Alex\" --json") { args in
            let store = LibraryStore.shared
            let groupID: UUID
            if let group = args.string("group") {
                groupID = try findGroup(group).id
            } else {
                groupID = store.library.sortedGroups.first?.id ?? store.addGroup(name: "My Snippets").id
            }
            let type = try args.string("type").map(contentType) ?? .plainText
            guard type != .formattedText else { throw AgentError.invalid("formatted text snippets are made in the ExpansionLens window. Use --type plain") }
            let snippet = store.addSnippet(to: groupID, abbreviation: args.string("abbreviation") ?? "", label: args.string("label") ?? "",
                                           content: try args.required("content"), type: type)
            return detail(snippet)
        },
        AgentCommand(name: "snippets update", summary: "Change a snippet's abbreviation, label, content, type or group. Only the options you give change.",
                     params: [snippetParam,
                              .init(name: "abbreviation", help: "a new abbreviation (\"\" removes it)"),
                              .init(name: "label", help: "a new label (\"\" clears it)"),
                              .init(name: "content", help: "new content, replacing the old"),
                              .init(name: "type", help: "plain, applescript, shell or javascript"),
                              .init(name: "group", help: "move it to this group, by id or name")],
                     example: "expansionlens snippets update \";addr\" --content \"1 Example Street\" --json") { args in
            let store = LibraryStore.shared
            let before = try findSnippet(args.required("snippet"))
            var changed = before
            if let abbreviation = args.string("abbreviation") { changed.abbreviation = abbreviation }
            if let label = args.string("label") { changed.label = label }
            if let type = args.string("type") {
                changed.type = try contentType(type)
                guard changed.type != .formattedText || before.type == .formattedText else {
                    throw AgentError.invalid("snippets become formatted text in the ExpansionLens window")
                }
            }
            if let content = args.string("content") {
                guard before.type != .formattedText else {
                    throw AgentError.invalid("\(short(before.id)) is formatted text; change its content in the ExpansionLens window (`expansionlens open --snippet \(short(before.id))`), or give --type plain to turn it into plain text")
                }
                changed.content = content
            }
            if changed.type != .formattedText { changed.rtf = nil }
            store.updateSnippet(changed)
            if let group = args.string("group") {
                let target = try findGroup(group)
                if target.id != before.groupID { store.move([before.id], to: target.id) }
            }
            guard let after = store.snippet(before.id) else { throw AgentError.notFound("the snippet went away while it was changing") }
            var result = detail(after)
            result["changed"] = after != before
            return result
        },
        AgentCommand(name: "snippets delete", summary: "Delete a snippet, on every Mac that syncs this library. Without --yes it only shows what it would delete.",
                     params: [snippetParam],
                     example: "expansionlens snippets delete \";addr\" --yes --json", destructive: true) { args in
            let snippet = try findSnippet(args.required("snippet"))
            guard args.confirmed else {
                return ["wouldDelete": summary(snippet),
                        "hint": "add --yes to delete it. It can't be undone, and it goes from every Mac that syncs this library"]
            }
            LibraryStore.shared.deleteSnippets([snippet.id])
            return ["deleted": short(snippet.id), "abbreviation": LibraryStore.shared.library.trigger(for: snippet), "name": snippet.displayName]
        },
        AgentCommand(name: "snippets import", summary: "Add snippets from a file, as Import File does: a CSV (abbreviation, content, label), a snippet group property list, or an ExpansionLens export. An export brought in again updates its groups instead of adding copies; a CSV always makes a new group named after the file.",
                     params: [.init(name: "path", kind: .path, required: true, positional: true, help: "the file to import")],
                     example: "expansionlens snippets import ~/Downloads/snippets.csv --json") { args in
            let path = try absolutePath(args.required("path"))
            guard FileManager.default.isReadableFile(atPath: path) else { throw AgentError.notFound("no file at \(path)") }
            let result = Importer.read([URL(fileURLWithPath: path)])
            guard !result.snippets.isEmpty else {
                throw AgentError.invalid("no snippets in \(path). ExpansionLens reads CSV files, snippet group property lists and its own exports")
            }
            LibraryStore.shared.add(result)
            return ["imported": result.summary, "snippets": result.snippets.count, "skipped": result.skipped,
                    "groups": result.groups.map { ["id": short($0.id), "name": $0.name] }]
        },
        AgentCommand(name: "snippets export", summary: "Save every group and snippet as a JSON file, as Export Snippets does; `snippets import` reads it back.",
                     params: [.init(name: "to", kind: .path, required: true, help: "a file, or a folder to save \"ExpansionLens Snippets.json\" in"),
                              .init(name: "overwrite", kind: .boolean, help: "replace a file that's already there")],
                     example: "expansionlens snippets export --to ~/Desktop --json") { args in
            var target = URL(fileURLWithPath: try absolutePath(args.required("to")))
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: target.path, isDirectory: &isFolder), isFolder.boolValue {
                target = target.appending(path: "ExpansionLens Snippets.json")
            }
            guard FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) else {
                throw AgentError.notFound("no folder \(target.deletingLastPathComponent().path)")
            }
            if FileManager.default.fileExists(atPath: target.path), try args.bool("overwrite") != true {
                throw AgentError.invalid("\(target.path) is already there. Add --overwrite to replace it, or give another --to")
            }
            try LibraryStore.shared.export(to: target)
            let library = LibraryStore.shared.library
            return ["path": target.path, "groups": library.groups.count, "snippets": library.snippets.count]
        },

        // MARK: Groups

        AgentCommand(name: "groups list", summary: "List the groups in the library's order: id, name, prefix (typed before each abbreviation in it), whether it's on, and how many snippets it holds.",
                     example: "expansionlens groups list --json", readOnly: true) { _ in
            let library = LibraryStore.shared.library
            return ["groups": library.sortedGroups.map { groupSummary($0, in: library) }]
        },
        AgentCommand(name: "groups add", summary: "Add a group, as the library's + button does.",
                     params: [.init(name: "name", required: true, help: "the group's name"),
                              .init(name: "prefix", help: "typed before every abbreviation in the group, like ;"),
                              .init(name: "notes", help: "notes about the group")],
                     example: "expansionlens groups add --name Work --prefix \"w.\" --json") { args in
            let store = LibraryStore.shared
            let name = try args.required("name").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw AgentError.invalid("--name can't be empty") }
            var group = store.addGroup(name: name)
            if args.string("prefix") != nil || args.string("notes") != nil {
                group.prefix = args.string("prefix") ?? ""
                group.notes = args.string("notes") ?? ""
                store.updateGroup(group)
            }
            return groupSummary(store.library.group(group.id) ?? group, in: store.library)
        },
        AgentCommand(name: "groups update", summary: "Rename a group, change its prefix or notes, or turn it on or off (a group that's off doesn't expand). Only the options you give change.",
                     params: [.init(name: "group", required: true, positional: true, help: "the group's id or name"),
                              .init(name: "name", help: "a new name"),
                              .init(name: "prefix", help: "a new prefix (\"\" removes it)"),
                              .init(name: "notes", help: "new notes (\"\" clears them)"),
                              .init(name: "enabled", kind: .boolean, help: "true or false")],
                     example: "expansionlens groups update Work --enabled false --json") { args in
            let store = LibraryStore.shared
            let before = try findGroup(args.required("group"))
            var group = before
            if let name = args.string("name") {
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentError.invalid("--name can't be empty") }
                group.name = name
            }
            if let prefix = args.string("prefix") { group.prefix = prefix }
            if let notes = args.string("notes") { group.notes = notes }
            if let enabled = try args.bool("enabled") { group.enabled = enabled }
            store.updateGroup(group)
            let after = store.library.group(before.id) ?? group
            var result = groupSummary(after, in: store.library)
            result["changed"] = after != before
            return result
        },
        AgentCommand(name: "groups delete", summary: "Delete a group and every snippet in it, on every Mac that syncs this library. Without --yes it only shows what it would delete.",
                     params: [.init(name: "group", required: true, positional: true, help: "the group's id or name")],
                     example: "expansionlens groups delete Work --yes --json", destructive: true) { args in
            let library = LibraryStore.shared.library
            let group = try findGroup(args.required("group"))
            guard args.confirmed else {
                return ["wouldDelete": groupSummary(group, in: library),
                        "snippets": library.snippets(in: group.id).prefix(20).map { summary($0) },
                        "hint": "add --yes to delete the group and its \(library.snippets(in: group.id).count) snippets. It can't be undone, and they go from every Mac that syncs this library"]
            }
            let count = library.snippets(in: group.id).count
            LibraryStore.shared.deleteGroup(group.id)
            return ["deleted": short(group.id), "name": group.name, "snippetsDeleted": count]
        },

        // MARK: Expansion and windows

        AgentCommand(name: "expansion on", summary: "Turn expansion on, as the menu bar menu and expansionlens://on do. It needs Accessibility permission, which only the person can give.",
                     example: "expansionlens expansion on --json") { _ in
            try setExpansion(true)
        },
        AgentCommand(name: "expansion off", summary: "Turn expansion off everywhere until it's turned on again, as expansionlens://off does.",
                     example: "expansionlens expansion off --json") { _ in
            try setExpansion(false)
        },
        AgentCommand(name: "open", summary: "Bring up the library window (optionally on one snippet or group), Settings or Help.",
                     params: [.init(name: "page", positional: true, help: "library (default), settings or help"),
                              .init(name: "snippet", help: "show this snippet in the library, by id or abbreviation"),
                              .init(name: "group", help: "show this group in the library, by id or name")],
                     example: "expansionlens open --snippet \";addr\"") { args in
            switch args.string("page")?.lowercased() ?? "library" {
            case "library":
                if let ref = args.string("snippet") {
                    let snippet = try findSnippet(ref)
                    MainWindow.shared.show(snippet: snippet.id)
                    return ["opened": "library", "snippet": short(snippet.id)]
                }
                if let ref = args.string("group") {
                    let group = try findGroup(ref)
                    MainWindow.shared.show(section: .group(group.id))
                    return ["opened": "library", "group": short(group.id)]
                }
                MainWindow.shared.show()
                return ["opened": "library"]
            case "settings":
                SettingsWindow.shared.show()
                return ["opened": "settings"]
            case "help":
                HelpWindow.shared.show()
                return ["opened": "help"]
            case let other:
                throw AgentError.usage("no page \"\(other)\". Use library, settings or help")
            }
        },
    ]

    // MARK: Finding things

    static let snippetParam = AgentCommand.Param(name: "snippet", required: true, positional: true,
                                                 help: "the snippet's id (any unique start of it) or its abbreviation, as typed")

    /// The first 8 characters of the id, or all of it when another record starts the same way
    /// (the starter snippets share their first characters).
    @MainActor
    static func short(_ id: UUID) -> String {
        let full = id.uuidString.lowercased()
        let start = String(full.prefix(8))
        let library = LibraryStore.shared.library
        let clashes = (library.snippets.map(\.id) + library.groups.map(\.id))
            .filter { $0 != id && $0.uuidString.lowercased().hasPrefix(start) }
        return clashes.isEmpty ? start : full
    }

    @MainActor
    static func findSnippet(_ ref: String) throws -> Snippet {
        let library = LibraryStore.shared.library
        let needle = ref.lowercased()
        if needle.count >= 4, needle.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            let matches = library.snippets.filter { $0.id.uuidString.lowercased().hasPrefix(needle) }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { throw AgentError.invalid("\(matches.count) snippets start with \(ref). Give more of the id") }
        }
        if let exact = library.snippets.first(where: { library.trigger(for: $0) == ref }) ?? library.snippet(abbreviation: ref), !ref.isEmpty {
            return exact
        }
        throw AgentError.notFound("no snippet with id or abbreviation \(ref). Run `expansionlens snippets list --search ...`")
    }

    @MainActor
    static func findGroup(_ ref: String) throws -> SnippetGroup {
        let library = LibraryStore.shared.library
        let needle = ref.lowercased()
        let byName = library.groups.filter { $0.name.lowercased() == needle }
        if byName.count == 1 { return byName[0] }
        let byID = library.groups.filter { $0.id.uuidString.lowercased().hasPrefix(needle) }
        if needle.count >= 4, byID.count == 1 { return byID[0] }
        if byName.count > 1 || byID.count > 1 { throw AgentError.invalid("more than one group matches \(ref). Use its id from `expansionlens groups list`") }
        throw AgentError.notFound("no group with id or name \(ref). Run `expansionlens groups list`")
    }

    static func absolutePath(_ path: String) throws -> String {
        guard path.hasPrefix("/") else { throw AgentError.usage("\(path) isn't an absolute path. Give the full path, starting with /") }
        return path
    }

    // MARK: Results

    static let typeNames: [(name: String, type: ContentType)] = [
        ("plain", .plainText), ("formatted", .formattedText), ("applescript", .appleScript), ("shell", .shellScript), ("javascript", .javaScript),
    ]

    static func typeName(_ type: ContentType) -> String { typeNames.first { $0.type == type }?.name ?? type.rawValue }

    static func contentType(_ name: String) throws -> ContentType {
        guard let match = typeNames.first(where: { $0.name == name.lowercased() || $0.type.rawValue.lowercased() == name.lowercased() }) else {
            throw AgentError.usage("--type must be one of \(typeNames.map(\.name).joined(separator: ", "))")
        }
        return match.type
    }

    static let sorts: [(name: String, sort: MainModel.Sort)] = [
        ("label", .label), ("abbreviation", .abbreviation), ("content", .content), ("modified", .modified), ("uses", .uses),
    ]

    static func stateName(_ state: ExpansionEngine.State) -> String {
        switch state {
        case .off: "off"
        case .needsAccessibility: "needs-accessibility"
        case .running: "running"
        case .blockedBySecureInput: "blocked-by-secure-input"
        }
    }

    @MainActor
    static func summary(_ snippet: Snippet) -> JSONObject {
        let library = LibraryStore.shared.library
        let group = library.group(snippet.groupID)
        var result: JSONObject = [
            "id": short(snippet.id), "abbreviation": library.trigger(for: snippet), "name": snippet.displayName,
            "group": group?.name ?? "", "type": typeName(snippet.type), "uses": snippet.useCount,
            "updated": JSON.date(snippet.updatedAt),
            "preview": String(snippet.content.replacingOccurrences(of: "\n", with: " ").prefix(80)),
        ]
        if group?.enabled == false { result["groupEnabled"] = false }
        if let used = snippet.lastUsed { result["lastUsed"] = JSON.date(used) }
        return result
    }

    @MainActor
    static func detail(_ snippet: Snippet) -> JSONObject {
        let library = LibraryStore.shared.library
        var result = summary(snippet)
        result["preview"] = nil
        result["content"] = snippet.content
        result["ownAbbreviation"] = snippet.abbreviation
        result["label"] = snippet.label
        result["groupId"] = short(snippet.groupID)
        result["case"] = snippet.caseMode?.rawValue ?? "default"
        result["created"] = JSON.date(snippet.createdAt)
        result["groupEnabled"] = library.group(snippet.groupID)?.enabled ?? false
        if snippet.type == .formattedText { result["formatted"] = true }
        let fields = FieldCollector.items(for: snippet, in: library)
        if !fields.isEmpty { result["fields"] = fields.map(fieldInfo) }
        let conflicts = Conflict.find(in: library, settings: Preferences.shared.matchSettings).compactMap { conflict -> JSONObject? in
            let other = conflict.snippet == snippet.id ? conflict.other : conflict.other == snippet.id ? conflict.snippet : nil
            guard let other, let o = library.snippets.first(where: { $0.id == other }) else { return nil }
            let mine = conflict.snippet == snippet.id
            return ["with": short(o.id), "abbreviation": library.trigger(for: o),
                    "problem": mine ? "this \(conflict.kind.title) \(library.trigger(for: o))" : "\(library.trigger(for: o)) \(conflict.kind.title) this"]
        }
        if !conflicts.isEmpty { result["conflicts"] = conflicts }
        return result
    }

    @MainActor
    static func groupSummary(_ group: SnippetGroup, in library: Library) -> JSONObject {
        var result: JSONObject = ["id": short(group.id), "name": group.name, "prefix": group.prefix, "enabled": group.enabled,
                                  "snippets": library.snippets(in: group.id).count]
        if !group.notes.isEmpty { result["notes"] = group.notes }
        if group.scope.mode != .all { result["apps"] = "\(group.scope.mode.rawValue): \(group.scope.bundleIDs.joined(separator: ", "))" }
        return result
    }

    static func fieldInfo(_ item: FieldCollector.Item) -> JSONObject {
        switch item {
        case .field(let field):
            var result: JSONObject = ["name": field.name, "kind": field.kind.rawValue, "default": field.defaultValue]
            if !field.options.isEmpty { result["options"] = field.options }
            return result
        case .optional(let name, let include, _):
            return ["name": name, "kind": "optional", "default": include]
        case .conditional(let name, let defaultBranch, let branches):
            return ["name": name, "kind": "conditional", "default": defaultBranch, "branches": branches]
        }
    }

    @MainActor
    static func page<T>(_ items: [T], _ args: Args, key: String, _ transform: (T) -> JSONObject) throws -> JSONObject {
        let limit = try args.int("limit", default: 50), offset = try args.int("offset", default: 0)
        guard limit > 0, offset >= 0 else { throw AgentError.usage("--limit must be above 0 and --offset 0 or more") }
        let slice = items.dropFirst(offset).prefix(limit)
        var result: JSONObject = [key: slice.map(transform), "total": items.count]
        if offset + slice.count < items.count { result["nextOffset"] = offset + slice.count }
        return result
    }

    // MARK: Doing things

    @MainActor
    static func setExpansion(_ on: Bool) throws -> JSONObject {
        let prefs = Preferences.shared
        let changed = prefs.enabled != on
        if changed { prefs.enabled = on }
        let state = ExpansionEngine.shared.state
        var result: JSONObject = ["enabled": prefs.enabled, "changed": changed, "engine": stateName(state)]
        if on, state == .needsAccessibility {
            result["hint"] = "ExpansionLens needs Accessibility permission to expand. Ask the person to allow it in System Settings › Privacy & Security"
        }
        return result
    }

    /// The editor's preview, with fill-in values from --fields. No scripts run, and nothing is typed.
    @MainActor
    static func expand(_ snippet: Snippet, fields json: String?) throws -> JSONObject {
        let library = LibraryStore.shared.library
        if snippet.type.isScript {
            return ["id": short(snippet.id), "abbreviation": library.trigger(for: snippet), "text": "", "script": typeName(snippet.type),
                    "note": "script snippets only run when they expand, so there's no text to show. `expansionlens snippets show` gives the script"]
        }
        let items = FieldCollector.items(for: snippet, in: library)
        var values = FieldValues()
        if let json {
            guard let given = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? JSONObject else {
                throw AgentError.usage("--fields must be a JSON object, like {\"Name\":\"Alex\"}")
            }
            for (name, value) in given {
                guard let item = items.first(where: { $0.name == name }) else {
                    throw AgentError.usage("\(short(snippet.id)) has no fill-in called \"\(name)\". It has: \(items.map(\.name).joined(separator: ", "))")
                }
                switch item {
                case .field:
                    values.text[name] = "\(value)"
                case .optional:
                    guard let on = value as? Bool else { throw AgentError.usage("\"\(name)\" is an optional part: give true or false") }
                    values.optionals[name] = on
                case .conditional(_, _, let branches):
                    if let index = value as? Int, branches.indices.contains(index) {
                        values.branches[name] = index
                    } else if let branch = value as? String, let index = branches.firstIndex(of: branch) {
                        values.branches[name] = index
                    } else {
                        throw AgentError.usage("\"\(name)\" is a choice of \(branches.joined(separator: ", ")): give one of those or its number from 0")
                    }
                }
            }
        }
        let expansion = Renderer(library: library, clipboard: clipboardText(), values: values).render(snippet)
        var keys: [String] = []
        for piece in expansion.pieces {
            switch piece {
            case .text: break
            case .key(let key): keys.append(key.rawValue)
            case .delay(let ms): keys.append("delay \(ms) ms")
            case .cursor: keys.append("cursor")
            case .selectEnd: keys.append("select-end")
            }
        }
        var result: JSONObject = ["id": short(snippet.id), "abbreviation": library.trigger(for: snippet), "text": expansion.text]
        if !keys.isEmpty { result["keys"] = keys }
        if !items.isEmpty { result["fields"] = items.map(fieldInfo) }
        if !expansion.errors.isEmpty { result["errors"] = expansion.errors }
        return result
    }

    /// The clipboard, for %clipboard. Something a password manager marked as concealed stays out.
    @MainActor
    static func clipboardText() -> String {
        let board = NSPasteboard.general
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        guard !(board.types ?? []).contains(concealed) else { return "" }
        return board.string(forType: .string) ?? ""
    }
}
