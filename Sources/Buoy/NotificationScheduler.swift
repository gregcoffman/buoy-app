import AppKit
import BuoyCore
import UserNotifications

/// Keeps the system's pending notifications in sync with the plan from `NotificationPlanner`.
@MainActor
final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    private weak var store: AppStore?
    private var pending: DispatchWorkItem?
    private var authorizationRequested = false

    /// Notifications need a real app bundle; `swift run` executables don't have one.
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }
    private var center: UNUserNotificationCenter { .current() }

    private enum Action {
        static let complete = "buoy.complete"
        static let snooze = "buoy.snoozeTomorrow"
    }

    private enum Category {
        /// One task: Complete or Snooze right from the banner.
        static let task = "buoy.task"
        /// Several tasks folded together: only snoozing is offered, since completing
        /// tasks you haven't looked at would be a guess.
        static let group = "buoy.group"
    }

    init(store: AppStore) {
        self.store = store
        super.init()
        guard isAvailable else { return }
        center.delegate = self
        let complete = UNNotificationAction(identifier: Action.complete, title: "Complete", options: [])
        let snooze = UNNotificationAction(identifier: Action.snooze, title: "Snooze Until Tomorrow", options: [])
        let snoozeAll = UNNotificationAction(identifier: Action.snooze, title: "Snooze All Until Tomorrow", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.task, actions: [complete, snooze], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.group, actions: [snoozeAll], intentIdentifiers: []),
        ])
    }

    /// Coalesces bursts of changes into one reschedule.
    func setNeedsReschedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.reschedule() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func reschedule() async {
        guard isAvailable, let store else { return }
        let prefs = store.notificationPreferences
        center.removeAllPendingNotificationRequests()
        guard prefs.enabled else { return }

        if !authorizationRequested {
            authorizationRequested = true
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let plan = NotificationPlanner.plan(tasks: store.tasks, now: Date(), preferences: prefs)
        for item in plan {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.body = item.body
            content.sound = .default
            content.threadIdentifier = "buoy"
            content.userInfo = ["taskIDs": item.taskIDs.map(\.uuidString)]
            content.categoryIdentifier = item.taskIDs.count == 1 ? Category.task : Category.group
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: item.fireAt)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: trigger))
        }
    }

    /// Right away: your agent handed a Delegated card in. Clicking it opens the card.
    func notifyReview(_ project: BuoyTask) {
        guard isAvailable, let store, store.notificationPreferences.enabled, store.notificationPreferences.whenReview else { return }
        let content = UNMutableNotificationContent()
        content.title = "Ready for review"
        content.body = project.result.isEmpty ? project.title : "\(project.title): \(project.result)"
        content.sound = .default
        content.threadIdentifier = "buoy.review"
        content.userInfo = ["projectID": project.id.uuidString]
        let request = UNNotificationRequest(identifier: "review-\(project.id.uuidString)", content: content, trigger: nil)
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            try? await center.add(request)
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus? {
        guard isAvailable else { return nil }
        return await center.notificationSettings().authorizationStatus
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let ids = (response.notification.request.content.userInfo["taskIDs"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
        let projectID = (response.notification.request.content.userInfo["projectID"] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier
        await MainActor.run {
            guard let store = self.store else { return }
            store.tick()
            if let projectID {
                store.openProject(projectID)
                NSApp.activate(ignoringOtherApps: true)
                store.openMainWindow?()
                return
            }
            switch action {
            case Action.complete:
                store.complete(ids, undoManager: nil)
                return
            case Action.snooze:
                store.snooze(ids, .tomorrow, undoManager: nil)
                return
            default:
                break
            }
            store.route = .today
            store.selection = Set(ids)
            NSApp.activate(ignoringOtherApps: true)
            store.openMainWindow?()
        }
    }
}
