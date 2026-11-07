import Foundation

/// A calendar day with no time or time zone ("2026-12-01").
///
/// Show On and Due dates are days, not instants. Storing them as plain days keeps
/// "due December 1" meaning December 1 even if the user travels across time zones.
public struct LocalDate: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day containing `date` in `calendar`'s time zone.
    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    /// Parses the ISO form `yyyy-MM-dd`.
    public init?(iso: String) {
        let parts = iso.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { iso }

    public static func < (a: LocalDate, b: LocalDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public static func today(_ now: Date = Date(), calendar: Calendar = .current) -> LocalDate {
        LocalDate(now, calendar: calendar)
    }

    // MARK: Conversions

    public var components: DateComponents { DateComponents(year: year, month: month, day: day) }

    /// Midnight at the start of this day in `calendar`'s time zone.
    public func startOfDay(calendar: Calendar = .current) -> Date {
        calendar.date(from: components)!
    }

    /// This day at a given wall-clock time.
    public func at(hour: Int, minute: Int = 0, calendar: Calendar = .current) -> Date {
        var c = components
        c.hour = hour
        c.minute = minute
        return calendar.date(from: c)!
    }

    // MARK: Arithmetic

    public func adding(days n: Int, calendar: Calendar = .current) -> LocalDate {
        adding(.day, n, calendar: calendar)
    }

    public func adding(_ component: Calendar.Component, _ n: Int, calendar: Calendar = .current) -> LocalDate {
        // Do the math at noon so DST transitions never push us onto a neighbouring day.
        let noon = at(hour: 12, calendar: calendar)
        return LocalDate(calendar.date(byAdding: component, value: n, to: noon)!, calendar: calendar)
    }

    /// Whole days from `self` to `other` (positive when `other` is later).
    public func days(until other: LocalDate, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: at(hour: 12, calendar: calendar),
                                to: other.at(hour: 12, calendar: calendar)).day!
    }

    /// 1 = Sunday … 7 = Saturday (Foundation's convention).
    public func weekday(calendar: Calendar = .current) -> Int {
        calendar.component(.weekday, from: at(hour: 12, calendar: calendar))
    }

    /// The next date strictly after `self` that falls on `weekday` (1 = Sunday … 7 = Saturday).
    public func next(weekday target: Int, calendar: Calendar = .current) -> LocalDate {
        var delta = (target - weekday(calendar: calendar) + 7) % 7
        if delta == 0 { delta = 7 }
        return adding(days: delta, calendar: calendar)
    }
}
