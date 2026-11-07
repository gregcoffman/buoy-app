import AppKit
import BuoyCore
import SwiftUI

/// A task opened in place (an accordion). Every change is saved immediately.
struct TaskCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let taskID: UUID

    private enum Field { case title }
    @FocusState private var focus: Field?
    @State private var notesFocus = 0

    private var task: BuoyTask { store.task(taskID) ?? BuoyTask(title: "") }

    private func binding<T>(_ keyPath: WritableKeyPath<BuoyTask, T>) -> Binding<T> {
        Binding(
            get: { task[keyPath: keyPath] },
            set: { value in
                var t = task
                t[keyPath: keyPath] = value
                store.update(t)
            }
        )
    }

    /// Date changes can move a task to another list; say where it went.
    private func setDates(_ change: (inout BuoyTask) -> Void) {
        var t = task
        change(&t)
        store.update(t, announceMoves: true)
    }

    var body: some View {
        let task = self.task
        CardSurface(onClickOutside: { store.collapse(reselect: false) }) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    if task.isCompleted {
                        store.markIncomplete([taskID], undoManager: undoManager)
                    } else {
                        store.collapse()
                        store.complete([taskID], undoManager: undoManager)
                    }
                } label: {
                    Checkbox(checked: task.isCompleted)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                TextField("Title", text: binding(\.title), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .focused($focus, equals: .title)
                    .onSubmit { store.collapse() }
            }
            NotesEditor(text: binding(\.notes), placeholder: task.isProject ? "Why / context: what your agent needs to know" : "Notes",
                        focusRequest: notesFocus, onEscape: { store.collapse() })
                .padding(.leading, 25)
            if task.isProject {
                ProjectReport(task: task, result: binding(\.result))
                    .padding(.leading, 25)
                    .padding(.top, 4)
            }
            HStack(spacing: 12) {
                StatusLine(task: task)
                if task.source == .agent {
                    Label("Added by an agent", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Theme.agent)
                }
            }
            .padding(.leading, 25)
            .padding(.top, 2)
            HStack(alignment: .top, spacing: 6) {
                FlowLayout(spacing: 6) {
                    DateChip(kind: .showOn, value: task.showOn) { d in setDates { $0.showOn = d } }
                    DateChip(kind: .due, value: task.dueOn) { d in setDates { $0.dueOn = d } }
                    if task.dueOn != nil {
                        LeadChip(value: task.leadDays) { n in setDates { $0.leadDays = n } }
                    }
                    RepeatChip(task: task)
                    TagChips(task: task)
                    EffortChip(value: task.effortHours) { hours in binding(\.effortHours).wrappedValue = hours }
                }
                Spacer(minLength: 4)
                TaskCardMenus(task: task)
            }
            .padding(.leading, 25)
            .padding(.top, 4)
        }
        .onExitCommand { store.collapse() }
        .onAppear {
            // Ready to type into the notes, with the cursor after any existing text.
            for delay in [0.05, 0.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { notesFocus += 1 }
            }
        }
    }
}

/// What the agent reports on a project: where it's at, and what it delivered.
private struct ProjectReport: View {
    let task: BuoyTask
    @Binding var result: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(task.isCompleted ? "Done" : task.boardColumn.title)
                    .lineLimit(1)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.projects.opacity(0.15), in: Capsule())
                    .foregroundStyle(Theme.projects)
                if !task.status.isEmpty && !task.isCompleted {
                    Label(task.status, systemImage: "ellipsis.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.agent)
                }
            }
            if task.isCompleted || !result.isEmpty {
                Text("What was delivered")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                NotesEditor(text: $result, placeholder: "Your agent describes what it delivered")
            }
        }
    }
}

/// A new task being written in place (the + button / ⌘N). The title understands
/// natural language, like the ⌃Space panel.
struct DraftTaskCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    @Bindable var model: QuickEntryModel
    var extraTags: [String] = []
    var onDone: (BuoyTask?) -> Void

    private enum Field { case title, notes }
    @FocusState private var focus: Field?

    var body: some View {
        CardSurface(onClickOutside: { if model.text.isEmpty && model.notes.isEmpty { onDone(nil) } }, announce: true) {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if model.isNote {
                        Image(systemName: "note.text")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.notes)
                            .frame(width: 15)
                    } else {
                        Checkbox(checked: false).opacity(0.5)
                    }
                }
                .padding(.top, 2)
                TextField("New Task", text: $model.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .focused($focus, equals: .title)
                    .onSubmit(submit)
            }
            TextField("Notes", text: $model.notes, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1...14)
                .focused($focus, equals: .notes)
                .padding(.leading, 25)
            HStack(alignment: .top) {
                if model.isNote {
                    Chip(icon: "note.text", text: "Note · saved to Notes as plain text", active: true, tint: Theme.notes)
                    Spacer(minLength: 0)
                } else {
                    QuickEntryChips(model: model)
                }
                Text(model.text.isEmpty ? "Try “due fri lead 3d every month #home”" : "↩ add · esc cancel")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, 25)
            .padding(.top, 4)
        }
        .onExitCommand { onDone(nil) }
        .onAppear {
            for delay in [0.05, 0.15, 0.35] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { focus = .title }
            }
        }
        .onChange(of: model.focusRequest) { focus = .title }
    }

    private func submit() {
        // A line starting with ">" is a note, wherever it's typed.
        if let text = model.noteText {
            let body = model.notes.isEmpty ? text : text + "\n" + model.notes
            guard store.addNote(body, undoManager: undoManager) != nil else { return }
            model.reset()
            onDone(nil)
            store.present(Toast(message: "Saved to Notes", undo: nil))
            return
        }
        guard model.canSubmit else { return }
        var entry = model.entry
        entry.tags = BuoyTask.normalizedTags(entry.tags + extraTags)
        let task = store.add(entry, notes: model.notes, undoManager: undoManager)
        model.reset()
        onDone(task)
    }
}

/// The raised card surface shared by open and new tasks.
struct CardSurface<Content: View>: View {
    /// Called when the user clicks anywhere else in the window.
    var onClickOutside: () -> Void
    /// Briefly outline the card in the accent colour when it appears (new tasks).
    var announce = false
    @ViewBuilder var content: Content
    @State private var glow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(ClickOutsideRegion(onOutside: onClickOutside))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(glow ? 0.8 : 0), lineWidth: 2)
            )
            .onAppear {
                guard announce else { return }
                glow = true
                withAnimation(.easeOut(duration: 1.2).delay(0.4)) { glow = false }
            }
            .shadow(color: .black.opacity(0.13), radius: 7, y: 2)
            .padding(.vertical, 6)
            .padding(.horizontal, -4)
    }
}

// MARK: - Status

/// Where the task is right now and why, in one quiet line.
struct StatusLine: View {
    @Environment(AppStore.self) private var store
    let task: BuoyTask

    var body: some View {
        let (icon, text, color) = describe()
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
    }

    private func describe() -> (String, String, Color) {
        let today = store.today
        switch store.placement(of: task) {
        case .logbook(let at):
            return ("checkmark", "Completed \(Formatters.day(LocalDate(at), today: today).lowercasedIfRelative) at \(Formatters.time(at))", .secondary)
        case .later:
            return ("tray", "In Later" + (task.dueOn.map { " · due \(Formatters.day($0, today: today).lowercasedIfRelative)" } ?? ""), .secondary)
        case .upcoming(let rises, let snoozed):
            if snoozed { return ("moon.zzz", "Snoozed until \(Formatters.snooze(rises, now: store.now))", .secondary) }
            return ("arrow.up", "Rises \(Formatters.day(LocalDate(rises), today: today).lowercasedIfRelative)", .secondary)
        case .today(let reason):
            let why: String = switch reason {
            case .overdue(let days): days == 1 ? "Overdue by 1 day" : "Overdue by \(days) days"
            case .dueToday: "Due today"
            case .leadTime(let left): left == 1 ? "Due tomorrow" : "Due in \(left) days"
            case .showOn: "In Today"
            case .surfaced: "Moved to Today"
            case .snoozeEnded: "Back from snooze"
            case .anytime: "In Today · no dates"
            }
            let color: Color = if case .overdue = reason { Theme.due } else if case .dueToday = reason { Theme.lead } else { .secondary }
            return ("sun.max", why, color)
        }
    }
}

extension String {
    var lowercasedIfRelative: String {
        ["Today", "Tomorrow", "Yesterday"].contains(self) ? lowercased() : self
    }
}

// MARK: - Menus

private struct TaskCardMenus: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let task: BuoyTask

    var body: some View {
        HStack(spacing: 4) {
            if !task.isCompleted {
                Menu {
                    ForEach(SnoozeOption.presets, id: \.self) { option in
                        Button(option.label) { snooze(option) }
                    }
                    Divider()
                    Button("Pick a Date…") { store.snoozePicker = SnoozeTargets(ids: [task.id]) }
                } label: {
                    Image(systemName: "moon.zzz")
                }
                .help("Snooze")
                .modifier(IconMenuStyle())
            }
            Menu {
                if task.recurrence != nil && !task.isCompleted {
                    Button("Skip This Occurrence") { store.skip([task.id], undoManager: undoManager) }
                }
                if !task.isCompleted && !store.placement(of: task).isToday {
                    Button("Move to Today") { store.surface([task.id], undoManager: undoManager) }
                }
                if !task.isCompleted && !task.later {
                    Button("Move to Later") { store.moveToLater([task.id], undoManager: undoManager) }
                }
                if task.snoozedUntil != nil && store.placement(of: task).isUpcoming {
                    Button("Unsnooze") { store.unsnooze([task.id], undoManager: undoManager) }
                }
                if !task.isCompleted {
                    Button(task.isProject ? "Convert to Task" : "Convert to Project") {
                        store.convertKind([task.id], to: task.isProject ? .task : .project, undoManager: undoManager)
                    }
                    Button("Convert to Note") { store.convertToNotes([task.id], undoManager: undoManager) }
                }
                Divider()
                Button("Delete Task", role: .destructive) {
                    store.collapse()
                    store.delete([task.id], undoManager: undoManager)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("More")
            .modifier(IconMenuStyle())
        }
    }

    private func snooze(_ option: SnoozeOption) {
        store.collapse()
        store.snooze([task.id], option, undoManager: undoManager)
    }
}

struct IconMenuStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

// MARK: - Repeat

private struct RepeatChip: View {
    let task: BuoyTask
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            Chip(icon: "repeat", text: task.recurrence?.summary ?? "Repeat", active: task.recurrence != nil, tint: Theme.repeatTint)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            RecurrenceEditor(taskID: task.id)
                .padding(14)
                .frame(width: 320)
        }
    }
}

private struct RecurrenceEditor: View {
    @Environment(AppStore.self) private var store
    let taskID: UUID

    private enum Frequency: String, CaseIterable, Identifiable {
        case none = "Never", day = "Daily", week = "Weekly", month = "Monthly", year = "Yearly"
        var id: String { rawValue }
        var unit: RecurrenceRule.Unit? {
            switch self {
            case .none: nil
            case .day: .day
            case .week: .week
            case .month: .month
            case .year: .year
            }
        }
    }

    private enum MonthlyOn: Hashable { case dayOfMonth, nthWeekday, lastWeekday, lastDay }

    private var task: BuoyTask { store.task(taskID) ?? BuoyTask(title: "") }
    private var anchor: LocalDate { task.dueOn ?? task.showOn ?? store.today }

    private func save(_ rule: RecurrenceRule?) {
        var t = task
        t.recurrence = rule
        store.update(t)
    }

    /// Rebuilds the rule with changes, always as a new rule anchored on the task's date.
    private func edit(_ change: (inout (unit: RecurrenceRule.Unit, interval: Int, mode: RecurrenceRule.Mode,
                                        weekdays: [Int], ordinal: Int?, weekday: Int?)) -> Void) {
        guard let rule = task.recurrence else { return }
        var parts = (unit: rule.unit, interval: rule.interval, mode: rule.mode,
                     weekdays: rule.weekdays, ordinal: rule.monthOrdinal, weekday: rule.monthWeekday)
        change(&parts)
        save(RecurrenceRule(unit: parts.unit, interval: parts.interval, mode: parts.mode, anchorOn: anchor,
                            weekdays: parts.weekdays, monthOrdinal: parts.ordinal, monthWeekday: parts.weekday))
    }

    var body: some View {
        let rule = task.recurrence
        VStack(alignment: .leading, spacing: 12) {
            Text("Repeat").font(.headline)
            Picker("Repeat", selection: Binding<Frequency>(
                get: { rule.flatMap { r in Frequency.allCases.first { $0.unit == r.unit } } ?? .none },
                set: { freq in
                    guard let unit = freq.unit else { return save(nil) }
                    save(RecurrenceRule(unit: unit, interval: rule?.interval ?? 1, mode: rule?.mode ?? .schedule, anchorOn: anchor))
                }
            )) {
                ForEach(Frequency.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let rule {
                Stepper(value: Binding(get: { rule.interval }, set: { n in edit { $0.interval = n } }), in: 1...365) {
                    Text("Every \(rule.interval == 1 ? "" : "\(rule.interval) ")\(rule.unit.rawValue)\(rule.interval == 1 ? "" : "s")")
                        .monospacedDigit()
                }

                if rule.mode == .schedule && rule.unit == .week {
                    WeekdayPicker(selected: rule.weekdays.isEmpty ? [anchor.weekday()] : rule.weekdays) { days in
                        edit { $0.weekdays = days == [anchor.weekday()] ? [] : days }
                    }
                }

                if rule.mode == .schedule && rule.unit == .month {
                    monthlyPicker(rule)
                }

                Picker("Next one", selection: Binding(get: { rule.mode }, set: { m in edit { $0.mode = m } })) {
                    Text("On a schedule").tag(RecurrenceRule.Mode.schedule)
                    Text("After I complete it").tag(RecurrenceRule.Mode.completion)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(explanation(rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func monthlyPicker(_ rule: RecurrenceRule) -> some View {
        let nth = (anchor.day - 1) / 7 + 1
        let weekday = anchor.weekday()
        let weekdayName = anchor.at(hour: 12).formatted(.dateTime.weekday(.wide))
        let isLastWeekday = anchor.adding(days: 7).month != anchor.month
        let current: MonthlyOn = switch (rule.monthOrdinal, rule.monthWeekday) {
        case (nil, _): .dayOfMonth
        case (-1, nil): .lastDay
        case (-1, _): .lastWeekday
        default: .nthWeekday
        }
        Picker("On", selection: Binding<MonthlyOn>(
            get: { current },
            set: { choice in
                edit {
                    switch choice {
                    case .dayOfMonth: $0.ordinal = nil; $0.weekday = nil
                    case .nthWeekday: $0.ordinal = nth; $0.weekday = weekday
                    case .lastWeekday: $0.ordinal = -1; $0.weekday = weekday
                    case .lastDay: $0.ordinal = -1; $0.weekday = nil
                    }
                }
            }
        )) {
            Text("Day \(anchor.day)").tag(MonthlyOn.dayOfMonth)
            if nth <= 4 { Text("The \(RecurrenceRule.ordinalName(nth)) \(weekdayName)").tag(MonthlyOn.nthWeekday) }
            if isLastWeekday { Text("The last \(weekdayName)").tag(MonthlyOn.lastWeekday) }
            Text("The last day").tag(MonthlyOn.lastDay)
        }
    }

    private func explanation(_ rule: RecurrenceRule) -> String {
        switch rule.mode {
        case .schedule:
            return "\(rule.summary), counted from \(Formatters.day(anchor, today: store.today).lowercasedIfRelative)."
        case .completion:
            let n = rule.interval == 1 ? rule.unit.rawValue : "\(rule.interval) \(rule.unit.rawValue)s"
            return "The next one appears \(n) after you complete this one."
        }
    }
}

private struct WeekdayPicker: View {
    let selected: [Int]
    let onChange: ([Int]) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(1...7, id: \.self) { day in
                let on = selected.contains(day)
                Button {
                    var set = Set(selected)
                    if on { set.remove(day) } else { set.insert(day) }
                    if !set.isEmpty { onChange(set.sorted()) }
                } label: {
                    Text(["S", "M", "T", "W", "T", "F", "S"][day - 1])
                        .font(.caption.weight(.semibold))
                        .frame(width: 26, height: 26)
                        .background(on ? Theme.repeatTint : Theme.chipFill, in: Circle())
                        .foregroundStyle(on ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Tags

private struct TagChips: View {
    @Environment(AppStore.self) private var store
    let task: BuoyTask
    @State private var adding = false

    var body: some View {
        ForEach(task.tags, id: \.self) { tag in
            HStack(spacing: 3) {
                Text(tag)
                Button {
                    var t = task
                    t.tags.removeAll { $0 == tag }
                    store.update(t)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Remove \(tag)")
            }
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.chipFill, in: Capsule())
            .foregroundStyle(.secondary)
        }
        Button { adding = true } label: {
            Chip(icon: "tag", text: task.tags.isEmpty ? "Tags" : "", active: false)
        }
        .buttonStyle(.plain)
        .help("Add a tag")
        .popover(isPresented: $adding, arrowEdge: .bottom) {
            TagPicker(task: task) { adding = false }
                .padding(12)
                .frame(width: 220)
        }
    }
}

private struct TagPicker: View {
    @Environment(AppStore.self) private var store
    let task: BuoyTask
    let done: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var suggestions: [String] {
        let q = draft.trimmingCharacters(in: .whitespaces)
        return store.knownTags
            .filter { s in !task.tags.contains { $0.caseInsensitiveCompare(s) == .orderedSame } }
            .filter { q.isEmpty || $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Tag name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { add(draft) }
            ForEach(suggestions.prefix(8), id: \.self) { tag in
                PopoverRow(title: tag) { add(tag) }
            }
        }
        .onAppear { focused = true }
    }

    private func add(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !name.isEmpty else { return }
        let existing = store.knownTags.first { $0.caseInsensitiveCompare(name) == .orderedSame }
        var t = task
        t.tags.append(existing ?? name)
        store.update(t)
        done()
    }
}

// MARK: - Layout

/// Wraps children onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(proposal.width ?? width, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
