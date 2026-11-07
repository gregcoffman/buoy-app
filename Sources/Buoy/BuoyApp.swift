import AppKit
import BuoyCore
import SwiftUI

@main
struct BuoyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        let store = appDelegate.store

        Window("Buoy", id: "main") {
            RootView()
                .environment(store)
        }
        .defaultSize(width: 960, height: 620)
        // buoy:// links are handled by the app delegate; they shouldn't open a window.
        .handlesExternalEvents(matching: [])
        .commands { BuoyCommands(store: store, quickEntry: appDelegate.quickEntry) }

        Settings {
            SettingsView()
                .environment(store)
                .environment(appDelegate.notificationStatus)
        }

        MenuBarExtra(isInserted: Binding(get: { store.showMenuBarIcon }, set: { store.showMenuBarIcon = $0 })) {
            MenuBarView()
                .environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    let store: AppStore

    var body: some View {
        let count = store.todayCount
        if count > 0 {
            Label("\(count)", systemImage: "lifepreserver")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "lifepreserver")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AppStore()
    let notificationStatus = NotificationStatus()
    private(set) lazy var quickEntry = QuickEntryPanelController(store: store)
    private lazy var notifications = NotificationScheduler(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched as a bare executable (swift run), become a regular foreground app.
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }

        HotKeyCenter.shared.action = { [weak self] in
            Task { @MainActor in self?.quickEntry.toggle() }
        }
        store.hotKeyRegistered = HotKeyCenter.shared.register(store.hotKey)
        store.onHotKeyChange = { [weak self] in self?.store.hotKeyRegistered = HotKeyCenter.shared.register($0) }

        store.onTasksChanged = { [weak self] in self?.notifications.setNeedsReschedule() }
        store.onHandedIn = { [weak self] project in self?.notifications.notifyReview(project) }

        // Text fields sit on raised cards; stop the shared field editor painting its own
        // (darker) background over them while editing.
        NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { note in
            if let editor = note.object as? NSTextView, editor.isFieldEditor, editor.drawsBackground {
                editor.drawsBackground = false
            }
        }
        notifications.setNeedsReschedule()

        #if DEBUG
        DebugSnapshots.runIfRequested(store: store, quickEntry: quickEntry)
        #endif
    }

    /// buoy:// links from agents (also delivered when the link launched Buoy).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { AgentLinkHandler.handle(url, store: store) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Stay alive for the menu bar, the global shortcut, and notifications.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { store.openMainWindow?() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        store.tick()
    }
}

// MARK: Menus

struct BuoyCommands: Commands {
    let store: AppStore
    let quickEntry: QuickEntryPanelController

    private var undoManager: UndoManager? { NSApp.keyWindow?.undoManager }
    private var selected: [UUID] { Array(store.selection) }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(store.route == .notes ? "New Note" : store.route == .projects ? "New Project" : "New Task") {
                store.openMainWindow?()
                store.startComposing()
            }
            .keyboardShortcut("n")
            Button("New Note") {
                store.openMainWindow?()
                store.startNote()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Quick Entry…") { quickEntry.show() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandGroup(after: .saveItem) {
            Divider()
            Button("Back Up Database…") { BackupUI.backup(store) }
            Button("Restore from Backup…") { BackupUI.restore(store) }
        }

        CommandGroup(before: .sidebar) {
            // In sidebar order.
            Button("The Bridge") { store.route = .bridge }.keyboardShortcut("1")
            Button("Today") { store.route = .today }.keyboardShortcut("2")
            Button("Upcoming") { store.route = .upcoming }.keyboardShortcut("3")
            Button("Later") { store.route = .later }.keyboardShortcut("4")
            Button("Logbook") { store.route = .logbook }.keyboardShortcut("5")
            Button("Delegated") { store.route = .projects }.keyboardShortcut("6")
            Button("Notes") { store.route = .notes }.keyboardShortcut("7")
            Button("Search") { store.focusSearchRequest += 1 }.keyboardShortcut("f")
            Divider()
        }

        CommandMenu("Notes") {
            Button("Copy All & Archive") { store.copyAllAndArchive(undoManager: undoManager) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(store.activeNoteCount == 0)
        }

        CommandMenu("Task") {
            Button("Complete") { store.complete(selected, undoManager: undoManager) }
                .keyboardShortcut("k")
                .disabled(store.selection.isEmpty)
            Menu("Snooze") {
                Button("Later Today") { store.snooze(selected, .laterToday, undoManager: undoManager) }
                Button("Tomorrow") { store.snooze(selected, .tomorrow, undoManager: undoManager) }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button("This Weekend") { store.snooze(selected, .thisWeekend, undoManager: undoManager) }
                Button("Next Week") { store.snooze(selected, .nextWeek, undoManager: undoManager) }
                Divider()
                Button("Pick a Date…") { store.snoozePicker = SnoozeTargets(ids: selected) }
            }
            .disabled(store.selection.isEmpty)
            Button("Move to Today") { store.surface(selected, undoManager: undoManager) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(store.selection.isEmpty)
            Button("Move to Later") { store.moveToLater(selected, undoManager: undoManager) }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(store.selection.isEmpty)
            Divider()
            Button(store.expandedTaskID == nil ? "Open Task" : "Close Task") { store.toggleExpanded() }
                .keyboardShortcut("i")
            Button("Skip This Occurrence") { store.skip(selected, undoManager: undoManager) }
                .disabled(!selected.contains { store.task($0)?.recurrence != nil })
            Divider()
            // No key equivalent: ⌘⌫ must keep working inside text fields. The list handles Delete.
            Button("Delete") { store.delete(selected, undoManager: undoManager) }
                .disabled(store.selection.isEmpty)
        }
    }
}
