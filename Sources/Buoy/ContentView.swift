import BuoyCore
import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let error = store.startupError {
            StartupErrorView(message: error)
        } else {
            ContentView()
        }
    }
}

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            Group {
                if store.route == .notes {
                    NotesScreen()
                } else if store.route == .projects {
                    if store.projectDraft != nil { ProjectDetail() } else { ProjectBoard() }
                } else {
                    TaskListScreen(route: store.route ?? .today)
                }
            }
                .id(store.route)
                // The title-bar strip above the content: grab it to move the window.
                .overlay(alignment: .top) {
                    WindowDragArea().frame(height: 28).ignoresSafeArea(.container, edges: .top)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // The project editor has its own Save and Cancel.
                    if !(store.route == .projects && store.projectDraft != nil) { BottomBar() }
                }
                .navigationTitle("")
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .overlay(alignment: .bottom) { ToastView().padding(.bottom, 44) }
        .sheet(item: $store.snoozePicker) { targets in
            SnoozeDatePicker { day in
                store.collapse()
                store.snooze(targets.ids, .until(day), undoManager: undoManager)
            }
        }
        .alert(item: $store.alert) { message in
            Alert(title: Text(message.title), message: Text(message.message))
        }
        .onAppear {
            store.openMainWindow = { openWindow(id: "main") }
        }
        .frame(minWidth: 660, minHeight: 420)
    }
}

// MARK: Sidebar

private struct Sidebar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    @State private var renaming: String?
    @State private var newName = ""

    var body: some View {
        @Bindable var store = store
        List(selection: $store.route) {
            Section {
                row(.bridge)
                row(.today, badge: store.todayCount)
                    .dropDestination(for: String.self) { items, _ in dropTasks(items) { store.surface($0, undoManager: undoManager) } }
                row(.upcoming)
                row(.later, badge: store.laterCount)
                    .dropDestination(for: String.self) { items, _ in dropTasks(items) { store.moveToLater($0, undoManager: undoManager) } }
                row(.logbook)
            }
            Section {
                row(.projects, badge: store.reviewCount)
                row(.notes, badge: store.activeNoteCount)
            }
            if !store.sidebarTags.isEmpty {
                Section("Tags") {
                    ForEach(store.sidebarTags, id: \.self) { tag in
                        row(.tag(tag))
                            .contextMenu {
                                Button("Rename…") {
                                    newName = tag
                                    renaming = tag
                                }
                                Button("Delete Tag", role: .destructive) { store.deleteTag(tag) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar(removing: .sidebarToggle)
        .safeAreaInset(edge: .bottom, spacing: 0) { LogoLockup() }
        .alert("Rename Tag", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let old = renaming { store.renameTag(old, to: newName) }
                renaming = nil
            }
        }
    }

    /// Tasks dragged from a list onto Today or Later in the sidebar.
    private func dropTasks(_ items: [String], _ action: ([UUID]) -> Void) -> Bool {
        let ids = items.compactMap(UUID.init(uuidString:)).filter { store.task($0) != nil }
        guard !ids.isEmpty else { return false }
        withAnimation(.snappy(duration: 0.25)) { action(ids) }
        return true
    }

    private func row(_ route: SidebarRoute, badge: Int = 0) -> some View {
        NavigationLink(value: route) {
            Label {
                Text(route.title)
            } icon: {
                route.icon(size: 15).frame(width: 18)
            }
        }
        .badge(badge)
        // A badged row loses the link's value as its selection tag, so clicking it
        // selected nothing (and the window fell back to Today). Tag it explicitly.
        .tag(route)
    }
}

// MARK: Lists

private enum SectionHeader {
    case none
    case day(LocalDate)
    case text(String)
    /// A collapsible group on The Bridge: Today, Upcoming, Later.
    case group(SidebarRoute, count: Int)
}

private struct ListSection: Identifiable {
    let id: String
    let header: SectionHeader
    let rows: [(task: BuoyTask, context: RowContext)]
}

struct TaskListScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let route: SidebarRoute
    @State private var draft = QuickEntryModel()
    @AppStorage("todayPeekOpen") private var peekOpen = false
    /// The Bridge's collapsed groups, e.g. "upcoming,later".
    @AppStorage("bridgeCollapsed") private var collapsedGroups = ""

    var body: some View {
        @Bindable var store = store
        let sections = self.sections
        ScrollViewReader { proxy in
        List(selection: $store.selection) {
            header
                .id("header")
                .selectionDisabled()
                .listRowSeparator(.hidden)

            if (route == .today || route == .bridge) && !store.pendingReview.isEmpty {
                ReviewStrip()
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if (route == .today || route == .bridge) && !store.suggestions.isEmpty {
                SuggestionStrip()
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if store.composing {
                DraftTaskCard(model: draft, extraTags: routeTags, onDone: finishedComposing)
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.97, anchor: .top)),
                        removal: .opacity))
            }

            if isEmpty && !store.composing {
                emptyState
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
            }

            ForEach(sections) { section in
                switch section.header {
                case .none:
                    Section { rows(section.rows) }
                case .day(let day):
                    Section { rows(section.rows) } header: { DayHeader(day: day, today: store.today) }
                case .text(let title):
                    Section { rows(section.rows) } header: { TextHeader(title: title) }
                case .group(let group, let count):
                    Section {
                        if !isCollapsed(group) { rows(section.rows) }
                    } header: {
                        GroupHeader(group: group, count: count, collapsed: isCollapsed(group)) { toggle(group) }
                    }
                }
            }

            if route == .today { tomorrowPeek }
        }
        .listStyle(.inset)
        // Use the empty band under the (invisible) toolbar instead of starting below it.
        .ignoresSafeArea(.container, edges: .top)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
        .contextMenu(forSelectionType: UUID.self) { ids in
            TaskActions(ids: Array(ids))
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { store.expand(id) }
        }
        .onDeleteCommand {
            store.delete(Array(store.selection), undoManager: undoManager)
        }
        .onChange(of: store.selection) {
            // Selecting another task closes the open one.
            if let open = store.expandedTaskID, !store.selection.isEmpty, !store.selection.contains(open) {
                store.expandedTaskID = nil
            }
        }
        .onChange(of: store.focusQuickEntryRequest) {
            // Bring the new-task card into view, then put the cursor in it.
            withAnimation(.snappy) { proxy.scrollTo("header", anchor: .top) }
            draft.focusRequest += 1
        }
        }
        .onDisappear { store.composing = false }
    }

    @ViewBuilder
    private func rows(_ rows: [(task: BuoyTask, context: RowContext)]) -> some View {
        ForEach(rows, id: \.task.id) { row in
            TaskRow(task: row.task, context: row.context)
                .tag(row.task.id)
                // Drag onto Today or Later in the sidebar to move it there.
                .draggable(row.task.id.uuidString)
                .selectionDisabled(store.expandedTaskID == row.task.id)
                .listRowSeparator(.hidden)
                .listRowBackground(store.expandedTaskID == row.task.id ? Color.clear : nil)
        }
    }

    private func finishedComposing(_ task: BuoyTask?) {
        withAnimation(.snappy(duration: 0.2)) { store.composing = false }
        guard let task else { return }
        // If the new task went somewhere else, say where so it doesn't feel lost.
        let placement = store.placement(of: task)
        let landedHere: Bool = switch (route, placement) {
        case (.today, .today), (.upcoming, .upcoming), (.later, .later), (.bridge, _): true
        default: false
        }
        if landedHere {
            store.selection = [task.id]
        } else {
            store.present(Toast(message: store.placementSummary(for: task), undo: nil))
        }
    }

    private var routeTags: [String] {
        if case .tag(let tag) = route { [tag] } else { [] }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                route.icon(size: 26)
                Text(route.title)
                    .font(.system(size: 27, weight: .bold))
            }
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 38)
        }
        .padding(.top, 16)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Nothing in the title is clickable, so the whole block grabs the window.
        .overlay(WindowDragArea())
    }

    private var subtitle: String {
        switch route {
        case .bridge:
            let day = store.now.formatted(.dateTime.weekday(.wide).month(.wide).day())
            return "\(day) · \(store.todayItems.count) today · \(store.upcomingItems.count) upcoming · \(store.laterItems.count) later"
        case .today:
            let count = store.todayItems.count
            let day = store.now.formatted(.dateTime.weekday(.wide).month(.wide).day())
            return count == 0 ? day : "\(day) · \(count) \(count == 1 ? "task" : "tasks")"
        case .later:
            let count = store.laterItems.count
            return count == 0 ? "Nothing parked" : "\(count) parked for later"
        case .upcoming:
            let count = store.upcomingItems.count
            return "\(count) \(count == 1 ? "task" : "tasks") waiting to rise"
        case .logbook:
            return "\(store.logbookTasks.count) completed"
        case .tag(let tag):
            return "\(store.tagged(tag).filter { !$0.isCompleted }.count) active"
        case .notes, .projects:
            return "" // Notes and Projects have their own screens.
        }
    }

    // MARK: Tomorrow peek

    @ViewBuilder
    private var tomorrowPeek: some View {
        let tomorrow = store.today.adding(days: 1)
        let rising = store.upcomingItems.filter { LocalDate($0.risesAt) == tomorrow }
        if !rising.isEmpty {
            Button {
                withAnimation(.snappy(duration: 0.2)) { peekOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(peekOpen ? 90 : 0))
                    Image(systemName: "arrow.up").font(.caption)
                    Text("\(rising.count) \(rising.count == 1 ? "task rises" : "tasks rise") tomorrow")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .selectionDisabled()
            .listRowSeparator(.hidden)
            .padding(.top, 18)

            if peekOpen {
                ForEach(rising) { item in
                    TaskRow(task: item.task, context: .upcoming(risesAt: item.risesAt, snoozed: item.snoozed))
                        .opacity(0.7)
                        .tag(item.task.id)
                        .listRowSeparator(.hidden)
                        .selectionDisabled(store.expandedTaskID == item.task.id)
                }
            }
        }
    }

    // MARK: Empty states

    /// Nothing to show at all (collapsed groups on The Bridge still count as content).
    private var isEmpty: Bool {
        switch route {
        case .bridge: store.todayItems.isEmpty && store.upcomingItems.isEmpty && store.laterItems.isEmpty
        default: sections.allSatisfy { $0.rows.isEmpty }
        }
    }

    private func isCollapsed(_ group: SidebarRoute) -> Bool {
        collapsedGroups.split(separator: ",").contains { $0 == "\(group)" }
    }

    private func toggle(_ group: SidebarRoute) {
        var groups = Set(collapsedGroups.split(separator: ",").map(String.init))
        if !groups.insert("\(group)").inserted { groups.remove("\(group)") }
        withAnimation(.snappy(duration: 0.2)) { collapsedGroups = groups.sorted().joined(separator: ",") }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch route {
        case .today, .bridge:
            VStack(spacing: 14) {
                BobbingBuoy()
                Text(store.searchText.isEmpty ? "Nothing needs your attention" : "No matches")
                    .font(.title3.weight(.semibold))
                Text("Tasks rise here when their Show On date arrives, their lead time begins, or they come due.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 340)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 50)
        case .upcoming:
            quietEmpty("Nothing on the horizon", "Tasks with future Show On dates, lead times, or snoozes wait here until they're relevant.")
        case .later:
            quietEmpty(store.searchText.isEmpty ? "Nothing in Later" : "No matches",
                       "Park something here to keep it out of Today: right-click ▸ Move to Later, ⌥⌘L, or end a quick entry with “later”.")
        case .logbook:
            quietEmpty(store.searchText.isEmpty ? "No completed tasks yet" : "No matches", "Completed tasks are recorded here.")
        case .tag(let tag):
            quietEmpty("Nothing tagged \(tag)", "")
        case .notes, .projects:
            EmptyView()
        }
    }

    private func quietEmpty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            if !detail.isEmpty {
                Text(detail).multilineTextAlignment(.center).foregroundStyle(.tertiary).frame(maxWidth: 340)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: Sections

    private var sections: [ListSection] {
        switch route {
        case .bridge:
            // Near to far: what needs you now, what's coming, what you parked.
            let today = store.todayItems, upcoming = store.upcomingItems, later = store.laterItems
            return [
                ListSection(id: "g-today", header: .group(.today, count: today.count), rows: today.map { ($0.task, .today($0.reason)) }),
                ListSection(id: "g-upcoming", header: .group(.upcoming, count: upcoming.count),
                            rows: upcoming.map { ($0.task, .upcoming(risesAt: $0.risesAt, snoozed: $0.snoozed)) }),
                ListSection(id: "g-later", header: .group(.later, count: later.count), rows: later.map { ($0, .later) }),
            ]
        case .later:
            return [ListSection(id: "later", header: .none, rows: store.laterItems.map { ($0, .later) })]
        case .today:
            return [ListSection(id: "today", header: .none, rows: store.todayItems.map { ($0.task, .today($0.reason)) })]
        case .upcoming:
            return upcomingSections(store.upcomingItems)
        case .logbook:
            return logbookSections(store.logbookTasks)
        case .tag(let tag):
            let tagged = store.tagged(tag)
            let today = Attention.today(tagged, now: store.now)
            let upcoming = Attention.upcoming(tagged, now: store.now)
            let done = Attention.logbook(tagged).prefix(20)
            return [
                ListSection(id: "t", header: .text("Today"), rows: today.map { ($0.task, .today($0.reason)) }),
                ListSection(id: "u", header: .text("Upcoming"), rows: upcoming.map { ($0.task, .upcoming(risesAt: $0.risesAt, snoozed: $0.snoozed)) }),
                ListSection(id: "l", header: .text("Completed"), rows: done.map { ($0, .logbook) }),
            ].filter { !$0.rows.isEmpty }
        case .notes, .projects:
            return []
        }
    }

    /// Day-by-day for the next two weeks, then by month.
    private func upcomingSections(_ items: [Attention.UpcomingItem]) -> [ListSection] {
        let today = store.today
        var order: [String] = []
        var headers: [String: SectionHeader] = [:]
        var grouped: [String: [(BuoyTask, RowContext)]] = [:]
        for item in items {
            let day = LocalDate(item.risesAt)
            let key: String
            if today.days(until: day) <= 14 {
                key = day.iso
                headers[key] = headers[key] ?? .day(day)
            } else {
                key = String(day.iso.prefix(7))
                headers[key] = headers[key] ?? .text(Formatters.month(day))
            }
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append((item.task, .upcoming(risesAt: item.risesAt, snoozed: item.snoozed)))
        }
        return order.map { ListSection(id: $0, header: headers[$0]!, rows: grouped[$0]!.map { (task: $0.0, context: $0.1) }) }
    }

    private func logbookSections(_ tasks: [BuoyTask]) -> [ListSection] {
        var order: [String] = []
        var grouped: [String: [BuoyTask]] = [:]
        for task in tasks {
            let key = LocalDate(task.completion!.completedAt).iso
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(task)
        }
        return order.map { key in
            ListSection(id: key, header: .day(LocalDate(iso: key)!), rows: grouped[key]!.map { ($0, .logbook) })
        }
    }
}

/// Date header: a big day number, then the day's name, over a hairline.
private struct DayHeader: View {
    let day: LocalDate
    let today: LocalDate

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(day.day)")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)
                Text(label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
        .padding(.top, 14)
    }

    private var label: String {
        switch today.days(until: day) {
        case 0: "Today"
        case 1: "Tomorrow"
        case -1: "Yesterday"
        default:
            day.month == today.month
                ? day.at(hour: 12).formatted(.dateTime.weekday(.wide))
                : "\(day.at(hour: 12).formatted(.dateTime.weekday(.wide))) · \(day.at(hour: 12).formatted(.dateTime.month(.wide)))"
        }
    }
}

/// A collapsible group header on The Bridge, in the group's colour.
private struct GroupHeader: View {
    let group: SidebarRoute
    let count: Int
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    group.icon(size: 15)
                    Text(group.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("\(count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show \(group.title)" : "Hide \(group.title)")
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
        .padding(.top, 14)
    }
}

private struct TextHeader: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.primary)
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
        .padding(.top, 14)
    }
}

// MARK: Bottom bar

private struct BottomBar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var store = store
        let selected = Array(store.selection)
        HStack(spacing: 4) {
            if store.searching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $store.searchText)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onExitCommand(perform: closeSearch)
                    if !store.searchText.isEmpty {
                        Button { store.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.chipFill, in: RoundedRectangle(cornerRadius: 7))
                .frame(maxWidth: 360)
                Button("Done", action: closeSearch)
                    .buttonStyle(.borderless)
                    .padding(.leading, 6)
            } else if store.route == .projects {
                BarButton(title: "New Project", icon: "plus", shortcut: "⌘N") { store.startProject() }
                BarButton(title: "Search", icon: "magnifyingglass", shortcut: "⌘F") { openSearch() }
            } else if store.route == .notes {
                BarButton(title: "New Note", icon: "square.and.pencil", shortcut: "⌥⌘N") { store.startNote() }
                BarButton(title: "Copy", icon: "doc.on.doc", shortcut: "⌘C") {
                    store.copyNotes(selected, undoManager: undoManager)
                }
                .disabled(selected.isEmpty)
                BarButton(title: "Copy All & Archive", icon: "tray.and.arrow.up", shortcut: "⇧⌘C") {
                    store.copyAllAndArchive(undoManager: undoManager)
                }
                .disabled(store.activeNoteCount == 0)
                BarButton(title: "Search", icon: "magnifyingglass", shortcut: "⌘F") { openSearch() }
            } else {
                BarButton(title: "New Task", icon: "plus", shortcut: "⌘N") { store.startComposing() }

                Menu {
                    ForEach(SnoozeOption.presets, id: \.self) { option in
                        Button(option.label) { store.snooze(selected, option, undoManager: undoManager) }
                    }
                    Divider()
                    Button("Pick a Date…") { store.snoozePicker = SnoozeTargets(ids: selected) }
                } label: {
                    Label("Snooze", systemImage: "moon.zzz")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 8)
                .disabled(selected.isEmpty)
                .help("Snooze the selected tasks")

                BarButton(title: "Move to Today", icon: "arrow.up.to.line", shortcut: "⇧⌘T") {
                    store.surface(selected, undoManager: undoManager)
                }
                .disabled(selected.isEmpty || store.route == .today)

                BarButton(title: "Later", icon: "tray.and.arrow.down", shortcut: "⌥⌘L") {
                    store.moveToLater(selected, undoManager: undoManager)
                }
                .disabled(selected.isEmpty || store.route == .later)

                BarButton(title: "Search", icon: "magnifyingglass", shortcut: "⌘F") { openSearch() }
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.snappy(duration: 0.2), value: store.searching)
        .onChange(of: store.focusSearchRequest) { openSearch() }
    }

    private func openSearch() {
        store.searching = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
    }

    private func closeSearch() {
        store.searchText = ""
        store.searching = false
    }
}

/// A labelled bottom-bar button. The tooltip adds the keyboard shortcut.
private struct BarButton: View {
    let title: String
    let icon: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(hovering && isEnabled ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(title) (\(shortcut))")
    }
}

/// Actions for one or more tasks, used by context menus.
struct TaskActions: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let ids: [UUID]

    var body: some View {
        let tasks = ids.compactMap(store.task)
        let active = tasks.filter { !$0.isCompleted }
        let done = tasks.filter(\.isCompleted)
        if ids.count == 1, let id = ids.first {
            Button("Open") { store.expand(id) }
            Divider()
        }
        if !active.isEmpty {
            Button("Complete") { store.complete(active.map(\.id), undoManager: undoManager) }
            SnoozeMenu(ids: active.map(\.id))
            if active.contains(where: { !store.placement(of: $0).isToday }) {
                Button("Move to Today") { store.surface(active.map(\.id), undoManager: undoManager) }
            }
            if active.contains(where: { !$0.later }) {
                Button("Move to Later") { store.moveToLater(active.map(\.id), undoManager: undoManager) }
            }
            if active.contains(where: { $0.snoozedUntil != nil && store.placement(of: $0).isUpcoming }) {
                Button("Unsnooze") { store.unsnooze(active.map(\.id), undoManager: undoManager) }
            }
            if active.contains(where: { $0.recurrence != nil }) {
                Button("Skip This Occurrence") {
                    store.skip(active.filter { $0.recurrence != nil }.map(\.id), undoManager: undoManager)
                }
            }
        }
        if !done.isEmpty {
            Button("Mark as Not Done") { store.markIncomplete(done.map(\.id), undoManager: undoManager) }
        }
        if !active.isEmpty {
            Divider()
            let plain = active.filter { !$0.isProject }, projects = active.filter(\.isProject)
            if !plain.isEmpty {
                Button(plain.count > 1 ? "Convert \(plain.count) Tasks to Projects" : "Convert to Project") {
                    store.convertKind(plain.map(\.id), to: .project, undoManager: undoManager)
                }
            }
            if !projects.isEmpty {
                Button(projects.count > 1 ? "Convert \(projects.count) Projects to Tasks" : "Convert to Task") {
                    store.convertKind(projects.map(\.id), to: .task, undoManager: undoManager)
                }
            }
            Button(active.count > 1 ? "Convert \(active.count) to Notes" : "Convert to Note") {
                store.convertToNotes(active.map(\.id), undoManager: undoManager)
            }
        }
        Divider()
        Button("Delete", role: .destructive) { store.delete(ids, undoManager: undoManager) }
    }
}

// MARK: Toast

private struct ToastView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let toast = store.toast {
            HStack(spacing: 12) {
                Text(toast.message)
                    .lineLimit(1)
                if let undo = toast.undo {
                    Button(toast.actionTitle, action: undo)
                        .buttonStyle(.borderless)
                        .fontWeight(.semibold)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
        }
    }
}

// MARK: Startup error

private struct StartupErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Buoy couldn't open your tasks", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
                .textSelection(.enabled)
        } actions: {
            Button("Show Data Folder") {
                NSWorkspace.shared.activateFileViewerSelecting([Storage.defaultDirectory()])
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .frame(minWidth: 520, minHeight: 320)
    }
}

// MARK: Logo

/// The Buoy logo (mark + wordmark) at the foot of the sidebar, with a
/// separate "by Greg" credit just beneath it.
private struct LogoLockup: View {
    var body: some View {
        // The credit hangs off the end of the wordmark, like a signature.
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 8) {
                BuoyMark(size: 27)
                Text("Buoy")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
            }
            Text("by Greg")
                .font(.system(size: 11).italic())
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Buoy by Greg")
    }
}
