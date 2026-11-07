import BuoyCore
import Foundation
import SwiftUI

enum Formatters {
    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    private static let weekdayName = formatter("EEEE")
    private static let shortWeekday = formatter("EEE")
    private static let monthDay = formatter("MMMd")
    private static let monthDayYear = formatter("MMMdyyyy")
    private static let fullDay = formatter("EEEEMMMMd")
    private static let monthYear = formatter("MMMMyyyy")
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// "Today", "Tomorrow", "Friday", "Oct 12", "Jan 3, 2028".
    static func day(_ date: LocalDate, today: LocalDate) -> String {
        let delta = today.days(until: date)
        switch delta {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return weekdayName.string(from: date.at(hour: 12))
        default:
            return (date.year == today.year ? monthDay : monthDayYear).string(from: date.at(hour: 12))
        }
    }

    /// Compact form for badges: "Today", "Tue", "Oct 12".
    static func shortDay(_ date: LocalDate, today: LocalDate) -> String {
        let delta = today.days(until: date)
        switch delta {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return shortWeekday.string(from: date.at(hour: 12))
        default:
            return (date.year == today.year ? monthDay : monthDayYear).string(from: date.at(hour: 12))
        }
    }

    static func sectionTitle(_ date: LocalDate, today: LocalDate) -> String {
        let delta = today.days(until: date)
        switch delta {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return fullDay.string(from: date.at(hour: 12))
        }
    }

    static func month(_ date: LocalDate) -> String { monthYear.string(from: date.at(hour: 12)) }

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// "3:40 PM", "tomorrow", "Saturday", "Oct 12".
    static func snooze(_ date: Date, now: Date) -> String {
        let target = LocalDate(date)
        let today = LocalDate(now)
        let isMidnight = date == target.startOfDay()
        if target == today { return time(date) }
        let name = day(target, today: today)
        if isMidnight { return name == "Tomorrow" ? "tomorrow" : name }
        return "\(name) \(time(date))"
    }

    /// "16 days", "3 weeks", "2 months".
    static func age(_ days: Int) -> String {
        if days >= 60 { return "\(days / 30) months" }
        if days >= 21 { return "\(days / 7) weeks" }
        return "\(days) days"
    }

    static func leadTime(_ days: Int) -> String {
        if days % 7 == 0 && days >= 7 {
            let w = days / 7
            return w == 1 ? "1 week" : "\(w) weeks"
        }
        return days == 1 ? "1 day" : "\(days) days"
    }
}

/// How a due date should look in a row.
struct DueBadge {
    let text: String
    let color: Color

    init?(task: BuoyTask, today: LocalDate) {
        guard let due = task.dueOn else { return nil }
        let delta = today.days(until: due)
        switch delta {
        case ..<(-1):
            text = "Overdue \(-delta) days"
            color = .red
        case -1:
            text = "Due yesterday"
            color = .red
        case 0:
            text = "Due today"
            color = .orange
        default:
            text = "Due \(Formatters.shortDay(due, today: today))"
            let inLead = task.leadStart().map { $0 <= today } ?? false
            color = inLead || delta <= 2 ? .orange.opacity(0.85) : .secondary
        }
    }
}
