import Foundation

public enum Recurrence {
    /// Builds the next occurrence of a recurring task completed on `completedOn`.
    ///
    /// The new task keeps title, notes, tags, lead time and rule. Dates move together:
    /// if the task had both Show On and Due, their spacing is preserved.
    ///
    /// Schedule mode: the next date on the rule's calendar strictly after both the
    /// current occurrence and the completion day (missed occurrences are skipped
    /// rather than piling up).
    /// Completion mode: completion day + interval.
    public static func nextOccurrence(
        of task: BuoyTask,
        completedOn: LocalDate,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> BuoyTask? {
        guard let rule = task.recurrence, let dates = nextDates(of: task, after: completedOn, calendar: calendar) else { return nil }

        var anchoredRule = rule
        if rule.mode == .schedule && rule.anchorOn == nil {
            anchoredRule.anchorOn = task.dueOn ?? task.showOn ?? completedOn
        }

        return BuoyTask(
            title: task.title,
            notes: task.notes,
            showOn: dates.showOn,
            dueOn: dates.dueOn,
            leadDays: task.leadDays,
            recurrence: anchoredRule,
            tags: task.tags,
            createdAt: now,
            source: task.source,
            kind: task.kind,
            boardPosition: task.boardPosition,
            later: task.later,
            expectations: task.expectations,
            effortHours: task.effortHours
        )
    }

    /// Skips the current occurrence: the same task moves to the next occurrence's
    /// dates without anything being logged as done.
    public static func skip(_ task: BuoyTask, today: LocalDate, now: Date = Date(), calendar: Calendar = .current) -> BuoyTask? {
        guard task.recurrence != nil, !task.isCompleted,
              let dates = nextDates(of: task, after: today, calendar: calendar) else { return nil }
        var t = task
        t.showOn = dates.showOn
        t.dueOn = dates.dueOn
        t.snoozedUntil = nil
        t.surfacedAt = nil
        t.updatedAt = now
        return t
    }

    private static func nextDates(of task: BuoyTask, after day: LocalDate, calendar: Calendar) -> (showOn: LocalDate?, dueOn: LocalDate?)? {
        guard let rule = task.recurrence else { return nil }
        let primary = task.dueOn ?? task.showOn
        let nextPrimary: LocalDate
        switch rule.mode {
        case .completion:
            nextPrimary = day.adding(rule.unit.calendarComponent, rule.interval, calendar: calendar)
        case .schedule:
            let anchor = rule.anchorOn ?? primary ?? day
            let floor = max(primary ?? day, day)
            nextPrimary = firstOccurrence(of: rule, anchor: anchor, after: floor, calendar: calendar)
        }

        if let due = task.dueOn {
            let show = task.showOn.map { nextPrimary.adding(days: -$0.days(until: due, calendar: calendar), calendar: calendar) }
            return (show, nextPrimary)
        }
        // Show On only, or no dates at all: hide the next one until its day comes.
        return (nextPrimary, nil)
    }

    /// The first date of the rule's schedule that is strictly after `floor`.
    ///
    /// Plain rules: the smallest `anchor + n * interval` (n ≥ 1), always computed from
    /// the anchor so month-end dates don't drift. Patterned rules (specific weekdays,
    /// Nth weekday, last day of month) are measured in weeks/months from the anchor.
    public static func firstOccurrence(
        of rule: RecurrenceRule,
        anchor: LocalDate,
        after floor: LocalDate,
        calendar: Calendar = .current
    ) -> LocalDate {
        if !rule.weekdays.isEmpty {
            return nextWeekdayOccurrence(rule, anchor: anchor, after: floor, calendar: calendar)
        }
        if rule.monthOrdinal != nil {
            return nextMonthlyPatternOccurrence(rule, anchor: anchor, after: floor, calendar: calendar)
        }

        let step = rule.interval
        let component = rule.unit.calendarComponent
        // Jump close to the answer, then walk forward.
        var n = 1
        if floor > anchor {
            let approxUnitDays: Double = switch rule.unit {
            case .day: 1
            case .week: 7
            case .month: 30.44
            case .year: 365.25
            }
            let gap = Double(anchor.days(until: floor, calendar: calendar))
            n = max(1, Int(gap / (approxUnitDays * Double(step))) - 1)
        }
        func occurrence(_ k: Int) -> LocalDate { anchor.adding(component, k * step, calendar: calendar) }
        while n > 1 && occurrence(n - 1) > floor { n -= 1 }
        while occurrence(n) <= floor { n += 1 }
        return occurrence(n)
    }

    /// Specific weekdays, every `interval` weeks counted from the anchor's week (weeks start Sunday).
    private static func nextWeekdayOccurrence(_ rule: RecurrenceRule, anchor: LocalDate, after floor: LocalDate, calendar: Calendar) -> LocalDate {
        let anchorWeekStart = anchor.adding(days: -(anchor.weekday(calendar: calendar) - 1), calendar: calendar)
        var day = floor.adding(days: 1, calendar: calendar)
        for _ in 0..<(7 * rule.interval * 2 + 7) {
            let weekday = day.weekday(calendar: calendar)
            if rule.weekdays.contains(weekday) {
                let weekStart = day.adding(days: -(weekday - 1), calendar: calendar)
                let weeks = anchorWeekStart.days(until: weekStart, calendar: calendar) / 7
                if weeks % rule.interval == 0 || weeks < 0 { return day }
            }
            day = day.adding(days: 1, calendar: calendar)
        }
        return day
    }

    /// "The 2nd Tuesday", "the last Friday", or "the last day", every `interval` months from the anchor's month.
    private static func nextMonthlyPatternOccurrence(_ rule: RecurrenceRule, anchor: LocalDate, after floor: LocalDate, calendar: Calendar) -> LocalDate {
        let anchorMonth = LocalDate(year: anchor.year, month: anchor.month, day: 1)
        var k = 0
        if floor > anchor {
            let months = (floor.year - anchor.year) * 12 + (floor.month - anchor.month)
            k = max(0, months / rule.interval - 1)
        }
        for _ in 0..<600 {
            let month = anchorMonth.adding(.month, k * rule.interval, calendar: calendar)
            if let day = patternDay(in: month, rule: rule, calendar: calendar), day > floor { return day }
            k += 1
        }
        return floor.adding(days: 1, calendar: calendar)
    }

    /// The matching day within the month starting at `first`, or nil (e.g. no 5th Tuesday).
    static func patternDay(in first: LocalDate, rule: RecurrenceRule, calendar: Calendar) -> LocalDate? {
        guard let ordinal = rule.monthOrdinal else { return nil }
        let last = first.adding(.month, 1, calendar: calendar).adding(days: -1, calendar: calendar)
        guard let weekday = rule.monthWeekday else {
            return ordinal == -1 ? last : nil
        }
        if ordinal == -1 {
            let back = (last.weekday(calendar: calendar) - weekday + 7) % 7
            return last.adding(days: -back, calendar: calendar)
        }
        let forward = (weekday - first.weekday(calendar: calendar) + 7) % 7
        let day = first.adding(days: forward + (ordinal - 1) * 7, calendar: calendar)
        return day.month == first.month ? day : nil
    }

    /// The first day on or after `day` that matches a patterned rule; `day` itself for plain rules.
    /// Used to place a brand-new "every Mon, Wed, Fri" task on its first matching day.
    /// The interval doesn't apply yet: "every other Thursday" starts on the next Thursday, and
    /// the series is anchored there.
    public static func firstMatch(of rule: RecurrenceRule, onOrAfter day: LocalDate, calendar: Calendar = .current) -> LocalDate {
        guard rule.hasPattern else { return day }
        let single = RecurrenceRule(unit: rule.unit, interval: 1, mode: rule.mode, anchorOn: rule.anchorOn, weekdays: rule.weekdays,
                                    monthOrdinal: rule.monthOrdinal, monthWeekday: rule.monthWeekday)
        return firstOccurrence(of: single, anchor: single.anchorOn ?? day, after: day.adding(days: -1, calendar: calendar), calendar: calendar)
    }
}
