import AppKit
import ExpansionLensKit
import IOKit

/// CloudKit's bookkeeping (change token, outbox, saved record fields), kept in
/// SyncState.plist beside the library rather than in UserDefaults, since it can grow.
@MainActor
final class SyncState {
    static let shared = SyncState()
    private var values: [String: Data]
    private let url: URL
    private var saveScheduled = false

    private init() {
        url = LibraryStore.shared.folder.appendingPathComponent("SyncState.plist")
        values = (try? PropertyListDecoder().decode([String: Data].self, from: Data(contentsOf: url))) ?? [:]
    }

    func data(forKey key: String) -> Data? { values[key] }

    func set(_ data: Data?, forKey key: String) throws {
        values[key] = data
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let state = SyncState.shared
                state.saveScheduled = false
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                if let data = try? encoder.encode(state.values) { try? data.write(to: state.url, options: .atomic) }
            }
        }
    }
}

struct SyncFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A stable id for this Mac (a hash of its hardware UUID, never the UUID itself) and its name.
enum DeviceIdentity {
    static let id: String = {
        if let override = ProcessInfo.processInfo.environment["EXPANSIONLENS_DEVICE_ID"] { return override }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        if let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String {
            return String(SyncCrypto.sha256Hex(Data(("ExpansionLens" + uuid).utf8)).prefix(16))
        }
        let key = "deviceID"
        if let saved = AppDefaults.store.string(forKey: key) { return saved }
        let made = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
        AppDefaults.store.set(made, forKey: key)
        return made
    }()

    static var name: String { ProcessInfo.processInfo.environment["EXPANSIONLENS_DEVICE_NAME"] ?? Host.current().localizedName ?? "Mac" }
}

/// When ExpansionLens's own windows were last used, so an automatic update waits.
@MainActor
enum AppActivity {
    private(set) static var lastActive = Date.distantPast
    static func touch() { lastActive = Date() }
}
