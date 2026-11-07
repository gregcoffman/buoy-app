import BuoyCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            NotificationSettings().tabItem { Label("Notifications", systemImage: "bell") }
            DataSettings().tabItem { Label("Data", systemImage: "externaldrive") }
            AgentSettings().tabItem { Label("Agent", systemImage: "sparkles") }
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Picker("Quick Entry shortcut", selection: $store.hotKey) {
                ForEach(HotKeyPreset.allCases) { Text($0.label).tag($0) }
            }
            if store.hotKeyRegistered {
                Text("Opens a capture window from any app.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(store.hotKey.label) is already used by another app or by macOS (System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Input Sources). Pick another shortcut or free that one up.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Toggle("Show Buoy in the menu bar", isOn: $store.showMenuBarIcon)
            LaunchAtLoginToggle()
        }
        .formStyle(.grouped)
    }
}

/// Keeps Buoy running after a restart, so the shortcut, menu bar and notifications keep working.
/// The system's login-item state is the source of truth; nothing is stored in Buoy's database.
private struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?
    private let available = Bundle.main.bundleURL.pathExtension == "app"

    var body: some View {
        Toggle("Open Buoy at login", isOn: Binding(get: { enabled }, set: set))
            .disabled(!available)
        if let error {
            Text(error).font(.caption).foregroundStyle(.orange)
        } else if SMAppService.mainApp.status == .requiresApproval {
            HStack {
                Text("Allow Buoy in System Settings ▸ General ▸ Login Items.")
                    .font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    .controlSize(.small)
            }
        } else {
            Text("Keeps the ⌃Space shortcut, menu bar and notifications working after a restart.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Couldn't change this: \(error.localizedDescription) Login items work best when Buoy is in /Applications (scripts/build-app.sh --install)."
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}

private struct NotificationSettings: View {
    @Environment(AppStore.self) private var store
    @Environment(NotificationStatus.self) private var status

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Notifications", isOn: $store.notificationPreferences.enabled)
                if status.denied {
                    HStack {
                        Text("Notifications are turned off for Buoy in System Settings.")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                        .controlSize(.small)
                    }
                }
                if !status.available {
                    Text("Notifications are only available when Buoy runs as an app bundle (build with scripts/build-app.sh).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Notify me when") {
                Toggle("A task rises into Today", isOn: $store.notificationPreferences.whenActive)
                Toggle("A task is due", isOn: $store.notificationPreferences.whenDue)
                Toggle("A snoozed task comes back", isOn: $store.notificationPreferences.whenSnoozeEnds)
                Toggle("Your agent hands in work for review", isOn: $store.notificationPreferences.whenReview)
            }
            .disabled(!store.notificationPreferences.enabled)
            Section {
                DatePicker("Deliver at", selection: Binding(
                    get: {
                        LocalDate.today().at(hour: store.notificationPreferences.hour, minute: store.notificationPreferences.minute)
                    },
                    set: { date in
                        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                        store.notificationPreferences.hour = c.hour ?? 9
                        store.notificationPreferences.minute = c.minute ?? 0
                    }
                ), displayedComponents: .hourAndMinute)
            } footer: {
                Text("Date-based notifications arrive at this time. Several at once are combined into one, and Today stays the place to see everything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!store.notificationPreferences.enabled)
        }
        .formStyle(.grouped)
        .task { await status.refresh() }
    }
}

/// The key agents put in buoy:// links.
private struct AgentSettings: View {
    @Environment(AppStore.self) private var store
    @State private var confirmingNewKey = false
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Link key") {
                    Text(store.agentKey)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                HStack {
                    Button(copied ? "Copied" : "Copy Key") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(store.agentKey, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    Button("New Key…") { confirmingNewKey = true }
                }
                Text("An agent can add and change tasks with buoy:// links (see URL_SCHEME.md). Every link must include key=\u{2026} with this key; links without it are ignored, so a web page can't change your tasks. Anything an agent adds is marked with \(Image(systemName: "sparkles")).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Review new tasks and projects from agents", isOn: Binding(get: { store.reviewAgentTasks }, set: { store.reviewAgentTasks = $0 }))
                Text("When on, tasks and projects an agent adds wait at the top of Today until you accept or dismiss them. When off, they go straight to your lists and the board.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Deleted by agents") {
                let tasks = store.deletedTasks, notes = store.deletedNotes
                if tasks.isEmpty && notes.isEmpty {
                    Text("Nothing. Anything an agent deletes is kept here for 30 days.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tasks) { task in
                        DeletedRow(icon: task.isProject ? "rectangle.split.3x1" : "checkmark.square",
                                   title: task.title, deletedAt: task.deletedAt) { store.restoreDeleted(task.id) }
                    }
                    ForEach(notes) { note in
                        DeletedRow(icon: "note.text", title: note.firstLine, deletedAt: note.deletedAt) { store.restoreDeleted(note.id) }
                    }
                    Text("Kept for 30 days after deletion, then removed for good.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Make a new key?", isPresented: $confirmingNewKey) {
            Button("Cancel", role: .cancel) {}
            Button("New Key") { store.regenerateAgentKey() }
        } message: {
            Text("Links using the current key will stop working until the agent has the new one.")
        }
    }
}

private struct DeletedRow: View {
    @Environment(AppStore.self) private var store
    let icon: String
    let title: String
    let deletedAt: Date?
    let restore: () -> Void

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            Text(title.isEmpty ? "Untitled" : title).lineLimit(1)
            Spacer()
            if let deletedAt {
                Text(Formatters.day(LocalDate(deletedAt), today: store.today))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Restore", action: restore)
        }
    }
}

private struct DataSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            Section {
                LabeledContent("Location") {
                    Text(store.storage?.databaseURL.path ?? "—")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Show in Finder") {
                        if let url = store.storage?.databaseURL {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    Spacer()
                }
            } footer: {
                Text("Your tasks are stored only on this Mac in a standard SQLite database. No account, no cloud, no tracking.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Back Up…") { BackupUI.backup(store) }
                    Button("Restore from Backup…") { BackupUI.restore(store) }
                    Spacer()
                    Button("Show Backups Folder") {
                        if let dir = store.storage?.backupsDirectory {
                            NSWorkspace.shared.open(dir)
                        }
                    }
                }
            } header: {
                Text("Backups")
            } footer: {
                Text("Buoy keeps a daily automatic backup (the last 14) and saves a copy before every upgrade or restore. A backup is a single file you can copy to another Mac and restore there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Whether the system lets Buoy post notifications.
@MainActor
@Observable
final class NotificationStatus {
    var denied = false
    var available = Bundle.main.bundleURL.pathExtension == "app"

    func refresh() async {
        guard available else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        denied = settings.authorizationStatus == .denied
    }
}

/// Save / open panels for backup and restore.
@MainActor
enum BackupUI {
    static func backup(_ store: AppStore) {
        let panel = NSSavePanel()
        panel.title = "Back Up Buoy"
        panel.nameFieldStringValue = Storage.suggestedBackupName()
        panel.allowedContentTypes = [.init(filenameExtension: Storage.backupExtension) ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.backup(to: url)
    }

    static func restore(_ store: AppStore) {
        let panel = NSOpenPanel()
        panel.title = "Restore Buoy Backup"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = store.storage?.backupsDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let summary: String
        do {
            let info = try Storage.validateBackup(at: url)
            summary = "This backup contains \(info.taskCount) tasks."
        } catch {
            let alert = NSAlert()
            alert.messageText = "Can't restore this file"
            alert.informativeText = "\(error)"
            alert.runModal()
            return
        }

        let confirm = NSAlert()
        confirm.messageText = "Replace all current tasks with this backup?"
        confirm.informativeText = "\(summary) Your current data will be saved to the Backups folder first, so you can switch back."
        confirm.addButton(withTitle: "Restore")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        store.restore(from: url)
    }
}
