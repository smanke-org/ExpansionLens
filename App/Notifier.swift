import AppKit
import ExpansionLensKit
import UserNotifications

/// Notifications other than updates: problems while expanding, new suggestions, the tutor,
/// and PasteLens also expanding abbreviations.
@MainActor
enum Notifier {
    static let suggestionCategory = "suggestion"
    static let pasteLensCategory = "pastelens"
    static let problemCategory = "problem"
    static let createAction = "create"
    static let turnOffAction = "turnOff"

    /// Added beside AutoUpdater's own categories.
    static var categories: [UNNotificationCategory] {
        [
            UNNotificationCategory(identifier: suggestionCategory,
                                   actions: [UNNotificationAction(identifier: createAction, title: "Create Snippet", options: [.foreground])],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: pasteLensCategory,
                                   actions: [UNNotificationAction(identifier: turnOffAction, title: "Turn Off in PasteLens", options: [])],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: problemCategory, actions: [], intentIdentifiers: []),
        ]
    }

    static func problem(_ message: String, snippet: Snippet?) {
        post(id: "problem-\(UUID().uuidString)", title: snippet.map { "\($0.displayName) didn't fully expand" } ?? "Expansion problem",
             body: message, category: problemCategory, info: snippet.map { ["snippet": $0.id.uuidString] } ?? [:])
    }

    static func suggestion(_ suggestion: Suggestion) {
        post(id: "suggestion-\(suggestion.hash)", title: "You type this often",
             body: "“\(suggestion.text.prefix(120))” could be a snippet.", category: suggestionCategory, info: ["hash": suggestion.hash])
    }

    static func tutor(abbreviation: String, label: String) {
        post(id: "tutor-\(abbreviation)", title: "There's a snippet for that", body: "Type \(abbreviation) for “\(label)”.",
             category: problemCategory, info: [:])
    }

    static func pasteLensConflict() {
        post(id: "pastelens-conflict", title: "PasteLens is also expanding abbreviations",
             body: "Both apps would expand the same abbreviations. Turn off abbreviation expansion in PasteLens and keep your snippets here.",
             category: pasteLensCategory, info: [:])
    }

    private static func post(id: String, title: String, body: String, category: String, info: [String: String]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// A click on one of these notifications or their buttons.
    static func handle(category: String, action: String, info: [AnyHashable: Any]) {
        switch category {
        case suggestionCategory:
            MainWindow.shared.show(section: .suggestions)
            if action == createAction, let hash = info["hash"] as? String { MainWindow.shared.createFromSuggestion(hash) }
        case pasteLensCategory:
            if action == turnOffAction { PasteLensBridge.askPasteLensToStopExpanding() } else { SettingsWindow.shared.show(tab: "Expansion") }
        case problemCategory:
            if let id = (info["snippet"] as? String).flatMap(UUID.init) { MainWindow.shared.show(snippet: id) }
        default:
            break
        }
    }
}

/// Keeps ExpansionLens and PasteLens from both expanding abbreviations.
///
/// PasteLens keeps the choice in its own settings (`snippets.expansion`). When it's on and
/// PasteLens is running, ExpansionLens says so once per launch, in a notification whose button
/// asks PasteLens (1.1.1 and later) to turn it off, and in Settings and the menu. Both apps
/// announce changes with distributed notifications, so each notices the other right away.
@Observable
@MainActor
final class PasteLensBridge {
    static let shared = PasteLensBridge()

    nonisolated static let pasteLensID = "com.smanke.PasteLens"
    /// Posted by PasteLens when its expansion setting changes or it launches.
    static let pasteLensChanged = Notification.Name("com.smanke.PasteLens.expansionChanged")
    /// Asks PasteLens to turn its abbreviation expansion off.
    static let disableRequest = Notification.Name("com.smanke.PasteLens.disableExpansion")
    /// Posted by ExpansionLens when it starts or stops expanding.
    static let expansionLensChanged = Notification.Name("com.smanke.ExpansionLens.expansionChanged")

    private(set) var conflict = false
    @ObservationIgnored private var warnedThisLaunch = false
    @ObservationIgnored private var timer: Timer?

    func start() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Self.pasteLensChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PasteLensBridge.shared.check() }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { note in
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard id == PasteLensBridge.pasteLensID else { return }
                // Give it a moment to read its settings.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { PasteLensBridge.shared.check() } }
            }
        }
        // A settings change in an older PasteLens isn't announced; look now and then.
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            MainActor.assumeIsolated { PasteLensBridge.shared.check() }
        }
        announce()
        check()
    }

    /// Tells PasteLens whether ExpansionLens is expanding, so it can warn from its side too.
    func announce() {
        DistributedNotificationCenter.default().postNotificationName(Self.expansionLensChanged, object: nil,
                                                                     userInfo: ["enabled": Preferences.shared.enabled ? "1" : "0"],
                                                                     deliverImmediately: true)
        check()
    }

    static var pasteLensExpanding: Bool {
        // Read straight from PasteLens's preferences, refreshed first so a change made there shows.
        CFPreferencesAppSynchronize(pasteLensID as CFString)
        return (CFPreferencesCopyAppValue("snippets.expansion" as CFString, pasteLensID as CFString) as? Bool) ?? false
    }

    static var pasteLensRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: pasteLensID).isEmpty
    }

    func check() {
        let now = Preferences.shared.enabled && Self.pasteLensRunning && Self.pasteLensExpanding
        if now != conflict { conflict = now }
        if now, !warnedThisLaunch, Preferences.shared.warnPasteLens {
            warnedThisLaunch = true
            Notifier.pasteLensConflict()
        }
    }

    static func askPasteLensToStopExpanding() {
        DistributedNotificationCenter.default().postNotificationName(disableRequest, object: nil, userInfo: nil, deliverImmediately: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                PasteLensBridge.shared.check()
                // An older PasteLens doesn't listen; open it so the switch can be turned off by hand.
                if PasteLensBridge.shared.conflict, let url = URL(string: "pastelens://settings") { NSWorkspace.shared.open(url) }
            }
        }
    }
}
