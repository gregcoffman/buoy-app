import BuoyCore
import SwiftUI
import UniformTypeIdentifiers

/// One board for all your projects, handing work to your agent: Shaping · Ready ·
/// In progress · Ready for review · Done. You shape the ask and move it to Ready; the
/// agent orders Ready, takes cards from the top, reports its status while it works, and
/// hands each one back for review with what it delivered. You move it to Done. Drag
/// cards to reorder them or move them between columns.
/// Undated projects live only here; a project with a date also shows up in Today and
/// Upcoming when it's time.
struct ProjectBoard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(alignment: .top, spacing: 10) {
                ForEach(BoardColumn.allCases, id: \.self) { column in
                    BoardColumnView(column: column)
                }
                BoardColumnView(column: nil)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                SidebarRoute.projects.icon(size: 26)
                Text("Delegated")
                    .font(.system(size: 27, weight: .bold))
            }
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 38)
        }
        .padding(.top, 30)
        .padding(.bottom, 14)
        .padding(.leading, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Nothing in the title is clickable, so the whole block grabs the window.
        .overlay(WindowDragArea())
    }

    private var subtitle: String {
        let counts = BoardColumn.allCases.map { "\(store.board($0).count) \($0.title.lowercased())" }
        return counts.joined(separator: " · ")
    }
}

// MARK: - Column

private struct BoardColumnView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    /// nil is Done.
    let column: BoardColumn?
    @State private var targetedEnd = false

    private var cards: [BuoyTask] { column.map { store.board($0) } ?? store.doneProjects }
    private var title: String { column?.title ?? "Done" }

    var body: some View {
        let cards = self.cards
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.callout.weight(.semibold))
                Text("\(cards.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if column == .shaping {
                    Button { store.startProject() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New Project (⌘N)")
                }
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { index, project in
                        ProjectCardView(project: project, column: column, index: index)
                    }
                    // The rest of the column: drop here to go to the bottom.
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .overlay(alignment: .top) {
                            if targetedEnd { DropLine() }
                        }
                        .contentShape(Rectangle())
                        .dropDestination(for: String.self) { items, _ in
                            drop(items, at: cards.count)
                        } isTargeted: { targetedEnd = $0 }
                    if cards.isEmpty {
                        Text(emptyHint)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(6)
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.chipFill.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var emptyHint: String {
        switch column {
        case .shaping: "Write the ask and its context here, then move it to Ready."
        case .ready: "Your agent picks up from the top."
        case .inProgress: "Nothing being worked on."
        case .review: "Finished work waits here for you to check."
        case nil: "Finished projects show here, with what was delivered."
        }
    }

    private func drop(_ items: [String], at index: Int) -> Bool {
        guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
        withAnimation(.snappy(duration: 0.25)) {
            store.moveProject(id, to: column, at: index, undoManager: undoManager)
        }
        return true
    }
}

// MARK: - Card

private struct ProjectCardView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let project: BuoyTask
    let column: BoardColumn?
    let index: Int
    @State private var targeted = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(project.title.isEmpty ? "Untitled project" : project.title)
                .font(.callout)
                .foregroundStyle(project.isCompleted ? .secondary : .primary)
                .strikethrough(project.isCompleted, color: .secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            // What the agent reports: its status while working, what it delivered once handed in.
            if project.isCompleted || column == .review, !project.result.isEmpty {
                Label(project.result, systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .help(project.result)
            } else if !project.isCompleted, !project.status.isEmpty {
                Label(project.status, systemImage: "ellipsis.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.agent)
                    .lineLimit(2)
                    .help(project.status)
            }
            if hasMeta {
                // Wraps rather than truncating: five columns leave little room.
                FlowLayout(spacing: 6) {
                    if !project.isCompleted, let badge = DueBadge(task: project, today: store.today) {
                        HStack(spacing: 3) {
                            Image(systemName: "flag.fill").font(.system(size: 8))
                            Text(badge.text).monospacedDigit()
                        }
                        .foregroundStyle(badge.color)
                    } else if let show = project.showOn, !project.isCompleted {
                        Text("Shows \(Formatters.shortDay(show, today: store.today))").foregroundStyle(.secondary)
                    }
                    if !project.notes.isEmpty || !project.expectations.isEmpty {
                        Image(systemName: "doc.text").foregroundStyle(.tertiary)
                    }
                    if project.recurrence != nil {
                        Image(systemName: "repeat").foregroundStyle(.tertiary)
                    }
                    if project.source == .agent { AgentMark() }
                    if let hours = project.effortHours, !project.isCompleted {
                        Text("~\(Effort.format(hours))").foregroundStyle(.tertiary).monospacedDigit()
                            .help("Level of effort")
                    }
                    ForEach(project.tags.prefix(2), id: \.self) { tag in
                        Text(tag)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.chipFill, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(hovering ? 0.16 : 0.07)))
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        .overlay(alignment: .top) {
            if targeted { DropLine().offset(y: -4) }
        }
        .modifier(FadeIn(active: store.recentlyAdded.contains(project.id)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { store.openProject(project.id) }
        .draggable(project.id.uuidString) {
            Text(project.title)
                .font(.callout)
                .padding(8)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
        }
        // Dropping on a card puts the dragged project just above it.
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)), id != project.id else { return false }
            withAnimation(.snappy(duration: 0.25)) {
                store.moveProject(id, to: column, at: index, undoManager: undoManager)
            }
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu { menu }
        .help("Double-click to open · drag to reorder or move")
    }

    private var hasMeta: Bool {
        DueBadge(task: project, today: store.today) != nil || project.showOn != nil || !project.notes.isEmpty
            || !project.expectations.isEmpty
            || project.recurrence != nil || project.source == .agent || !project.tags.isEmpty
            || (project.effortHours != nil && !project.isCompleted)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open") { store.openProject(project.id) }
        Divider()
        Menu("Move To") {
            ForEach(BoardColumn.allCases, id: \.self) { target in
                Button(target.title) {
                    store.moveProject(project.id, to: target, at: 0, undoManager: undoManager)
                }
                .disabled(target == column)
            }
            Button("Done") { store.moveProject(project.id, to: nil, at: 0, undoManager: undoManager) }
                .disabled(column == nil)
        }
        if let column {
            Button("Move to Top") { store.moveProject(project.id, to: column, at: 0, undoManager: undoManager) }
            Button("Move to Bottom") {
                store.moveProject(project.id, to: column, at: store.board(column).count, undoManager: undoManager)
            }
            Divider()
            Button("Convert to Task") { store.convertKind([project.id], to: .task, undoManager: undoManager) }
            Button("Convert to Note") { store.convertToNotes([project.id], undoManager: undoManager) }
        }
        Divider()
        Button("Delete", role: .destructive) { store.delete([project.id], undoManager: undoManager) }
    }
}

/// Where a dragged card will land.
private struct DropLine: View {
    var body: some View {
        Capsule().fill(Color.accentColor).frame(height: 3)
    }
}

// MARK: - Editor

/// A project opened to write its brief: it takes the whole area right of the sidebar.
/// Nothing is saved until you click Save; Cancel throws your edits away.
struct ProjectDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    @FocusState private var titleFocused: Bool
    @State private var whyFocus = 0
    @State private var expectationsFocus = 0

    var body: some View {
        if let draft = store.projectDraft {
            let live = draft.isNew ? nil : store.task(draft.task.id)
            VStack(spacing: 0) {
                topBar(draft, live: live)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        TextField("The ask: what do you want done?", text: field(\.title), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 26, weight: .bold))
                            .focused($titleFocused)
                        section("Why / context", hint: "Background, links, constraints: anything your agent needs to know.",
                                onTap: { whyFocus += 1 }) {
                            NotesEditor(text: field(\.notes), placeholder: "Why this matters, and what your agent should know…",
                                        prominent: true, focusRequest: whyFocus)
                        }
                        section("Delivery expectations", hint: "What done looks like: the format, where it goes, how you'll judge it.",
                                onTap: { expectationsFocus += 1 }) {
                            NotesEditor(text: field(\.expectations), placeholder: "When it's done, I expect…",
                                        prominent: true, focusRequest: expectationsFocus)
                        }
                        if let live, !live.status.isEmpty || !live.result.isEmpty {
                            agentReport(live)
                        }
                        details(draft.task)
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 28)
                    .frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear {
                if draft.isNew {
                    for delay in [0.05, 0.2] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { titleFocused = true } }
                }
            }
        }
    }

    private func topBar(_ draft: ProjectDraft, live: BuoyTask?) -> some View {
        HStack(spacing: 10) {
            SidebarRoute.projects.icon(size: 18)
            Text(draft.isNew ? "New project" : live.map { $0.isCompleted ? "Done" : $0.boardColumn.title } ?? "Project")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Theme.projects.opacity(0.15), in: Capsule())
                .foregroundStyle(Theme.projects)
            if (live ?? draft.task).source == .agent {
                Label("Added by an agent", systemImage: "sparkles").font(.caption).foregroundStyle(Theme.agent)
            }
            Spacer()
            Button("Cancel") { store.projectDraft = nil }
                .controlSize(.large)
            Button("Save") { store.saveProjectDraft(undoManager: undoManager) }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(draft.task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Save (⌘S)")
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 10)
        // The empty stretch between the badge and the buttons grabs the window.
        .background(WindowDragArea())
    }

    private func section<Content: View>(_ title: String, hint: String, onTap: @escaping () -> Void,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(hint).font(.callout).foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
                .padding(12)
                // Clicking the empty part of the box puts the cursor in the text.
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.chipFill.opacity(0.6))
                    .onTapGesture(perform: onTap))
        }
    }

    private func agentReport(_ live: BuoyTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("From your agent", systemImage: "sparkles").font(.headline).foregroundStyle(Theme.agent)
            if !live.status.isEmpty && !live.isCompleted {
                Label(live.status, systemImage: "ellipsis.circle").foregroundStyle(Theme.agent)
            }
            if !live.result.isEmpty {
                Text("What was delivered").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                Text(live.result).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.agent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func details(_ task: BuoyTask) -> some View {
        HStack(spacing: 8) {
            DateChip(kind: .showOn, value: task.showOn) { d in edit { $0.showOn = d } }
            DateChip(kind: .due, value: task.dueOn) { d in
                edit { $0.dueOn = d; if d == nil { $0.leadDays = 0 } }
            }
            if task.dueOn != nil {
                LeadChip(value: task.leadDays) { n in edit { $0.leadDays = n } }
            }
            EffortChip(value: task.effortHours) { hours in edit { $0.effortHours = hours } }
            HStack(spacing: 5) {
                Image(systemName: "tag").foregroundStyle(.secondary)
                TextField("Tags, separated by commas", text: Binding(
                    get: { task.tags.joined(separator: ", ") },
                    set: { raw in edit { $0.tags = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } }
                ))
                .textFieldStyle(.plain)
                .frame(minWidth: 180)
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Theme.chipFill, in: Capsule())
        }
    }

    private func field(_ keyPath: WritableKeyPath<BuoyTask, String>) -> Binding<String> {
        Binding(get: { store.projectDraft?.task[keyPath: keyPath] ?? "" },
                set: { value in edit { $0[keyPath: keyPath] = value } })
    }

    private func edit(_ change: (inout BuoyTask) -> Void) {
        guard var draft = store.projectDraft else { return }
        change(&draft.task)
        store.projectDraft = draft
    }
}

struct ProjectDraft {
    var task: BuoyTask
    let isNew: Bool
    /// The estimate when you opened it, so Save only writes effort if you changed it.
    var openedEffort: Double?
}
