import AppKit
import BuoyCore
import os

/// Carries out `buoy://` links from agents. Each valid command goes through the same
/// store methods the UI uses, so Buoy stays the only writer to its database and the
/// window updates as if you'd done it yourself. Anything invalid changes nothing and
/// is logged:
///
///     log stream --predicate 'subsystem == "app.buoy.Buoy"'
@MainActor
enum AgentLinkHandler {
    static let log = Logger(subsystem: "app.buoy.Buoy", category: "url")

    static func handle(_ url: URL, store: AppStore) {
        // Never log the key.
        let shown = redacted(url)
        guard store.storage != nil else {
            log.error("Ignored \(shown, privacy: .public): Buoy couldn't open its data")
            return
        }
        switch AgentLink.parse(url, today: store.today) {
        case .failure(let error):
            log.error("Ignored \(shown, privacy: .public): \(error.description, privacy: .public)")
        case .success(let link):
            guard constantTimeEqual(link.key, store.agentKey) else {
                log.error("Ignored \(shown, privacy: .public): \(AgentLinkError.wrongKey.description, privacy: .public)")
                return
            }
            switch perform(link.command, store: store) {
            case .success(let message):
                log.notice("\(message, privacy: .public)")
            case .failure(let error):
                log.error("Ignored \(shown, privacy: .public): \(error.description, privacy: .public)")
            }
        }
    }

    private static func perform(_ command: AgentCommand, store: AppStore) -> Result<String, AgentLinkError> {
        switch command {
        case .add(let fields, let requestedID):
            let id = requestedID ?? UUID()
            if store.task(id) != nil || store.deletedTasks.contains(where: { $0.id == id }) {
                return .failure(.rejected("id \(id.uuidString) is already used"))
            }
            // "every monday" with no dates starts on the first Monday, as in quick entry.
            let showOn = fields.showOn ?? (fields.dueOn == nil ? fields.repeats?.firstDay : nil)
            let entry = ParsedEntry(title: fields.title, showOn: showOn, dueOn: fields.dueOn,
                                    leadDays: fields.leadDays, tags: fields.tags, recurrence: fields.repeats?.rule,
                                    later: fields.later)
            // Projects skip the review strip: Shaping is where you look them over anyway.
            let review = store.reviewAgentTasks && fields.kind == .task
            guard let task = store.add(entry, notes: fields.notes, id: id, source: .agent, pendingReview: review,
                                       kind: fields.kind, column: .shaping, position: .top, expectations: fields.expectations,
                                       effortHours: fields.effortHours) else {
                return .failure(.rejected("couldn't add the \(fields.kind.rawValue)"))
            }
            let what = task.isProject ? "project" : "task"
            let outcome = review ? "waiting for review in Today"
                : task.isProject ? "on the board in \(task.boardColumn.title)" : store.placementSummary(for: task)
            return .success("Added \(what) “\(task.title)” [\(task.id.uuidString)]: \(outcome)")

        case .complete(let target, let result):
            let task: BuoyTask
            switch target {
            case .id(let id):
                guard let found = store.task(id) else { return .failure(.notFound(id)) }
                task = found
            case .titleMatch(let title):
                // Only tasks in your lists: ones waiting for review don't count.
                switch AgentLink.resolve(titleMatch: title, in: store.tasks.filter { !$0.pendingReview }) {
                case .success(let found): task = found
                case .failure(let error): return .failure(error)
                }
            }
            guard !task.isCompleted else { return .failure(.rejected("“\(task.title)” is already complete")) }
            guard !task.pendingReview else { return .failure(.rejected("“\(task.title)” is waiting for review; accept it first")) }
            // Finished projects go to Ready for review; only you move them to Done.
            if task.isProject {
                return .failure(.rejected("“\(task.title)” is a project: hand it in with update column=review and a result; only the user moves it to Done"))
            }
            if result != nil { return .failure(.invalid("result", "only for projects")) }
            store.complete([task.id], undoManager: nil)
            return .success("Completed “\(task.title)” [\(task.id.uuidString)]")

        case .snooze(let id, let until):
            guard let task = store.task(id) else { return .failure(.notFound(id)) }
            guard !task.isCompleted else { return .failure(.rejected("“\(task.title)” is complete")) }
            guard !task.pendingReview else { return .failure(.rejected("“\(task.title)” is waiting for review; accept it first")) }
            store.snooze([id], .until(until), undoManager: nil)
            return .success("Snoozed “\(task.title)” [\(id.uuidString)] until \(until.iso)")

        case .update(let id, let changes):
            guard let task = store.task(id) else { return .failure(.notFound(id)) }
            var edited = changes.applied(to: task, today: store.today)
            if edited.leadDays > 0 && edited.dueOn == nil {
                return .failure(.invalid("lead_days", "the task has no due date"))
            }
            if !edited.isProject {
                if changes.column != nil { return .failure(.invalid("column", "only for projects")) }
                if changes.status != nil { return .failure(.invalid("status", "only for projects")) }
                if changes.result != nil { return .failure(.invalid("result", "only for projects")) }
                if changes.expectations != nil { return .failure(.invalid("expectations", "only for projects")) }
            }
            if !task.isProject && edited.isProject {
                // A task becoming a project starts in Shaping, like any new one.
                if let column = changes.column, column != .shaping {
                    return .failure(.rejected("a new project starts in Shaping; only you move it to Ready"))
                }
                edited.boardColumn = .shaping
                edited.boardPosition = store.boardPosition(.shaping, .top, excluding: id)
            } else if let column = changes.column, task.isProject, column != task.boardColumn {
                // You decide what's ready; the agent only works what you've handed it.
                if task.isCompleted { return .failure(.rejected("“\(task.title)” is done; it isn't on the board")) }
                if task.boardColumn == .shaping {
                    return .failure(.rejected("“\(task.title)” is in Shaping; only you move it to Ready"))
                }
                // Blocked: back to the user in Shaping, saying what's needed. Ready would loop.
                if column == .shaping && (changes.status ?? "").isEmpty {
                    return .failure(.missing("status: say what you need when sending a card back to Shaping"))
                }
                if task.boardColumn == .review {
                    return .failure(.rejected("“\(task.title)” is waiting for the user's review; only they move it on"))
                }
                if column == .review && edited.result.isEmpty {
                    return .failure(.missing("result: say what you delivered when moving to review"))
                }
                // Handed in: the result says it all now, so last progress line goes.
                if column == .review && changes.status == nil { edited.status = "" }
                edited.boardPosition = store.boardPosition(column, .top, excluding: id)
            }
            store.update(edited)
            if edited.isProject && edited.boardColumn == .review && task.boardColumn != .review {
                store.onHandedIn?(edited)
            }
            return .success("Updated \(edited.isProject ? "project" : "task") “\(edited.title)” [\(id.uuidString)]")

        case .suggest(let id, let move, let reason):
            guard let task = store.task(id) else { return .failure(.notFound(id)) }
            guard let move else {
                guard task.openSuggestion != nil else { return .success("No suggestion to withdraw for “\(task.title)”") }
                store.setSuggestion(id, nil)
                return .success("Withdrew the suggestion for “\(task.title)” [\(id.uuidString)]")
            }
            if task.isProject { return .failure(.rejected("“\(task.title)” is a project; suggestions are for tasks")) }
            if task.isCompleted { return .failure(.rejected("“\(task.title)” is complete")) }
            if task.pendingReview { return .failure(.rejected("“\(task.title)” is waiting for review; accept it first")) }
            if move == .later && task.later { return .failure(.rejected("“\(task.title)” is already in Later")) }
            store.setSuggestion(id, Suggestion(move: move, reason: reason))
            return .success("Suggested \(move.summary) for “\(task.title)” [\(id.uuidString)]")

        case .reorder(.tasks, let ids):
            // Any open tasks (and dated projects); Today shows the ones that are due in this order.
            for id in ids {
                guard let item = store.task(id) else { return .failure(.notFound(id)) }
                if item.isCompleted || item.pendingReview {
                    return .failure(.rejected("“\(item.title)” is \(item.isCompleted ? "complete" : "waiting for review")"))
                }
            }
            store.reorder(.tasks, ids)
            return .success("Ordered \(ids.count) tasks: \(ids.compactMap { store.task($0)?.title }.joined(separator: " · "))")

        case .reorder(.ready, let ids):
            // The whole column, whatever you're searching for on screen.
            let current = Board.column(.ready, of: store.tasks).map(\.id)
            let missing = current.filter { !ids.contains($0) }
            let extra = ids.filter { !current.contains($0) }
            guard missing.isEmpty, extra.isEmpty else {
                var why = ["ids must list each of the \(current.count) projects in Ready exactly once"]
                if !missing.isEmpty { why.append("missing \(missing.map(\.uuidString).joined(separator: ", "))") }
                if !extra.isEmpty { why.append("not in Ready: \(extra.map(\.uuidString).joined(separator: ", "))") }
                return .failure(.rejected(why.joined(separator: "; ")))
            }
            guard ids != current else { return .success("Ready is already in that order") }
            store.reorder(.ready, ids)
            return .success("Reordered Ready: \(ids.compactMap { store.task($0)?.title }.joined(separator: " · "))")

        case .delete(let id):
            guard let what = store.agentDelete(id) else { return .failure(.notFound(id)) }
            return .success("Deleted \(what) [\(id.uuidString)]; restorable for 30 days in Settings ▸ Agent")

        case .note(let text):
            guard let note = store.addNote(text, source: .agent) else { return .failure(.missing("text")) }
            return .success("Saved a note [\(note.id.uuidString)]")
        }
    }

    /// The link with its key replaced, for logs.
    private static func redacted(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "a buoy:// link" }
        parts.queryItems = parts.queryItems?.map { $0.name == "key" ? URLQueryItem(name: "key", value: "•••") : $0 }
        return parts.string ?? "a buoy:// link"
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !y.isEmpty else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
