import Foundation

/// A `buoy://` link from an agent, parsed and validated. Parsing never touches the
/// database: Buoy applies a valid command through the same store methods the UI uses,
/// so Buoy stays the only writer to its own data.
///
/// Every link must carry `key` (checked against the one in Settings by the app).
/// Anything unknown, missing, duplicated or malformed is rejected as a whole: there
/// are no partial commands.
public struct AgentLink: Equatable, Sendable {
    public var key: String
    public var command: AgentCommand

    public static let actions = ["add", "complete", "snooze", "update", "note", "delete", "reorder", "suggest"]

    /// Parses `url`. `today` is used to reject snoozes that wouldn't hide anything.
    public static func parse(_ url: URL, today: LocalDate = .today()) -> Result<AgentLink, AgentLinkError> {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.malformed)
        }
        let action = (parts.host ?? "").lowercased()
        guard actions.contains(action) else { return .failure(.unknownAction(action)) }

        var params: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard params[item.name] == nil else { return .failure(.duplicate(item.name)) }
            params[item.name] = item.value ?? ""
        }
        let allowed: Set<String> = switch action {
        case "add": ["title", "notes", "expectations", "show_on", "due_on", "lead_days", "tags", "id", "kind", "later", "effort_hours", "repeat"]
        case "complete": ["id", "title_match", "result"]
        case "snooze": ["id", "until"]
        case "update": ["id", "title", "notes", "expectations", "show_on", "due_on", "lead_days", "tags", "kind", "column", "later", "status", "result", "effort_hours", "repeat"]
        case "delete": ["id"]
        case "reorder": ["list", "ids"]
        case "suggest": ["id", "later", "show_on", "due_on", "reason", "clear"]
        default: ["text"]
        }
        if let unknown = params.keys.filter({ $0 != "key" && !allowed.contains($0) }).sorted().first {
            return .failure(.unknownParameter(unknown))
        }
        guard let key = params["key"], !key.isEmpty else { return .failure(.missing("key")) }

        do {
            let command: AgentCommand
            switch action {
            case "add":
                guard let title = params["title"]?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                    throw AgentLinkError.missing("title")
                }
                let dueOn = try date(params, "due_on")
                let leadDays = try lead(params)
                if (leadDays ?? 0) > 0 && dueOn == nil { throw AgentLinkError.invalid("lead_days", "needs due_on") }
                // A new project always starts at the top of Shaping: only you move it to Ready.
                let kind = try self.kind(params) ?? .task
                if kind != .project && params["expectations"] != nil {
                    throw AgentLinkError.invalid("expectations", "only for kind=project")
                }
                command = .add(AgentTaskFields(
                    title: title, notes: params["notes"] ?? "", showOn: try date(params, "show_on"),
                    dueOn: dueOn, leadDays: leadDays ?? 0, tags: tags(params["tags"] ?? ""),
                    kind: kind, later: try flag(params, "later") ?? false,
                    expectations: params["expectations"] ?? "", effortHours: try effort(params),
                    repeats: try repeats(params, today: today) ?? nil),
                    id: try uuid(params, "id"))
            case "complete":
                let result = params["result"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                switch (try uuid(params, "id"), params["title_match"]?.trimmingCharacters(in: .whitespacesAndNewlines)) {
                case (let id?, nil): command = .complete(.id(id), result: result)
                case (nil, let title?) where !title.isEmpty: command = .complete(.titleMatch(title), result: result)
                case (nil, _): throw AgentLinkError.missing("id or title_match")
                default: throw AgentLinkError.conflicting("id", "title_match")
                }
            case "snooze":
                guard let id = try uuid(params, "id") else { throw AgentLinkError.missing("id") }
                guard let until = try date(params, "until") else { throw AgentLinkError.missing("until") }
                guard until > today else { throw AgentLinkError.invalid("until", "\(until.iso) is not after today") }
                command = .snooze(id: id, until: until)
            case "update":
                guard let id = try uuid(params, "id") else { throw AgentLinkError.missing("id") }
                var changes = AgentTaskChanges()
                if let title = params["title"] {
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { throw AgentLinkError.invalid("title", "empty") }
                    changes.title = trimmed
                }
                changes.notes = params["notes"]
                changes.expectations = params["expectations"]
                // Present but empty clears the date.
                if params["show_on"] != nil { changes.showOn = .some(try date(params, "show_on")) }
                if params["due_on"] != nil { changes.dueOn = .some(try date(params, "due_on")) }
                changes.leadDays = try lead(params)
                if let raw = params["tags"] { changes.tags = tags(raw) }
                changes.kind = try kind(params)
                changes.column = try column(params)
                changes.later = try flag(params, "later")
                changes.status = params["status"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                changes.result = params["result"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                if params["effort_hours"] != nil { changes.effortHours = .some(try effort(params)) }
                changes.repeats = try repeats(params, today: today)
                guard !changes.isEmpty else { throw AgentLinkError.missing("a field to change") }
                command = .update(id: id, changes)
            case "delete":
                guard let id = try uuid(params, "id") else { throw AgentLinkError.missing("id") }
                command = .delete(id)
            case "suggest":
                guard let id = try uuid(params, "id") else { throw AgentLinkError.missing("id") }
                if try flag(params, "clear") == true {
                    if let extra = ["later", "show_on", "due_on", "reason"].first(where: { params[$0] != nil }) {
                        throw AgentLinkError.conflicting("clear", extra)
                    }
                    command = .suggest(id: id, nil, reason: "")
                    break
                }
                var moves: [(String, SuggestedMove)] = []
                if let later = try flag(params, "later") {
                    guard later else { throw AgentLinkError.invalid("later", "0 (suggest later=1, or clear=1 to withdraw)") }
                    moves.append(("later", .later))
                }
                if let day = try date(params, "show_on") {
                    guard day > today else { throw AgentLinkError.invalid("show_on", "\(day.iso) is not after today") }
                    moves.append(("show_on", .showOn(day)))
                }
                if let day = try date(params, "due_on") {
                    guard day >= today else { throw AgentLinkError.invalid("due_on", "\(day.iso) is in the past") }
                    moves.append(("due_on", .dueOn(day)))
                }
                guard moves.count <= 1 else { throw AgentLinkError.conflicting(moves[0].0, moves[1].0) }
                guard let move = moves.first?.1 else { throw AgentLinkError.missing("later=1, show_on or due_on") }
                guard let reason = params["reason"]?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
                    throw AgentLinkError.missing("reason")
                }
                command = .suggest(id: id, move, reason: reason)
            case "reorder":
                guard let rawList = params["list"] else { throw AgentLinkError.missing("list") }
                guard let list = AgentList(rawValue: rawList.lowercased()) else {
                    throw AgentLinkError.invalid("list", "\(rawList) (tasks or ready)")
                }
                guard let raw = params["ids"], !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw AgentLinkError.missing("ids")
                }
                var ids: [UUID] = []
                for part in raw.split(separator: ",", omittingEmptySubsequences: false) {
                    let text = part.trimmingCharacters(in: .whitespaces)
                    guard let id = UUID(uuidString: text) else { throw AgentLinkError.invalid("ids", text) }
                    guard !ids.contains(id) else { throw AgentLinkError.invalid("ids", "\(text) is listed twice") }
                    ids.append(id)
                }
                command = .reorder(list, ids)
            default:
                guard let text = params["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AgentLinkError.missing("text")
                }
                command = .note(text)
            }
            return .success(AgentLink(key: key, command: command))
        } catch let error as AgentLinkError {
            return .failure(error)
        } catch {
            return .failure(.malformed)
        }
    }

    // MARK: Values

    /// A strict, real calendar date: `2026-12-01` yes; `2026-2-1`, `2026-02-30`, `Dec 1` no.
    /// An empty value means "no date".
    static func date(_ params: [String: String], _ name: String) throws -> LocalDate? {
        guard let raw = params[name], !raw.isEmpty else { return nil }
        guard raw.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let day = LocalDate(iso: raw),
              LocalDate(day.at(hour: 12)) == day else {
            throw AgentLinkError.invalid(name, raw)
        }
        return day
    }

    /// Hours, like `2` or `0.5`. An empty value means "not estimated".
    static func effort(_ params: [String: String]) throws -> Double? {
        guard let raw = params["effort_hours"], !raw.isEmpty else { return nil }
        guard let hours = Double(raw), hours.isFinite, hours > 0, hours <= Effort.maxHours else {
            throw AgentLinkError.invalid("effort_hours", "\(raw) (hours, more than 0 and at most \(Int(Effort.maxHours)))")
        }
        return hours
    }

    /// `repeat`, in the words quick entry understands: "every 2 weeks", "every other monday",
    /// "every last friday", "every 90 days after done". nil: not given; `.some(nil)`: an empty
    /// value, which stops it repeating.
    static func repeats(_ params: [String: String], today: LocalDate) throws -> AgentRepeat?? {
        guard let raw = params["repeat"] else { return nil }
        let phrase = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if phrase.isEmpty { return .some(nil) }
        let first = phrase.split(separator: " ").first.map { $0.lowercased() } ?? ""
        let parsed = QuickEntryParser(now: today.at(hour: 12)).parse("x " + phrase)
        // The phrase must be a repeat and nothing else: no dates, tags or other words.
        guard ["every", "repeat"].contains(first), var rule = parsed.recurrence, parsed.title == "x",
              parsed.dueOn == nil, parsed.leadDays == nil, parsed.tags.isEmpty, !parsed.later,
              parsed.showOn == nil || (rule.hasPattern && parsed.showOn == Recurrence.firstMatch(of: rule, onOrAfter: today)) else {
            throw AgentLinkError.invalid("repeat", "\(phrase) (like “every 2 weeks”, “every other monday” or “every last friday”)")
        }
        rule.anchorOn = nil
        return .some(AgentRepeat(rule: rule, firstDay: parsed.showOn))
    }

    static func lead(_ params: [String: String]) throws -> Int? {
        guard let raw = params["lead_days"] else { return nil }
        guard let days = Int(raw), (0...365).contains(days) else { throw AgentLinkError.invalid("lead_days", raw) }
        return days
    }

    /// IDs are uppercase UUID strings, like every row Buoy writes.
    static func uuid(_ params: [String: String], _ name: String) throws -> UUID? {
        guard let raw = params[name], !raw.isEmpty else { return nil }
        guard let id = UUID(uuidString: raw) else { throw AgentLinkError.invalid(name, raw) }
        return id
    }

    static func kind(_ params: [String: String]) throws -> TaskKind? {
        guard let raw = params["kind"] else { return nil }
        guard let kind = TaskKind(rawValue: raw.lowercased()) else { throw AgentLinkError.invalid("kind", "\(raw) (task or project)") }
        return kind
    }

    static func column(_ params: [String: String]) throws -> BoardColumn? {
        guard let raw = params["column"] else { return nil }
        guard let column = BoardColumn(rawValue: raw.lowercased()) else {
            throw AgentLinkError.invalid("column", raw.lowercased() == "done"
                ? "done (use column=review; only the user moves a project to Done)" : "\(raw) (ready, in_progress or review)")
        }
        return column
    }

    /// `1`/`0` (also true/false, yes/no).
    static func flag(_ params: [String: String], _ name: String) throws -> Bool? {
        guard let raw = params[name] else { return nil }
        switch raw.lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: throw AgentLinkError.invalid(name, "\(raw) (1 or 0)")
        }
    }

    static func tags(_ raw: String) -> [String] {
        BuoyTask.normalizedTags(raw.split(separator: ",").map(String.init))
    }

    // MARK: title_match

    /// The one open task whose title matches exactly (ignoring case and surrounding spaces).
    /// Zero or several matches is an error: Buoy never guesses which task was meant.
    public static func resolve(titleMatch: String, in tasks: [BuoyTask]) -> Result<BuoyTask, AgentLinkError> {
        let wanted = titleMatch.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = tasks.filter {
            !$0.isCompleted && $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(wanted, options: [.caseInsensitive]) == .orderedSame
        }
        switch matches.count {
        case 1: return .success(matches[0])
        case 0: return .failure(.noMatch(wanted))
        default: return .failure(.ambiguous(wanted, matches.map { "\($0.title) [\($0.id.uuidString)]" }))
        }
    }
}

public enum AgentCommand: Equatable, Sendable {
    /// `id` lets the agent choose the new task's ID, so it can refer to it later.
    case add(AgentTaskFields, id: UUID?)
    /// `result` is what a project delivered.
    case complete(AgentTarget, result: String?)
    case snooze(id: UUID, until: LocalDate)
    case update(id: UUID, AgentTaskChanges)
    case note(String)
    /// A task, project or note. Recoverable for 30 days.
    case delete(UUID)
    /// A new order, top first. `tasks`: your open tasks, in the order Today should show
    /// them. `ready`: every project in Ready, once.
    case reorder(AgentList, [UUID])
    /// Suggests Later, a Show On date or a due date for a task, with a reason. nil
    /// withdraws the agent's suggestion.
    case suggest(id: UUID, SuggestedMove?, reason: String)
}

/// The lists an agent can put in order.
public enum AgentList: String, Sendable, Equatable {
    /// Your todo list: open tasks, in the order Today shows them.
    case tasks
    /// The Delegated queue.
    case ready
}

/// Where a project goes in its board column.
public enum BoardPlacement: String, Sendable, Equatable {
    case top
    case bottom
}

public enum AgentTarget: Equatable, Sendable {
    case id(UUID)
    case titleMatch(String)
}

/// A repeat from a link. `firstDay` is the first matching day for patterns like
/// "every monday", used as the Show On date when the task has no dates of its own.
public struct AgentRepeat: Equatable, Sendable {
    public var rule: RecurrenceRule
    public var firstDay: LocalDate?

    public static func == (a: AgentRepeat, b: AgentRepeat) -> Bool {
        a.firstDay == b.firstDay && a.rule.copy(anchorOn: nil).summary == b.rule.copy(anchorOn: nil).summary
    }

    /// `task` repeating by this rule: anchored on its dates (or the first matching day), as
    /// quick entry would.
    public func applied(to task: BuoyTask, today: LocalDate) -> BuoyTask {
        var t = task
        if t.showOn == nil && t.dueOn == nil, let firstDay { t.showOn = firstDay }
        t.recurrence = rule.copy(anchorOn: rule.mode == .schedule ? (t.dueOn ?? t.showOn ?? today) : nil)
        return t
    }
}

public struct AgentTaskFields: Equatable, Sendable {
    public var title: String
    public var notes: String
    public var showOn: LocalDate?
    public var dueOn: LocalDate?
    public var leadDays: Int
    public var tags: [String]
    public var kind: TaskKind = .task
    /// Park it in Later instead of Today.
    public var later: Bool = false
    /// For projects: what done looks like.
    public var expectations: String = ""
    public var effortHours: Double?
    public var repeats: AgentRepeat?
}

/// Only the fields present in the link. A date set to `.some(nil)` is cleared.
public struct AgentTaskChanges: Equatable, Sendable {
    public var title: String?
    public var notes: String?
    public var expectations: String?
    public var showOn: LocalDate??
    public var dueOn: LocalDate??
    public var leadDays: Int?
    public var tags: [String]?
    public var kind: TaskKind?
    /// Applied by the app, which checks the move is one an agent may make.
    public var column: BoardColumn?
    public var later: Bool?
    public var status: String?
    public var result: String?
    /// `.some(nil)` clears the estimate.
    public var effortHours: Double??
    /// `.some(nil)` stops it repeating.
    public var repeats: AgentRepeat??

    public init() {}

    public var isEmpty: Bool {
        title == nil && notes == nil && expectations == nil && showOn == nil && dueOn == nil && leadDays == nil && tags == nil
            && kind == nil && column == nil && later == nil && status == nil && result == nil && effortHours == nil && repeats == nil
    }

    /// `task` with these changes applied.
    public func applied(to task: BuoyTask, today: LocalDate = .today()) -> BuoyTask {
        var t = task
        if let title { t.title = title }
        if let notes { t.notes = notes }
        if let expectations { t.expectations = expectations }
        if let showOn { t.showOn = showOn }
        if let dueOn { t.dueOn = dueOn }
        if let leadDays { t.leadDays = leadDays }
        if let tags { t.tags = tags }
        if let kind { t.kind = kind }
        if let column { t.boardColumn = column }
        if let status { t.status = status }
        if let result { t.result = result }
        if let effortHours { t.effortHours = effortHours }
        // After the dates, so a new repeat anchors on them.
        if let repeats {
            if let repeats { t = repeats.applied(to: t, today: today) } else { t.recurrence = nil }
        }
        if let later {
            t.later = later
            if later { t.surfacedAt = nil }
        }
        return t
    }
}

public enum AgentLinkError: Error, Equatable, Sendable, CustomStringConvertible {
    case malformed
    case unknownAction(String)
    case unknownParameter(String)
    case duplicate(String)
    case missing(String)
    case invalid(String, String)
    case conflicting(String, String)
    case wrongKey
    case noMatch(String)
    case ambiguous(String, [String])
    case notFound(UUID)
    case rejected(String)

    public var description: String {
        switch self {
        case .malformed: "not a valid buoy:// link"
        case .unknownAction(let a): "unknown action “\(a)” (expected \(AgentLink.actions.joined(separator: ", ")))"
        case .unknownParameter(let p): "unknown parameter “\(p)”"
        case .duplicate(let p): "parameter “\(p)” given more than once"
        case .missing(let p): "missing \(p)"
        case .invalid(let p, let v): "invalid \(p): \(v)"
        case .conflicting(let a, let b): "give \(a) or \(b), not both"
        case .wrongKey: "wrong or missing key"
        case .noMatch(let t): "no open task titled “\(t)”"
        case .ambiguous(let t, let matches): "\(matches.count) open tasks titled “\(t)”: \(matches.joined(separator: "; "))"
        case .notFound(let id): "nothing with id \(id.uuidString)"
        case .rejected(let why): why
        }
    }
}
