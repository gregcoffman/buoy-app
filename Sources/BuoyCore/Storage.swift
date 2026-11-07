import Foundation

/// Owns the on-disk database: where it lives, opening and migrating it safely,
/// and backup / restore.
public final class Storage {
    public let directory: URL
    public let databaseURL: URL
    public let backupsDirectory: URL
    public let db: Database
    public let repository: TaskRepository

    public static let backupExtension = "sqlite"

    /// Where Buoy keeps its data.
    ///
    /// - `BUOY_DATA_DIR` overrides everything (useful for testing).
    /// - Debug builds use `Application Support/Buoy-Dev`, so development never touches
    ///   the real database in `Application Support/Buoy`.
    public static func defaultDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["BUOY_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if DEBUG
        return support.appendingPathComponent("Buoy-Dev", isDirectory: true)
        #else
        return support.appendingPathComponent("Buoy", isDirectory: true)
        #endif
    }

    /// Opens (creating if needed) and migrates the database in `directory`.
    /// Before any migration touches an existing database, a backup is written.
    public init(directory: URL = Storage.defaultDirectory()) throws {
        self.directory = directory
        databaseURL = directory.appendingPathComponent("Buoy.sqlite")
        backupsDirectory = directory.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)

        db = try Database(path: databaseURL.path)
        repository = TaskRepository(db: db)
        try Self.migrateSafely(db, backupsDirectory: backupsDirectory)
    }

    private static func migrateSafely(_ db: Database, backupsDirectory: URL) throws {
        let pending = try Migrations.pending(for: db)
        guard !pending.isEmpty else { return }
        let from = db.userVersion
        if from > 0 {
            let name = "Buoy-before-migration-v\(from)-to-v\(Migrations.latestVersion)-\(timestamp()).\(backupExtension)"
            try db.writeCopy(to: backupsDirectory.appendingPathComponent(name))
        }
        try Migrations.migrate(db)
    }

    // MARK: Backup

    /// Writes a complete, portable copy of the database to `url`.
    /// The file is an ordinary SQLite database that any copy of Buoy can restore.
    public func backup(to url: URL) throws {
        try db.writeCopy(to: url)
    }

    public static func suggestedBackupName(date: Date = Date()) -> String {
        "Buoy Backup \(timestamp(date)).\(backupExtension)"
    }

    /// Makes a daily automatic backup if the latest one is older than `interval`,
    /// keeping the most recent `keep` automatic backups.
    @discardableResult
    public func automaticBackupIfNeeded(now: Date = Date(), interval: TimeInterval = 24 * 3600, keep: Int = 14) throws -> URL? {
        let autos = automaticBackups()
        if let latest = autos.first, let date = modificationDate(latest), now.timeIntervalSince(date) < interval {
            return nil
        }
        let url = backupsDirectory.appendingPathComponent("Buoy-auto-\(Self.timestamp(now)).\(Self.backupExtension)")
        try db.writeCopy(to: url)
        for old in automaticBackups().dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
        }
        return url
    }

    /// Automatic backups, newest first.
    public func automaticBackups() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("Buoy-auto-") }
            .sorted { (modificationDate($0) ?? .distantPast) > (modificationDate($1) ?? .distantPast) }
    }

    private func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // MARK: Restore

    public enum RestoreError: Error, CustomStringConvertible {
        case notABuoyBackup(String)
        case damaged(String)

        public var description: String {
            switch self {
            case .notABuoyBackup(let detail): "That file isn't a Buoy backup. (\(detail))"
            case .damaged(let detail): "That backup appears to be damaged. (\(detail))"
            }
        }
    }

    /// Checks that `url` is a readable Buoy database this version can open.
    public static func validateBackup(at url: URL) throws -> (taskCount: Int, schemaVersion: Int) {
        let source: Database
        do {
            source = try Database(path: url.path, readOnly: true)
        } catch {
            throw RestoreError.notABuoyBackup("\(error)")
        }
        let version = source.userVersion
        if version > Migrations.latestVersion {
            throw Migrations.MigrationError.newerThanApp(databaseVersion: version, appVersion: Migrations.latestVersion)
        }
        let tables: Set<String>
        do {
            tables = Set(try source.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0.string("name") })
        } catch {
            throw RestoreError.notABuoyBackup("\(error)")
        }
        guard version >= 1, tables.isSuperset(of: ["tasks", "tags", "task_tags", "completions"]) else {
            throw RestoreError.notABuoyBackup("missing Buoy tables")
        }
        let integrity = (try? source.query("PRAGMA integrity_check").first?.string("integrity_check")) ?? "unknown"
        guard integrity == "ok" else { throw RestoreError.damaged(integrity) }
        let count = (try? source.query("SELECT COUNT(*) AS n FROM tasks").first?.int("n")) ?? 0
        return (count, version)
    }

    /// Replaces all current data with the contents of the backup at `url`.
    /// The current data is saved to the Backups folder first, so a restore can itself be undone.
    /// Returns the location of that safety copy.
    @discardableResult
    public func restore(from url: URL) throws -> URL {
        _ = try Self.validateBackup(at: url)
        let safety = backupsDirectory.appendingPathComponent("Buoy-before-restore-\(Self.timestamp()).\(Self.backupExtension)")
        try db.writeCopy(to: safety)

        let source = try Database(path: url.path, readOnly: true)
        try db.replaceContents(with: source)
        // An older backup may need upgrading to the current schema.
        try Self.migrateSafely(db, backupsDirectory: backupsDirectory)
        return safety
    }

    // MARK: Helpers

    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f.string(from: date).replacingOccurrences(of: " ", with: "-")
    }
}
