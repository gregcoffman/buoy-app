import Foundation

/// The result of parsing a quick-entry line such as
/// `Renew passport due dec 1 lead 30d #finance`.
public struct ParsedEntry: Equatable, Sendable {
    public var title: String
    public var showOn: LocalDate?
    public var dueOn: LocalDate?
    public var leadDays: Int?
    public var tags: [String]
    public var recurrence: RecurrenceRule?
    /// "… later" at the end: park it in Later instead of Today.
    public var later: Bool

    public init(title: String = "", showOn: LocalDate? = nil, dueOn: LocalDate? = nil,
                leadDays: Int? = nil, tags: [String] = [], recurrence: RecurrenceRule? = nil, later: Bool = false) {
        self.later = later
        self.title = title
        self.showOn = showOn
        self.dueOn = dueOn
        self.leadDays = leadDays
        self.tags = tags
        self.recurrence = recurrence
    }

    public static func == (a: ParsedEntry, b: ParsedEntry) -> Bool {
        a.title == b.title && a.later == b.later && a.showOn == b.showOn && a.dueOn == b.dueOn && a.leadDays == b.leadDays
            && a.tags == b.tags && a.recurrence?.unit == b.recurrence?.unit
            && a.recurrence?.interval == b.recurrence?.interval && a.recurrence?.mode == b.recurrence?.mode
    }
}

/// Parses quick-entry text. Keywords only take effect when a valid value follows,
/// so ordinary titles ("Work on report", "Read book by Tolkien") are left alone.
///
/// Supported:
/// - Due:        `due fri`, `by dec 1`, `deadline 12/1`
/// - Show On:    `show mon`, `start next week`, `defer mar 1`, `on friday`, bare `tomorrow`
/// - Lead time:  `lead 30d`, `lead 2 weeks`, `warn 1 month`
/// - Repeat:     `every day|week|month|year`, `every 2 weeks`, `every other week`,
///               `every monday`, `every other thursday`, `every mon wed fri`, `every weekday`, `every 2nd tuesday`,
///               `every last friday`, `every last day of the month`, `every 90 days after done`, `repeat monthly`
/// - Tags:       `#finance #home`
/// - Dates:      today, tomorrow, weekdays, next week/month/year, weekend, in 3 days,
///               in 2 weeks, dec 1, 1 dec, december 1st 2027, 12/1, 12/1/27, 2026-12-01, end of month
public struct QuickEntryParser: Sendable {
    public var calendar: Calendar
    public var now: Date

    public init(now: Date = Date(), calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    private var today: LocalDate { LocalDate(now, calendar: calendar) }

    public func parse(_ input: String) -> ParsedEntry {
        var tokens = input.split(whereSeparator: \.isWhitespace).map(String.init)
        var result = ParsedEntry()
        // "later" as the last word parks the task in Later (and isn't part of the title).
        if tokens.count > 1, let last = tokens.last, normalize(last) == "later" {
            tokens.removeLast()
            result.later = true
        }
        var titleWords: [String] = []
        var i = 0

        while i < tokens.count {
            let word = normalize(tokens[i])
            let rest = Array(tokens[(i + 1)...])

            if tokens[i].hasPrefix("#"), tokens[i].count > 1 {
                let tag = String(tokens[i].dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: ",.;"))
                if !tag.isEmpty { result.tags.append(tag) }
                i += 1
                continue
            }

            if ["due", "by", "deadline"].contains(word), let (date, used) = parseDate(rest) {
                result.dueOn = date
                i += 1 + used
                continue
            }
            if ["show", "start", "starting", "defer", "on"].contains(word), let (date, used) = parseDate(rest) {
                result.showOn = date
                i += 1 + used
                continue
            }
            if ["lead", "warn", "notice"].contains(word), let (days, used) = parseDuration(rest) {
                result.leadDays = days
                i += 1 + used
                continue
            }
            if word == "every", let (rule, used) = parseEvery(rest) {
                result.recurrence = rule
                i += 1 + used
                continue
            }
            if ["repeat", "repeats", "repeating"].contains(word), let first = rest.first,
               let unit = adverbUnit(normalize(first)) {
                var used = 1
                let mode = parseCompletionSuffix(Array(rest.dropFirst()), used: &used)
                result.recurrence = RecurrenceRule(unit: unit, interval: 1, mode: mode)
                i += 1 + used
                continue
            }
            if ["tomorrow", "tmrw", "tmr"].contains(word), result.showOn == nil {
                result.showOn = today.adding(days: 1, calendar: calendar)
                i += 1
                continue
            }

            titleWords.append(tokens[i])
            i += 1
        }

        result.title = titleWords.joined(separator: " ")
        result.tags = BuoyTask.normalizedTags(result.tags)

        // "every monday" with no dates: start on the first matching day (today, if it matches).
        if let rule = result.recurrence, rule.hasPattern, rule.mode == .schedule, result.showOn == nil, result.dueOn == nil {
            result.showOn = Recurrence.firstMatch(of: rule, onOrAfter: today, calendar: calendar)
        }
        if var rule = result.recurrence, rule.mode == .schedule {
            rule.anchorOn = result.dueOn ?? result.showOn ?? today
            result.recurrence = rule
        }
        return result
    }

    // MARK: Dates

    /// Parses a date phrase at the start of `tokens`, returning the date and tokens consumed.
    public func parseDate(_ tokens: [String]) -> (LocalDate, Int)? {
        guard let first = tokens.first.map(normalize) else { return nil }
        let second = tokens.count > 1 ? normalize(tokens[1]) : nil
        let third = tokens.count > 2 ? normalize(tokens[2]) : nil

        switch first {
        case "today", "tod", "tonight": return (today, 1)
        case "tomorrow", "tmrw", "tmr", "tom": return (today.adding(days: 1, calendar: calendar), 1)
        case "weekend": return (weekend(), 1)
        case "eom": return (endOfMonth(), 1)
        default: break
        }

        if let weekday = Self.weekdays[first] {
            return (today.next(weekday: weekday, calendar: calendar), 1)
        }

        if first == "next" || first == "this", let second {
            if let weekday = Self.weekdays[second] { return (today.next(weekday: weekday, calendar: calendar), 2) }
            if second == "weekend" { return (weekend(), 2) }
            if first == "next" {
                switch second {
                case "week": return (today.next(weekday: 2, calendar: calendar), 2)
                case "month":
                    let d = today.adding(.month, 1, calendar: calendar)
                    return (LocalDate(year: d.year, month: d.month, day: 1), 2)
                case "year": return (LocalDate(year: today.year + 1, month: 1, day: 1), 2)
                default: break
                }
            }
        }

        if first == "end", second == "of", third == "month" { return (endOfMonth(), 3) }

        if first == "in", let (amount, unit, used) = parseAmountAndUnit(Array(tokens.dropFirst())) {
            return (today.adding(unit.calendarComponent, amount, calendar: calendar), 1 + used)
        }

        if let iso = LocalDate(iso: first), isValid(iso) { return (iso, 1) }
        if let numeric = parseNumericDate(first) { return (numeric, 1) }

        // "dec 1", "december 1st", "dec 1 2027"
        if let month = Self.months[first], let second, let day = parseDayNumber(second) {
            if let third, let year = parseYear(third), let date = makeDate(year: year, month: month, day: day) {
                return (date, 3)
            }
            if let date = inferYear(month: month, day: day) { return (date, 2) }
        }
        // "1 dec", "1st december 2027"
        if let day = parseDayNumber(first), let second, let month = Self.months[second] {
            if let third, let year = parseYear(third), let date = makeDate(year: year, month: month, day: day) {
                return (date, 3)
            }
            if let date = inferYear(month: month, day: day) { return (date, 2) }
        }
        return nil
    }

    private func weekend() -> LocalDate {
        let wd = today.weekday(calendar: calendar)
        return (wd == 7 || wd == 1) ? today : today.next(weekday: 7, calendar: calendar)
    }

    private func endOfMonth() -> LocalDate {
        let firstOfNext = LocalDate(year: today.year, month: today.month, day: 1).adding(.month, 1, calendar: calendar)
        return firstOfNext.adding(days: -1, calendar: calendar)
    }

    private func parseNumericDate(_ s: String) -> LocalDate? {
        let parts = s.split(separator: "/").compactMap { Int($0) }
        guard parts.count == s.split(separator: "/").count, (2...3).contains(parts.count) else { return nil }
        let month = parts[0], day = parts[1]
        if parts.count == 3 {
            let year = parts[2] < 100 ? 2000 + parts[2] : parts[2]
            return makeDate(year: year, month: month, day: day)
        }
        return inferYear(month: month, day: day)
    }

    private func parseDayNumber(_ s: String) -> Int? {
        let digits = s.replacingOccurrences(of: #"(st|nd|rd|th)$"#, with: "", options: .regularExpression)
        guard let n = Int(digits), (1...31).contains(n) else { return nil }
        return n
    }

    private func parseYear(_ s: String) -> Int? {
        guard let n = Int(s), (2000...2200).contains(n) else { return nil }
        return n
    }

    /// Month/day without a year means the next time that date comes around.
    private func inferYear(month: Int, day: Int) -> LocalDate? {
        guard let date = makeDate(year: today.year, month: month, day: day) else { return nil }
        return date < today ? makeDate(year: today.year + 1, month: month, day: day) : date
    }

    private func makeDate(year: Int, month: Int, day: Int) -> LocalDate? {
        let d = LocalDate(year: year, month: month, day: day)
        return isValid(d) ? d : nil
    }

    private func isValid(_ d: LocalDate) -> Bool {
        guard let date = calendar.date(from: d.components) else { return false }
        return LocalDate(date, calendar: calendar) == d
    }

    // MARK: Durations

    /// "30d", "30", "30 days", "2w", "2 weeks", "a month" → days.
    public func parseDuration(_ tokens: [String]) -> (Int, Int)? {
        guard let first = tokens.first.map(normalize) else { return nil }
        if let (amount, unit, used) = parseAmountAndUnit(tokens) {
            return (amount * Self.approximateDays(unit), used)
        }
        if let n = Int(first), n >= 0 { return (n, 1) }
        return nil
    }

    private func parseAmountAndUnit(_ tokens: [String]) -> (Int, RecurrenceRule.Unit, Int)? {
        guard let first = tokens.first.map(normalize) else { return nil }
        // Compact: "30d", "2w", "3mo", "1y"
        if let match = first.firstMatch(of: #/^(\d+)(d|w|mo|m|y)$/#) {
            let n = Int(match.1)!
            let unit: RecurrenceRule.Unit = switch match.2 {
            case "d": .day
            case "w": .week
            case "y": .year
            default: .month
            }
            return (n, unit, 1)
        }
        let amount: Int? = ["a", "an", "one"].contains(first) ? 1 : Int(first)
        guard let amount, tokens.count > 1, let unit = unitWord(normalize(tokens[1])) else { return nil }
        return (amount, unit, 2)
    }

    private static func approximateDays(_ unit: RecurrenceRule.Unit) -> Int {
        switch unit {
        case .day: 1
        case .week: 7
        case .month: 30
        case .year: 365
        }
    }

    private func unitWord(_ s: String) -> RecurrenceRule.Unit? {
        switch s {
        case "day", "days", "d": .day
        case "week", "weeks", "wk", "wks", "w": .week
        case "month", "months", "mo", "mos": .month
        case "year", "years", "yr", "yrs", "y": .year
        default: nil
        }
    }

    private func adverbUnit(_ s: String) -> RecurrenceRule.Unit? {
        switch s {
        case "daily": .day
        case "weekly": .week
        case "monthly": .month
        case "yearly", "annually": .year
        default: nil
        }
    }

    // MARK: Recurrence

    private func parseEvery(_ tokens: [String]) -> (RecurrenceRule, Int)? {
        guard let first = tokens.first.map(normalize) else { return nil }
        let second = tokens.count > 1 ? normalize(tokens[1]) : nil
        var unit: RecurrenceRule.Unit
        var interval = 1
        var used: Int
        var weekdays: [Int] = []
        var ordinal: Int? = nil
        var monthWeekday: Int? = nil

        if first == "weekday" || first == "weekdays" {
            // Every weekday: Monday–Friday.
            unit = .week
            weekdays = [2, 3, 4, 5, 6]
            used = 1
        } else if let (days, consumed) = parseWeekdayList(tokens) {
            // "every mon", "every mon wed fri", "every mon, wed and fri", "every mon/wed/fri"
            unit = .week
            weekdays = days
            used = consumed
        } else if let n = Self.ordinals[first], let second, let wd = Self.weekdays[second] {
            // "every 2nd tuesday", "every last friday"
            unit = .month
            ordinal = n
            monthWeekday = wd
            used = 2
        } else if first == "last", second == "day" {
            // "every last day of the month"
            unit = .month
            ordinal = -1
            used = 2
            let rest = tokens.dropFirst(2).map(normalize)
            if rest.starts(with: ["of", "the", "month"]) { used += 3 } else if rest.starts(with: ["of", "month"]) { used += 2 }
        } else if first == "end", second == "of", tokens.count > 2, normalize(tokens[2]) == "month" {
            unit = .month
            ordinal = -1
            used = 3
        } else if let u = unitWord(first) {
            unit = u
            used = 1
        } else if first == "other", let (days, consumed) = parseWeekdayList(Array(tokens.dropFirst())) {
            // "every other thursday", "every other mon and thu"
            unit = .week
            interval = 2
            weekdays = days
            used = 1 + consumed
        } else if first == "other", let second, let u = unitWord(second) {
            unit = u
            interval = 2
            used = 2
        } else if let (n, u, consumed) = parseAmountAndUnit(tokens) {
            unit = u
            interval = n
            used = consumed
        } else {
            return nil
        }
        guard interval >= 1 else { return nil }
        let mode = parseCompletionSuffix(Array(tokens.dropFirst(used)), used: &used)
        let rule = RecurrenceRule(unit: unit, interval: interval, mode: mode, weekdays: weekdays,
                                  monthOrdinal: ordinal, monthWeekday: monthWeekday)
        return (rule, used)
    }

    /// Weekday names separated by spaces, commas, slashes, "and" or "&".
    private func parseWeekdayList(_ tokens: [String]) -> ([Int], Int)? {
        var days: [Int] = []
        var used = 0
        for token in tokens {
            let parts = token.lowercased().split(whereSeparator: { $0 == "/" || $0 == "," }).map { normalize(String($0)) }
            if parts.isEmpty { used += 1; continue }
            let mapped = parts.compactMap { Self.weekdays[$0] }
            if mapped.count == parts.count {
                days += mapped
                used += 1
            } else if !days.isEmpty, ["and", "&"].contains(normalize(token)) {
                used += 1
            } else {
                break
            }
        }
        // Don't swallow a trailing "and" that wasn't followed by a day.
        while used > 0, ["and", "&"].contains(normalize(tokens[used - 1])) { used -= 1 }
        return days.isEmpty ? nil : (days, used)
    }

    /// Recognises "after done", "after completion", "after completed", "from completion".
    private func parseCompletionSuffix(_ tokens: [String], used: inout Int) -> RecurrenceRule.Mode {
        guard tokens.count >= 2 else { return .schedule }
        let a = normalize(tokens[0]), b = normalize(tokens[1])
        if ["after", "from"].contains(a), ["done", "completion", "completed", "complete", "finishing", "finished"].contains(b) {
            used += 2
            return .completion
        }
        return .schedule
    }

    // MARK: Vocabulary

    private func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!"))
    }

    static let weekdays: [String: Int] = [
        "sun": 1, "sunday": 1,
        "mon": 2, "monday": 2,
        "tue": 3, "tues": 3, "tuesday": 3,
        "wed": 4, "weds": 4, "wednesday": 4,
        "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
        "fri": 6, "friday": 6,
        "sat": 7, "saturday": 7,
    ]

    static let ordinals: [String: Int] = [
        "first": 1, "1st": 1, "second": 2, "2nd": 2, "third": 3, "3rd": 3, "fourth": 4, "4th": 4, "last": -1,
    ]

    static let months: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3,
        "apr": 4, "april": 4, "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7,
        "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9, "oct": 10, "october": 10,
        "nov": 11, "november": 11, "dec": 12, "december": 12,
    ]
}
