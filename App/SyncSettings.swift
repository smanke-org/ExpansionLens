import AppKit
import ExpansionLensKit
import SwiftUI

struct SyncSettings: View {
    @State private var sync = SyncEngine.shared
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var error: String?
    @State private var changing = false
    @State private var confirmDelete = false

    var joining: Bool { sync.keyringExists }
    var ready: Bool {
        if joining { return !passphrase.isEmpty }
        return passphrase.count >= 8 && passphrase == confirm
    }

    var body: some View {
        Form {
            if sync.enabled, sync.status != .needsPassphrase {
                Section {
                    LabeledContent("Status") {
                        HStack {
                            Text(sync.status.summary).foregroundStyle(statusColor)
                            if let last = sync.lastSync { Text("· \(last.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary) }
                        }
                    }
                    LabeledContent("Stored in", value: sync.folderDescription)
                    Button("Sync Now") { sync.pull() }
                }
                Section("Other Macs") {
                    if sync.devices.isEmpty {
                        Text("None yet. Turn on sync on your other Macs with the same passphrase.").foregroundStyle(.secondary)
                    }
                    ForEach(sync.devices) { device in
                        LabeledContent(device.name, value: "seen \(device.lastSeen.formatted(.relative(presentation: .named)))")
                    }
                }
                Section {
                    Text("Snippets, groups and settings sync. Whether expansion is on, suggestions, and the Dock and menu bar choices stay on each Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    if changing {
                        SecureField("New passphrase", text: $passphrase)
                        SecureField("Confirm", text: $confirm)
                        HStack {
                            Button("Cancel") { changing = false; passphrase = ""; confirm = "" }
                            Button("Change Passphrase") { changePassphrase() }.disabled(passphrase.count < 8 || passphrase != confirm)
                        }
                    } else {
                        Button("Change Passphrase…") { changing = true }
                    }
                    Button("Turn Off Sync on This Mac") { sync.turnOff() }
                    Button("Delete Synced Data from iCloud…", role: .destructive) { confirmDelete = true }
                }
            } else {
                setup
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Text("""
                Everything ExpansionLens puts in iCloud is encrypted on this Mac with AES-256-GCM before upload. \
                The key is protected by your sync passphrase (PBKDF2-SHA256, 600,000 rounds), which never leaves your Macs, \
                so Apple can't read your snippets. If you forget the passphrase, delete the synced data and start again; \
                what's on each Mac stays.
                """).font(.caption).foregroundStyle(.secondary)
            } header: { Text("Encryption") }
        }
        .formStyle(.grouped)
        .onAppear { if !sync.enabled || sync.status == .needsPassphrase { sync.probe() } }
        .confirmationDialog("Delete synced data?", isPresented: $confirmDelete) {
            Button("Delete from iCloud", role: .destructive) { sync.deleteCloudData() }
        } message: {
            Text("ExpansionLens's encrypted records are removed from iCloud. Snippets on each Mac stay. Other Macs stop syncing until you set up again.")
        }
    }

    var statusColor: Color {
        switch sync.status {
        case .failed, .unavailable: .red
        default: .primary
        }
    }

    @ViewBuilder var setup: some View {
        Section {
            if case .unavailable(let why) = sync.status {
                Label(why, systemImage: "exclamationmark.icloud").foregroundStyle(.orange)
            }
            Text(joining
                 ? "Another Mac already syncs ExpansionLens. Enter the passphrase you chose there."
                 : "Choose a passphrase. You'll enter the same one on each Mac you want to sync. It isn't stored in iCloud.")
            SecureField("Passphrase", text: $passphrase)
            if !joining {
                SecureField("Confirm passphrase", text: $confirm)
                if !passphrase.isEmpty && passphrase.count < 8 { Text("At least 8 characters.").font(.caption).foregroundStyle(.secondary) }
                else if !confirm.isEmpty && confirm != passphrase { Text("The passphrases don't match.").font(.caption).foregroundStyle(.red) }
            }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(joining ? "Join and Sync" : "Turn On Sync") { setUp() }.disabled(!ready || working).keyboardShortcut(.defaultAction)
            }
        } header: {
            Text("Sync with your other Macs through iCloud")
        }
    }

    func setUp() {
        working = true
        error = nil
        Task {
            do {
                try await sync.setUp(passphrase: passphrase)
                passphrase = ""
                confirm = ""
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }

    func changePassphrase() {
        Task {
            do {
                try await sync.changePassphrase(to: passphrase)
                changing = false
                passphrase = ""
                confirm = ""
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

