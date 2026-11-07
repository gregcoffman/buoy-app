import Foundation

/// A plain-text note: a thought captured for later, not a task. Notes have no
/// dates, tags or repeats. What's typed is exactly what gets copied out.
public struct Note: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Set once the note has been used (copied elsewhere). Archived notes are kept.
    public var archivedAt: Date?
    /// Who created it: you, or an agent through `buoy://note`.
    public var source: ItemSource
    /// Set when an agent deleted it; restorable for 30 days, then removed.
    public var deletedAt: Date?

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date(), updatedAt: Date? = nil, archivedAt: Date? = nil,
                source: ItemSource = .user, deletedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.archivedAt = archivedAt
        self.source = source
        self.deletedAt = deletedAt
    }

    public var isArchived: Bool { archivedAt != nil }
    public var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var lines: [Substring] {
        text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The first non-empty line, shown as the note's title in lists.
    public var firstLine: String {
        lines.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// Everything after the first line, flattened onto one line for previews.
    public var remainder: String {
        lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    /// The text to put on the clipboard: exactly as typed, minus trailing blank space.
    /// Several notes are separated by a blank line.
    public static func clipboardText(_ notes: [Note]) -> String {
        notes.map { note in
            var text = note.text
            while let last = text.last, last.isWhitespace || last.isNewline { text.removeLast() }
            return text
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    /// The note a task becomes: its title, then its notes. Tags come along as
    /// `#tags` so they survive the paste; dates and repeats are dropped.
    public init(convertingTask task: BuoyTask, at date: Date = Date()) {
        var firstLine = task.title
        let tags = task.tags.map { "#" + $0.replacingOccurrences(of: " ", with: "-") }
        if !tags.isEmpty { firstLine += " " + tags.joined(separator: " ") }
        let notes = task.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(text: notes.isEmpty ? firstLine : firstLine + "\n" + notes, createdAt: date, source: task.source)
    }

    /// The task a note becomes: the first line is the title, the rest its notes.
    /// The text isn't parsed, so nothing in it turns into a date or tag.
    public var asTask: BuoyTask {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let title = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let notes = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return BuoyTask(title: title, notes: notes, source: source)
    }

    /// Quick entry saves a line as a note when it starts with `>`.
    /// Returns the note's text, or nil when the line is an ordinary task.
    public static func capturedText(from input: String) -> String? {
        let trimmed = input.drop { $0.isWhitespace }
        guard trimmed.first == ">" else { return nil }
        return String(trimmed.dropFirst().drop { $0 == " " || $0 == "\t" })
    }
}

// MARK: - Persistence

extension TaskRepository {
    /// All notes, newest first.
    public func loadNotes() throws -> [Note] {
        try db.query("SELECT * FROM notes ORDER BY created_at DESC").compactMap { row in
            guard let id = row.uuid("id") else { return nil }
            return Note(id: id, text: row.string("text") ?? "",
                        createdAt: row.date("created_at") ?? Date(),
                        updatedAt: row.date("updated_at"),
                        archivedAt: row.date("archived_at"),
                        source: row.string("source").flatMap(ItemSource.init(rawValue:)) ?? .user,
                        deletedAt: row.date("deleted_at"))
        }
    }

    public func save(_ note: Note) throws {
        try save([note])
    }

    public func save(_ notes: [Note]) throws {
        try db.transaction {
            for note in notes {
                try db.run("""
                    INSERT INTO notes (id, text, created_at, updated_at, archived_at, source, deleted_at) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        text = excluded.text, updated_at = excluded.updated_at, archived_at = excluded.archived_at,
                        deleted_at = excluded.deleted_at
                    """, note.id, note.text, note.createdAt, note.updatedAt, note.archivedAt, note.source.rawValue, note.deletedAt)
            }
        }
    }

    public func delete(noteIDs: [UUID]) throws {
        try db.transaction {
            for id in noteIDs { try db.run("DELETE FROM notes WHERE id = ?", id) }
        }
    }
}
