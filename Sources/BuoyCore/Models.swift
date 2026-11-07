import Foundation

/// A task, or a project living on the Projects board.
public enum TaskKind: String, Sendable, Hashable {
    case task
    case project
}

/// Where an open project sits on the board, which hands work to an agent: you shape
/// the ask, move it to Ready, the agent works it and hands it back for review, and you
/// move it to Done. Done isn't a column value: a completed project is in Done, whatever
/// column it was in.
public enum BoardColumn: String, Sendable, Hashable, CaseIterable {
    case shaping
    case ready
    case inProgress = "in_progress"
    case review

    public var title: String {
        switch self {
        case .shaping: "Shaping"
        case .ready: "Ready"
        case .inProgress: "In progress"
        case .review: "Ready for review"
        }
    }
}

/// A rough level of effort, in hours.
public enum Effort {
    /// The most a single estimate may be.
    public static let maxHours = 1000.0

    /// Short enough for a card: "30m", "1h", "1.5h", "12h". Rounded to the quarter hour.
    public static func format(_ hours: Double) -> String {
        if hours < 1 { return "\(max(1, Int((hours * 60).rounded())))m" }
        let quarters = (hours * 4).rounded() / 4
        return quarters == quarters.rounded()
            ? "\(Int(quarters))h"
            : "\(quarters.formatted(.number.precision(.fractionLength(0...2))))h"
    }
}

/// Who created a task or note.
public enum ItemSource: String, Sendable, Hashable {
    case user
    case agent
}

/// A single task. Its state (Today / Upcoming / Logbook) is never stored; it is
/// derived from these attributes by `Attention.placement(of:now:)`.
public struct BuoyTask: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String
    /// "Start showing me this task."
    public var showOn: LocalDate?
    /// "This must be completed by this date."
    public var dueOn: LocalDate?
    /// "Start showing it this many days before it is due." 0 means no lead time.
    public var leadDays: Int
    /// While in the future, the task is hidden from Today. Never touches `dueOn`.
    public var snoozedUntil: Date?
    /// Set when the user explicitly pulls a task into Today.
    public var surfacedAt: Date?
    public var recurrence: RecurrenceRule?
    /// Tag names, kept sorted case-insensitively.
    public var tags: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var completion: Completion?
    /// Who created it: you, or an agent through a `buoy://` link.
    public var source: ItemSource
    /// An agent added it and you haven't accepted it yet. It stays out of every list,
    /// count and notification until you do.
    public var pendingReview: Bool
    public var kind: TaskKind
    /// For projects: the board column and the order within it (smaller is higher).
    public var boardColumn: BoardColumn
    public var boardPosition: Double
    /// Set when an agent deleted it; restorable for 30 days, then removed.
    public var deletedAt: Date?
    /// Parked in Later: kept out of Today until you move it back, unless a deadline needs you.
    public var later: Bool
    /// For projects: what done looks like, written by you for the agent.
    public var expectations: String
    /// For projects: one line from the agent on where it's at ("Comparing three vendors").
    public var status: String
    /// For projects: the agent's description of what it delivered.
    public var result: String
    /// Rough level of effort in hours, usually the agent's estimate. nil: not estimated.
    public var effortHours: Double?
    /// Your agent's order for Today (smaller is higher). nil: not ordered yet.
    public var agentRank: Double?
    /// Your agent's latest suggestion for when to do it. Kept after you dismiss it, so the
    /// agent can see you said no.
    public var suggestion: Suggestion?

    public init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        showOn: LocalDate? = nil,
        dueOn: LocalDate? = nil,
        leadDays: Int = 0,
        snoozedUntil: Date? = nil,
        surfacedAt: Date? = nil,
        recurrence: RecurrenceRule? = nil,
        tags: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        completion: Completion? = nil,
        source: ItemSource = .user,
        pendingReview: Bool = false,
        kind: TaskKind = .task,
        boardColumn: BoardColumn = .shaping,
        boardPosition: Double = 0,
        deletedAt: Date? = nil,
        later: Bool = false,
        status: String = "",
        result: String = "",
        expectations: String = "",
        effortHours: Double? = nil,
        agentRank: Double? = nil,
        suggestion: Suggestion? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.showOn = showOn
        self.dueOn = dueOn
        self.leadDays = max(0, leadDays)
        self.snoozedUntil = snoozedUntil
        self.surfacedAt = surfacedAt
        self.recurrence = recurrence
        self.tags = Self.normalizedTags(tags)
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.completion = completion
        self.source = source
        self.pendingReview = pendingReview
        self.kind = kind
        self.boardColumn = boardColumn
        self.boardPosition = boardPosition
        self.deletedAt = deletedAt
        self.later = later
        self.status = status
        self.result = result
        self.expectations = expectations
        self.effortHours = effortHours
        self.agentRank = agentRank
        self.suggestion = suggestion
    }

    public var isProject: Bool { kind == .project }

    /// A project with no dates (and not pulled into Today) lives only on the board.
    public var staysOnBoard: Bool {
        isProject && showOn == nil && dueOn == nil && surfacedAt == nil
    }

    public var isCompleted: Bool { completion != nil }

    /// The day the lead-time window opens, if the task has a due date and lead time.
    public func leadStart(calendar: Calendar = .current) -> LocalDate? {
        guard let due = dueOn, leadDays > 0 else { return nil }
        return due.adding(days: -leadDays, calendar: calendar)
    }

    public static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in tags {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            result.append(name)
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// What your agent suggests doing with a task.
public enum SuggestedMove: Hashable, Sendable {
    /// Park it in Later.
    case later
    /// Start showing it on that day.
    case showOn(LocalDate)
    /// Make it due that day.
    case dueOn(LocalDate)

    /// For logs: "Later", "show on 2026-11-03", "due 2026-11-30".
    public var summary: String {
        switch self {
        case .later: "Later"
        case .showOn(let day): "show on \(day.iso)"
        case .dueOn(let day): "due \(day.iso)"
        }
    }
}

/// A suggestion from your agent, waiting in the strip at the top of Today until you
/// accept or dismiss it. Nothing changes until you accept.
public struct Suggestion: Hashable, Sendable {
    public var move: SuggestedMove
    /// One line on why ("No date, in Today 3 weeks").
    public var reason: String
    public var createdAt: Date
    public var dismissedAt: Date?

    public init(move: SuggestedMove, reason: String, createdAt: Date = Date(), dismissedAt: Date? = nil) {
        self.move = move
        self.reason = reason
        self.createdAt = createdAt
        self.dismissedAt = dismissedAt
    }
}

extension BuoyTask {
    /// The suggestion waiting for you, if you haven't dismissed it.
    public var openSuggestion: Suggestion? {
        suggestion?.dismissedAt == nil ? suggestion : nil
    }

    /// The task with `move` applied, as if you'd made the change yourself; the suggestion
    /// is cleared. A new date replaces any snooze or Move to Today, and a Show On date
    /// brings it out of Later so it can rise that day.
    public func applying(_ move: SuggestedMove, today: LocalDate) -> BuoyTask {
        var t = self
        t.suggestion = nil
        t.snoozedUntil = nil
        t.surfacedAt = nil
        switch move {
        case .later:
            t.later = true
        case .showOn(let day):
            t.showOn = day
            t.later = false
        case .dueOn(let day):
            t.dueOn = day
        }
        // Re-anchor schedule-based repeats on the new date, as editing the date would.
        if move != .later, let rule = t.recurrence, rule.mode == .schedule {
            t.recurrence = rule.copy(anchorOn: t.dueOn ?? t.showOn ?? today)
        }
        return t
    }
}

public struct Completion: Hashable, Sendable {
    public var id: UUID
    public var completedAt: Date
    /// The occurrence generated when a recurring task was completed; removed again on undo.
    public var nextTaskID: UUID?

    public init(id: UUID = UUID(), completedAt: Date, nextTaskID: UUID? = nil) {
        self.id = id
        self.completedAt = completedAt
        self.nextTaskID = nextTaskID
    }
}

/// How a task repeats. Rules are immutable rows: editing a task's recurrence
/// creates a new rule, so completed occurrences keep the rule they were created under.
public struct RecurrenceRule: Hashable, Sendable {
    public enum Unit: String, CaseIterable, Sendable {
        case day, week, month, year

        public var calendarComponent: Calendar.Component {
            switch self {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
        }
    }

    public enum Mode: String, CaseIterable, Sendable {
        /// Next occurrence follows the calendar ("the 1st of every month").
        case schedule
        /// Next occurrence is measured from when you completed it ("90 days after I last did it").
        case completion
    }

    public var id: UUID
    public var unit: Unit
    public var interval: Int
    public var mode: Mode
    /// For schedule mode: the date the series is measured from, so monthly tasks
    /// on the 31st don't drift to the 28th after February.
    public var anchorOn: LocalDate?
    /// Weekly on specific days (1 = Sunday … 7 = Saturday). Empty means "same weekday as the anchor".
    public var weekdays: [Int]
    /// Monthly on "the Nth weekday": 1–4, or -1 for the last. With `monthWeekday == nil`
    /// and -1, it means the last day of the month.
    public var monthOrdinal: Int?
    public var monthWeekday: Int?

    public init(id: UUID = UUID(), unit: Unit, interval: Int = 1, mode: Mode = .schedule, anchorOn: LocalDate? = nil,
                weekdays: [Int] = [], monthOrdinal: Int? = nil, monthWeekday: Int? = nil) {
        self.id = id
        self.unit = unit
        self.interval = max(1, interval)
        self.mode = mode
        self.anchorOn = anchorOn
        self.weekdays = unit == .week ? Array(Set(weekdays.filter { (1...7).contains($0) })).sorted() : []
        let ordinalValid = unit == .month && monthOrdinal.map { (1...4).contains($0) || $0 == -1 } == true
        self.monthOrdinal = ordinalValid ? monthOrdinal : nil
        self.monthWeekday = ordinalValid ? monthWeekday.flatMap { (1...7).contains($0) ? $0 : nil } : nil
        if self.monthOrdinal != nil, self.monthWeekday == nil, self.monthOrdinal != -1 { self.monthOrdinal = nil }
    }

    /// Same pattern, new identity (and optionally a new anchor).
    public func copy(anchorOn: LocalDate?) -> RecurrenceRule {
        RecurrenceRule(unit: unit, interval: interval, mode: mode, anchorOn: anchorOn,
                       weekdays: weekdays, monthOrdinal: monthOrdinal, monthWeekday: monthWeekday)
    }

    /// True when the rule uses specific weekdays or an Nth-weekday / last-day monthly pattern.
    public var hasPattern: Bool { !weekdays.isEmpty || monthOrdinal != nil }

    static let shortWeekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    public static func ordinalName(_ n: Int) -> String {
        switch n {
        case -1: "last"
        case 1: "1st"
        case 2: "2nd"
        case 3: "3rd"
        default: "\(n)th"
        }
    }

    public var summary: String {
        var base: String
        switch (unit, interval) {
        case (.day, 1): base = "Every day"
        case (.week, 1): base = "Every week"
        case (.month, 1): base = "Every month"
        case (.year, 1): base = "Every year"
        case (.week, 2): base = "Every other week"
        default: base = "Every \(interval) \(unit.rawValue)s"
        }
        if mode == .schedule {
            if !weekdays.isEmpty {
                let days = weekdays == [2, 3, 4, 5, 6] ? (interval == 1 ? "weekday" : "weekdays") : weekdays.map { Self.shortWeekdayNames[$0 - 1] }.joined(separator: ", ")
                base = interval == 1 ? "Every \(days)" : "\(base) on \(days)"
            } else if let ordinal = monthOrdinal {
                let what = monthWeekday.map { "the \(Self.ordinalName(ordinal)) \(Self.weekdayNames[$0 - 1])" } ?? "the last day"
                base = "\(base) on \(what)"
            }
        }
        return mode == .completion ? "\(base) after completion" : base
    }
}
