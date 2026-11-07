import BuoyCore
import Foundation

// A small self-contained check runner for BuoyCore: `swift run BuoyChecks`.
// (XCTest and Swift Testing need a full Xcode install; this runs with just the Command Line Tools.)

var passed = 0
var failures: [String] = []
var currentGroup = ""

func group(_ name: String, _ body: () throws -> Void) {
    currentGroup = name
    do { try body() } catch { failures.append("[\(name)] threw: \(error)") }
}

func check(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    if condition { passed += 1 } else { failures.append("[\(currentGroup)] line \(line): \(message())") }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String = "", line: Int = #line) {
    check(actual == expected, "\(label) expected \(expected), got \(actual)", line: line)
}

// Fixed clock: Saturday 26 September 2026, 10:00 in New York.
var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/New_York")!
NSTimeZone.default = calendar.timeZone
func d(_ iso: String) -> LocalDate { LocalDate(iso: iso)! }
func at(_ iso: String, _ hour: Int = 10, _ minute: Int = 0) -> Date { d(iso).at(hour: hour, minute: minute, calendar: calendar) }
let now = at("2026-09-26")
let today = d("2026-09-26")

func place(_ task: BuoyTask, _ when: Date = now) -> Placement { Attention.placement(of: task, now: when, calendar: calendar) }

// MARK: - LocalDate

group("LocalDate") {
    expectEqual(today.weekday(calendar: calendar), 7, "Sep 26 2026 is a Saturday")
    expectEqual(d("2026-01-31").adding(.month, 1, calendar: calendar), d("2026-02-28"))
    expectEqual(d("2026-12-31").adding(days: 1, calendar: calendar), d("2027-01-01"))
    expectEqual(d("2026-11-01").days(until: d("2026-12-01"), calendar: calendar), 30)
    expectEqual(today.next(weekday: 2, calendar: calendar), d("2026-09-28"))
    expectEqual(today.next(weekday: 7, calendar: calendar), d("2026-10-03"), "next Saturday is strictly after")
    expectEqual(LocalDate(iso: "2026-13-01"), nil)
    // DST (Nov 1 2026 in New York) doesn't disturb day arithmetic.
    expectEqual(d("2026-10-31").adding(days: 2, calendar: calendar), d("2026-11-02"))
}

// MARK: - Attention (PRD §5, §13)

group("Attention") {
    check(place(BuoyTask(title: "Buy light bulbs")) == .today(.anytime), "undated tasks are in Today")

    let deferred = BuoyTask(title: "Research landscaping", showOn: d("2027-03-01"))
    check(place(deferred).isUpcoming, "future Show On stays out of Today")
    check(place(deferred, at("2027-03-01", 0, 1)) == .today(.showOn), "rises on its Show On date")

    let passport = BuoyTask(title: "Renew passport", dueOn: d("2026-12-01"), leadDays: 30)
    expectEqual(passport.leadStart(calendar: calendar), d("2026-11-01"), "lead window opens Nov 1")
    check(place(passport, at("2026-10-31")).isUpcoming, "not before the lead window")
    check(place(passport, at("2026-11-01")) == .today(.leadTime(daysLeft: 30)), "surfaces when the lead window starts")

    let license = BuoyTask(title: "Renew driver's license", dueOn: d("2026-11-30"), leadDays: 14)
    expectEqual(license.leadStart(calendar: calendar), d("2026-11-16"), "PRD example: Nov 16")

    let registration = BuoyTask(title: "Submit registration", dueOn: d("2026-10-15"))
    check(place(registration).isUpcoming, "due date without lead time waits")
    check(place(registration, at("2026-10-15")) == .today(.dueToday), "due today is in Today")
    check(place(registration, at("2026-10-17")) == .today(.overdue(days: 2)), "overdue is in Today")

    if case .upcoming(let rises, let snoozed) = place(registration) {
        expectEqual(LocalDate(rises, calendar: calendar), d("2026-10-15"))
        check(!snoozed, "not snoozed")
    } else { check(false, "expected upcoming") }

    var snoozed = BuoyTask(title: "Overdue but snoozed", dueOn: d("2026-09-20"))
    snoozed.snoozedUntil = at("2026-09-27", 0)
    check(place(snoozed) == .upcoming(risesAt: at("2026-09-27", 0), snoozed: true), "snooze hides even overdue tasks")
    check(place(snoozed, at("2026-09-27", 0, 1)) == .today(.overdue(days: 7)), "returns after snooze")
    expectEqual(snoozed.dueOn, d("2026-09-20"), "snooze never changes the due date")

    var snoozedFuture = BuoyTask(title: "Snoozed from Today", showOn: d("2026-12-01"))
    snoozedFuture.snoozedUntil = at("2026-09-26", 9)
    check(place(snoozedFuture) == .today(.snoozeEnded), "expired snooze rises back into Today")

    var surfaced = BuoyTask(title: "Pulled in early", showOn: d("2026-12-01"))
    surfaced.surfacedAt = now
    check(place(surfaced) == .today(.surfaced), "manually surfaced tasks are in Today")

    var done = BuoyTask(title: "Done", dueOn: d("2026-09-20"))
    done.completion = Completion(completedAt: now)
    check(place(done) == .logbook(completedAt: now), "completed tasks are in the Logbook")

    // Ordering
    let list = [
        BuoyTask(title: "undated", createdAt: at("2026-09-01")),
        BuoyTask(title: "undated, newer", createdAt: at("2026-09-20")),
        BuoyTask(title: "lead", dueOn: d("2026-09-29"), leadDays: 7),
        BuoyTask(title: "due today", dueOn: today),
        BuoyTask(title: "overdue 1", dueOn: d("2026-09-25")),
        BuoyTask(title: "overdue 5", dueOn: d("2026-09-21")),
        BuoyTask(title: "shown, due later", showOn: d("2026-09-20"), dueOn: d("2026-10-20")),
        BuoyTask(title: "future", showOn: d("2026-10-10")),
        done,
    ]
    expectEqual(Attention.today(list, now: now, calendar: calendar).map(\.task.title),
                ["overdue 5", "overdue 1", "due today", "lead", "shown, due later", "undated, newer", "undated"], "Today order: undated newest first")
    expectEqual(Attention.upcoming(list, now: now, calendar: calendar).map(\.task.title), ["future"])
    expectEqual(Attention.logbook(list).map(\.title), ["Done"])
}

// MARK: - Recurrence (PRD §8)

group("Recurrence") {
    let mortgageRule = RecurrenceRule(unit: .month, anchorOn: d("2026-10-01"))
    let mortgage = BuoyTask(title: "Pay mortgage", notes: "Account 123", dueOn: d("2026-10-01"), leadDays: 5,
                            recurrence: mortgageRule, tags: ["Finance"])
    let early = Recurrence.nextOccurrence(of: mortgage, completedOn: d("2026-09-28"), calendar: calendar)!
    expectEqual(early.dueOn, d("2026-11-01"), "paid early → next month")
    expectEqual(early.leadDays, 5, "keeps lead time")
    expectEqual(early.tags, ["Finance"], "keeps tags")
    expectEqual(early.notes, "Account 123", "keeps notes")
    expectEqual(early.recurrence?.unit, .month, "keeps rule")
    check(early.id != mortgage.id && early.completion == nil, "new active occurrence")

    let late = Recurrence.nextOccurrence(of: mortgage, completedOn: d("2026-10-05"), calendar: calendar)!
    expectEqual(late.dueOn, d("2026-11-01"), "paid a little late → still next month")
    let veryLate = Recurrence.nextOccurrence(of: mortgage, completedOn: d("2026-12-05"), calendar: calendar)!
    expectEqual(veryLate.dueOn, d("2027-01-01"), "missed occurrences are skipped, not piled up")

    // Month-end anchoring doesn't drift.
    let rent = BuoyTask(title: "Month end", dueOn: d("2026-01-31"), recurrence: RecurrenceRule(unit: .month, anchorOn: d("2026-01-31")))
    let feb = Recurrence.nextOccurrence(of: rent, completedOn: d("2026-01-31"), calendar: calendar)!
    expectEqual(feb.dueOn, d("2026-02-28"))
    let mar = Recurrence.nextOccurrence(of: feb, completedOn: d("2026-02-28"), calendar: calendar)!
    expectEqual(mar.dueOn, d("2026-03-31"), "back to the 31st after February")

    // Completion-based: HVAC filter.
    let hvac = BuoyTask(title: "Replace HVAC filter", recurrence: RecurrenceRule(unit: .day, interval: 90, mode: .completion))
    let nextFilter = Recurrence.nextOccurrence(of: hvac, completedOn: today, calendar: calendar)!
    expectEqual(nextFilter.showOn, d("2026-12-25"), "90 days after completion")
    check(place(nextFilter).isUpcoming, "next filter change waits in Upcoming")

    // Show On / Due spacing preserved.
    let weekly = BuoyTask(title: "Timesheet", showOn: d("2026-10-07"), dueOn: d("2026-10-09"),
                          recurrence: RecurrenceRule(unit: .week, anchorOn: d("2026-10-09")))
    let nextWeek = Recurrence.nextOccurrence(of: weekly, completedOn: d("2026-10-08"), calendar: calendar)!
    expectEqual(nextWeek.dueOn, d("2026-10-16"))
    expectEqual(nextWeek.showOn, d("2026-10-14"), "Show On stays two days before Due")

    // Undated daily task comes back tomorrow.
    let daily = BuoyTask(title: "Stretch", recurrence: RecurrenceRule(unit: .day, anchorOn: d("2026-09-01")))
    let tomorrow = Recurrence.nextOccurrence(of: daily, completedOn: today, calendar: calendar)!
    expectEqual(tomorrow.showOn, d("2026-09-27"))

    // Every 2 weeks, yearly.
    let biweekly = RecurrenceRule(unit: .week, interval: 2)
    expectEqual(Recurrence.firstOccurrence(of: biweekly, anchor: d("2026-01-02"), after: d("2026-09-26"), calendar: calendar), d("2026-10-09"), "20 fortnights after Jan 2")
    let yearly = RecurrenceRule(unit: .year)
    expectEqual(Recurrence.firstOccurrence(of: yearly, anchor: d("2024-02-29"), after: d("2026-09-26"), calendar: calendar), d("2027-02-28"))

    check(Recurrence.nextOccurrence(of: BuoyTask(title: "one-off"), completedOn: today, calendar: calendar) == nil, "non-recurring → nil")
}

// MARK: - Quick entry parsing (PRD §11)

group("QuickEntryParser") {
    let parser = QuickEntryParser(now: now, calendar: calendar)

    let passport = parser.parse("Renew passport due dec 1 lead 30d #finance")
    expectEqual(passport.title, "Renew passport")
    expectEqual(passport.dueOn, d("2026-12-01"))
    expectEqual(passport.leadDays, 30)
    expectEqual(passport.tags, ["finance"])

    expectEqual(parser.parse("Research landscaping ideas show mar 1").showOn, d("2027-03-01"), "past month/day rolls to next year")
    expectEqual(parser.parse("Work on report").title, "Work on report", "'on' without a date is just a word")
    expectEqual(parser.parse("Read book by Tolkien").title, "Read book by Tolkien")
    expectEqual(parser.parse("Read book by Tolkien").dueOn, nil)

    let call = parser.parse("Call mom tomorrow")
    expectEqual(call.title, "Call mom")
    expectEqual(call.showOn, d("2026-09-27"))

    let mortgage = parser.parse("Pay mortgage due oct 1 every month #home #Finance")
    expectEqual(mortgage.title, "Pay mortgage")
    expectEqual(mortgage.dueOn, d("2026-10-01"))
    expectEqual(mortgage.recurrence?.unit, .month)
    expectEqual(mortgage.recurrence?.mode, .schedule)
    expectEqual(mortgage.recurrence?.anchorOn, d("2026-10-01"))
    expectEqual(mortgage.tags, ["Finance", "home"])

    let hvac = parser.parse("Replace HVAC filter every 90 days after done")
    expectEqual(hvac.title, "Replace HVAC filter")
    expectEqual(hvac.recurrence?.interval, 90)
    expectEqual(hvac.recurrence?.unit, .day)
    expectEqual(hvac.recurrence?.mode, .completion)

    let sync = parser.parse("Team sync every monday")
    expectEqual(sync.title, "Team sync")
    expectEqual(sync.recurrence?.unit, .week)
    expectEqual(sync.showOn, d("2026-09-28"))

    expectEqual(parser.parse("x due 10/15").dueOn, d("2026-10-15"))
    expectEqual(parser.parse("x due 1/5/27").dueOn, d("2027-01-05"))
    expectEqual(parser.parse("x due fri").dueOn, d("2026-10-02"))
    expectEqual(parser.parse("x due next week").dueOn, d("2026-09-28"))
    expectEqual(parser.parse("x due next month").dueOn, d("2026-10-01"))
    expectEqual(parser.parse("x due in 2 weeks").dueOn, d("2026-10-10"))
    expectEqual(parser.parse("x due in 3 days").dueOn, d("2026-09-29"))
    expectEqual(parser.parse("x due 2026-12-01").dueOn, d("2026-12-01"))
    expectEqual(parser.parse("x due dec 1st 2027").dueOn, d("2027-12-01"))
    expectEqual(parser.parse("x due 1 dec").dueOn, d("2026-12-01"))
    expectEqual(parser.parse("x due today").dueOn, today)
    expectEqual(parser.parse("x due end of month").dueOn, d("2026-09-30"))
    expectEqual(parser.parse("x show weekend").showOn, d("2026-09-26"), "it's already the weekend")
    expectEqual(parser.parse("x lead 2 weeks due dec 1").leadDays, 14)
    expectEqual(parser.parse("x due dec 1 warn 1 month").leadDays, 30)
    expectEqual(parser.parse("x every other week").recurrence?.interval, 2)
    expectEqual(parser.parse("x repeat monthly").recurrence?.unit, .month)
    expectEqual(parser.parse("x every 3 months after completion").recurrence?.mode, .completion)
    expectEqual(parser.parse("x due feb 30").title, "x due feb 30", "invalid date stays in the title")
    expectEqual(parser.parse("Plan the weekly review").recurrence, nil, "'weekly' alone isn't a repeat")
}

// MARK: - Snooze (PRD §6)

group("Snooze") {
    expectEqual(SnoozeOption.laterToday.wakeDate(from: now, calendar: calendar), at("2026-09-26", 13))
    expectEqual(SnoozeOption.laterToday.wakeDate(from: at("2026-09-26", 22, 30), calendar: calendar), at("2026-09-27", 0))
    expectEqual(SnoozeOption.tomorrow.wakeDate(from: now, calendar: calendar), at("2026-09-27", 0))
    expectEqual(SnoozeOption.thisWeekend.wakeDate(from: now, calendar: calendar), at("2026-09-27", 0), "Saturday → Sunday")
    expectEqual(SnoozeOption.thisWeekend.wakeDate(from: at("2026-09-30"), calendar: calendar), at("2026-10-03", 0))
    expectEqual(SnoozeOption.nextWeek.wakeDate(from: now, calendar: calendar), at("2026-09-28", 0))
    expectEqual(SnoozeOption.until(d("2026-10-15")).wakeDate(from: now, calendar: calendar), at("2026-10-15", 0))
}

// MARK: - Notifications (PRD §10)

group("NotificationPlanner") {
    let prefs = NotificationPreferences(hour: 9)
    let rent = BuoyTask(title: "Pay rent", dueOn: d("2026-10-01"), leadDays: 3)
    let plan = NotificationPlanner.plan(tasks: [rent], now: now, preferences: prefs, calendar: calendar)
    expectEqual(plan.map(\.fireAt), [at("2026-09-28", 9), at("2026-10-01", 9)], "rises, then due")
    expectEqual(plan.map(\.title), ["Now in Today", "Due today"])

    let a = BuoyTask(title: "A", dueOn: d("2026-10-02"))
    let b = BuoyTask(title: "B", dueOn: d("2026-10-02"))
    let grouped = NotificationPlanner.plan(tasks: [a, b], now: now, preferences: prefs, calendar: calendar)
    expectEqual(grouped.count, 1, "same-time notifications are combined")
    expectEqual(grouped.first?.title, "2 tasks due today")

    var snoozed = BuoyTask(title: "Snoozed")
    snoozed.snoozedUntil = at("2026-09-27", 0)
    let wake = NotificationPlanner.plan(tasks: [snoozed], now: now, preferences: prefs, calendar: calendar)
    expectEqual(wake.map(\.fireAt), [at("2026-09-27", 9)], "midnight snoozes announce at the usual time")

    var off = prefs
    off.enabled = false
    check(NotificationPlanner.plan(tasks: [rent], now: now, preferences: off, calendar: calendar).isEmpty, "disabled → nothing")
    off = prefs
    off.whenActive = false
    expectEqual(NotificationPlanner.plan(tasks: [rent], now: now, preferences: off, calendar: calendar).count, 1)

    let many = (0..<100).map { BuoyTask(title: "T\($0)", dueOn: today.adding(days: $0 + 1, calendar: calendar)) }
    expectEqual(NotificationPlanner.plan(tasks: many, now: now, preferences: prefs, calendar: calendar).count, 60, "respects the system limit")
}

// MARK: - Storage, migrations, backup & restore (PRD §14–17)

group("Storage") {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buoy-checks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    var task = BuoyTask(title: "Renew passport", notes: "Photos first", dueOn: d("2026-12-01"), leadDays: 30,
                        recurrence: RecurrenceRule(unit: .year, anchorOn: d("2026-12-01")), tags: ["Finance", "Errands"])
    task.snoozedUntil = at("2026-09-27", 0)
    var done = BuoyTask(title: "Old task")
    done.completion = Completion(completedAt: now)

    do {
        let storage = try Storage(directory: dir)
        expectEqual(storage.db.userVersion, Migrations.latestVersion, "migrated to latest")
        try storage.repository.save([task, done])
        try storage.repository.setSetting("notify.hour", "8")
    }

    // Survives quitting and reopening.
    let reopened = try Storage(directory: dir)
    let loaded = try reopened.repository.loadAll()
    expectEqual(loaded.count, 2)
    let p = loaded.first { $0.id == task.id }
    expectEqual(p?.title, "Renew passport")
    expectEqual(p?.notes, "Photos first")
    expectEqual(p?.dueOn, d("2026-12-01"))
    expectEqual(p?.leadDays, 30)
    expectEqual(p?.tags, ["Errands", "Finance"])
    expectEqual(p?.recurrence?.unit, .year)
    expectEqual(p?.recurrence?.anchorOn, d("2026-12-01"))
    check(abs((p?.snoozedUntil?.timeIntervalSince1970 ?? 0) - at("2026-09-27", 0).timeIntervalSince1970) < 0.001, "snooze persisted")
    check(loaded.first { $0.id == done.id }?.isCompleted == true, "completion persisted")
    expectEqual(reopened.repository.setting("notify.hour"), "8")

    // Completing a recurring task saves the completion and its next occurrence together.
    var recurring = BuoyTask(title: "Pay mortgage", dueOn: d("2026-10-01"), recurrence: RecurrenceRule(unit: .month, anchorOn: d("2026-10-01")))
    try reopened.repository.save(recurring)
    let next = Recurrence.nextOccurrence(of: recurring, completedOn: today, calendar: calendar)!
    recurring.completion = Completion(completedAt: now, nextTaskID: next.id)
    try reopened.repository.save([recurring, next])
    let afterComplete = try reopened.repository.loadAll()
    expectEqual(afterComplete.first { $0.id == recurring.id }?.completion?.nextTaskID, next.id, "completion links next occurrence")
    expectEqual(afterComplete.first { $0.id == next.id }?.dueOn, d("2026-11-01"))
    try reopened.repository.delete(taskIDs: [recurring.id, next.id])

    // Tags: rename merges into an existing tag.
    try reopened.repository.renameTag("errands", to: "finance")
    expectEqual(try reopened.repository.loadAll().first { $0.id == task.id }?.tags, ["Finance"])

    // Backup, wipe, restore.
    let backupURL = dir.appendingPathComponent("manual-backup.sqlite")
    try reopened.backup(to: backupURL)
    check(!FileManager.default.fileExists(atPath: backupURL.path + "-wal"), "backup is a single file")
    let info = try Storage.validateBackup(at: backupURL)
    expectEqual(info.taskCount, 2)
    try reopened.repository.delete(taskIDs: [task.id, done.id])
    expectEqual(try reopened.repository.loadAll().count, 0)
    let safety = try reopened.restore(from: backupURL)
    expectEqual(try reopened.repository.loadAll().count, 2, "restored")
    check(FileManager.default.fileExists(atPath: safety.path), "safety copy made before restore")
    expectEqual(try Storage.validateBackup(at: safety).taskCount, 0, "safety copy holds the pre-restore state")

    // Not a backup.
    let junk = dir.appendingPathComponent("junk.sqlite")
    try "hello".write(to: junk, atomically: true, encoding: .utf8)
    var rejected = false
    do { _ = try Storage.validateBackup(at: junk) } catch { rejected = true }
    check(rejected, "rejects non-Buoy files")

    // Automatic backups: at most one per day.
    let first = try reopened.automaticBackupIfNeeded(now: Date())
    let second = try reopened.automaticBackupIfNeeded(now: Date())
    check(first != nil && second == nil, "one automatic backup per interval")

    // A database from a newer Buoy is refused and left untouched.
    let newerDir = dir.appendingPathComponent("newer")
    do {
        let s = try Storage(directory: newerDir)
        try s.db.setUserVersion(99)
    }
    var refused = false
    do { _ = try Storage(directory: newerDir) } catch is Migrations.MigrationError { refused = true }
    check(refused, "refuses a newer schema")
    let raw = try Database(path: newerDir.appendingPathComponent("Buoy.sqlite").path)
    expectEqual(raw.userVersion, 99, "newer database not modified")
}

// MARK: - Recurrence patterns

group("Recurrence patterns") {
    let mwf = RecurrenceRule(unit: .week, anchorOn: d("2026-09-28"), weekdays: [6, 2, 4, 2])
    expectEqual(mwf.weekdays, [2, 4, 6], "weekdays normalised")
    expectEqual(mwf.summary, "Every Mon, Wed, Fri")
    expectEqual(Recurrence.firstOccurrence(of: mwf, anchor: d("2026-09-28"), after: d("2026-09-28"), calendar: calendar), d("2026-09-30"))
    expectEqual(Recurrence.firstOccurrence(of: mwf, anchor: d("2026-09-28"), after: d("2026-10-02"), calendar: calendar), d("2026-10-05"))
    let biweekly = RecurrenceRule(unit: .week, interval: 2, anchorOn: d("2026-09-28"), weekdays: [2, 6])
    expectEqual(Recurrence.firstOccurrence(of: biweekly, anchor: d("2026-09-28"), after: d("2026-10-02"), calendar: calendar), d("2026-10-12"), "skips the off week")
    expectEqual(biweekly.summary, "Every other week on Mon, Fri")
    expectEqual(RecurrenceRule(unit: .week, weekdays: [2, 3, 4, 5, 6]).summary, "Every weekday")

    let secondTue = RecurrenceRule(unit: .month, anchorOn: d("2026-10-13"), monthOrdinal: 2, monthWeekday: 3)
    expectEqual(secondTue.summary, "Every month on the 2nd Tuesday")
    expectEqual(Recurrence.firstOccurrence(of: secondTue, anchor: d("2026-10-13"), after: d("2026-10-13"), calendar: calendar), d("2026-11-10"))
    let lastFri = RecurrenceRule(unit: .month, anchorOn: today, monthOrdinal: -1, monthWeekday: 6)
    expectEqual(Recurrence.firstOccurrence(of: lastFri, anchor: today, after: today, calendar: calendar), d("2026-10-30"))
    let lastDay = RecurrenceRule(unit: .month, anchorOn: d("2026-01-31"), monthOrdinal: -1)
    expectEqual(lastDay.summary, "Every month on the last day")
    expectEqual(Recurrence.firstOccurrence(of: lastDay, anchor: d("2026-01-31"), after: d("2026-01-31"), calendar: calendar), d("2026-02-28"))
    expectEqual(Recurrence.firstOccurrence(of: lastDay, anchor: d("2026-01-31"), after: d("2026-02-28"), calendar: calendar), d("2026-03-31"))
    let everyOtherLastDay = RecurrenceRule(unit: .month, interval: 2, anchorOn: d("2026-01-31"), monthOrdinal: -1)
    expectEqual(Recurrence.firstOccurrence(of: everyOtherLastDay, anchor: d("2026-01-31"), after: d("2026-01-31"), calendar: calendar), d("2026-03-31"))
    check(RecurrenceRule(unit: .month, monthOrdinal: 3).monthOrdinal == nil, "3rd without a weekday is invalid")

    let gym = BuoyTask(title: "Gym", showOn: d("2026-09-28"), recurrence: mwf)
    expectEqual(Recurrence.nextOccurrence(of: gym, completedOn: d("2026-09-28"), calendar: calendar)?.showOn, d("2026-09-30"))

    let parser = QuickEntryParser(now: now, calendar: calendar)
    let g = parser.parse("Gym every mon wed fri #health")
    expectEqual(g.title, "Gym")
    expectEqual(g.recurrence?.weekdays, [2, 4, 6])
    expectEqual(g.showOn, d("2026-09-28"), "starts on the first matching day")
    expectEqual(g.tags, ["health"])
    expectEqual(parser.parse("x every mon, wed and fri").recurrence?.weekdays, [2, 4, 6])
    expectEqual(parser.parse("x every mon/wed").recurrence?.weekdays, [2, 4])
    let standup = parser.parse("Standup every weekday")
    expectEqual(standup.recurrence?.weekdays, [2, 3, 4, 5, 6])
    expectEqual(standup.showOn, d("2026-09-28"))
    let club = parser.parse("Book club every 2nd tuesday")
    expectEqual(club.title, "Book club")
    expectEqual(club.recurrence?.monthOrdinal, 2)
    expectEqual(club.recurrence?.monthWeekday, 3)
    expectEqual(club.showOn, d("2026-10-13"))
    let card = parser.parse("Pay card every last day of the month")
    expectEqual(card.title, "Pay card")
    expectEqual(card.recurrence?.monthOrdinal, -1)
    expectEqual(card.showOn, d("2026-09-30"))
    expectEqual(parser.parse("Review every last friday").showOn, d("2026-10-30"))
    expectEqual(parser.parse("Team sync every monday").showOn, d("2026-09-28"))
}

// MARK: - Skip, aging, quick dates

group("Skip occurrence") {
    let mortgage = BuoyTask(title: "Pay mortgage", dueOn: d("2026-10-01"), leadDays: 5,
                            recurrence: RecurrenceRule(unit: .month, anchorOn: d("2026-10-01")))
    let skipped = Recurrence.skip(mortgage, today: today, calendar: calendar)
    expectEqual(skipped?.id, mortgage.id, "same task, not a new one")
    expectEqual(skipped?.dueOn, d("2026-11-01"))
    check(skipped?.isCompleted == false, "nothing logged")
    check(Recurrence.skip(BuoyTask(title: "one-off"), today: today, calendar: calendar) == nil, "only repeating tasks can be skipped")
}

group("Aging") {
    let old = BuoyTask(title: "Old", createdAt: at("2026-09-06"))
    expectEqual(Attention.lingeringDays(old, reason: .anytime, now: now, calendar: calendar), 20)
    expectEqual(Attention.lingeringDays(BuoyTask(title: "New", createdAt: at("2026-09-20")), reason: .anytime, now: now, calendar: calendar), nil)
    var withDue = old
    withDue.dueOn = d("2026-12-01")
    expectEqual(Attention.lingeringDays(withDue, reason: .showOn, now: now, calendar: calendar), nil, "deadlines speak for themselves")
    var backFromSnooze = old
    backFromSnooze.snoozedUntil = at("2026-09-20", 0)
    expectEqual(Attention.lingeringDays(backFromSnooze, reason: .snoozeEnded, now: now, calendar: calendar), nil, "snoozing resets the age")
}

group("QuickDates") {
    let presets = QuickDates.presets(today: today, calendar: calendar)
    expectEqual(presets.map(\.label), ["Today", "Tomorrow", "This Weekend", "Next Week", "In a Month"])
    expectEqual(presets.map(\.date), [today, d("2026-09-27"), today, d("2026-09-28"), d("2026-10-26")])
}

// MARK: - Migration v1 → v2

group("Migration v2") {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buoy-mig-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let taskID = UUID(), ruleID = UUID()
    do {
        // A database exactly as Buoy 1.0 left it.
        let v1 = try Database(path: dir.appendingPathComponent("Buoy.sqlite").path)
        try v1.execute(Migrations.all[0].sql)
        try v1.setUserVersion(1)
        try v1.run("INSERT INTO recurrence_rules (id, unit, interval, mode, anchor_on, created_at) VALUES (?, 'month', 1, 'schedule', '2026-10-01', 0)", ruleID)
        try v1.run("INSERT INTO tasks (id, title, due_on, recurrence_rule_id, created_at, updated_at) VALUES (?, 'Pay mortgage', '2026-10-01', ?, 0, 0)", taskID, ruleID)
    }
    let upgraded = try Storage(directory: dir)
    expectEqual(upgraded.db.userVersion, Migrations.latestVersion, "upgraded to the latest schema")
    let tasks = try upgraded.repository.loadAll()
    expectEqual(tasks.count, 1, "no data lost")
    expectEqual(tasks.first?.recurrence?.unit, .month)
    expectEqual(tasks.first?.recurrence?.weekdays, [])
    let backups = (try? FileManager.default.contentsOfDirectory(atPath: upgraded.backupsDirectory.path)) ?? []
    check(backups.contains { $0.hasPrefix("Buoy-before-migration-v1-to-") }, "backup written before migrating: \(backups)")

    // Pattern rules round-trip.
    let gym = BuoyTask(title: "Gym", showOn: d("2026-09-28"),
                       recurrence: RecurrenceRule(unit: .week, anchorOn: d("2026-09-28"), weekdays: [2, 4, 6]))
    let club = BuoyTask(title: "Club", recurrence: RecurrenceRule(unit: .month, monthOrdinal: -1, monthWeekday: 6))
    try upgraded.repository.save([gym, club])
    let reloaded = try upgraded.repository.loadAll()
    expectEqual(reloaded.first { $0.id == gym.id }?.recurrence?.weekdays, [2, 4, 6])
    expectEqual(reloaded.first { $0.id == club.id }?.recurrence?.monthOrdinal, -1)
    expectEqual(reloaded.first { $0.id == club.id }?.recurrence?.monthWeekday, 6)
}

// MARK: - Notes

group("Notes capture") {
    expectEqual(Note.capturedText(from: "> gate code is 4471"), "gate code is 4471")
    expectEqual(Note.capturedText(from: "  >idea"), "idea", "leading spaces and no space after >")
    expectEqual(Note.capturedText(from: ">"), "", "note mode with nothing typed yet")
    expectEqual(Note.capturedText(from: "Call Sam > tomorrow"), nil, "> only counts at the start")
    expectEqual(Note.capturedText(from: "Renew passport due dec 1"), nil, "ordinary tasks are untouched")
    expectEqual(Note.capturedText(from: "> call Sam tomorrow #work"), "call Sam tomorrow #work", "no dates or tags parsed")
    // Tasks still parse exactly as before.
    let parser = QuickEntryParser(now: now, calendar: calendar)
    expectEqual(parser.parse("Renew passport due dec 1 #finance").title, "Renew passport")
}

group("Notes text") {
    let note = Note(text: "\n  Gate code  \n4471\n\n- ask about parking\n")
    expectEqual(note.firstLine, "Gate code")
    expectEqual(note.remainder, "4471 - ask about parking")
    check(Note(text: " \n ").isBlank, "whitespace-only is blank")
    // Copy keeps text exactly as typed (bullets, #tags, **bold**), trimming only the end.
    let a = Note(text: "- one\n- **two** #work\n\n")
    let b = Note(text: "second")
    expectEqual(Note.clipboardText([a, b]), "- one\n- **two** #work\n\nsecond")
    expectEqual(Note.clipboardText([Note(text: "  "), b]), "second", "blank notes are skipped")
}

group("Notes conversion") {
    let task = BuoyTask(title: "Pay rent", notes: "Portal: rent.example.com\n", dueOn: d("2026-10-01"), leadDays: 5,
                        recurrence: RecurrenceRule(unit: .month), tags: ["Finance", "Home Office"])
    expectEqual(Note(convertingTask: task).text, "Pay rent #Finance #Home-Office\nPortal: rent.example.com")
    expectEqual(Note(convertingTask: BuoyTask(title: "Call Sam")).text, "Call Sam", "no notes, no tags")

    let back = Note(text: "\n Retro ideas #work \n- keep it short\n\n- ask Dana\n").asTask
    expectEqual(back.title, "Retro ideas #work", "first line is the title, not parsed")
    expectEqual(back.notes, "- keep it short\n\n- ask Dana")
    expectEqual(back.tags, [], "no tags created")
    check(back.dueOn == nil && back.showOn == nil && back.recurrence == nil, "undated: goes to Today")
    expectEqual(Note(text: "call Sam tomorrow").asTask.title, "call Sam tomorrow", "dates aren't parsed")
    check(place(back) == .today(.anytime), "lands in Today")
}

group("Notes storage") {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buoy-notes-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let taskID = UUID()
    do {
        // A database exactly as Buoy left it before Notes (schema v2), with a task in it.
        let v2 = try Database(path: dir.appendingPathComponent("Buoy.sqlite").path)
        try v2.execute(Migrations.all[0].sql)
        try v2.execute(Migrations.all[1].sql)
        try v2.setUserVersion(2)
        try v2.run("INSERT INTO tasks (id, title, notes, due_on, lead_days, created_at, updated_at) VALUES (?, 'Pay rent', 'portal', '2026-10-01', 5, 0, 0)", taskID)
    }
    let storage = try Storage(directory: dir)
    expectEqual(storage.db.userVersion, Migrations.latestVersion, "upgraded to the latest schema")
    let tasks = try storage.repository.loadAll()
    expectEqual(tasks.map(\.title), ["Pay rent"], "tasks survive the upgrade")
    expectEqual(tasks.first?.id, taskID)
    expectEqual(tasks.first?.leadDays, 5)
    let backups = (try? FileManager.default.contentsOfDirectory(atPath: storage.backupsDirectory.path)) ?? []
    check(backups.contains { $0.hasPrefix("Buoy-before-migration-v2-to-") }, "backup written before adding notes: \(backups)")
    expectEqual(try storage.repository.loadNotes(), [], "no notes yet")

    let first = Note(text: "gate code 4471", createdAt: at("2026-09-25"))
    var second = Note(text: "idea: #work retro\n- keep it short", createdAt: at("2026-09-26"))
    try storage.repository.save([first, second])
    expectEqual(try storage.repository.loadNotes().map(\.id), [second.id, first.id], "newest first")

    second.archivedAt = at("2026-09-26", 12)
    second.text += "\n- edited"
    try storage.repository.save(second)
    let reloaded = try storage.repository.loadNotes()
    expectEqual(reloaded.first { $0.id == second.id }?.text, "idea: #work retro\n- keep it short\n- edited", "text kept exactly")
    check(reloaded.first { $0.id == second.id }?.isArchived == true, "archived notes are kept")
    expectEqual(try storage.repository.allTagNames(), [], "#tags in notes don't become Buoy tags")

    try storage.repository.delete(noteIDs: [first.id])
    expectEqual(try storage.repository.loadNotes().map(\.id), [second.id])
    expectEqual(try storage.repository.loadAll().count, 1, "tasks untouched by notes")

    // Rolling back to Buoy before Notes: drop the table and the version, and tasks are intact.
    try storage.db.execute("DROP TABLE notes; PRAGMA user_version = 2")
    expectEqual(try Migrations.pending(for: storage.db).map(\.version).first, 3, "old schema again")
    expectEqual(try storage.repository.loadAll().map(\.title), ["Pay rent"])
}

// MARK: - Agent links (buoy://)

group("Agent links") {
    func parse(_ s: String) -> Result<AgentLink, AgentLinkError> { AgentLink.parse(URL(string: s)!, today: today) }
    func command(_ s: String) -> AgentCommand? { if case .success(let link) = parse(s) { link.command } else { nil } }
    func error(_ s: String) -> AgentLinkError? { if case .failure(let e) = parse(s) { e } else { nil } }

    // add
    let add = parse("buoy://add?key=K1&title=Renew%20passport&notes=Form%20DS-82%0Aphotos&due_on=2026-12-01&lead_days=30&tags=Finance,%20travel")
    if case .success(let link) = add, case .add(let f, let id) = link.command {
        expectEqual(link.key, "K1")
        expectEqual(f.title, "Renew passport", "percent-decoded")
        expectEqual(f.notes, "Form DS-82\nphotos", "newlines survive")
        expectEqual(f.dueOn, d("2026-12-01"))
        expectEqual(f.leadDays, 30)
        expectEqual(f.tags, ["Finance", "travel"], "comma-separated, trimmed")
        check(id == nil, "no id given")
    } else { check(false, "add should parse: \(add)") }
    if case .add(let f, _)? = command("buoy://add?key=K&title=Call%20mom%20tomorrow") {
        check(f.showOn == nil && f.dueOn == nil, "the title is not run through the date parser")
    } else { check(false, "plain add") }
    let chosen = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"
    if case .add(_, let id)? = command("buoy://add?key=K&title=X&id=\(chosen)") {
        expectEqual(id?.uuidString, chosen.uppercased(), "ids are uppercase UUIDs")
    } else { check(false, "add with id") }
    expectEqual(error("buoy://add?key=K"), .missing("title"))
    expectEqual(error("buoy://add?key=K&title=%20%20"), .missing("title"), "blank title")
    expectEqual(error("buoy://add?title=X"), .missing("key"))
    expectEqual(error("buoy://add?key=&title=X"), .missing("key"))
    expectEqual(error("buoy://add?key=K&title=X&due_on=2026-02-30"), .invalid("due_on", "2026-02-30"), "not a real date")
    expectEqual(error("buoy://add?key=K&title=X&due_on=2026-2-1"), .invalid("due_on", "2026-2-1"), "strict format")
    expectEqual(error("buoy://add?key=K&title=X&show_on=tomorrow"), .invalid("show_on", "tomorrow"))
    expectEqual(error("buoy://add?key=K&title=X&lead_days=5"), .invalid("lead_days", "needs due_on"))
    expectEqual(error("buoy://add?key=K&title=X&due_on=2026-12-01&lead_days=-1"), .invalid("lead_days", "-1"))
    expectEqual(error("buoy://add?key=K&title=X&id=nope"), .invalid("id", "nope"))
    expectEqual(error("buoy://add?key=K&title=X&due=2026-12-01"), .unknownParameter("due"), "typos are rejected, not ignored")
    expectEqual(error("buoy://add?key=K&title=X&title=Y"), .duplicate("title"))
    expectEqual(error("buoy://destroy?key=K&id=\(chosen)"), .unknownAction("destroy"))

    // complete
    expectEqual(command("buoy://complete?key=K&id=\(chosen)"), .complete(.id(UUID(uuidString: chosen)!), result: nil))
    expectEqual(command("buoy://complete?key=K&title_match=Pay%20rent"), .complete(.titleMatch("Pay rent"), result: nil))
    expectEqual(error("buoy://complete?key=K"), .missing("id or title_match"))
    expectEqual(error("buoy://complete?key=K&id=\(chosen)&title_match=X"), .conflicting("id", "title_match"))

    // snooze
    expectEqual(command("buoy://snooze?key=K&id=\(chosen)&until=2026-10-01"), .snooze(id: UUID(uuidString: chosen)!, until: d("2026-10-01")))
    expectEqual(error("buoy://snooze?key=K&id=\(chosen)&until=2026-09-26"), .invalid("until", "2026-09-26 is not after today"))
    expectEqual(error("buoy://snooze?key=K&until=2026-10-01"), .missing("id"))

    // update
    if case .update(_, let c)? = command("buoy://update?key=K&id=\(chosen)&due_on=&title=New%20title&tags=") {
        check(c.dueOn == .some(nil), "empty due_on clears it")
        check(c.showOn == nil, "absent show_on is left alone")
        expectEqual(c.title, "New title")
        expectEqual(c.tags, [], "empty tags clears them")
        let before = BuoyTask(title: "Old", showOn: d("2026-10-01"), dueOn: d("2026-10-05"), tags: ["Home"])
        let after = c.applied(to: before)
        check(after.title == "New title" && after.dueOn == nil && after.showOn == d("2026-10-01") && after.tags.isEmpty, "applied")
    } else { check(false, "update should parse") }
    expectEqual(error("buoy://update?key=K&id=\(chosen)"), .missing("a field to change"))
    expectEqual(error("buoy://update?key=K&id=\(chosen)&title="), .invalid("title", "empty"))

    // note
    expectEqual(command("buoy://note?key=K&text=gate%20code%204471%20%23home"), .note("gate code 4471 #home"))
    expectEqual(error("buoy://note?key=K&text="), .missing("text"))

    // title_match: exactly one open task, or nothing happens.
    var done = BuoyTask(title: "Water plants")
    done.completion = Completion(completedAt: now)
    let tasks = [BuoyTask(title: "Pay rent"), BuoyTask(title: "Call Sam"), BuoyTask(title: "call sam "), done, BuoyTask(title: "Water plants")]
    if case .success(let t) = AgentLink.resolve(titleMatch: " pay RENT", in: tasks) { expectEqual(t.title, "Pay rent") } else { check(false, "one match") }
    if case .failure(.ambiguous(_, let m)) = AgentLink.resolve(titleMatch: "Call Sam", in: tasks) { expectEqual(m.count, 2) } else { check(false, "two matches") }
    if case .failure(.noMatch) = AgentLink.resolve(titleMatch: "Pay", in: tasks) {} else { check(false, "no partial matching") }
    if case .success = AgentLink.resolve(titleMatch: "Water plants", in: tasks) {} else { check(false, "completed tasks don't count") }
}

group("Source attribution") {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buoy-src-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let mine = UUID(), noteID = UUID()
    do {
        // A database as Buoy with Notes left it (v3), with a task and a note.
        let v3 = try Database(path: dir.appendingPathComponent("Buoy.sqlite").path)
        for m in Migrations.all where m.version <= 3 { try v3.execute(m.sql) }
        try v3.setUserVersion(3)
        try v3.run("INSERT INTO tasks (id, title, created_at, updated_at) VALUES (?, 'Mine', 0, 0)", mine)
        try v3.run("INSERT INTO notes (id, text, created_at, updated_at) VALUES (?, 'my note', 0, 0)", noteID)
    }
    let storage = try Storage(directory: dir)
    let backups = (try? FileManager.default.contentsOfDirectory(atPath: storage.backupsDirectory.path)) ?? []
    check(backups.contains { $0.hasPrefix("Buoy-before-migration-v3-to-") }, "backup before adding source: \(backups)")
    expectEqual(try storage.repository.loadAll().first?.source, .user, "existing tasks are yours")
    expectEqual(try storage.repository.loadNotes().first?.source, .user, "existing notes are yours")
    let theirs = BuoyTask(title: "From the agent", recurrence: RecurrenceRule(unit: .week), source: .agent)
    try storage.repository.save(theirs)
    try storage.repository.save(Note(text: "agent note", source: .agent))
    expectEqual(try storage.repository.loadAll().first { $0.id == theirs.id }?.source, .agent)
    expectEqual(try storage.repository.loadNotes().first { $0.text == "agent note" }?.source, .agent)
    expectEqual(Recurrence.nextOccurrence(of: theirs, completedOn: today, now: now, calendar: calendar)?.source, .agent, "repeats keep their source")
    expectEqual(Note(convertingTask: theirs).source, .agent, "conversions keep their source")
}

group("Review gate") {
    let waiting = BuoyTask(title: "Agent idea", dueOn: d("2026-09-26"), source: .agent, pendingReview: true)
    let laterWaiting = BuoyTask(title: "Agent later", showOn: d("2026-10-05"), source: .agent, pendingReview: true)
    var doneWaiting = BuoyTask(title: "Agent done", source: .agent, pendingReview: true)
    doneWaiting.completion = Completion(completedAt: now)
    let accepted = BuoyTask(title: "Agent accepted", source: .agent)
    let all = [waiting, laterWaiting, doneWaiting, accepted]
    expectEqual(Attention.today(all, now: now, calendar: calendar).map(\.task.title), ["Agent accepted"], "pending tasks aren't in Today")
    expectEqual(Attention.upcoming(all, now: now, calendar: calendar).count, 0, "or Upcoming")
    expectEqual(Attention.logbook(all).count, 0, "or the Logbook")
    let plan = NotificationPlanner.plan(tasks: [waiting, laterWaiting], now: now, preferences: NotificationPreferences(hour: 9), calendar: calendar)
    expectEqual(plan.count, 0, "and send no notifications")
    var nowAccepted = waiting
    nowAccepted.pendingReview = false
    check(place(nowAccepted) == .today(.dueToday), "once accepted it goes where its dates say")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buoy-gate-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let mine = UUID()
    do {
        let v4 = try Database(path: dir.appendingPathComponent("Buoy.sqlite").path)
        for m in Migrations.all where m.version <= 4 { try v4.execute(m.sql) }
        try v4.setUserVersion(4)
        try v4.run("INSERT INTO tasks (id, title, created_at, updated_at) VALUES (?, 'Mine', 0, 0)", mine)
    }
    let storage = try Storage(directory: dir)
    expectEqual(storage.db.userVersion, Migrations.latestVersion)
    let loaded = try storage.repository.loadAll()
    check(loaded.first?.pendingReview == false, "existing tasks aren't pending")
    try storage.repository.save(waiting)
    check(try storage.repository.loadAll().first { $0.id == waiting.id }?.pendingReview == true, "pending round-trips")
    try storage.repository.save(nowAccepted)
    check(try storage.repository.loadAll().first { $0.id == waiting.id }?.pendingReview == false, "accepting is saved")
    let backups = (try? FileManager.default.contentsOfDirectory(atPath: storage.backupsDirectory.path)) ?? []
    check(backups.contains { $0.hasPrefix("Buoy-before-migration-v4-to-") }, "backup before the review gate: \(backups)")
}

group("Projects") {
    // Where projects show up.
    let undated = BuoyTask(title: "Kitchen remodel", kind: .project)
    let dueToday = BuoyTask(title: "Tax filing", dueOn: today, kind: .project)
    let leadLater = BuoyTask(title: "Offsite", dueOn: d("2026-10-20"), leadDays: 7, kind: .project)
    let shows = BuoyTask(title: "Garden", showOn: d("2026-09-20"), kind: .project)
    var pulled = BuoyTask(title: "Pulled in", kind: .project)
    pulled.surfacedAt = now
    var gone = BuoyTask(title: "Deleted task")
    gone.deletedAt = now
    var finished = BuoyTask(title: "Shipped", kind: .project)
    finished.completion = Completion(completedAt: now)
    let all = [undated, dueToday, leadLater, shows, pulled, gone, finished, BuoyTask(title: "Plain task")]
    let todayTitles = Set(Attention.today(all, now: now, calendar: calendar).map(\.task.title))
    expectEqual(todayTitles, ["Tax filing", "Garden", "Pulled in", "Plain task"], "undated projects stay on the board; deleted items nowhere")
    expectEqual(Attention.upcoming(all, now: now, calendar: calendar).map(\.task.title), ["Offsite"], "dated projects rise like tasks")
    expectEqual(Attention.logbook(all).map(\.title), ["Shipped"], "finished projects go to the Logbook")
    check(undated.staysOnBoard && !dueToday.staysOnBoard && !BuoyTask(title: "t").staysOnBoard, "staysOnBoard")
    let notified = NotificationPlanner.plan(tasks: [undated, gone], now: now, preferences: NotificationPreferences(hour: 9), calendar: calendar)
    expectEqual(notified.count, 0, "no notifications for board-only projects or deleted tasks")

    // Board order.
    let a = BuoyTask(title: "A", kind: .project, boardColumn: .shaping, boardPosition: 1)
    let b = BuoyTask(title: "B", kind: .project, boardColumn: .shaping, boardPosition: 2)
    let c = BuoyTask(title: "C", kind: .project, boardColumn: .inProgress, boardPosition: 0)
    var pending = BuoyTask(title: "Pending", kind: .project, boardColumn: .shaping, boardPosition: 0)
    pending.pendingReview = true
    let board = [b, c, a, pending, finished, undated]
    expectEqual(Board.column(.shaping, of: board).map(\.title), ["Kitchen remodel", "A", "B"], "in position order; pending excluded")
    expectEqual(Board.column(.inProgress, of: board).map(\.title), ["C"])
    expectEqual(Board.done(board, now: now).map(\.title), ["Shipped"])
    let column = [a, b]
    expectEqual(Board.position(at: 0, in: column), 0, "top")
    expectEqual(Board.position(at: 2, in: column), 3, "bottom")
    expectEqual(Board.position(at: 1, in: column), 1.5, "between")
    expectEqual(Board.position(at: 0, in: []), 0, "empty column")

    // Repeating projects stay projects.
    let monthly = BuoyTask(title: "Monthly review", dueOn: d("2026-10-01"), recurrence: RecurrenceRule(unit: .month), kind: .project, boardColumn: .inProgress,
                           status: "Halfway", result: "Sent the report")
    let next = Recurrence.nextOccurrence(of: monthly, completedOn: today, now: now, calendar: calendar)
    expectEqual(next?.kind, .project)
    expectEqual(next?.boardColumn, .shaping, "the next round starts in Shaping")
    check(next?.status == "" && next?.result == "", "the next round starts without last round's status or result")

    // Links.
    let someIDForResult = UUID()
    func parse(_ s: String) -> Result<AgentLink, AgentLinkError> { AgentLink.parse(URL(string: s)!, today: today) }
    if case .success(let link) = parse("buoy://add?key=K&title=Kitchen&kind=project"), case .add(let f, _) = link.command {
        check(f.kind == .project, "add a project")
    } else { check(false, "project add should parse") }
    if case .failure(let e) = parse("buoy://add?key=K&title=X&kind=project&column=ready") { expectEqual(e, .unknownParameter("column")) }
    else { check(false, "agents can't choose a new project's column") }
    if case .failure(let e) = parse("buoy://update?key=K&id=\(UUID().uuidString)&position=top") { expectEqual(e, .unknownParameter("position")) }
    else { check(false, "agents can't reorder") }
    if case .success(let link) = parse("buoy://update?key=K&id=\(UUID().uuidString)&column=in_progress&status=%20Reading%20the%20docs%20"),
       case .update(_, let ch) = link.command {
        check(ch.column == .inProgress && ch.status == "Reading the docs", "claim with a status")
        let t = ch.applied(to: BuoyTask(title: "P", kind: .project, boardColumn: .ready))
        check(t.boardColumn == .inProgress && t.status == "Reading the docs", "applied")
    } else { check(false, "update column and status") }
    if case .success(let link) = parse("buoy://complete?key=K&id=\(someIDForResult.uuidString)&result=Wrote%20the%20plan"),
       case .complete(.id(let id), let result) = link.command {
        check(id == someIDForResult && result == "Wrote the plan", "complete with a result")
    } else { check(false, "complete with result") }
    if case .failure(let e) = parse("buoy://update?key=K&id=\(UUID().uuidString)&column=doing") {
        expectEqual(e, .invalid("column", "doing (ready, in_progress or review)"))
    } else { check(false, "old column names rejected") }
    if case .success(let link) = parse("buoy://add?key=K&title=Plain"), case .add(let f, _) = link.command {
        check(f.kind == .task, "kind defaults to task")
    } else { check(false, "plain add") }
    if case .failure(.invalid(let p, let why)) = parse("buoy://update?key=K&id=\(UUID().uuidString)&column=done") {
        check(p == "column" && why.contains("column=review"), "column=done points at review: \(why)")
    } else { check(false, "column=done rejected") }
    if case .failure(let e) = parse("buoy://add?key=K&title=X&kind=epic") { expectEqual(e, .invalid("kind", "epic (task or project)")) }
    else { check(false, "bad kind") }
    let someID = UUID()
    if case .success(let link) = parse("buoy://delete?key=K&id=\(someID.uuidString)") { expectEqual(link.command, .delete(someID)) }
    else { check(false, "delete parses") }
    if case .failure(let e) = parse("buoy://delete?key=K") { expectEqual(e, .missing("id")) } else { check(false, "delete needs id") }
    if case .success(let link) = parse("buoy://update?key=K&id=\(someID.uuidString)&kind=project"), case .update(_, let ch) = link.command {
        expectEqual(ch.applied(to: BuoyTask(title: "T")).kind, .project, "update converts")
    } else { check(false, "update kind") }
}

group("Projects storage") {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buoy-proj-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let mine = UUID(), noteID = UUID()
    do {
        let v5 = try Database(path: dir.appendingPathComponent("Buoy.sqlite").path)
        for m in Migrations.all where m.version <= 5 { try v5.execute(m.sql) }
        try v5.setUserVersion(5)
        try v5.run("INSERT INTO tasks (id, title, created_at, updated_at) VALUES (?, 'Mine', 0, 0)", mine)
        try v5.run("INSERT INTO notes (id, text, created_at, updated_at) VALUES (?, 'note', 0, 0)", noteID)
    }
    let storage = try Storage(directory: dir)
    expectEqual(storage.db.userVersion, Migrations.latestVersion)
    let backups = (try? FileManager.default.contentsOfDirectory(atPath: storage.backupsDirectory.path)) ?? []
    check(backups.contains { $0.hasPrefix("Buoy-before-migration-v5-to-") }, "backup before projects: \(backups)")
    let loaded = try storage.repository.loadAll().first
    check(loaded?.kind == .task && loaded?.boardColumn == .shaping && loaded?.deletedAt == nil, "existing tasks stay tasks")
    check(try storage.repository.loadNotes().first?.deletedAt == nil, "existing notes aren't deleted")

    var project = BuoyTask(title: "Remodel", kind: .project, boardColumn: .inProgress, boardPosition: -2.5,
                           status: "Getting quotes", result: "")
    try storage.repository.save(project)
    let back = try storage.repository.loadAll().first { $0.id == project.id }
    check(back?.kind == .project && back?.boardColumn == .inProgress && back?.boardPosition == -2.5
          && back?.status == "Getting quotes", "project round-trips")

    // Agent deletes are kept, then purged after 30 days.
    project.deletedAt = now.addingTimeInterval(-31 * 86_400)
    try storage.repository.save(project)
    var recent = BuoyTask(title: "Recently deleted")
    recent.deletedAt = now.addingTimeInterval(-86_400)
    try storage.repository.save(recent)
    try storage.repository.save(Note(text: "old", deletedAt: now.addingTimeInterval(-40 * 86_400)))
    try storage.repository.purgeDeleted(before: now.addingTimeInterval(-30 * 86_400))
    let remaining = try storage.repository.loadAll().map(\.title).sorted()
    expectEqual(remaining, ["Mine", "Recently deleted"], "only deletes older than 30 days are purged")
    expectEqual(try storage.repository.loadNotes().map(\.text), ["note"], "old deleted notes purged")
}

group("Later") {
    let parser = QuickEntryParser(now: now, calendar: calendar)
    let parked = parser.parse("Research standing desks later")
    expectEqual(parked.title, "Research standing desks")
    check(parked.later, "trailing “later” parks it")
    let alone = parser.parse("later")
    check(alone.title == "later" && !alone.later, "a lone “later” is just a title")
    check(parser.parse("Call Sam later.").later, "punctuation after “later” is fine")
    check(!parser.parse("Later: plan the party").later, "only the last word counts")
    let withDate = parser.parse("Book the venue due fri later")
    check(withDate.later && withDate.dueOn != nil, "dates still parse alongside later")

    func p(_ t: BuoyTask, _ when: Date = now) -> Placement { Attention.placement(of: t, now: when, calendar: calendar) }
    expectEqual(p(BuoyTask(title: "Someday", later: true)), .later, "undated + later → Later")
    expectEqual(p(BuoyTask(title: "Shown", showOn: d("2026-09-20"), later: true)), .later, "Show On doesn't override Later")
    expectEqual(p(BuoyTask(title: "Due", dueOn: today, later: true)), .today(.dueToday), "deadlines win: due today")
    expectEqual(p(BuoyTask(title: "Late", dueOn: d("2026-09-24"), later: true)), .today(.overdue(days: 2)), "deadlines win: overdue")
    expectEqual(p(BuoyTask(title: "Lead", dueOn: d("2026-09-30"), leadDays: 7, later: true)), .today(.leadTime(daysLeft: 4)), "deadlines win: lead time")
    expectEqual(p(BuoyTask(title: "Far", dueOn: d("2026-12-01"), leadDays: 7, later: true)), .later, "a far deadline waits in Later")
    var snoozed = BuoyTask(title: "Snoozed", later: true)
    snoozed.snoozedUntil = at("2026-09-28", 0)
    check(p(snoozed).isUpcoming, "a snoozed Later task waits in Upcoming…")
    expectEqual(p(snoozed, at("2026-09-28", 1)), .later, "…and returns to Later")

    let tasks = [BuoyTask(title: "Now"), BuoyTask(title: "Old parked", createdAt: at("2026-09-01"), later: true),
                 BuoyTask(title: "New parked", createdAt: at("2026-09-20"), later: true),
                 BuoyTask(title: "Due parked", dueOn: today, later: true)]
    expectEqual(Attention.later(tasks, now: now, calendar: calendar).map(\.title), ["New parked", "Old parked"], "Later list, newest first")
    expectEqual(Set(Attention.today(tasks, now: now, calendar: calendar).map(\.task.title)), ["Now", "Due parked"], "Today leaves parked tasks out")
    let plan = NotificationPlanner.plan(tasks: [BuoyTask(title: "Parked show", showOn: d("2026-09-28"), later: true),
                                                BuoyTask(title: "Parked due", dueOn: d("2026-09-29"), later: true)],
                                        now: now, preferences: NotificationPreferences(hour: 9), calendar: calendar)
    expectEqual(plan.map(\.body), ["Parked due"], "only the deadline notifies")
    let repeating = BuoyTask(title: "Weekly", dueOn: d("2026-09-20"), recurrence: RecurrenceRule(unit: .week), later: true)
    check(Recurrence.nextOccurrence(of: repeating, completedOn: today, now: now, calendar: calendar)?.later == true, "repeats stay in Later")

    // Links.
    if case .success(let link) = AgentLink.parse(URL(string: "buoy://add?key=K&title=X&later=1")!, today: today),
       case .add(let f, _) = link.command { check(f.later, "add later=1") } else { check(false, "add later") }
    if case .failure(let e) = AgentLink.parse(URL(string: "buoy://add?key=K&title=X&later=maybe")!, today: today) {
        expectEqual(e, .invalid("later", "maybe (1 or 0)"))
    } else { check(false, "bad later value") }
    if case .success(let link) = AgentLink.parse(URL(string: "buoy://update?key=K&id=\(UUID().uuidString)&later=0")!, today: today),
       case .update(_, let ch) = link.command {
        check(ch.applied(to: BuoyTask(title: "T", later: true)).later == false, "update later=0")
    } else { check(false, "update later") }

    // Storage.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buoy-later-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    do {
        let v6 = try Database(path: dir.appendingPathComponent("Buoy.sqlite").path)
        for m in Migrations.all where m.version <= 6 { try v6.execute(m.sql) }
        try v6.setUserVersion(6)
        try v6.run("INSERT INTO tasks (id, title, created_at, updated_at) VALUES (?, 'Mine', 0, 0)", UUID())
    }
    let storage = try Storage(directory: dir)
    expectEqual(storage.db.userVersion, Migrations.latestVersion)
    check(try storage.repository.loadAll().first?.later == false, "existing tasks aren't in Later")
    let backups = (try? FileManager.default.contentsOfDirectory(atPath: storage.backupsDirectory.path)) ?? []
    check(backups.contains { $0.hasPrefix("Buoy-before-migration-v6-to-") }, "backup before Later: \(backups)")
    let laterTask = BuoyTask(title: "Parked", later: true)
    try storage.repository.save(laterTask)
    check(try storage.repository.loadAll().first { $0.id == laterTask.id }?.later == true, "later round-trips")
}

group("Agent board") {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buoy-board-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let ids = (0..<4).map { _ in UUID() }
    do {
        let v7 = try Database(path: dir.appendingPathComponent("Buoy.sqlite").path)
        for m in Migrations.all where m.version <= 7 { try v7.execute(m.sql) }
        try v7.setUserVersion(7)
        for (id, column) in zip(ids, ["todo", "doing", "waiting"]) {
            try v7.run("INSERT INTO tasks (id, title, created_at, updated_at, kind, board_column, board_position) VALUES (?, ?, 0, 0, 'project', ?, 1)",
                       id, column, column)
        }
        try v7.run("INSERT INTO tasks (id, title, created_at, updated_at) VALUES (?, 'A task', 0, 0)", ids[3])
    }
    let storage = try Storage(directory: dir)
    expectEqual(storage.db.userVersion, Migrations.latestVersion)
    let loaded = try storage.repository.loadAll()
    expectEqual(loaded.count, 4, "nothing lost")
    check(loaded.allSatisfy { $0.boardColumn == .shaping && $0.status.isEmpty && $0.result.isEmpty },
          "every project starts over in Shaping: \(loaded.map(\.boardColumn))")
    check(loaded.filter(\.isProject).map(\.title).sorted() == ["doing", "todo", "waiting"], "projects stay projects")
    let backups = (try? FileManager.default.contentsOfDirectory(atPath: storage.backupsDirectory.path)) ?? []
    check(backups.contains { $0.hasPrefix("Buoy-before-migration-v7-to-") }, "backup before the agent board: \(backups)")
    var done = BuoyTask(title: "Delivered", kind: .project, boardColumn: .ready, result: "Wrote the plan\nand sent it")
    done.completion = Completion(completedAt: now)
    try storage.repository.save(done)
    let back = try storage.repository.loadAll().first { $0.id == done.id }
    check(back?.result == "Wrote the plan\nand sent it" && back?.boardColumn == .ready && back?.isCompleted == true, "result round-trips")

    let briefed = BuoyTask(title: "Brief", kind: .project, expectations: "A one-page PDF\nin my inbox")
    try storage.repository.save(briefed)
    expectEqual(try storage.repository.loadAll().first { $0.id == briefed.id }?.expectations, "A one-page PDF\nin my inbox", "expectations round-trip")
    let weekly = BuoyTask(title: "Weekly", dueOn: LocalDate(iso: "2026-10-01"), recurrence: RecurrenceRule(unit: .week), kind: .project, expectations: "Same as last week")
    expectEqual(Recurrence.nextOccurrence(of: weekly, completedOn: LocalDate(iso: "2026-10-01")!)?.expectations, "Same as last week", "the next round keeps the brief")

    func parse(_ s: String) -> Result<AgentLink, AgentLinkError> { AgentLink.parse(URL(string: s)!) }
    if case .success(let link) = parse("buoy://add?key=K&title=X&kind=project&expectations=A%20PDF"), case .add(let f, _) = link.command {
        expectEqual(f.expectations, "A PDF", "add with expectations")
    } else { check(false, "add with expectations") }
    if case .failure(let e) = parse("buoy://add?key=K&title=X&expectations=A%20PDF") { expectEqual(e, .invalid("expectations", "only for kind=project")) }
    else { check(false, "expectations need kind=project") }
    if case .success(let link) = parse("buoy://update?key=K&id=\(UUID().uuidString)&expectations=Two%20pages"), case .update(_, let ch) = link.command {
        expectEqual(ch.applied(to: BuoyTask(title: "P", kind: .project)).expectations, "Two pages", "update expectations")
    } else { check(false, "update expectations") }

    // Ready for review.
    if case .success(let link) = parse("buoy://update?key=K&id=\(UUID().uuidString)&column=review&result=Sent%20it"),
       case .update(_, let ch) = link.command {
        let t = ch.applied(to: BuoyTask(title: "P", kind: .project, boardColumn: .inProgress))
        check(t.boardColumn == .review && t.result == "Sent it", "hand in for review with a result")
    } else { check(false, "column=review parses") }
    expectEqual(BoardColumn.review.title, "Ready for review")
    expectEqual(BoardColumn.allCases, [.shaping, .ready, .inProgress, .review], "review sits between In progress and Done")
}

group("Level of effort") {
    func parse(_ s: String) -> Result<AgentLink, AgentLinkError> { AgentLink.parse(URL(string: s)!) }
    let id = UUID().uuidString
    if case .success(let link) = parse("buoy://add?key=K&title=X&effort_hours=2.5"), case .add(let f, _) = link.command {
        expectEqual(f.effortHours, 2.5, "add with effort, tasks too")
    } else { check(false, "add with effort") }
    if case .success(let link) = parse("buoy://update?key=K&id=\(id)&effort_hours=0.5"), case .update(_, let ch) = link.command {
        expectEqual(ch.applied(to: BuoyTask(title: "T")).effortHours, 0.5, "update effort")
    } else { check(false, "update effort") }
    if case .success(let link) = parse("buoy://update?key=K&id=\(id)&effort_hours="), case .update(_, let ch) = link.command {
        expectEqual(ch.applied(to: BuoyTask(title: "T", effortHours: 3)).effortHours, nil, "empty clears the estimate")
    } else { check(false, "clear effort") }
    for bad in ["0", "-1", "abc", "2000", "nan", "inf"] {
        if case .failure(.invalid(let p, _)) = parse("buoy://update?key=K&id=\(id)&effort_hours=\(bad)") { expectEqual(p, "effort_hours", bad) }
        else { check(false, "effort_hours=\(bad) rejected") }
    }
    expectEqual(Effort.format(0.5), "30m")
    expectEqual(Effort.format(0.25), "15m")
    expectEqual(Effort.format(1), "1h")
    expectEqual(Effort.format(1.5), "1.5h")
    expectEqual(Effort.format(2.25), "2.25h")
    expectEqual(Effort.format(12), "12h")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buoy-effort-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let old = UUID()
    do {
        let v9 = try Database(path: dir.appendingPathComponent("Buoy.sqlite").path)
        for m in Migrations.all where m.version <= 9 { try v9.execute(m.sql) }
        try v9.setUserVersion(9)
        try v9.run("INSERT INTO tasks (id, title, created_at, updated_at) VALUES (?, 'Old', 0, 0)", old)
    }
    let storage = try Storage(directory: dir)
    let loaded = try storage.repository.loadAll()
    check(loaded.count == 1 && loaded[0].effortHours == nil, "existing tasks start without an estimate")
    let sized = BuoyTask(title: "Sized", kind: .project, boardColumn: .review, effortHours: 1.5)
    try storage.repository.save(sized)
    let back = try storage.repository.loadAll().first { $0.id == sized.id }
    check(back?.effortHours == 1.5 && back?.boardColumn == .review, "effort and the review column round-trip")
    let weekly = BuoyTask(title: "Weekly", dueOn: LocalDate(iso: "2026-10-01"), recurrence: RecurrenceRule(unit: .week), effortHours: 2)
    expectEqual(Recurrence.nextOccurrence(of: weekly, completedOn: LocalDate(iso: "2026-10-01")!)?.effortHours, 2, "the next round keeps the estimate")
}

group("Reorder links") {
    func parse(_ s: String) -> Result<AgentLink, AgentLinkError> { AgentLink.parse(URL(string: s)!) }
    let a = UUID(), b = UUID()
    if case .success(let link) = parse("buoy://reorder?key=K&list=ready&ids=\(a.uuidString),%20\(b.uuidString)") {
        expectEqual(link.command, .reorder(.ready, [a, b]), "top first, spaces allowed")
    } else { check(false, "reorder ready parses") }
    if case .success(let link) = parse("buoy://reorder?key=K&list=Tasks&ids=\(b.uuidString),\(a.uuidString)") {
        expectEqual(link.command, .reorder(.tasks, [b, a]), "tasks, any case")
    } else { check(false, "reorder tasks parses") }
    if case .failure(let e) = parse("buoy://reorder?key=K&ids=\(a.uuidString)") { expectEqual(e, .missing("list")) } else { check(false, "reorder needs list") }
    if case .failure(let e) = parse("buoy://reorder?key=K&list=shaping&ids=\(a.uuidString)") { expectEqual(e, .invalid("list", "shaping (tasks or ready)"), "Shaping is yours") }
    else { check(false, "only today or ready") }
    if case .failure(let e) = parse("buoy://reorder?key=K&list=tasks") { expectEqual(e, .missing("ids")) } else { check(false, "reorder needs ids") }
    if case .failure(.invalid(let p, _)) = parse("buoy://reorder?key=K&list=tasks&ids=\(a.uuidString),nope") { expectEqual(p, "ids") }
    else { check(false, "bad id rejected") }
    if case .failure(.invalid(let p, let why)) = parse("buoy://reorder?key=K&list=tasks&ids=\(a.uuidString),\(a.uuidString)") {
        check(p == "ids" && why.contains("twice"), "duplicate rejected: \(why)")
    } else { check(false, "duplicate id rejected") }
    if case .failure(let e) = parse("buoy://reorder?key=K&list=tasks&ids=\(a.uuidString),") { if case .invalid("ids", _) = e {} else { check(false, "trailing comma: \(e)") } }
    else { check(false, "trailing comma rejected") }
}

group("Agent order in Today") {
    let now = d("2026-10-20").at(hour: 9)
    let overdue = BuoyTask(title: "Overdue", dueOn: d("2026-10-18"), createdAt: now.addingTimeInterval(-9000))
    let plain = BuoyTask(title: "Plain", createdAt: now.addingTimeInterval(-8000))
    let dueToday = BuoyTask(title: "Due today", dueOn: d("2026-10-20"), createdAt: now.addingTimeInterval(-7000))
    func order(_ tasks: [BuoyTask]) -> [String] { Attention.today(tasks, now: now).map(\.task.title) }
    expectEqual(order([plain, overdue, dueToday]), ["Overdue", "Due today", "Plain"], "unordered: most urgent first")
    var p = plain, o = overdue, t = dueToday
    p.agentRank = 0; t.agentRank = 1; o.agentRank = 2
    expectEqual(order([o, t, p]), ["Plain", "Due today", "Overdue"], "the agent's order wins")
    let fresh = BuoyTask(title: "Fresh", createdAt: now)
    let freshOverdue = BuoyTask(title: "Fresh overdue", dueOn: d("2026-10-01"), createdAt: now)
    expectEqual(order([o, t, p, fresh, freshOverdue]), ["Fresh overdue", "Fresh", "Plain", "Due today", "Overdue"],
                "new arrivals sit on top, most urgent first, until the agent orders again")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buoy-rank-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let storage = try Storage(directory: dir)
    try storage.repository.save(p)
    expectEqual(try storage.repository.loadAll().first?.agentRank, 0, "rank round-trips")
    let weekly = BuoyTask(title: "Weekly", dueOn: d("2026-10-01"), recurrence: RecurrenceRule(unit: .week), agentRank: 3)
    expectEqual(Recurrence.nextOccurrence(of: weekly, completedOn: d("2026-10-01"))?.agentRank, nil, "the next round arrives unordered")
}

group("Agent suggestions") {
    let today = d("2026-10-20")
    func parse(_ s: String) -> Result<AgentLink, AgentLinkError> { AgentLink.parse(URL(string: s)!, today: today) }
    let id = UUID()
    let base = "buoy://suggest?key=K&id=\(id.uuidString)"
    if case .success(let link) = parse(base + "&later=1&reason=%20Not%20urgent%20") {
        expectEqual(link.command, .suggest(id: id, .later, reason: "Not urgent"), "suggest Later")
    } else { check(false, "suggest later parses") }
    if case .success(let link) = parse(base + "&show_on=2026-10-23&reason=Tuesday") {
        expectEqual(link.command, .suggest(id: id, .showOn(d("2026-10-23")), reason: "Tuesday"), "suggest a Show On date")
    } else { check(false, "suggest show_on parses") }
    if case .success(let link) = parse(base + "&due_on=2026-10-20&reason=Today") {
        expectEqual(link.command, .suggest(id: id, .dueOn(today), reason: "Today"), "a due date today is fine")
    } else { check(false, "suggest due_on parses") }
    if case .success(let link) = parse(base + "&clear=1") { expectEqual(link.command, .suggest(id: id, nil, reason: ""), "withdraw") }
    else { check(false, "clear parses") }
    if case .failure(let e) = parse(base + "&later=1&show_on=2026-10-23&reason=x") { expectEqual(e, .conflicting("later", "show_on")) }
    else { check(false, "one move at a time") }
    if case .failure(let e) = parse(base + "&reason=x") { expectEqual(e, .missing("later=1, show_on or due_on")) } else { check(false, "needs a move") }
    if case .failure(let e) = parse(base + "&later=1") { expectEqual(e, .missing("reason")) } else { check(false, "needs a reason") }
    if case .failure(let e) = parse(base + "&later=1&reason=%20%20") { expectEqual(e, .missing("reason")) } else { check(false, "blank reason") }
    if case .failure(.invalid(let p, _)) = parse(base + "&show_on=2026-10-20&reason=x") { expectEqual(p, "show_on", "Show On must be after today") }
    else { check(false, "show_on today rejected") }
    if case .failure(.invalid(let p, _)) = parse(base + "&due_on=2026-10-19&reason=x") { expectEqual(p, "due_on", "no due dates in the past") }
    else { check(false, "past due_on rejected") }
    if case .failure(let e) = parse(base + "&clear=1&reason=x") { expectEqual(e, .conflicting("clear", "reason")) } else { check(false, "clear alone") }
    if case .failure(let e) = parse(base + "&later=0&reason=x") { if case .invalid("later", _) = e {} else { check(false, "later=0: \(e)") } }
    else { check(false, "later=0 rejected") }

    // Accepting does what you'd do by hand.
    var waiting = BuoyTask(title: "Ink", snoozedUntil: Date(), surfacedAt: Date())
    waiting.suggestion = Suggestion(move: .later, reason: "r")
    let parked = waiting.applying(.later, today: today)
    check(parked.later && parked.suggestion == nil && parked.snoozedUntil == nil && parked.surfacedAt == nil, "Later: parked, suggestion cleared")
    var inLater = BuoyTask(title: "Bike", later: true)
    inLater = inLater.applying(.showOn(d("2026-11-01")), today: today)
    check(inLater.showOn == d("2026-11-01") && !inLater.later, "a Show On date brings it out of Later")
    let monthly = BuoyTask(title: "Rent", dueOn: d("2026-11-01"), recurrence: RecurrenceRule(unit: .month, anchorOn: d("2026-11-01")))
    let moved = monthly.applying(.dueOn(d("2026-11-03")), today: today)
    check(moved.dueOn == d("2026-11-03") && moved.recurrence?.anchorOn == d("2026-11-03") && moved.recurrence?.id != monthly.recurrence?.id,
          "a new due date re-anchors the repeat")
    var dismissed = BuoyTask(title: "D")
    dismissed.suggestion = Suggestion(move: .later, reason: "r", dismissedAt: Date())
    check(dismissed.openSuggestion == nil && dismissed.suggestion != nil, "dismissed: kept, but not open")

    // Storage, from a v10 database.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buoy-suggest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let old = UUID()
    do {
        let v10 = try Database(path: dir.appendingPathComponent("Buoy.sqlite").path)
        for m in Migrations.all where m.version <= 10 { try v10.execute(m.sql) }
        try v10.setUserVersion(10)
        try v10.run("INSERT INTO tasks (id, title, created_at, updated_at) VALUES (?, 'Old', 0, 0)", old)
    }
    let storage = try Storage(directory: dir)
    expectEqual(try storage.repository.loadAll().first?.suggestion, nil, "existing tasks have no suggestion")
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    for (n, suggestion) in [Suggestion(move: .later, reason: "Not now", createdAt: at),
                            Suggestion(move: .showOn(d("2026-11-03")), reason: "Tuesday", createdAt: at),
                            Suggestion(move: .dueOn(d("2026-11-30")), reason: "End of month", createdAt: at, dismissedAt: at)].enumerated() {
        let t = BuoyTask(title: "S\(n)", suggestion: suggestion)
        try storage.repository.save(t)
        expectEqual(try storage.repository.loadAll().first { $0.id == t.id }?.suggestion, suggestion, "round-trips: \(suggestion.move.summary)")
    }
    var cleared = try storage.repository.loadAll().first { $0.title == "S0" }!
    cleared.suggestion = nil
    try storage.repository.save(cleared)
    expectEqual(try storage.repository.loadAll().first { $0.id == cleared.id }?.suggestion, nil, "clearing removes it")
}

group("Repeat links") {
    let today = d("2026-10-20") // a Tuesday
    func parse(_ s: String) -> Result<AgentLink, AgentLinkError> { AgentLink.parse(URL(string: s)!, today: today) }
    if case .success(let link) = parse("buoy://add?key=K&title=Exec%20update&due_on=2026-11-05&repeat=every%202%20weeks"),
       case .add(let f, _) = link.command, let rep = f.repeats {
        check(rep.rule.unit == .week && rep.rule.interval == 2 && rep.rule.mode == .schedule, "every 2 weeks")
        let t = rep.applied(to: BuoyTask(title: "Exec update", dueOn: d("2026-11-05")), today: today)
        expectEqual(t.recurrence?.anchorOn, d("2026-11-05"), "anchored on the due date")
        let next = Recurrence.nextOccurrence(of: t, completedOn: d("2026-11-05"))
        expectEqual(next?.dueOn, d("2026-11-19"), "two weeks later")
    } else { check(false, "add with repeat") }
    if case .success(let link) = parse("buoy://add?key=K&title=Gym&repeat=every%20mon%20wed%20fri"),
       case .add(let f, _) = link.command, let rep = f.repeats {
        expectEqual(rep.rule.weekdays, [2, 4, 6], "weekdays")
        expectEqual(rep.firstDay, d("2026-10-21"), "starts on the first matching day (Wednesday)")
    } else { check(false, "weekday repeat") }
    if case .success(let link) = parse("buoy://add?key=K&title=Exec&repeat=every%20other%20thursday"),
       case .add(let f, _) = link.command, let rep = f.repeats {
        check(rep.rule.unit == .week && rep.rule.interval == 2 && rep.rule.weekdays == [5], "every other thursday")
        expectEqual(rep.firstDay, d("2026-10-22"), "first Thursday")
        let t = rep.applied(to: BuoyTask(title: "Exec"), today: today)
        let next = Recurrence.nextOccurrence(of: t, completedOn: d("2026-10-22"))
        expectEqual(next?.showOn, d("2026-11-05"), "then two weeks on")
    } else { check(false, "every other thursday") }
    let saturday = d("2026-10-31")
    switch AgentLink.parse(URL(string: "buoy://add?key=K&title=Exec&repeat=every%20other%20thursday")!, today: saturday) {
    case .success(let link):
        if case .add(let f, _) = link.command { expectEqual(f.repeats?.firstDay, d("2026-11-05"), "from a Saturday: next Thursday") }
    case .failure(let e):
        let p = QuickEntryParser(now: saturday.at(hour: 12)).parse("x every other thursday")
        check(false, "from a Saturday: \(e); parser showOn \(String(describing: p.showOn)), firstMatch \(p.recurrence.map { Recurrence.firstMatch(of: $0, onOrAfter: saturday) }.map(String.init(describing:)) ?? "-")")
    }
    if case .success(let link) = parse("buoy://add?key=K&title=Filter&repeat=every%2090%20days%20after%20done"),
       case .add(let f, _) = link.command {
        check(f.repeats?.rule.mode == .completion && f.repeats?.rule.interval == 90, "after done")
    } else { check(false, "completion repeat") }
    if case .success(let link) = parse("buoy://update?key=K&id=\(UUID().uuidString)&repeat="), case .update(_, let ch) = link.command {
        let t = ch.applied(to: BuoyTask(title: "R", dueOn: today, recurrence: RecurrenceRule(unit: .month)), today: today)
        expectEqual(t.recurrence, nil, "empty repeat stops it repeating")
    } else { check(false, "clear repeat") }
    if case .success(let link) = parse("buoy://update?key=K&id=\(UUID().uuidString)&repeat=every%20last%20friday"),
       case .update(_, let ch) = link.command {
        let t = ch.applied(to: BuoyTask(title: "R", dueOn: d("2026-10-30")), today: today)
        check(t.recurrence?.monthOrdinal == -1 && t.recurrence?.anchorOn == d("2026-10-30"), "update to the last Friday, anchored on its due date")
    } else { check(false, "update repeat") }
    for bad in ["weekly%20on%20tuesday", "every", "every%202%20weeks%20due%20dec%201", "every%20week%20%23work", "every%20blue%20moon", "every%20week%20later"] {
        if case .failure(.invalid(let p, _)) = parse("buoy://add?key=K&title=X&repeat=\(bad)") { expectEqual(p, "repeat", bad) }
        else { check(false, "repeat=\(bad) rejected") }
    }
}

// MARK: - Report

print("")
if failures.isEmpty {
    print("✅ All \(passed) checks passed.")
    exit(0)
} else {
    print("❌ \(failures.count) failed, \(passed) passed:")
    for f in failures { print("  • \(f)") }
    exit(1)
}
