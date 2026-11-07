import Foundation

/// Reads and writes tasks, tags, completions and settings.
public final class TaskRepository {
    public let db: Database

    public init(db: Database) {
        self.db = db
    }

    // MARK: Loading

    public func loadAll() throws -> [BuoyTask] {
        let rules = try Dictionary(uniqueKeysWithValues: db.query("SELECT * FROM recurrence_rules").compactMap { row -> (String, RecurrenceRule)? in
            guard let id = row.uuid("id"),
                  let unit = row.string("unit").flatMap(RecurrenceRule.Unit.init(rawValue:)),
                  let mode = row.string("mode").flatMap(RecurrenceRule.Mode.init(rawValue:)) else { return nil }
            let weekdays = (row.string("weekdays") ?? "").split(separator: ",").compactMap { Int($0) }
            return (id.uuidString, RecurrenceRule(id: id, unit: unit, interval: row.int("interval") ?? 1,
                                                  mode: mode, anchorOn: row.localDate("anchor_on"), weekdays: weekdays,
                                                  monthOrdinal: row.int("month_ordinal"), monthWeekday: row.int("month_weekday")))
        })

        var tagsByTask: [String: [String]] = [:]
        for row in try db.query("SELECT tt.task_id, t.name FROM task_tags tt JOIN tags t ON t.id = tt.tag_id") {
            if let taskID = row.string("task_id"), let name = row.string("name") {
                tagsByTask[taskID, default: []].append(name)
            }
        }

        let rows = try db.query("""
            SELECT t.*, c.id AS completion_id, c.completed_at, c.next_task_id
            FROM tasks t LEFT JOIN completions c ON c.task_id = t.id
            """)
        return rows.compactMap { row in
            guard let id = row.uuid("id") else { return nil }
            var completion: Completion? = nil
            if let cid = row.uuid("completion_id"), let at = row.date("completed_at") {
                completion = Completion(id: cid, completedAt: at, nextTaskID: row.uuid("next_task_id"))
            }
            return BuoyTask(
                id: id,
                title: row.string("title") ?? "",
                notes: row.string("notes") ?? "",
                showOn: row.localDate("show_on"),
                dueOn: row.localDate("due_on"),
                leadDays: row.int("lead_days") ?? 0,
                snoozedUntil: row.date("snoozed_until"),
                surfacedAt: row.date("surfaced_at"),
                recurrence: row.string("recurrence_rule_id").flatMap { rules[$0] },
                tags: tagsByTask[id.uuidString] ?? [],
                createdAt: row.date("created_at") ?? Date(),
                updatedAt: row.date("updated_at"),
                completion: completion,
                source: row.string("source").flatMap(ItemSource.init(rawValue:)) ?? .user,
                pendingReview: (row.int("pending_review") ?? 0) != 0,
                kind: row.string("kind").flatMap(TaskKind.init(rawValue:)) ?? .task,
                boardColumn: row.string("board_column").flatMap(BoardColumn.init(rawValue:)) ?? .shaping,
                boardPosition: row.double("board_position") ?? 0,
                deletedAt: row.date("deleted_at"),
                later: (row.int("later") ?? 0) != 0,
                status: row.string("status") ?? "",
                result: row.string("result") ?? "",
                expectations: row.string("expectations") ?? "",
                effortHours: row.double("effort_hours"),
                agentRank: row.double("agent_rank"),
                suggestion: Self.suggestion(row)
            )
        }
    }

    // MARK: Suggestions

    private static func moveName(_ move: SuggestedMove?) -> String? {
        switch move {
        case .later: "later"
        case .showOn: "show_on"
        case .dueOn: "due_on"
        case nil: nil
        }
    }

    private static func moveDay(_ move: SuggestedMove?) -> LocalDate? {
        switch move {
        case .showOn(let day), .dueOn(let day): day
        default: nil
        }
    }

    private static func suggestion(_ row: Row) -> Suggestion? {
        let move: SuggestedMove
        switch (row.string("suggested_move"), row.localDate("suggested_on")) {
        case ("later", _): move = .later
        case ("show_on", let day?): move = .showOn(day)
        case ("due_on", let day?): move = .dueOn(day)
        default: return nil
        }
        return Suggestion(move: move, reason: row.string("suggestion_reason") ?? "",
                          createdAt: row.date("suggested_at") ?? Date(), dismissedAt: row.date("suggestion_dismissed_at"))
    }

    // MARK: Writing tasks

    /// Inserts or updates a task, its recurrence rule and its tags.
    public func save(_ task: BuoyTask) throws {
        try db.transaction { try saveWithoutTransaction(task) }
    }

    private func saveWithoutTransaction(_ task: BuoyTask) throws {
        if let rule = task.recurrence {
            // Rules are immutable; a changed rule always arrives with a new id.
            try db.run("""
                INSERT OR IGNORE INTO recurrence_rules
                    (id, unit, interval, mode, anchor_on, created_at, weekdays, month_ordinal, month_weekday)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, rule.id, rule.unit.rawValue, rule.interval, rule.mode.rawValue, rule.anchorOn, Date(),
                rule.weekdays.isEmpty ? nil : rule.weekdays.map(String.init).joined(separator: ","),
                rule.monthOrdinal, rule.monthWeekday)
        }
        try db.run("""
            INSERT INTO tasks (id, title, notes, show_on, due_on, lead_days, snoozed_until, surfaced_at,
                               recurrence_rule_id, created_at, updated_at, source, pending_review,
                               kind, board_column, board_position, deleted_at, later, status, result, expectations,
                               effort_hours, agent_rank,
                               suggested_move, suggested_on, suggestion_reason, suggested_at, suggestion_dismissed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title, notes = excluded.notes, show_on = excluded.show_on,
                due_on = excluded.due_on, lead_days = excluded.lead_days,
                snoozed_until = excluded.snoozed_until, surfaced_at = excluded.surfaced_at,
                recurrence_rule_id = excluded.recurrence_rule_id, updated_at = excluded.updated_at,
                pending_review = excluded.pending_review, kind = excluded.kind,
                board_column = excluded.board_column, board_position = excluded.board_position,
                deleted_at = excluded.deleted_at, later = excluded.later,
                status = excluded.status, result = excluded.result, expectations = excluded.expectations,
                effort_hours = excluded.effort_hours, agent_rank = excluded.agent_rank,
                suggested_move = excluded.suggested_move, suggested_on = excluded.suggested_on,
                suggestion_reason = excluded.suggestion_reason, suggested_at = excluded.suggested_at,
                suggestion_dismissed_at = excluded.suggestion_dismissed_at
            """,
            task.id, task.title, task.notes, task.showOn, task.dueOn, task.leadDays,
            task.snoozedUntil, task.surfacedAt, task.recurrence?.id, task.createdAt, task.updatedAt, task.source.rawValue,
            task.pendingReview ? 1 : 0, task.kind.rawValue, task.boardColumn.rawValue, task.boardPosition,
            task.deletedAt, task.later ? 1 : 0, task.status, task.result, task.expectations,
            task.effortHours, task.agentRank,
            Self.moveName(task.suggestion?.move), Self.moveDay(task.suggestion?.move), task.suggestion?.reason ?? "",
            task.suggestion?.createdAt, task.suggestion?.dismissedAt)

        try db.run("DELETE FROM task_tags WHERE task_id = ?", task.id)
        for name in task.tags {
            try db.run("INSERT OR IGNORE INTO tags (id, name, created_at) VALUES (?, ?, ?)", UUID(), name, Date())
            try db.run("""
                INSERT OR IGNORE INTO task_tags (task_id, tag_id)
                SELECT ?, id FROM tags WHERE name = ? COLLATE NOCASE
                """, task.id, name)
        }

        if let completion = task.completion {
            try db.run("""
                INSERT INTO completions (id, task_id, completed_at, next_task_id) VALUES (?, ?, ?, ?)
                ON CONFLICT(task_id) DO UPDATE SET completed_at = excluded.completed_at, next_task_id = excluded.next_task_id
                """, completion.id, task.id, completion.completedAt, completion.nextTaskID)
        } else {
            try db.run("DELETE FROM completions WHERE task_id = ?", task.id)
        }
    }

    /// Saves several tasks atomically (e.g. a completion plus its next occurrence).
    public func save(_ tasks: [BuoyTask]) throws {
        try db.transaction {
            // Tasks may reference each other (a completion points at the next occurrence),
            // so check foreign keys when the transaction commits, not row by row.
            try db.execute("PRAGMA defer_foreign_keys = ON")
            for task in tasks { try saveWithoutTransaction(task) }
        }
    }

    public func delete(taskIDs: [UUID]) throws {
        try db.transaction {
            for id in taskIDs { try db.run("DELETE FROM tasks WHERE id = ?", id) }
        }
    }

    /// Removes for good whatever an agent deleted before `cutoff` (30 days ago).
    public func purgeDeleted(before cutoff: Date) throws {
        try db.transaction {
            try db.run("DELETE FROM tasks WHERE deleted_at IS NOT NULL AND deleted_at < ?", cutoff)
            try db.run("DELETE FROM notes WHERE deleted_at IS NOT NULL AND deleted_at < ?", cutoff)
        }
    }

    // MARK: Tags

    public func allTagNames() throws -> [String] {
        try db.query("SELECT name FROM tags ORDER BY name COLLATE NOCASE").compactMap { $0.string("name") }
    }

    public func renameTag(_ old: String, to new: String) throws {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty else { return }
        try db.transaction {
            let existing = try db.query("SELECT id FROM tags WHERE name = ? COLLATE NOCASE", new).first?.string("id")
            let source = try db.query("SELECT id FROM tags WHERE name = ? COLLATE NOCASE", old).first?.string("id")
            guard let source else { return }
            if let existing, existing != source {
                // Merge into the existing tag.
                try db.run("INSERT OR IGNORE INTO task_tags (task_id, tag_id) SELECT task_id, ? FROM task_tags WHERE tag_id = ?", existing, source)
                try db.run("DELETE FROM tags WHERE id = ?", source)
            } else {
                try db.run("UPDATE tags SET name = ? WHERE id = ?", new, source)
            }
        }
    }

    public func deleteTag(_ name: String) throws {
        try db.run("DELETE FROM tags WHERE name = ? COLLATE NOCASE", name)
    }

    public func deleteUnusedTags() throws {
        try db.run("DELETE FROM tags WHERE id NOT IN (SELECT tag_id FROM task_tags)")
    }

    // MARK: Settings (ApplicationSetting)

    public func setting(_ key: String) -> String? {
        try? db.query("SELECT value FROM settings WHERE key = ?", key).first?.string("value")
    }

    public func setSetting(_ key: String, _ value: String?) throws {
        if let value {
            try db.run("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", key, value)
        } else {
            try db.run("DELETE FROM settings WHERE key = ?", key)
        }
    }
}
