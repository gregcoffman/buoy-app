import Foundation

/// Explicit, append-only schema migrations tracked with `PRAGMA user_version`.
///
/// Rules for adding a migration:
/// - Never edit or reorder a migration that has shipped. Append a new one.
/// - Never drop user data. Prefer `ALTER TABLE … ADD COLUMN` or copy-then-rename.
/// - Each migration runs in a transaction; a failure leaves the database untouched.
public enum Migrations {
    public struct Migration {
        public let version: Int
        public let name: String
        public let sql: String
    }

    public static let all: [Migration] = [
        Migration(version: 1, name: "Initial schema", sql: """
            CREATE TABLE recurrence_rules (
                id          TEXT PRIMARY KEY,
                unit        TEXT NOT NULL CHECK (unit IN ('day', 'week', 'month', 'year')),
                interval    INTEGER NOT NULL CHECK (interval >= 1),
                mode        TEXT NOT NULL CHECK (mode IN ('schedule', 'completion')),
                anchor_on   TEXT,
                created_at  REAL NOT NULL
            );

            CREATE TABLE tasks (
                id                  TEXT PRIMARY KEY,
                title               TEXT NOT NULL,
                notes               TEXT NOT NULL DEFAULT '',
                show_on             TEXT,
                due_on              TEXT,
                lead_days           INTEGER NOT NULL DEFAULT 0,
                snoozed_until       REAL,
                surfaced_at         REAL,
                recurrence_rule_id  TEXT REFERENCES recurrence_rules(id) ON DELETE SET NULL,
                created_at          REAL NOT NULL,
                updated_at          REAL NOT NULL
            );

            CREATE TABLE tags (
                id          TEXT PRIMARY KEY,
                name        TEXT NOT NULL UNIQUE COLLATE NOCASE,
                created_at  REAL NOT NULL
            );

            CREATE TABLE task_tags (
                task_id  TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
                tag_id   TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                PRIMARY KEY (task_id, tag_id)
            );
            CREATE INDEX task_tags_tag ON task_tags(tag_id);

            -- A task is complete exactly when it has a completion row.
            CREATE TABLE completions (
                id            TEXT PRIMARY KEY,
                task_id       TEXT NOT NULL UNIQUE REFERENCES tasks(id) ON DELETE CASCADE,
                completed_at  REAL NOT NULL,
                next_task_id  TEXT REFERENCES tasks(id) ON DELETE SET NULL
            );
            CREATE INDEX completions_completed_at ON completions(completed_at);

            CREATE TABLE settings (
                key    TEXT PRIMARY KEY,
                value  TEXT NOT NULL
            );
            """),
        Migration(version: 2, name: "Recurrence patterns (weekdays, Nth weekday, last day)", sql: """
            ALTER TABLE recurrence_rules ADD COLUMN weekdays TEXT;
            ALTER TABLE recurrence_rules ADD COLUMN month_ordinal INTEGER;
            ALTER TABLE recurrence_rules ADD COLUMN month_weekday INTEGER;
            """),
        // Only adds a table: removing it (and setting user_version back to 2)
        // returns the database to exactly what Buoy before Notes expects.
        Migration(version: 3, name: "Notes", sql: """
            CREATE TABLE notes (
                id           TEXT PRIMARY KEY,
                text         TEXT NOT NULL DEFAULT '',
                created_at   REAL NOT NULL,
                updated_at   REAL NOT NULL,
                archived_at  REAL
            );
            CREATE INDEX notes_created_at ON notes(created_at);
            """),
        // Who created each task or note: 'user', or 'agent' for buoy:// links. Adds columns only.
        Migration(version: 4, name: "Source attribution", sql: """
            ALTER TABLE tasks ADD COLUMN source TEXT NOT NULL DEFAULT 'user';
            ALTER TABLE notes ADD COLUMN source TEXT NOT NULL DEFAULT 'user';
            """),
        // Agent-added tasks waiting for you to accept them. Adds a column only.
        Migration(version: 5, name: "Review gate for agent tasks", sql: """
            ALTER TABLE tasks ADD COLUMN pending_review INTEGER NOT NULL DEFAULT 0;
            """),
        // Projects (a kind of task, on one board) and recoverable agent deletes. Adds columns only.
        Migration(version: 6, name: "Projects board and agent deletes", sql: """
            ALTER TABLE tasks ADD COLUMN kind TEXT NOT NULL DEFAULT 'task';
            ALTER TABLE tasks ADD COLUMN board_column TEXT NOT NULL DEFAULT 'todo';
            ALTER TABLE tasks ADD COLUMN board_position REAL NOT NULL DEFAULT 0;
            ALTER TABLE tasks ADD COLUMN deleted_at REAL;
            ALTER TABLE notes ADD COLUMN deleted_at REAL;
            """),
        // Later: tasks parked out of Today. Adds a column only.
        Migration(version: 7, name: "Later", sql: """
            ALTER TABLE tasks ADD COLUMN later INTEGER NOT NULL DEFAULT 0;
            """),
        // The board hands work to an agent: Shaping · Ready · In progress · Done. Every
        // open project starts over in Shaping. Adds the agent's status and result.
        Migration(version: 8, name: "Agent board", sql: """
            ALTER TABLE tasks ADD COLUMN status TEXT NOT NULL DEFAULT '';
            ALTER TABLE tasks ADD COLUMN result TEXT NOT NULL DEFAULT '';
            UPDATE tasks SET board_column = 'shaping' WHERE board_column NOT IN ('shaping', 'ready', 'in_progress');
            """),
        // A project's delivery expectations: what done looks like. Adds a column only.
        Migration(version: 9, name: "Delivery expectations", sql: """
            ALTER TABLE tasks ADD COLUMN expectations TEXT NOT NULL DEFAULT '';
            """),
        // Level of effort in hours on any task or project, and your agent's order for
        // Today (NULL: not estimated / not ordered). Adds columns only; the board's Ready
        // for review column is just a new column value.
        Migration(version: 10, name: "Effort and agent order", sql: """
            ALTER TABLE tasks ADD COLUMN effort_hours REAL;
            ALTER TABLE tasks ADD COLUMN agent_rank REAL;
            """),
        // Your agent's suggestion for a task (Later, a Show On date or a due date), with its
        // reason and whether you dismissed it. Adds columns only.
        Migration(version: 11, name: "Agent suggestions", sql: """
            ALTER TABLE tasks ADD COLUMN suggested_move TEXT;
            ALTER TABLE tasks ADD COLUMN suggested_on TEXT;
            ALTER TABLE tasks ADD COLUMN suggestion_reason TEXT NOT NULL DEFAULT '';
            ALTER TABLE tasks ADD COLUMN suggested_at REAL;
            ALTER TABLE tasks ADD COLUMN suggestion_dismissed_at REAL;
            """),
    ]

    public static var latestVersion: Int { all.map(\.version).max() ?? 0 }

    public enum MigrationError: Error, CustomStringConvertible {
        case newerThanApp(databaseVersion: Int, appVersion: Int)

        public var description: String {
            switch self {
            case let .newerThanApp(db, app):
                "This database was created by a newer version of Buoy (schema \(db); this app understands up to \(app)). Update Buoy to open it. Your data has not been changed."
            }
        }
    }

    /// Migrations that would run against `db`.
    public static func pending(for db: Database) throws -> [Migration] {
        let current = db.userVersion
        if current > latestVersion {
            throw MigrationError.newerThanApp(databaseVersion: current, appVersion: latestVersion)
        }
        return all.filter { $0.version > current }.sorted { $0.version < $1.version }
    }

    /// Brings `db` up to the latest schema.
    public static func migrate(_ db: Database) throws {
        for migration in try pending(for: db) {
            try db.transaction {
                try db.execute(migration.sql)
                try db.setUserVersion(migration.version)
            }
        }
    }
}
