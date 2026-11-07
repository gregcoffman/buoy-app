import Foundation

public struct NotificationPreferences: Equatable, Sendable {
    public var enabled: Bool
    /// A task rises into Today (Show On arrives or its lead-time window opens).
    public var whenActive: Bool
    /// A task's due date arrives.
    public var whenDue: Bool
    /// A snoozed task comes back.
    public var whenSnoozeEnds: Bool
    /// Your agent hands a Delegated card in to Ready for review (right away, not at `hour`).
    public var whenReview: Bool
    /// Time of day for date-based notifications.
    public var hour: Int
    public var minute: Int

    public init(enabled: Bool = true, whenActive: Bool = true, whenDue: Bool = true,
                whenSnoozeEnds: Bool = true, whenReview: Bool = true, hour: Int = 9, minute: Int = 0) {
        self.enabled = enabled
        self.whenActive = whenActive
        self.whenDue = whenDue
        self.whenSnoozeEnds = whenSnoozeEnds
        self.whenReview = whenReview
        self.hour = hour
        self.minute = minute
    }
}

public struct PlannedNotification: Equatable, Sendable {
    public var id: String
    public var fireAt: Date
    public var title: String
    public var body: String
    public var taskIDs: [UUID]
}

/// Works out which notifications to schedule. To keep noise down, everything
/// that fires at the same moment is folded into a single notification.
public enum NotificationPlanner {
    enum Kind: Int, Comparable {
        case due = 0, snoozeEnded, active
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    struct Event {
        var fireAt: Date
        var kind: Kind
        var task: BuoyTask
    }

    /// macOS keeps at most 64 pending notifications per app.
    public static func plan(
        tasks: [BuoyTask],
        now: Date,
        preferences: NotificationPreferences,
        limit: Int = 60,
        calendar: Calendar = .current
    ) -> [PlannedNotification] {
        guard preferences.enabled else { return [] }
        let today = LocalDate(now, calendar: calendar)
        var events: [Event] = []

        func at(_ day: LocalDate) -> Date {
            day.at(hour: preferences.hour, minute: preferences.minute, calendar: calendar)
        }

        for task in tasks where !task.isCompleted && task.isListed {
            let snoozedUntil = task.snoozedUntil.flatMap { $0 > now ? $0 : nil }
            if let s = snoozedUntil, preferences.whenSnoozeEnds {
                // Day-based snoozes end at midnight; announce them at the usual time instead.
                let day = LocalDate(s, calendar: calendar)
                let fire = s == day.startOfDay(calendar: calendar) ? max(at(day), s) : s
                events.append(Event(fireAt: fire, kind: .snoozeEnded, task: task))
            }

            // Days on which date rules move the task into Today.
            // A task in Later only comes back for its deadline (lead time), not its Show On date.
            let risesOn = task.later ? task.leadStart(calendar: calendar) : Attention.risesOn(task, calendar: calendar)
            let dueOn = task.dueOn

            if preferences.whenDue, let due = dueOn, due >= today {
                let fire = at(due)
                if fire > now && !(snoozedUntil.map { $0 > fire } ?? false) {
                    events.append(Event(fireAt: fire, kind: .due, task: task))
                }
            }
            if preferences.whenActive, let rise = risesOn, rise >= today, rise != dueOn {
                let fire = at(rise)
                if fire > now && !(snoozedUntil.map { $0 > fire } ?? false) {
                    events.append(Event(fireAt: fire, kind: .active, task: task))
                }
            }
        }

        let grouped = Dictionary(grouping: events, by: \.fireAt)
        return grouped.keys.sorted().prefix(limit).map { fireAt in
            var seen = Set<UUID>()
            let group = grouped[fireAt]!
                .sorted { ($0.kind, $0.task.title) < ($1.kind, $1.task.title) }
                .filter { seen.insert($0.task.id).inserted } // one mention per task
            return makeNotification(fireAt: fireAt, events: group)
        }
    }

    private static func makeNotification(fireAt: Date, events: [Event]) -> PlannedNotification {
        let ids = events.map(\.task.id)
        let id = "buoy.\(Int(fireAt.timeIntervalSince1970))"
        if events.count == 1, let e = events.first {
            let title: String = switch e.kind {
            case .due: "Due today"
            case .snoozeEnded: "Back from snooze"
            case .active: "Now in Today"
            }
            return PlannedNotification(id: id, fireAt: fireAt, title: title, body: e.task.title, taskIDs: ids)
        }
        let titles = events.map(\.task.title)
        let body = titles.count <= 3
            ? ListFormatter.localizedString(byJoining: titles)
            : titles.prefix(2).joined(separator: ", ") + ", and \(titles.count - 2) more"
        let dueCount = events.filter { $0.kind == .due }.count
        let title = dueCount > 0 && dueCount == events.count
            ? "\(events.count) tasks due today"
            : "\(events.count) tasks need attention"
        return PlannedNotification(id: id, fireAt: fireAt, title: title, body: body, taskIDs: ids)
    }
}
