import Foundation

/// Snoozing hides a task from Today until a moment in the future.
/// It never changes Show On or the Due Date.
public enum SnoozeOption: Hashable, Sendable {
    case laterToday
    case tomorrow
    case thisWeekend
    case nextWeek
    case until(LocalDate)

    public static let presets: [SnoozeOption] = [.laterToday, .tomorrow, .thisWeekend, .nextWeek]

    public var label: String {
        switch self {
        case .laterToday: "Later Today"
        case .tomorrow: "Tomorrow"
        case .thisWeekend: "This Weekend"
        case .nextWeek: "Next Week"
        case .until(let d): "Until \(d.iso)"
        }
    }

    /// When the snooze ends. Day-based snoozes end at the start of that day, so the
    /// task is waiting in Today as soon as the day begins.
    public func wakeDate(from now: Date, calendar: Calendar = .current) -> Date {
        let today = LocalDate(now, calendar: calendar)
        switch self {
        case .laterToday:
            let later = now.addingTimeInterval(3 * 3600)
            // Past the end of the day, "later" means tomorrow.
            return LocalDate(later, calendar: calendar) == today
                ? later : today.adding(days: 1, calendar: calendar).startOfDay(calendar: calendar)
        case .tomorrow:
            return today.adding(days: 1, calendar: calendar).startOfDay(calendar: calendar)
        case .thisWeekend:
            // Saturday, or Sunday if it's already Saturday; next Saturday if it's Sunday.
            let wd = today.weekday(calendar: calendar)
            let target = wd == 7 ? today.adding(days: 1, calendar: calendar) : today.next(weekday: 7, calendar: calendar)
            return target.startOfDay(calendar: calendar)
        case .nextWeek:
            return today.next(weekday: 2, calendar: calendar).startOfDay(calendar: calendar)
        case .until(let day):
            return day.startOfDay(calendar: calendar)
        }
    }
}

/// One-click date choices for Show On / Due pickers.
public enum QuickDates {
    public static func presets(today: LocalDate, calendar: Calendar = .current) -> [(label: String, date: LocalDate)] {
        let weekday = today.weekday(calendar: calendar)
        let weekend = (weekday == 7 || weekday == 1) ? today : today.next(weekday: 7, calendar: calendar)
        return [
            ("Today", today),
            ("Tomorrow", today.adding(days: 1, calendar: calendar)),
            ("This Weekend", weekend),
            ("Next Week", today.next(weekday: 2, calendar: calendar)),
            ("In a Month", today.adding(.month, 1, calendar: calendar)),
        ]
    }
}
