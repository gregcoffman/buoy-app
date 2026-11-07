import AppKit
import BuoyCore
import Observation
import SwiftUI

enum Override<T: Equatable>: Equatable {
    /// Use whatever the text parser found.
    case auto
    case set(T)
    case cleared

    func resolve(_ parsed: T?) -> T? {
        switch self {
        case .auto: parsed
        case .set(let v): v
        case .cleared: nil
        }
    }
}

/// Quick entry state: free text parsed live, plus optional explicit overrides
/// from the Show On / Due / Lead chips.
@MainActor
@Observable
final class QuickEntryModel {
    var text = ""
    var notes = ""
    var showOverride: Override<LocalDate> = .auto
    var dueOverride: Override<LocalDate> = .auto
    var leadOverride: Override<Int> = .auto
    /// Bumped by whoever owns the field (e.g. the hotkey panel) to put the cursor in it.
    var focusRequest = 0
    /// Briefly shown after adding ("Added to Upcoming · rises Thu").
    var confirmation: String?

    var parsed: ParsedEntry { QuickEntryParser().parse(text) }

    var entry: ParsedEntry {
        var e = parsed
        e.showOn = showOverride.resolve(e.showOn)
        e.dueOn = dueOverride.resolve(e.dueOn)
        e.leadDays = leadOverride.resolve(e.leadDays)
        if var rule = e.recurrence, rule.mode == .schedule {
            rule.anchorOn = e.dueOn ?? e.showOn ?? LocalDate.today()
            e.recurrence = rule
        }
        return e
    }

    var canSubmit: Bool { !parsed.title.trimmingCharacters(in: .whitespaces).isEmpty }

    /// A line starting with `>` is a note: kept as typed, with no dates or tags.
    var noteText: String? { Note.capturedText(from: text) }
    var isNote: Bool { noteText != nil }
    var isEmpty: Bool { text.isEmpty && showOverride == .auto && dueOverride == .auto && leadOverride == .auto }

    func reset() {
        text = ""
        notes = ""
        showOverride = .auto
        dueOverride = .auto
        leadOverride = .auto
        confirmation = nil
    }
}

/// Single-line quick entry, used by the ⌃Space panel and the menu bar.
struct QuickEntryField: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    @Bindable var model: QuickEntryModel
    var prompt = "New task"
    var large = false
    var autofocus = false
    var onSubmit: ((BuoyTask) -> Void)? = nil
    var onNoteSaved: ((Note) -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    /// The ⌃Space panel keeps the text on screen while it confirms and fades; it resets on close.
    var resetsOnSubmit = true

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if model.isNote {
                    Image(systemName: "note.text")
                        .font(.system(size: large ? 19 : 14, weight: .semibold))
                        .foregroundStyle(Theme.notes)
                        .frame(width: large ? 22 : nil)
                } else if large {
                    BuoyMark(size: 22)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(model.canSubmit ? Color.accentColor : .secondary)
                }
                TextField(prompt, text: $model.text)
                    .textFieldStyle(.plain)
                    .font(large ? .title2 : .body)
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand { onCancel?() }
            }
            if model.isNote {
                Chip(icon: "note.text", text: "Note · saved as plain text", active: true, tint: Theme.notes)
                    .padding(.leading, large ? 32 : 26)
                    .transition(.opacity)
            } else if !model.isEmpty || large {
                QuickEntryChips(model: model)
                    .padding(.leading, large ? 32 : 26)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.isEmpty)
        .onAppear { if autofocus { focused = true } }
        .onChange(of: model.focusRequest) { focused = true }
    }

    private func submit() {
        // Already confirming (and fading out): a second Return mustn't add it twice.
        guard model.confirmation == nil else { return }
        if let text = model.noteText {
            if let note = store.addNote(text, undoManager: undoManager) {
                if resetsOnSubmit { model.reset() }
                onNoteSaved?(note)
            }
            return
        }
        guard model.canSubmit else { return }
        if let task = store.add(model.entry, undoManager: undoManager) {
            if resetsOnSubmit { model.reset() }
            onSubmit?(task)
        }
    }
}

/// Chips that show what the parser found and let the user set dates directly.
struct QuickEntryChips: View {
    @Environment(AppStore.self) private var store
    @Bindable var model: QuickEntryModel

    var body: some View {
        let entry = model.entry
        HStack(spacing: 6) {
            DateChip(kind: .showOn, value: entry.showOn) { model.showOverride = $0.map { .set($0) } ?? .cleared }
            DateChip(kind: .due, value: entry.dueOn) { model.dueOverride = $0.map { .set($0) } ?? .cleared }
            if entry.dueOn != nil {
                LeadChip(value: entry.leadDays) { model.leadOverride = .set($0) }
            }
            if let rule = entry.recurrence {
                Chip(icon: "repeat", text: rule.summary, active: true, tint: Theme.repeatTint)
            }
            if entry.later {
                Chip(icon: "tray.fill", text: "Later", active: true, tint: Theme.later)
            }
            ForEach(entry.tags, id: \.self) { tag in
                Chip(icon: "tag", text: tag, active: true, tint: .secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Date and lead-time chips (shared with task cards)

struct DateChip: View {
    enum Kind {
        case showOn, due

        var label: String { self == .showOn ? "Show On" : "Due" }
        var icon: String { self == .showOn ? "sunrise.fill" : "flag.fill" }
        var tint: Color { self == .showOn ? Theme.showOn : Theme.due }
    }

    @Environment(AppStore.self) private var store
    let kind: Kind
    let value: LocalDate?
    let onSet: (LocalDate?) -> Void
    @State private var editing = false
    @State private var draft = Date()

    var body: some View {
        let today = store.today
        Button {
            draft = (value ?? today).at(hour: 12)
            editing = true
        } label: {
            Chip(icon: kind.icon,
                 text: value.map { "\(kind.label) \(Formatters.shortDay($0, today: today))" } ?? kind.label,
                 active: value != nil, tint: kind.tint)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(kind == .showOn ? "Start showing it…" : "Due…").font(.headline)
                // One click picks a common date…
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(QuickDates.presets(today: today), id: \.label) { preset in
                        PopoverRow(title: preset.label,
                                   detail: Formatters.shortDay(preset.date, today: today) == preset.label
                                       ? "" : Formatters.shortDay(preset.date, today: today),
                                   checked: value == preset.date) {
                            onSet(preset.date)
                            editing = false
                        }
                    }
                }
                Divider()
                // …or any date on the calendar; clicking a day applies and closes.
                DatePicker(kind.label, selection: $draft, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .onChange(of: draft) {
                        onSet(LocalDate(draft))
                        editing = false
                    }
                if value != nil {
                    Button("Clear \(kind.label)") { onSet(nil); editing = false }
                        .buttonStyle(.link)
                }
            }
            .padding(12)
            .frame(width: 250)
        }
    }
}

struct LeadChip: View {
    let value: Int?
    let onSet: (Int) -> Void
    @State private var editing = false

    private static let presets = [0, 1, 3, 7, 14, 30]

    var body: some View {
        Button {
            editing = true
        } label: {
            Chip(icon: "hourglass", text: value.map { $0 == 0 ? "No Lead Time" : "Lead \(Formatters.leadTime($0))" } ?? "Lead Time",
                 active: (value ?? 0) > 0, tint: Theme.lead)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Start showing it before it's due")
                    .font(.headline)
                    .padding(.bottom, 6)
                // One click picks and closes.
                ForEach(Self.presets, id: \.self) { days in
                    PopoverRow(title: days == 0 ? "None" : "\(Formatters.leadTime(days)) before",
                               checked: (value ?? 0) == days) {
                        onSet(days)
                        editing = false
                    }
                }
                Divider().padding(.vertical, 4)
                // Anything else: adjust and it applies immediately.
                Stepper(value: Binding(get: { value ?? 0 }, set: { onSet($0) }), in: 0...365) {
                    Text("Custom: \(Formatters.leadTime(value ?? 0))").monospacedDigit()
                }
            }
            .padding(12)
            .frame(width: 230)
        }
    }
}

/// Level of effort in hours. Kept quiet: grey even when set, since it's mostly for your agent.
struct EffortChip: View {
    let value: Double?
    let onSet: (Double?) -> Void
    @State private var editing = false

    private static let presets: [Double] = [0.5, 1, 2, 4, 8, 16]

    var body: some View {
        Button {
            editing = true
        } label: {
            Chip(icon: "clock", text: value.map { "~\(Effort.format($0))" } ?? "Effort", active: value != nil, tint: .secondary)
        }
        .buttonStyle(.plain)
        .help("Level of effort, in hours")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("About how long will it take?")
                    .font(.headline)
                    .padding(.bottom, 6)
                ForEach(Self.presets, id: \.self) { hours in
                    PopoverRow(title: Effort.format(hours), checked: value == hours) {
                        onSet(hours)
                        editing = false
                    }
                }
                Divider().padding(.vertical, 4)
                // Anything else, in half hours: applies immediately.
                Stepper(value: Binding(get: { value ?? 0 }, set: { onSet($0 > 0 ? $0 : nil) }), in: 0...Effort.maxHours, step: 0.5) {
                    Text("Custom: \(value.map(Effort.format) ?? "none")").monospacedDigit()
                }
                if value != nil {
                    Button("Clear Effort") { onSet(nil); editing = false }
                        .buttonStyle(.link)
                        .padding(.top, 4)
                }
            }
            .padding(12)
            .frame(width: 230)
        }
    }
}

/// A full-width, hover-highlighted row inside a popover.
struct PopoverRow: View {
    let title: String
    var detail: String = ""
    var checked = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(detail).foregroundStyle(.secondary)
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(checked ? 1 : 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
