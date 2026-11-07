import Foundation

/// Why a task is in Today. Ordered roughly by urgency.
public enum TodayReason: Hashable, Sendable {
    case overdue(days: Int)
    case dueToday
    case leadTime(daysLeft: Int)
    case showOn
    case surfaced
    case snoozeEnded
    /// No dates at all: a plain "buy light bulbs" task lives in Today until done.
    case anytime
}

public enum Placement: Hashable, Sendable {
    case today(TodayReason)
    /// `risesAt` is the moment the task will next enter Today.
    case upcoming(risesAt: Date, snoozed: Bool)
    /// Parked: out of Today until you move it, or until a deadline needs you.
    case later
    case logbook(completedAt: Date)

    public var isToday: Bool { if case .today = self { true } else { false } }
    public var isUpcoming: Bool { if case .upcoming = self { true } else { false } }
    public var isLater: Bool { self == .later }
}

/// The attention engine: decides where each task belongs right now (PRD §13).
public enum Attention {
    public static func placement(of task: BuoyTask, now: Date, calendar: Calendar = .current) -> Placement {
        if let completion = task.completion {
            return .logbook(completedAt: completion.completedAt)
        }
        if let snooze = task.snoozedUntil, snooze > now {
            return .upcoming(risesAt: snooze, snoozed: true)
        }

        let today = LocalDate(now, calendar: calendar)

        if let due = task.dueOn {
            if due < today { return .today(.overdue(days: due.days(until: today, calendar: calendar))) }
            if due == today { return .today(.dueToday) }
        }
        // Later holds back everything but deadlines: due today, overdue, or inside the lead time.
        if task.later {
            if let leadStart = task.leadStart(calendar: calendar), leadStart <= today, let due = task.dueOn {
                return .today(.leadTime(daysLeft: today.days(until: due, calendar: calendar)))
            }
            return .later
        }
        if let show = task.showOn, show <= today {
            return .today(.showOn)
        }
        if let leadStart = task.leadStart(calendar: calendar), leadStart <= today, let due = task.dueOn {
            return .today(.leadTime(daysLeft: today.days(until: due, calendar: calendar)))
        }
        if task.surfacedAt != nil { return .today(.surfaced) }
        if task.snoozedUntil != nil { return .today(.snoozeEnded) }
        if task.showOn == nil && task.dueOn == nil { return .today(.anytime) }

        let rises = risesOn(task, calendar: calendar) ?? today
        return .upcoming(risesAt: rises.startOfDay(calendar: calendar), snoozed: false)
    }

    /// The earliest day date-based rules put the task into Today.
    public static func risesOn(_ task: BuoyTask, calendar: Calendar = .current) -> LocalDate? {
        [task.showOn, task.leadStart(calendar: calendar), task.dueOn].compactMap { $0 }.min()
    }

    // MARK: Views

    public struct TodayItem: Identifiable, Hashable, Sendable {
        public var task: BuoyTask
        public var reason: TodayReason
        public var id: UUID { task.id }
    }

    public struct UpcomingItem: Identifiable, Hashable, Sendable {
        public var task: BuoyTask
        public var risesAt: Date
        public var snoozed: Bool
        public var id: UUID { task.id }
    }

    /// Today, most urgent first: overdue, due today, then anything with a
    /// deadline by due date, then undated work, newest first. Once your agent has
    /// ordered Today, its order wins; anything that arrived since sits on top, most
    /// urgent first, until the agent orders again.
    public static func today(_ tasks: [BuoyTask], now: Date, calendar: Calendar = .current) -> [TodayItem] {
        tasks.filter(\.isListed).compactMap { task -> TodayItem? in
            if case .today(let reason) = placement(of: task, now: now, calendar: calendar) {
                return TodayItem(task: task, reason: reason)
            }
            return nil
        }
        .sorted { a, b in
            switch (a.task.agentRank, b.task.agentRank) {
            case (nil, _?): return true
            case (_?, nil): return false
            case let (ra?, rb?) where ra != rb: return ra < rb
            default: break
            }
            let ka = sortKey(a), kb = sortKey(b)
            if ka.rank != kb.rank { return ka.rank < kb.rank }
            if ka.due != kb.due { return ka.due < kb.due }
            if a.task.createdAt != b.task.createdAt {
                // Undated work: the newest on top, so what you just added is easy to see.
                return ka.rank == 3 ? a.task.createdAt > b.task.createdAt : a.task.createdAt < b.task.createdAt
            }
            return a.task.id.uuidString < b.task.id.uuidString
        }
    }

    private static func sortKey(_ item: TodayItem) -> (rank: Int, due: String) {
        let due = item.task.dueOn?.iso ?? "9999-99-99"
        switch item.reason {
        case .overdue: return (0, due)
        case .dueToday: return (1, due)
        default: return (item.task.dueOn == nil ? 3 : 2, due)
        }
    }

    /// Upcoming, ordered by when each task will next rise.
    public static func upcoming(_ tasks: [BuoyTask], now: Date, calendar: Calendar = .current) -> [UpcomingItem] {
        tasks.filter(\.isListed).compactMap { task -> UpcomingItem? in
            if case .upcoming(let rises, let snoozed) = placement(of: task, now: now, calendar: calendar) {
                return UpcomingItem(task: task, risesAt: rises, snoozed: snoozed)
            }
            return nil
        }
        .sorted { a, b in
            if a.risesAt != b.risesAt { return a.risesAt < b.risesAt }
            return a.task.title.localizedCaseInsensitiveCompare(b.task.title) == .orderedAscending
        }
    }

    /// Later, newest first (like undated work in Today).
    public static func later(_ tasks: [BuoyTask], now: Date, calendar: Calendar = .current) -> [BuoyTask] {
        tasks.filter { $0.isListed && placement(of: $0, now: now, calendar: calendar) == .later }
            .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
    }

    /// Completed tasks, most recent first.
    public static func logbook(_ tasks: [BuoyTask]) -> [BuoyTask] {
        tasks.filter { $0.isCompleted && !$0.pendingReview && $0.deletedAt == nil }.sorted { $0.completion!.completedAt > $1.completion!.completedAt }
    }
}

extension BuoyTask {
    /// Whether Today and Upcoming consider it at all: not awaiting review, not deleted,
    /// and not a project that only lives on the board.
    var isListed: Bool { !pendingReview && deletedAt == nil && !staysOnBoard }
}

// MARK: - Board

/// Ordering on the Projects board. Positions are numbers; smaller is higher.
public enum Board {
    /// The position for an item dropped at `index` among `column` (already in board order,
    /// without the item being moved).
    public static func position(at index: Int, in column: [BuoyTask]) -> Double {
        let positions = column.map(\.boardPosition)
        guard !positions.isEmpty else { return 0 }
        if index <= 0 { return positions[0] - 1 }
        if index >= positions.count { return positions[positions.count - 1] + 1 }
        return (positions[index - 1] + positions[index]) / 2
    }

    /// Open projects in `column`, in board order.
    public static func column(_ column: BoardColumn, of tasks: [BuoyTask]) -> [BuoyTask] {
        tasks.filter { $0.isProject && !$0.isCompleted && !$0.pendingReview && $0.deletedAt == nil && $0.boardColumn == column }
            .sorted { ($0.boardPosition, $0.createdAt) < ($1.boardPosition, $1.createdAt) }
    }

    /// Projects finished in the last `days` days, most recent first.
    public static func done(_ tasks: [BuoyTask], now: Date, days: Int = 14) -> [BuoyTask] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return tasks.filter { $0.isProject && $0.deletedAt == nil && ($0.completion?.completedAt ?? .distantPast) >= cutoff }
            .sorted { $0.completion!.completedAt > $1.completion!.completedAt }
    }
}

// MARK: - Aging

extension Attention {
    /// How long a task without a due date has been sitting in Today, once it has been
    /// there at least `threshold` days. Undated tasks never fall out of Today on their
    /// own, so this is how Buoy gently says "maybe not now?" instead of letting Today
    /// turn into a backlog. Tasks with a due date return nil: their deadline speaks.
    public static func lingeringDays(_ task: BuoyTask, reason: TodayReason, now: Date,
                                     threshold: Int = 14, calendar: Calendar = .current) -> Int? {
        guard task.dueOn == nil, !task.isCompleted else { return nil }
        let arrived: LocalDate?
        switch reason {
        case .anytime: arrived = LocalDate(task.createdAt, calendar: calendar)
        case .showOn: arrived = task.showOn
        case .surfaced: arrived = task.surfacedAt.map { LocalDate($0, calendar: calendar) }
        case .snoozeEnded: arrived = task.snoozedUntil.map { LocalDate($0, calendar: calendar) }
        default: arrived = nil
        }
        guard let arrived else { return nil }
        let days = arrived.days(until: LocalDate(now, calendar: calendar), calendar: calendar)
        return days >= threshold ? days : nil
    }
}
