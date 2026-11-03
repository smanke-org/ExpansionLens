import Foundation

/// Where ExpansionLens keeps its settings. Normally the app's own defaults; a test copy can be
/// given a separate store (EXPANSIONLENS_DEFAULTS_SUITE), so two copies on one Mac behave like two Macs.
/// An agent CLI test copy (a Debug build run with `APP_STORE=<folder>`) gets its own store too.
enum AppDefaults {
    static let store: UserDefaults = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["EXPANSIONLENS_DEFAULTS_SUITE"] == nil, AgentSocket.isTestRun,
           let separate = UserDefaults(suiteName: agentTestSuite) {
            return separate
        }
        #endif
        if let suite = ProcessInfo.processInfo.environment["EXPANSIONLENS_DEFAULTS_SUITE"], let separate = UserDefaults(suiteName: suite) {
            return separate
        }
        return .standard
    }()

    /// The settings of an agent CLI test copy (APP_STORE), apart from the real app's.
    static let agentTestSuite = "com.smanke.ExpansionLens.agenttest"
}
