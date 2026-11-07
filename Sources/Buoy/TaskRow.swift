import BuoyCore
import SwiftUI

/// Context the row is shown in, which changes the secondary line.
enum RowContext {
    case today(TodayReason)
    case upcoming(risesAt: Date, snoozed: Bool)
    case logbook
    /// In Later: shows a Show On date if it has one.
    case later
    case plain
}

/// A task in a list. When opened it becomes a `TaskCard` in place.
struct TaskRow: View {
    @Environment(AppStore.self) private var store
    let task: BuoyTask
    let context: RowContext

    var body: some View {
        if store.expandedTaskID == task.id {
            TaskCard(taskID: task.id)
        } else {
            CollapsedTaskRow(task: task, context: context)
                .modifier(RiseIn(active: store.recentlyRisen.contains(task.id)))
                .modifier(FadeIn(active: store.recentlyAdded.contains(task.id)))
        }
    }
}

private struct CollapsedTaskRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let task: BuoyTask
    let context: RowContext

    @State private var checking = false
    @State private var fading = false
    /// Bumped on every check or un-check, so a pending completion from an earlier click is ignored.
    @State private var checkToken = 0

    var body: some View {
        let done = task.isCompleted || checking
        HStack(alignment: .center, spacing: 10) {
            checkbox
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .strikethrough(done, color: .secondary)
                        .foregroundStyle(done ? .secondary : .primary)
                        .lineLimit(1)
                    if !task.notes.isEmpty {
                        Image(systemName: "doc.text").font(.caption2).foregroundStyle(.tertiary)
                    }
                    if task.recurrence != nil {
                        Image(systemName: "repeat").font(.caption2).foregroundStyle(.tertiary)
                    }
                    if task.isProject {
                        ProjectMark()
                    }
                    if task.source == .agent {
                        AgentMark()
                    }
                }
                if let detail = detailLine {
                    detail
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        // Checked: struck through and greyed (the due badge loses its colour), then it fades away.
        .opacity(fading ? 0 : (checking ? 0.6 : 1))
    }

    private var checkbox: some View {
        Button {
            if task.isCompleted {
                store.markIncomplete([task.id], undoManager: undoManager)
            } else if checking {
                // A second click before it's gone changes your mind.
                checkToken += 1
                withAnimation(.easeOut(duration: 0.15)) {
                    checking = false
                    fading = false
                }
            } else {
                checkToken += 1
                let token = checkToken
                withAnimation(.easeOut(duration: 0.15)) { checking = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    guard checkToken == token else { return }
                    withAnimation(.easeIn(duration: 0.3)) { fading = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        guard checkToken == token else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            store.complete([task.id], undoManager: undoManager)
                        }
                        checking = false
                        fading = false
                    }
                }
            }
        } label: {
            Checkbox(checked: task.isCompleted || checking)
        }
        .buttonStyle(.plain)
        .help(task.isCompleted ? "Mark as not done" : "Complete")
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 6) {
            // Your agent's suggestion, when there is one, takes the place of "Not now".
            if !checking, case .today(let reason) = context, task.openSuggestion == nil,
               Attention.lingeringDays(task, reason: reason, now: store.now) != nil {
                NotNowMenu(task: task)
            }
            ForEach(task.tags.prefix(3), id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.chipFill, in: Capsule())
                    .foregroundStyle(.secondary)
            }
            if case .logbook = context {
                EmptyView()
            } else if let badge = DueBadge(task: task, today: store.today) {
                HStack(spacing: 3) {
                    Image(systemName: "flag.fill").font(.system(size: 9))
                    Text(badge.text).monospacedDigit()
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(checking ? Color.secondary : badge.color)
            }
        }
    }

    /// One quiet line explaining why the task is here or when it will rise.
    private var detailLine: Text? {
        let today = store.today
        switch context {
        case .today(let reason):
            if let days = Attention.lingeringDays(task, reason: reason, now: store.now) {
                return Text("In Today for \(Formatters.age(days))")
            }
            switch reason {
            case .snoozeEnded: return Text("Back from snooze")
            case .surfaced: return Text("Moved to Today")
            default: return nil
            }
        case .upcoming(let risesAt, let snoozed):
            if snoozed {
                return Text("\(Image(systemName: "moon.zzz")) Snoozed until \(Formatters.snooze(risesAt, now: store.now))")
            }
            var parts: [String] = []
            if let show = task.showOn, show > today {
                parts.append("Shows \(Formatters.day(show, today: today))")
            }
            if let lead = task.leadStart(), lead > today, task.showOn.map({ lead < $0 }) ?? true {
                parts.append("Rises \(Formatters.day(lead, today: today)) (\(Formatters.leadTime(task.leadDays)) ahead)")
            }
            if let rule = task.recurrence { parts.append(rule.summary) }
            return parts.isEmpty ? nil : Text(parts.joined(separator: " · "))
        case .logbook:
            guard let c = task.completion else { return nil }
            return Text("Completed at \(Formatters.time(c.completedAt))")
        case .later:
            if let show = task.showOn, show > store.today {
                return Text("Shows \(Formatters.day(show, today: store.today)), but parked in Later")
            }
            return nil
        case .plain:
            return nil
        }
    }
}

/// "Not now" for tasks that have lingered in Today: one click away from a better time.
private struct NotNowMenu: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let task: BuoyTask

    var body: some View {
        Menu {
            Button("Next Week") { store.snooze([task.id], .nextWeek, undoManager: undoManager) }
            Button("Next Month") {
                store.snooze([task.id], .until(store.today.adding(.month, 1)), undoManager: undoManager)
            }
            Divider()
            Button("Pick a Date…") { store.snoozePicker = SnoozeTargets(ids: [task.id]) }
        } label: {
            Text("Not now")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Theme.sea)
        .help("Snooze it until it's worth your attention")
    }
}

/// The snooze choices from PRD §6.
struct SnoozeMenu: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let ids: [UUID]

    var body: some View {
        Menu {
            ForEach(SnoozeOption.presets, id: \.self) { option in
                Button(option.label) { store.snooze(ids, option, undoManager: undoManager) }
            }
            Divider()
            Button("Pick a Date…") { store.snoozePicker = SnoozeTargets(ids: ids) }
        } label: {
            Label("Snooze", systemImage: "moon.zzz")
        }
    }
}

struct SnoozeTargets: Identifiable {
    let id = UUID()
    let ids: [UUID]
}

struct SnoozeDatePicker: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (LocalDate) -> Void
    @State private var date = LocalDate.today().adding(days: 1).at(hour: 12)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snooze until").font(.headline)
            DatePicker("Snooze until", selection: $date, in: Date()..., displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Snooze") {
                    onPick(LocalDate(date))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 280)
    }
}
