import AppKit
import ExpansionLensKit
import SwiftUI

// `expansionlens <command>` (the app binary under a short name): run it against the running app
// and exit, without starting a second copy. See Agent/AgentCLI.swift.
if let code = AgentCLI.runIfRequested() { exit(code) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // An agent CLI test copy stays out of the Dock.
    app.setActivationPolicy(AppPresence.showInDock && !AgentSocket.isTestRun ? .regular : .accessory)
    app.run()
}

/// Quits ExpansionLens without asking: for quitting itself (installing an update, ending a test).
@MainActor
enum QuitConfirmation {
    private(set) static var confirmed = false

    static func quitNow() {
        confirmed = true
        NSApp.terminate(nil)
    }
}

/// Launch, the menu bar item, the Dock menu, URLs and shortcuts.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var maintenanceTimer: Timer?

    /// Quitting asks first, while "Ask before quitting" is on in Settings › General. Not when
    /// the Mac is logging out, restarting or shutting down (macOS gives the quit a reason
    /// then), and not when ExpansionLens quits itself to install an update.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        guard Preferences.shared.confirmQuit, !QuitConfirmation.confirmed, !systemQuit else { return .terminateNow }

        // A menu bar app needs to be a regular one for the alert to come to the front; the
        // old policy goes back a runloop turn later, once the alert is gone (AppKit ignores
        // it while the modal still holds the app active).
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { DispatchQueue.main.async { NSApp.setActivationPolicy(previousPolicy) } }

        let alert = NSAlert()
        alert.messageText = "Quit \(AppInfo.name)?"
        alert.informativeText = "Abbreviations stop expanding until you open \(AppInfo.name) again."
        // NSAlert puts a Cancel button on Esc, and Quit has no key, so Return does nothing:
        // quitting takes a click on Quit, never a stray keystroke.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit").keyEquivalent = ""
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        alert.layout()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)

        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        if alert.suppressionButton?.state == .on { Preferences.shared.confirmQuit = false }
        return .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = mainMenu()
        AppAppearance.start()
        #if DEBUG
        // A test run of the agent CLI (APP_STORE): its own library and settings, and the agent
        // socket. Nothing else starts: no expansion (event tap), shortcuts, sync, menu bar item,
        // ToolHUD menu hub, ShortcutsLens report, PasteLens announcements or updater.
        if AgentSocket.isTestRun {
            _ = LibraryStore.shared
            AgentSocket.listen { AgentRouter.handle($0) }
            return
        }
        // A test run shares the installed app's settings, so it checks Help and stops
        // before sync or anything else starts.
        if let snapshot = ProcessInfo.processInfo.environment["EXPANSIONLENS_DEBUG_HELP_TEST"] {
            DebugHelpTest.run(snapshot: snapshot, delegate: self)
            return
        }
        if let how = ProcessInfo.processInfo.environment["EXPANSIONLENS_DEBUG_QUIT_TEST"] {
            DebugQuitTest.run(how)
            return
        }
        #if !APPSTORE
        // The update prompt, What's New and Settings drawn to PNGs; also starts nothing else.
        if let folder = ProcessInfo.processInfo.environment["EXPANSIONLENS_DEBUG_UPDATE_NOTES"] {
            DebugUpdateNotes.run(folder: folder)
            return
        }
        #endif
        #endif
        let newInstall = !AppDefaults.store.bool(forKey: "welcomed")

        _ = LibraryStore.shared
        // `expansionlens` and its MCP server talk to the app through this.
        AgentSocket.listen { AgentRouter.handle($0) }
        HotKeyCenter.shared.perform = { [weak self] action in self?.perform(action) }
        ExpansionEngine.shared.start()
        ShortcutsLensReport.start { HotKeyCenter.shared.reportedShortcuts }
        SyncEngine.shared.start()
        PasteLensBridge.shared.start()
        setUpStatusItem()

        // ToolHUD can take the menu into its own while it runs.
        NotificationCenter.default.addObserver(forName: AppPresence.menuBarDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.statusItem?.isVisible = MenuHub.shared.showsOwnIcon }
        }
        MenuHub.shared.start(menu: { [weak self] in
            let menu = NSMenu()
            self?.menuNeedsUpdate(menu)
            return menu
        }, icon: { [weak self] in
            self?.updateStatusIcon()
            return self?.statusItem?.button?.image
        })
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SyncEngine.shared.pull() }
        }
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { LibraryStore.shared.pruneTombstones() }
        }
        withObservationTracking({ _ = Preferences.shared.enabled }, onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.enabledChanged() } }
        })
        // ToolHUD lights its expansion buttons to match.
        ToolHUDFeatureStates.start {
            let on = Preferences.shared.enabled
            return ["toggle": on, "on": on, "off": !on]
        }

        #if !APPSTORE
        // Test copies (with their own data folder) leave updates to the real app.
        if ProcessInfo.processInfo.environment["EXPANSIONLENS_DATA_FOLDER"] == nil { AutoUpdater.shared.start() }
        #endif
        if newInstall {
            AppDefaults.store.set(true, forKey: "welcomed")
            WelcomeWindow.shared.show()
        } else if !AppPresence.showInMenuBar && !AppPresence.showInDock {
            SettingsWindow.shared.show()
        }
        DebugHooks.runIfRequested()
    }

    /// Expansion was turned on or off (menu, shortcut, Settings, toolbar).
    private func enabledChanged() {
        updateStatusIcon()
        PasteLensBridge.shared.announce()
        ToolHUDFeatureStates.publish()
        withObservationTracking({ _ = Preferences.shared.enabled }, onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.enabledChanged() } }
        })
    }

    /// CloudKit says another Mac changed something.
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        SyncEngine.shared.pull()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppActivity.touch()
        SyncEngine.shared.pull()
    }

    func applicationWillTerminate(_ notification: Notification) {
        LibraryStore.shared.saveNow()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = AppPresence.dockMenu(title: "Settings…", target: self, action: #selector(showSettings))
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(item("Quick Search", #selector(quickSearch)), at: 0)
        menu.insertItem(item("Open ExpansionLens", #selector(showMain)), at: 0)
        return menu
    }

    /// Opening the app again (from Applications, Spotlight, or the Dock tile) shows the library.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !AppPresence.showInMenuBar && !AppPresence.showInDock { SettingsWindow.shared.show() } else { MainWindow.shared.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// expansionlens:// URLs: quicksearch, open, new, newfromclipboard, editlast, toggle, on, off, settings.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "expansionlens" {
            switch url.host {
            case "quicksearch", "search": QuickSearchPanel.shared.show()
            case "new": MainWindow.shared.newSnippet()
            case "newfromclipboard": MainWindow.shared.newFromClipboard()
            case "editlast": MainWindow.shared.editLast()
            case "toggle": ExpansionEngine.shared.toggle()
            case "on": Preferences.shared.enabled = true
            case "off": Preferences.shared.enabled = false
            case "settings": SettingsWindow.shared.show()
            default: MainWindow.shared.show()
            }
        }
    }

    private func perform(_ action: HotKeyAction) {
        switch action {
        case .toggleExpansion: ExpansionEngine.shared.toggle()
        case .quickSearch: QuickSearchPanel.shared.toggle()
        case .openMain: MainWindow.shared.show()
        case .newSnippet: MainWindow.shared.newSnippet()
        case .newFromClipboard: MainWindow.shared.newFromClipboard()
        case .editLast: MainWindow.shared.editLast()
        }
    }

    // MARK: Menus

    private func mainMenu() -> NSMenu {
        let menu = AppPresence.mainMenu(appName: AppInfo.name, settingsTitle: "Settings…", target: self, settings: #selector(showSettings))
        // Right below About in the app menu.
        if let appMenu = menu.items.first?.submenu {
            var index = 1
            #if !APPSTORE
            appMenu.insertItem(item("Check for Updates…", #selector(checkForUpdates)), at: index)
            index += 1
            #endif
            appMenu.insertItem(item("Our other apps…", #selector(showOtherApps)), at: index)
        }
        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(item("New Snippet", #selector(newSnippet), key: "n"))
        file.addItem(item("New Snippet from Clipboard", #selector(newFromClipboard), key: "N"))
        file.addItem(.separator())
        file.addItem(item("Import from Other Apps…", #selector(importFromApps)))
        file.addItem(item("Import File…", #selector(importFile)))
        file.addItem(item("Export Snippets…", #selector(exportSnippets)))
        fileItem.submenu = file
        menu.insertItem(fileItem, at: 1)
        // Edit menu, so text fields get copy, paste and undo.
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.insertItem(editItem, at: 2)
        let format = NSMenuItem()
        format.submenu = NSFontManager.shared.fontMenu(true)
        format.submenu?.title = "Format"
        // Help menu, with the standard ⌘? (macOS adds its search field).
        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        let helpOpen = NSMenuItem(title: "ExpansionLens Help", action: #selector(showHelp), keyEquivalent: "?")
        helpOpen.target = self
        help.addItem(helpOpen)
        helpItem.submenu = help
        menu.addItem(helpItem)
        NSApp.helpMenu = help
        menu.insertItem(format, at: 3)
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.isVisible = MenuHub.shared.showsOwnIcon
        statusItem = item
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let on = Preferences.shared.enabled
        let image = NSImage(systemSymbolName: on ? "text.cursor" : "text.badge.xmark", accessibilityDescription: "ExpansionLens")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.appearsDisabled = !on
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = Preferences.shared
        let engine = ExpansionEngine.shared
        switch engine.state {
        case .needsAccessibility:
            menu.addItem(item("Allow Accessibility to Expand…", #selector(allowAccessibility)).showIcon("exclamationmark.triangle"))
        case .blockedBySecureInput(let app):
            let blocked = NSMenuItem(title: "Expansion Blocked (\(app ?? "Secure Input"))", action: nil, keyEquivalent: "")
            blocked.isEnabled = false
            menu.addItem(blocked)
        default: break
        }
        if PasteLensBridge.shared.conflict {
            menu.addItem(item("PasteLens Is Also Expanding — Turn It Off", #selector(turnOffPasteLens)).showIcon("exclamationmark.triangle"))
        }
        let toggle = item(prefs.enabled ? "Turn Off Expansion" : "Turn On Expansion", #selector(toggleExpansion))
        setKey(toggle, .toggleExpansion)
        menu.addItem(toggle.showIcon(prefs.enabled ? "text.badge.xmark" : "text.cursor"))
        menu.addItem(.separator())
        let search = item("Quick Search…", #selector(quickSearch))
        setKey(search, .quickSearch)
        menu.addItem(search.showIcon("magnifyingglass"))
        let snippets = NSMenuItem(title: "Insert Snippet", action: nil, keyEquivalent: "")
        snippets.submenu = snippetsMenu()
        menu.addItem(snippets)
        menu.addItem(.separator())
        let open = item("Open ExpansionLens", #selector(showMain))
        setKey(open, .openMain)
        menu.addItem(open.showIcon("macwindow"))
        let new = item("New Snippet", #selector(newSnippet))
        setKey(new, .newSnippet)
        menu.addItem(new.showIcon("square.and.pencil"))
        let fromClipboard = item("New Snippet from Clipboard", #selector(newFromClipboard))
        setKey(fromClipboard, .newFromClipboard)
        menu.addItem(fromClipboard)
        let last = item("Edit Last Expanded", #selector(editLast))
        setKey(last, .editLast)
        last.isEnabled = LibraryStore.shared.lastExpanded != nil
        menu.addItem(last)
        menu.addItem(.separator())
        menu.addItem(item("Import from Other Apps…", #selector(importFromApps)))
        menu.addItem(item("Import File…", #selector(importFile)))
        menu.addItem(.separator())
        let helpEntry = NSMenuItem(title: "ExpansionLens Help", action: #selector(showHelp), keyEquivalent: "")
        helpEntry.target = self
        helpEntry.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        menu.addItem(helpEntry)
        menu.addItem(item("Settings…", #selector(showSettings), key: ",").showIcon("gearshape"))
        #if !APPSTORE
        menu.addItem(updateItem().showIcon("arrow.down.circle"))
        #endif
        menu.addItem(item("About ExpansionLens", #selector(showAbout)))
        menu.addItem(item("Our other apps…", #selector(showOtherApps)))
        menu.addItem(.separator())
        let version = NSMenuItem(title: "ExpansionLens \(AppInfo.displayVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(item("Quit ExpansionLens", #selector(quit), key: "q"))
    }

    private func setKey(_ menuItem: NSMenuItem, _ action: HotKeyAction) {
        guard let key = Preferences.shared.hotKey(action)?.menuKeyEquivalent, !key.key.isEmpty else { return }
        menuItem.keyEquivalent = key.key
        menuItem.keyEquivalentModifierMask = key.mask
    }

    /// Groups, each with its snippets; choosing one inserts it into the front app.
    private func snippetsMenu() -> NSMenu {
        let menu = NSMenu()
        let library = LibraryStore.shared.library
        for group in library.sortedGroups where group.enabled {
            let sub = NSMenu()
            for snippet in library.snippets(in: group.id).sorted(by: { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }).prefix(100) {
                let i = NSMenuItem(title: "\(snippet.displayName)  \(library.trigger(for: snippet))", action: #selector(insertFromMenu(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = snippet.id
                sub.addItem(i)
            }
            let groupItem = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
            groupItem.submenu = sub
            menu.addItem(groupItem)
        }
        if menu.items.isEmpty { menu.addItem(withTitle: "No snippets", action: nil, keyEquivalent: "") }
        return menu
    }

    @objc private func insertFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let snippet = LibraryStore.shared.snippet(id) else { return }
        // The menu closes first, then the app underneath has focus again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Inserter.shared.insert(snippet) }
    }

    @objc private func toggleExpansion() { ExpansionEngine.shared.toggle() }
    @objc private func quickSearch() { QuickSearchPanel.shared.show() }
    @objc private func showMain() { MainWindow.shared.show() }
    @objc private func newSnippet() { MainWindow.shared.newSnippet() }
    @objc private func newFromClipboard() { MainWindow.shared.newFromClipboard() }
    @objc private func editLast() { MainWindow.shared.editLast() }
    @objc private func importFromApps() { Importer.importFromApps() }
    @objc private func importFile() { Importer.importFile() }
    @objc private func exportSnippets() { Importer.export() }
    @objc private func showSettings() { SettingsWindow.shared.show() }
    @objc func showHelp() { HelpWindow.shared.show() }
    @objc private func turnOffPasteLens() { PasteLensBridge.askPasteLensToStopExpanding() }
    @objc private func allowAccessibility() { ExpansionEngine.requestAccess(); ExpansionEngine.openAccessibilitySettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    #if !APPSTORE
    @objc private func installUpdate() { AutoUpdater.shared.installNow() }
    @objc private func checkForUpdates() { UpdateController.checkForUpdates() }
    /// The developer's site, which lists every app.
    @objc private func showOtherApps() {
        if let url = URL(string: "https://stevemanke.com/") { NSWorkspace.shared.open(url) }
    }
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        AppInfo.showAbout()
    }

    /// Check for Updates, or what's waiting when an update is already known.
    private func updateItem() -> NSMenuItem {
        if let staged = AutoUpdater.shared.staged {
            return item("Update to \(staged.version) Now (Otherwise Installs When Idle)", #selector(installUpdate))
        } else if let pending = UpdateAvailability.shared.pending {
            return item("Update to \(pending)…", #selector(checkForUpdates))
        }
        return item("Check for Updates…", #selector(checkForUpdates))
    }
    #endif
}
