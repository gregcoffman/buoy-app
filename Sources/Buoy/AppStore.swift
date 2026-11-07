import AppKit
import BuoyCore
import Observation
import Security
import SwiftUI

enum SidebarRoute: Hashable {
    case bridge, today, upcoming, later, logbook
    case notes
    case projects
    case tag(String)

    var title: String {
        switch self {
        case .bridge: "The Bridge"
        case .today: "Today"
        case .later: "Later"
        case .upcoming: "Upcoming"
        case .logbook: "Logbook"
        case .notes: "Notes"
        case .projects: "Delegated"
        case .tag(let name): name
        }
    }
}

struct Toast: Identifiable {
    let id = UUID()
    let message: String
    let undo: (() -> Void)?
    /// The button label for `undo` (e.g. "Archive" after copying a note).
    var actionTitle = "Undo"
}

/// Everything the UI needs: the task list, derived views, and every user action.
/// All persistence goes through `Storage`; nothing is held only in memory.
@MainActor
@Observable
final class AppStore {
    private(set) var storage: Storage?
    private(set) var startupError: String?

    private(set) var tasks: [BuoyTask] = []
    private(set) var knownTags: [String] = []
    private(set) var notes: [Note] = []
    /// Things an agent deleted, restorable until they're 30 days old.
    private(set) var deletedTasks: [BuoyTask] = []
    private(set) var deletedNotes: [Note] = []
    /// The clock the attention engine runs on. Ticks forward so snoozes and
    /// Show On dates take effect without user interaction.
    private(set) var now = Date()

    var route: SidebarRoute? = .bridge
    var selection: Set<UUID> = []
    var searchText = ""
    var toast: Toast?
    /// The task or note opened in place (accordion), if any.
    var expandedTaskID: UUID?
    /// True while a new task card is open in the list.
    var composing = false
    /// The project open in the full-size editor, with your unsaved edits. Kept while you
    /// visit other screens, so a half-written brief is still there when you come back.
    var projectDraft: ProjectDraft?
    /// Tasks that just rose into Today, so their rows can float up into place.
    private(set) var recentlyRisen: Set<UUID> = []
    /// Tasks and notes that were just added (or accepted, or converted), so their rows fade in.
    private(set) var recentlyAdded: Set<UUID> = []
    var alert: AlertMessage?
    var snoozePicker: SnoozeTargets?
    /// Bumped to ask the visible list to focus its quick-entry field (⌘N).
    var focusQuickEntryRequest = 0
    /// Whether the search field in the bottom bar is showing.
    var searching = false
    /// Bumped to put the cursor in the search field (⌘F).
    var focusSearchRequest = 0

    /// Set by a view that has access to `openWindow`, so AppKit code can reopen the main window.
    var openMainWindow: (() -> Void)?

    // Settings (persisted in the database's settings table)
    var notificationPreferences = NotificationPreferences() { didSet { persistNotificationPreferences() } }
    var showMenuBarIcon = true { didSet { setSetting("menuBar.enabled", showMenuBarIcon ? "1" : "0") } }
    var hotKey: HotKeyPreset = .controlSpace { didSet { setSetting("hotKey", hotKey.rawValue); onHotKeyChange?(hotKey) } }
    @ObservationIgnored var onHotKeyChange: ((HotKeyPreset) -> Void)?
    /// False when the chosen shortcut is already taken by another app or macOS.
    var hotKeyRegistered = true
    @ObservationIgnored var onTasksChanged: (() -> Void)?
    /// Your agent handed a card in for review (to notify you).
    @ObservationIgnored var onHandedIn: ((BuoyTask) -> Void)?
    /// The secret every buoy:// link must carry (Settings ▸ Agent).
    private(set) var agentKey = ""
    /// Agent-added tasks wait for review before joining your lists (on by default).
    var reviewAgentTasks = true { didSet { setSetting("agent.reviewNewTasks", reviewAgentTasks ? "1" : "0") } }

    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var toastTimer: Timer?
    @ObservationIgnored private var loadingSettings = false
    @ObservationIgnored private var lastTodayIDs: Set<UUID>?

    struct AlertMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    init() {
        do {
            let storage = try Storage()
            self.storage = storage
            loadSettings()
            // Drop notes left empty (e.g. Buoy quit while a new note was open).
            if let blank = try? storage.repository.loadNotes().filter(\.isBlank).map(\.id), !blank.isEmpty {
                try? storage.repository.delete(noteIDs: blank)
            }
            try? storage.repository.purgeDeleted(before: Date().addingTimeInterval(-30 * 86_400))
            reload()
            _ = try? storage.automaticBackupIfNeeded()
        } catch {
            startupError = "\(error)"
        }
        startClock()
    }

    // MARK: Clock

    private func startClock() {
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let center = NotificationCenter.default
        for name in [Notification.Name.NSCalendarDayChanged, NSNotification.Name.NSSystemClockDidChange] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
                _ = try? self?.storage?.automaticBackupIfNeeded()
            }
        }
    }

    func tick() {
        let previousDay = LocalDate(now)
        now = Date()
        noteTodayChanges()
        if LocalDate(now) != previousDay {
            _ = try? storage?.automaticBackupIfNeeded()
            onTasksChanged?()
        }
    }

    var today: LocalDate { LocalDate(now) }

    // MARK: Derived views

    var todayItems: [Attention.TodayItem] { Attention.today(filtered(tasks), now: now) }
    var upcomingItems: [Attention.UpcomingItem] { Attention.upcoming(filtered(tasks), now: now) }
    var logbookTasks: [BuoyTask] { Attention.logbook(filtered(tasks)) }
    var todayCount: Int { Attention.today(tasks, now: now).count }
    var laterItems: [BuoyTask] { Attention.later(filtered(tasks), now: now) }
    var laterCount: Int { Attention.later(tasks, now: now).count }
    /// Delegated cards waiting for you to check.
    var reviewCount: Int { Board.column(.review, of: tasks).count }

    func tagged(_ tag: String) -> [BuoyTask] {
        filtered(tasks).filter { !$0.pendingReview && $0.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
    }

    /// Tasks an agent added that are waiting for you to accept or dismiss, oldest first.
    var pendingReview: [BuoyTask] {
        tasks.filter { $0.pendingReview && !$0.isCompleted }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Tags that are attached to at least one active task, plus any stored tags.
    var sidebarTags: [String] { knownTags }

    private func filtered(_ list: [BuoyTask]) -> [BuoyTask] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.notes.localizedCaseInsensitiveContains(q)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    func task(_ id: UUID) -> BuoyTask? { tasks.first { $0.id == id } }

    // Notes: newest first; archived ones most recently used first.
    var activeNotes: [Note] { filteredNotes.filter { !$0.isArchived } }
    var archivedNotes: [Note] {
        filteredNotes.filter(\.isArchived).sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }
    var activeNoteCount: Int { notes.filter { !$0.isArchived }.count }

    private var filteredNotes: [Note] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return notes }
        return notes.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }

    func placement(of task: BuoyTask) -> Placement { Attention.placement(of: task, now: now) }

    // MARK: Loading

    func reload() {
        guard let repo = storage?.repository else { return }
        do {
            let all = try repo.loadAll()
            tasks = all.filter { $0.deletedAt == nil }
            deletedTasks = all.filter { $0.deletedAt != nil }.sorted { $0.deletedAt! > $1.deletedAt! }
            knownTags = try repo.allTagNames()
            let allNotes = try repo.loadNotes()
            notes = allNotes.filter { $0.deletedAt == nil }
            deletedNotes = allNotes.filter { $0.deletedAt != nil }.sorted { $0.deletedAt! > $1.deletedAt! }
            selection = selection.filter { id in tasks.contains { $0.id == id } || notes.contains { $0.id == id } }
        } catch {
            report("Couldn't load tasks", error)
        }
        if let id = expandedTaskID, task(id) == nil, note(id) == nil { expandedTaskID = nil }
        noteTodayChanges()
        onTasksChanged?()
    }

    private func report(_ title: String, _ error: Error) {
        alert = AlertMessage(title: title, message: "\(error)")
    }

    // MARK: Undoable changes

    /// Applies a change and makes it undoable, both from the toast and from Edit ▸ Undo.
    /// Undo restores a snapshot of the affected tasks and removes any tasks the change created.
    private func perform(
        _ label: String,
        affecting ids: [UUID],
        undoManager: UndoManager?,
        showToast: Bool = true,
        _ change: (TaskRepository) throws -> [UUID]
    ) {
        guard let repo = storage?.repository else { return }
        let snapshot = tasks.filter { ids.contains($0.id) }
        let created: [UUID]
        do {
            created = try change(repo)
        } catch {
            report("Couldn't \(label.lowercased())", error)
            reload()
            return
        }
        reload()

        let token = UndoToken()
        let undo: () -> Void = { [weak self] in
            guard let self, let repo = self.storage?.repository else { return }
            do {
                try repo.delete(taskIDs: created)
                try repo.save(snapshot)
            } catch {
                self.report("Couldn't undo", error)
            }
            undoManager?.removeAllActions(withTarget: token)
            self.toast = nil
            self.reload()
        }
        undoManager?.registerUndo(withTarget: token) { _ in undo() }
        undoManager?.setActionName(label)
        if showToast { present(Toast(message: label, undo: undo)) }
    }

    private final class UndoToken {}

    func present(_ toast: Toast) {
        self.toast = toast
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in
                if self?.toast?.id == toast.id { withAnimation { self?.toast = nil } }
            }
        }
    }

    // MARK: Actions

    @discardableResult
    func add(_ entry: ParsedEntry, notes: String = "", undoManager: UndoManager? = nil, select: Bool = false,
             id: UUID = UUID(), source: ItemSource = .user, pendingReview: Bool = false,
             kind: TaskKind = .task, column: BoardColumn = .shaping, position: BoardPlacement = .top,
             expectations: String = "", effortHours: Double? = nil) -> BuoyTask? {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        var rule = entry.recurrence
        if var r = rule, r.mode == .schedule, r.anchorOn == nil {
            r.anchorOn = entry.dueOn ?? entry.showOn ?? today
            rule = r
        }
        var task = BuoyTask(id: id, title: title, notes: notes.trimmingCharacters(in: .whitespacesAndNewlines), showOn: entry.showOn, dueOn: entry.dueOn,
                            leadDays: entry.dueOn == nil ? 0 : (entry.leadDays ?? 0),
                            recurrence: rule, tags: entry.tags, createdAt: Date(), source: source, pendingReview: pendingReview,
                            kind: kind, boardColumn: column, boardPosition: boardPosition(column, position))
        task.later = entry.later
        task.expectations = expectations.trimmingCharacters(in: .whitespacesAndNewlines)
        task.effortHours = effortHours
        markAdded([task.id])
        perform("Add Task", affecting: [], undoManager: undoManager, showToast: false) { repo in
            try repo.save(task)
            return [task.id]
        }
        if select { selection = [task.id] }
        return task
    }

    /// Saves edits from an open task card immediately. Not added to the undo stack
    /// (text fields have their own undo); structural actions are. With `announceMoves`,
    /// a change that sends the task to another list says where it went.
    func update(_ edited: BuoyTask, announceMoves: Bool = false) {
        guard let repo = storage?.repository, let old = task(edited.id) else { return }
        var task = edited
        task.tags = BuoyTask.normalizedTags(task.tags)
        if task.dueOn == nil { task.leadDays = 0 }

        let datesChanged = task.showOn != old.showOn || task.dueOn != old.dueOn || task.leadDays != old.leadDays
        if datesChanged {
            // A new schedule replaces any manual override.
            task.snoozedUntil = nil
            task.surfacedAt = nil
            // Re-anchor schedule-based repeats on the new date.
            if let rule = task.recurrence, rule.mode == .schedule, rule.id == old.recurrence?.id {
                task.recurrence = rule.copy(anchorOn: task.dueOn ?? task.showOn ?? today)
            }
        }
        guard task != old else { return }
        task.updatedAt = Date()

        let wasToday = placement(of: old).isToday
        if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task }
        do {
            try repo.save(task)
            if task.tags != old.tags { knownTags = try repo.allTagNames() }
        } catch {
            report("Couldn't save changes", error)
            reload()
        }
        if announceMoves, placement(of: task).isToday != wasToday {
            present(Toast(message: placementSummary(for: task, verb: "Moved to"), undo: nil))
        }
        onTasksChanged?()
    }

    func complete(_ ids: [UUID], undoManager: UndoManager?) {
        let targets = ids.compactMap(task).filter { !$0.isCompleted }
        guard !targets.isEmpty else { return }
        let label = targets.count == 1 ? "Completed “\(targets[0].title)”" : "Completed \(targets.count) tasks"
        let at = Date()
        perform(label, affecting: targets.map(\.id), undoManager: undoManager) { repo in
            var changed: [BuoyTask] = []
            var created: [UUID] = []
            for var task in targets {
                let next = Recurrence.nextOccurrence(of: task, completedOn: LocalDate(at), now: at)
                task.completion = Completion(completedAt: at, nextTaskID: next?.id)
                task.snoozedUntil = nil
                changed.append(task)
                if let next {
                    changed.append(next)
                    created.append(next.id)
                }
            }
            try repo.save(changed)
            return created
        }
        selection.subtract(ids)
    }

    /// Returns a completed task to active work (from the Logbook).
    func markIncomplete(_ ids: [UUID], undoManager: UndoManager?) {
        let targets = ids.compactMap(task).filter(\.isCompleted)
        guard !targets.isEmpty else { return }
        // Retract generated next occurrences that haven't been touched since.
        let retracted = targets.compactMap { $0.completion?.nextTaskID }.filter { nextID in
            guard let next = task(nextID) else { return false }
            return !next.isCompleted && next.updatedAt == next.createdAt
        }
        perform("Marked Incomplete", affecting: targets.map(\.id) + retracted, undoManager: undoManager) { repo in
            try repo.delete(taskIDs: retracted)
            try repo.save(targets.map { task in
                var t = task
                t.completion = nil
                return t
            })
            return []
        }
    }

    func snooze(_ ids: [UUID], _ option: SnoozeOption, undoManager: UndoManager?) {
        let targets = ids.compactMap(task).filter { !$0.isCompleted }
        guard !targets.isEmpty else { return }
        let until = option.wakeDate(from: Date())
        let label = "Snoozed until \(Formatters.snooze(until, now: now))"
        perform(label, affecting: targets.map(\.id), undoManager: undoManager) { repo in
            try repo.save(targets.map { task in
                var t = task
                t.snoozedUntil = until
                t.updatedAt = Date()
                return t
            })
            return []
        }
        selection.subtract(ids)
    }

    func unsnooze(_ ids: [UUID], undoManager: UndoManager?) {
        let targets = ids.compactMap(task).filter { $0.snoozedUntil != nil }
        guard !targets.isEmpty else { return }
        perform("Unsnoozed", affecting: targets.map(\.id), undoManager: undoManager) { repo in
            try repo.save(targets.map { task in
                var t = task
                t.snoozedUntil = nil
                t.surfacedAt = Date()
                return t
            })
            return []
        }
    }

    /// Pulls a task into Today now, without changing its dates.
    func surface(_ ids: [UUID], undoManager: UndoManager?) {
        let targets = ids.compactMap(task).filter { !$0.isCompleted }
        guard !targets.isEmpty else { return }
        perform("Moved to Today", affecting: targets.map(\.id), undoManager: undoManager) { repo in
            try repo.save(targets.map { task in
                var t = task
                t.surfacedAt = Date()
                t.snoozedUntil = nil
                t.later = false
                return t
            })
            return []
        }
    }

    /// Parks tasks in Later: out of Today until you move them back (deadlines still come through).
    func moveToLater(_ ids: [UUID], undoManager: UndoManager?) {
        let targets = ids.compactMap(task).filter { !$0.isCompleted && !$0.later }
        guard !targets.isEmpty else { return }
        if let open = expandedTaskID, ids.contains(open) { collapse(reselect: false) }
        let label = targets.count == 1 ? "Moved “\(targets[0].title)” to Later" : "Moved \(targets.count) tasks to Later"
        perform(label, affecting: targets.map(\.id), undoManager: undoManager) { repo in
            try repo.save(targets.map { task in
                var t = task
                t.later = true
                t.surfacedAt = nil
                t.snoozedUntil = nil
                t.updatedAt = Date()
                return t
            })
            return []
        }
        if route != .later { selection.subtract(ids) }
    }

    func delete(_ ids: [UUID], undoManager: UndoManager?) {
        let targets = ids.compactMap(task)
        guard !targets.isEmpty else { return }
        let label = targets.count == 1 ? "Deleted “\(targets[0].title)”" : "Deleted \(targets.count) tasks"
        perform(label, affecting: targets.map(\.id), undoManager: undoManager) { repo in
            try repo.delete(taskIDs: targets.map(\.id))
            return []
        }
        selection.subtract(ids)
    }

    /// Moves a repeating task on to its next occurrence without logging it as done.
    func skip(_ ids: [UUID], undoManager: UndoManager?) {
        let skipped = ids.compactMap(task).compactMap { Recurrence.skip($0, today: today) }
        guard !skipped.isEmpty else { return }
        let label = skipped.count == 1
            ? "Skipped to \(Formatters.day((skipped[0].dueOn ?? skipped[0].showOn) ?? today, today: today))"
            : "Skipped \(skipped.count) tasks"
        perform(label, affecting: skipped.map(\.id), undoManager: undoManager) { repo in
            try repo.save(skipped)
            return []
        }
    }

    // MARK: Projects

    /// Open projects in a board column, in your order (search applies).
    func board(_ column: BoardColumn) -> [BuoyTask] { Board.column(column, of: filtered(tasks)) }
    var doneProjects: [BuoyTask] { Board.done(filtered(tasks), now: now) }

    /// Where a new or moved project goes: the top or bottom of `column`.
    func boardPosition(_ column: BoardColumn, _ placement: BoardPlacement, excluding id: UUID? = nil) -> Double {
        let items = Board.column(column, of: tasks).filter { $0.id != id }
        return Board.position(at: placement == .top ? 0 : items.count, in: items)
    }

    /// The board's New Project button / ⌘N on Projects: a blank brief in the editor.
    func startProject() {
        route = .projects
        searchText = ""
        searching = false
        collapse(reselect: false)
        projectDraft = ProjectDraft(task: BuoyTask(title: "", kind: .project), isNew: true)
    }

    /// Opens a project in the full-size editor.
    func openProject(_ id: UUID) {
        guard let project = task(id), project.isProject else { return }
        route = .projects
        projectDraft = ProjectDraft(task: project, isNew: false, openedEffort: project.effortHours)
    }

    /// Save in the project editor. Only your fields are written, so anything the agent
    /// changed meanwhile (its status, result or column) is kept.
    @discardableResult
    func saveProjectDraft(undoManager: UndoManager?) -> Bool {
        guard let draft = projectDraft else { return false }
        let d = draft.task
        guard !d.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if draft.isNew {
            let entry = ParsedEntry(title: d.title, showOn: d.showOn, dueOn: d.dueOn, leadDays: d.leadDays, tags: d.tags)
            guard add(entry, notes: d.notes, undoManager: undoManager, kind: .project, column: .shaping,
                      position: .top, expectations: d.expectations, effortHours: d.effortHours) != nil else { return false }
            present(Toast(message: "Added to Shaping", undo: nil))
        } else if var current = task(d.id) {
            current.title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
            current.notes = d.notes
            current.expectations = d.expectations
            current.showOn = d.showOn
            current.dueOn = d.dueOn
            current.leadDays = d.leadDays
            current.tags = d.tags
            // Effort is the one field you share with your agent: keep its estimate unless you changed it.
            if d.effortHours != draft.openedEffort { current.effortHours = d.effortHours }
            update(current, announceMoves: true)
        }
        projectDraft = nil
        return true
    }

    /// Drag and drop on the board: into `column` at `index`, or to Done (`column == nil`) to finish it.
    func moveProject(_ id: UUID, to column: BoardColumn?, at index: Int, undoManager: UndoManager?) {
        guard let project = task(id), project.isProject else { return }
        guard let column else {
            if !project.isCompleted { complete([id], undoManager: undoManager) }
            return
        }
        var moved = project
        moved.boardColumn = column
        moved.boardPosition = Board.position(at: index, in: Board.column(column, of: tasks).filter { $0.id != id })
        moved.updatedAt = Date()
        // Moving a card out of Shaping answers whatever the agent was blocked on.
        if project.boardColumn == .shaping && column != .shaping { moved.status = "" }
        if project.isCompleted {
            // Out of Done: back on the board where you dropped it.
            moved.completion = nil
            perform("Moved back to \(column.title)", affecting: [id], undoManager: undoManager) { repo in
                try repo.save(moved)
                return []
            }
        } else if column != project.boardColumn {
            perform("Moved to \(column.title)", affecting: [id], undoManager: undoManager, showToast: false) { repo in
                try repo.save(moved)
                return []
            }
        } else {
            // Reordering within a column: not worth a toast, but undoable.
            perform("Reorder", affecting: [id], undoManager: undoManager, showToast: false) { repo in
                try repo.save(moved)
                return []
            }
        }
    }

    /// Your agent's new order, top first (the handler checks the ids). For tasks, anything
    /// left out loses its place and sits on top of Today as new. Undo puts the old order back.
    func reorder(_ list: AgentList, _ ids: [UUID]) {
        var reordered = ids.enumerated().compactMap { index, id -> BuoyTask? in
            guard var item = task(id) else { return nil }
            switch list {
            case .tasks: item.agentRank = Double(index)
            case .ready: item.boardPosition = Double(index)
            }
            item.updatedAt = Date()
            return item
        }
        if list == .tasks {
            reordered += tasks.filter { $0.agentRank != nil && !ids.contains($0.id) }.map {
                var unranked = $0
                unranked.agentRank = nil
                return unranked
            }
        }
        let name = list == .tasks ? "your tasks" : "Ready"
        perform("Your agent reordered \(name)", affecting: reordered.map(\.id), undoManager: nil) { repo in
            try repo.save(reordered)
            return []
        }
    }

    /// Task ⇄ project. A new project goes to the top of Shaping; everything else carries over.
    func convertKind(_ ids: [UUID], to kind: TaskKind, undoManager: UndoManager?) {
        let targets = ids.compactMap(task).filter { $0.kind != kind && !$0.isCompleted }
        guard !targets.isEmpty else { return }
        if let open = expandedTaskID, ids.contains(open) { expandedTaskID = nil }
        var top = boardPosition(.shaping, .top)
        let converted = targets.map { t -> BuoyTask in
            var c = t
            c.kind = kind
            if kind == .project {
                c.boardColumn = .shaping
                c.boardPosition = top
                top -= 1
            }
            c.updatedAt = Date()
            return c
        }
        let what = kind == .project ? "project" : "task"
        let label = targets.count == 1 ? "“\(targets[0].title)” is now a \(what)" : "Converted \(targets.count) to \(what)s"
        markAdded(converted.map(\.id))
        perform(label, affecting: targets.map(\.id), undoManager: undoManager) { repo in
            try repo.save(converted)
            return []
        }
    }

    // MARK: Agent deletes (recoverable for 30 days)

    /// Marks a task, project or note as deleted by an agent. Returns what it was, or nil if not found.
    @discardableResult
    func agentDelete(_ id: UUID) -> String? {
        guard let repo = storage?.repository else { return nil }
        if let open = expandedTaskID, open == id { expandedTaskID = nil }
        let now = Date()
        if var t = task(id) {
            t.deletedAt = now
            perform("An agent deleted “\(t.title)”", affecting: [id], undoManager: nil) { repo in
                try repo.save(t)
                return []
            }
            return "\(t.isProject ? "project" : "task") “\(t.title)”"
        }
        if var n = note(id) {
            n.deletedAt = now
            do { try repo.save(n) } catch { report("Couldn't delete the note", error) }
            reload()
            return "note “\(n.firstLine)”"
        }
        return nil
    }

    /// Brings back something an agent deleted.
    func restoreDeleted(_ id: UUID) {
        guard let repo = storage?.repository else { return }
        do {
            if var t = deletedTasks.first(where: { $0.id == id }) {
                t.deletedAt = nil
                try repo.save(t)
                markAdded([id])
            } else if var n = deletedNotes.first(where: { $0.id == id }) {
                n.deletedAt = nil
                try repo.save(n)
                markAdded([id])
            }
        } catch { report("Couldn't restore", error) }
        reload()
    }

    // MARK: Review (agent tasks)

    /// Lets agent tasks into your lists, wherever their dates put them.
    func accept(_ ids: [UUID], undoManager: UndoManager?) {
        let targets = ids.compactMap(task).filter(\.pendingReview)
        guard !targets.isEmpty else { return }
        if let open = expandedTaskID, ids.contains(open) { expandedTaskID = nil }
        let accepted = targets.map { var t = $0; t.pendingReview = false; t.updatedAt = Date(); return t }
        // "Accepted, now in Upcoming · rises Thu", "Accepted, now on the board in Shaping"
        let label = accepted.count == 1
            ? (accepted[0].staysOnBoard ? "Accepted, now on the board in \(accepted[0].boardColumn.title)"
                                        : placementSummary(for: accepted[0], verb: "Accepted, now in"))
            : "Accepted \(accepted.count)"
        markAdded(accepted.map(\.id))
        perform(label, affecting: targets.map(\.id), undoManager: undoManager) { repo in
            try repo.save(accepted)
            return []
        }
    }

    /// Turns agent tasks away. They're deleted (undo brings them back).
    func dismiss(_ ids: [UUID], undoManager: UndoManager?) {
        let targets = ids.compactMap(task).filter(\.pendingReview)
        guard !targets.isEmpty else { return }
        if let open = expandedTaskID, ids.contains(open) { expandedTaskID = nil }
        let label = targets.count == 1 ? "Dismissed “\(targets[0].title)”" : "Dismissed \(targets.count) tasks"
        perform(label, affecting: targets.map(\.id), undoManager: undoManager) { repo in
            try repo.delete(taskIDs: targets.map(\.id))
            return []
        }
    }

    // MARK: Suggestions (from your agent)

    /// Tasks your agent suggests moving, oldest suggestion first. Dismissed ones are kept
    /// on the task (so the agent can see) but not shown.
    var suggestions: [BuoyTask] {
        tasks.filter { !$0.isProject && !$0.isCompleted && !$0.pendingReview && $0.deletedAt == nil && $0.openSuggestion != nil }
            .sorted { $0.openSuggestion!.createdAt < $1.openSuggestion!.createdAt }
    }

    /// Your agent sets or withdraws its suggestion for a task. Nothing else changes.
    func setSuggestion(_ id: UUID, _ suggestion: Suggestion?) {
        guard var t = task(id) else { return }
        t.suggestion = suggestion
        update(t)
    }

    /// Does what your agent suggested, as if you'd done it by hand.
    func acceptSuggestions(_ ids: [UUID], undoManager: UndoManager?) {
        let targets = ids.compactMap(task).filter { $0.openSuggestion != nil && !$0.isCompleted }
        guard !targets.isEmpty else { return }
        if let open = expandedTaskID, ids.contains(open) { collapse(reselect: false) }
        let moved = targets.map { t -> BuoyTask in
            var m = t.applying(t.openSuggestion!.move, today: today)
            m.updatedAt = Date()
            return m
        }
        let label = moved.count == 1
            ? placementSummary(for: moved[0], verb: "Moved “\(moved[0].title)” to")
            : "Accepted \(moved.count) suggestions"
        perform(label, affecting: targets.map(\.id), undoManager: undoManager) { repo in
            try repo.save(moved)
            return []
        }
        selection.subtract(ids)
    }

    /// Says no to your agent's suggestions. They're kept as dismissed, so it knows.
    func dismissSuggestions(_ ids: [UUID], undoManager: UndoManager?) {
        let targets = ids.compactMap(task).filter { $0.openSuggestion != nil }
        guard !targets.isEmpty else { return }
        let dismissed = targets.map { t -> BuoyTask in
            var d = t
            d.suggestion?.dismissedAt = Date()
            d.updatedAt = Date()
            return d
        }
        let label = targets.count == 1 ? "Dismissed the suggestion" : "Dismissed \(targets.count) suggestions"
        perform(label, affecting: targets.map(\.id), undoManager: undoManager) { repo in
            try repo.save(dismissed)
            return []
        }
    }

    // MARK: Accordion & composing

    func expand(_ id: UUID) {
        composing = false
        selection = []
        withAnimation(.snappy(duration: 0.22)) { expandedTaskID = id }
    }

    /// Closes the open task. `reselect` keeps it selected afterwards (Esc, Return);
    /// a click elsewhere passes false so it doesn't steal that click's selection.
    func collapse(reselect: Bool = true) {
        guard let id = expandedTaskID else { return }
        withAnimation(.snappy(duration: 0.22)) { expandedTaskID = nil }
        // A note closed with nothing in it was never really written.
        if let note = note(id), note.isBlank {
            try? storage?.repository.delete(noteIDs: [id])
            reload()
            return
        }
        if reselect, task(id) != nil || note(id) != nil { selection = [id] }
    }

    /// ⌘I / Return: open the selected task, or close the open one.
    func toggleExpanded() {
        if expandedTaskID != nil { collapse() } else if selection.count == 1, let id = selection.first { expand(id) }
    }

    /// The + button / ⌘N: open a new-task card in the current list.
    func startComposing() {
        // "New" on the Notes screen means a new note; on Projects, a new project.
        if route == .notes { startNote(); return }
        if route == .projects { startProject(); return }
        if route == .logbook || route == nil { route = .today }
        collapse(reselect: false)
        selection = []
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { composing = true }
        focusQuickEntryRequest += 1
    }

    /// "Added to Upcoming · rises tomorrow", "Moved to Today".
    func placementSummary(for task: BuoyTask, verb: String = "Added to") -> String {
        switch placement(of: task) {
        case .today:
            return "\(verb) Today"
        case .upcoming(let rises, let snoozed):
            let when = Formatters.day(LocalDate(rises), today: today).lowercasedIfRelative
            return snoozed ? "\(verb) Upcoming · snoozed until \(when)" : "\(verb) Upcoming · rises \(when)"
        case .later:
            return "\(verb) Later"
        case .logbook:
            return "\(verb) Logbook"
        }
    }

    /// Remembers which tasks just rose into Today (a Show On date arriving, a snooze
    /// ending, …) so their rows can float up into place.
    private func noteTodayChanges() {
        let ids = Set(Attention.today(tasks, now: now).map(\.task.id))
        defer { lastTodayIDs = ids }
        guard let previous = lastTodayIDs else { return }
        // Something you just added fades in instead of rising.
        let risen = ids.subtracting(previous).subtracting(recentlyAdded)
        guard !risen.isEmpty else { return }
        recentlyRisen.formUnion(risen)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.recentlyRisen.subtract(risen)
        }
    }

    // MARK: Notes

    /// Saves a note. Its text is kept exactly as typed.
    @discardableResult
    func addNote(_ text: String, undoManager: UndoManager? = nil, source: ItemSource = .user) -> Note? {
        let note = Note(text: text, source: source)
        guard !note.isBlank else { return nil }
        markAdded([note.id])
        performOnNotes("Add Note", affecting: [], undoManager: undoManager, showToast: false) { repo in
            try repo.save(note)
            return [note.id]
        }
        return note
    }

    /// The New Note button / ⌥⌘N: a blank note, opened and ready to type in.
    func startNote() {
        route = .notes
        searchText = ""
        searching = false
        collapse(reselect: false)
        let note = Note(text: "")
        do {
            try storage?.repository.save(note)
        } catch {
            report("Couldn't create a note", error)
            return
        }
        reload()
        selection = []
        // Open it once the Notes list is on screen; a list that's still being
        // built can miss the change and show the row closed.
        DispatchQueue.main.async { [weak self] in
            withAnimation(.snappy(duration: 0.22)) { self?.expandedTaskID = note.id }
        }
    }

    /// Saves typing in an open note. Text fields have their own undo.
    func updateNote(_ id: UUID, text: String) {
        guard var note = note(id), note.text != text else { return }
        note.text = text
        note.updatedAt = Date()
        if let index = notes.firstIndex(where: { $0.id == id }) { notes[index] = note }
        do { try storage?.repository.save(note) } catch {
            report("Couldn't save the note", error)
            reload()
        }
    }

    /// Copies notes as plain text. A single active note offers to archive itself.
    func copyNotes(_ ids: [UUID], undoManager: UndoManager?) {
        let targets = notes.filter { ids.contains($0.id) }
        let text = Note.clipboardText(targets)
        guard !text.isEmpty else { return }
        writeToClipboard(text)
        let label = targets.count == 1 ? "Copied “\(Self.shortTitle(targets[0]))”" : "Copied \(targets.count) notes"
        let active = targets.filter { !$0.isArchived }.map(\.id)
        present(Toast(message: label,
                      undo: active.isEmpty ? nil : { [weak self] in self?.archiveNotes(active, undoManager: undoManager) },
                      actionTitle: "Archive"))
    }

    /// Copies every note in the list, then archives them, in one undoable step.
    func copyAllAndArchive(undoManager: UndoManager?) {
        let targets = activeNotes.filter { !$0.isBlank }
        guard !targets.isEmpty else { return }
        writeToClipboard(Note.clipboardText(targets))
        archiveNotes(targets.map(\.id), undoManager: undoManager,
                     label: targets.count == 1 ? "Copied and archived 1 note" : "Copied and archived \(targets.count) notes")
    }

    func archiveNotes(_ ids: [UUID], undoManager: UndoManager?, label: String? = nil) {
        let targets = ids.compactMap(note).filter { !$0.isArchived }
        guard !targets.isEmpty else { return }
        if let open = expandedTaskID, ids.contains(open) { expandedTaskID = nil }
        let at = Date()
        let label = label ?? (targets.count == 1 ? "Archived “\(Self.shortTitle(targets[0]))”" : "Archived \(targets.count) notes")
        performOnNotes(label, affecting: targets.map(\.id), undoManager: undoManager) { repo in
            try repo.save(targets.map { var n = $0; n.archivedAt = at; return n })
            return []
        }
        selection.subtract(ids)
    }

    /// Puts archived notes back in the list.
    func unarchiveNotes(_ ids: [UUID], undoManager: UndoManager?) {
        let targets = ids.compactMap(note).filter(\.isArchived)
        guard !targets.isEmpty else { return }
        performOnNotes("Moved back to Notes", affecting: targets.map(\.id), undoManager: undoManager) { repo in
            try repo.save(targets.map { var n = $0; n.archivedAt = nil; return n })
            return []
        }
    }

    func deleteNotes(_ ids: [UUID], undoManager: UndoManager?) {
        let targets = ids.compactMap(note)
        guard !targets.isEmpty else { return }
        if let open = expandedTaskID, ids.contains(open) { expandedTaskID = nil }
        let label = targets.count == 1 ? "Deleted “\(Self.shortTitle(targets[0]))”" : "Deleted \(targets.count) notes"
        performOnNotes(label, affecting: targets.map(\.id), undoManager: undoManager) { repo in
            try repo.delete(noteIDs: targets.map(\.id))
            return []
        }
        selection.subtract(ids)
    }

    // MARK: Converting between tasks and notes

    /// Turns tasks into notes (title, then notes; tags as #tags; dates dropped).
    func convertToNotes(_ ids: [UUID], undoManager: UndoManager?) {
        let targets = ids.compactMap(task).filter { !$0.isCompleted }
        guard !targets.isEmpty else { return }
        let created = targets.map { Note(convertingTask: $0) }
        let label = targets.count == 1 ? "“\(targets[0].title)” is now a note" : "Converted \(targets.count) tasks to notes"
        convert(label, removingTasks: targets, removingNotes: [], creatingTasks: [], creatingNotes: created, undoManager: undoManager)
    }

    /// Turns notes into undated tasks (first line is the title, the rest its notes), so they land in Today.
    func convertToTasks(_ ids: [UUID], undoManager: UndoManager?) {
        let targets = ids.compactMap(note).filter { !$0.isBlank }
        guard !targets.isEmpty else { return }
        let created = targets.map(\.asTask)
        let label = targets.count == 1 ? "“\(created[0].title)” is now a task in Today" : "Converted \(targets.count) notes to tasks in Today"
        convert(label, removingTasks: [], removingNotes: targets, creatingTasks: created, creatingNotes: [], undoManager: undoManager)
    }

    private func convert(_ label: String, removingTasks: [BuoyTask], removingNotes: [Note],
                         creatingTasks: [BuoyTask], creatingNotes: [Note], undoManager: UndoManager?) {
        guard let repo = storage?.repository else { return }
        let removedIDs = removingTasks.map(\.id) + removingNotes.map(\.id)
        if let open = expandedTaskID, removedIDs.contains(open) { expandedTaskID = nil }
        markAdded(creatingTasks.map(\.id) + creatingNotes.map(\.id))
        do {
            try repo.save(creatingTasks)
            try repo.save(creatingNotes)
            try repo.delete(taskIDs: removingTasks.map(\.id))
            try repo.delete(noteIDs: removingNotes.map(\.id))
        } catch {
            report("Couldn't convert", error)
        }
        selection.subtract(removedIDs)
        reload()

        let token = UndoToken()
        let undo: () -> Void = { [weak self] in
            guard let self, let repo = self.storage?.repository else { return }
            do {
                try repo.delete(taskIDs: creatingTasks.map(\.id))
                try repo.delete(noteIDs: creatingNotes.map(\.id))
                try repo.save(removingTasks)
                try repo.save(removingNotes)
            } catch {
                self.report("Couldn't undo", error)
            }
            undoManager?.removeAllActions(withTarget: token)
            self.toast = nil
            self.reload()
        }
        undoManager?.registerUndo(withTarget: token) { _ in undo() }
        undoManager?.setActionName(creatingNotes.isEmpty ? "Convert to Task" : "Convert to Note")
        present(Toast(message: label, undo: undo))
    }

    /// Like `perform`, for notes: undo restores a snapshot and removes any notes the change created.
    private func performOnNotes(
        _ label: String,
        affecting ids: [UUID],
        undoManager: UndoManager?,
        showToast: Bool = true,
        _ change: (TaskRepository) throws -> [UUID]
    ) {
        guard let repo = storage?.repository else { return }
        let snapshot = notes.filter { ids.contains($0.id) }
        let created: [UUID]
        do {
            created = try change(repo)
        } catch {
            report("Couldn't \(label.lowercased())", error)
            reload()
            return
        }
        reload()

        let token = UndoToken()
        let undo: () -> Void = { [weak self] in
            guard let self, let repo = self.storage?.repository else { return }
            do {
                try repo.delete(noteIDs: created)
                try repo.save(snapshot)
            } catch {
                self.report("Couldn't undo", error)
            }
            undoManager?.removeAllActions(withTarget: token)
            self.toast = nil
            self.reload()
        }
        undoManager?.registerUndo(withTarget: token) { _ in undo() }
        undoManager?.setActionName(label)
        if showToast { present(Toast(message: label, undo: undo)) }
    }

    private func writeToClipboard(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    private static func shortTitle(_ note: Note) -> String {
        let line = note.firstLine
        return line.count > 28 ? String(line.prefix(27)) + "…" : line
    }

    /// Marks rows to fade in when they first appear. Call before the change reloads the lists.
    private func markAdded(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        recentlyAdded.formUnion(ids)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.recentlyAdded.subtract(ids)
        }
    }

    // MARK: Tags

    func renameTag(_ old: String, to new: String) {
        do {
            try storage?.repository.renameTag(old, to: new)
            if route == .tag(old) { route = .tag(new) }
            reload()
        } catch { report("Couldn't rename tag", error) }
    }

    func deleteTag(_ name: String) {
        do {
            try storage?.repository.deleteTag(name)
            if route == .tag(name) { route = .today }
            reload()
        } catch { report("Couldn't delete tag", error) }
    }

    // MARK: Backup & restore

    func backup(to url: URL) {
        do {
            try storage?.backup(to: url)
            present(Toast(message: "Backup saved to \(url.lastPathComponent)", undo: nil))
        } catch { report("Backup failed", error) }
    }

    func restore(from url: URL) {
        guard let storage else { return }
        do {
            let safety = try storage.restore(from: url)
            loadSettings()
            reload()
            selection = []
            alert = AlertMessage(title: "Backup restored",
                                 message: "Your previous data was saved to \(safety.lastPathComponent) in the Backups folder.")
        } catch { report("Restore failed", error) }
    }

    // MARK: Settings

    private func setSetting(_ key: String, _ value: String?) {
        guard !loadingSettings else { return }
        try? storage?.repository.setSetting(key, value)
    }

    private func loadSettings() {
        guard let repo = storage?.repository else { return }
        loadingSettings = true
        defer { loadingSettings = false }
        var p = NotificationPreferences()
        func flag(_ key: String, _ fallback: Bool) -> Bool { repo.setting(key).map { $0 == "1" } ?? fallback }
        p.enabled = flag("notify.enabled", p.enabled)
        p.whenActive = flag("notify.active", p.whenActive)
        p.whenDue = flag("notify.due", p.whenDue)
        p.whenSnoozeEnds = flag("notify.snooze", p.whenSnoozeEnds)
        p.whenReview = flag("notify.review", p.whenReview)
        p.hour = repo.setting("notify.hour").flatMap(Int.init) ?? p.hour
        p.minute = repo.setting("notify.minute").flatMap(Int.init) ?? p.minute
        notificationPreferences = p
        showMenuBarIcon = flag("menuBar.enabled", true)
        hotKey = repo.setting("hotKey").flatMap(HotKeyPreset.init(rawValue:)) ?? .controlSpace
        reviewAgentTasks = flag("agent.reviewNewTasks", true)
        if let key = repo.setting("agent.urlKey"), !key.isEmpty {
            agentKey = key
        } else {
            loadingSettings = false
            regenerateAgentKey()
        }
    }

    /// A new random key; links with the old one stop working.
    func regenerateAgentKey() {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        agentKey = bytes.map { String(format: "%02x", $0) }.joined()
        setSetting("agent.urlKey", agentKey)
    }

    private func persistNotificationPreferences() {
        let p = notificationPreferences
        setSetting("notify.enabled", p.enabled ? "1" : "0")
        setSetting("notify.active", p.whenActive ? "1" : "0")
        setSetting("notify.due", p.whenDue ? "1" : "0")
        setSetting("notify.snooze", p.whenSnoozeEnds ? "1" : "0")
        setSetting("notify.review", p.whenReview ? "1" : "0")
        setSetting("notify.hour", String(p.hour))
        setSetting("notify.minute", String(p.minute))
        onTasksChanged?()
    }
}
