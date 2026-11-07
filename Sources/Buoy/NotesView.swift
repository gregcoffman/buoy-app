import BuoyCore
import SwiftUI

/// Notes: plain-text thoughts waiting to be copied somewhere else. Newest first;
/// used notes go to Archived, where they stay until deleted.
struct NotesScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    @AppStorage("notesArchiveOpen") private var archiveOpen = false

    var body: some View {
        @Bindable var store = store
        let active = store.activeNotes
        let archived = store.archivedNotes
        List(selection: $store.selection) {
            header
                .selectionDisabled()
                .listRowSeparator(.hidden)

            if active.isEmpty {
                emptyState
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
            }

            ForEach(active) { note in
                row(note)
            }

            if !archived.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { archiveOpen.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(archiveOpen || !store.searchText.isEmpty ? 90 : 0))
                        Image(systemName: "archivebox").font(.caption)
                        Text("Archived · \(archived.count)")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .selectionDisabled()
                .listRowSeparator(.hidden)
                .padding(.top, 18)

                // Searching looks through the archive too.
                if archiveOpen || !store.searchText.isEmpty {
                    ForEach(archived) { note in
                        row(note)
                    }
                }
            }
        }
        .listStyle(.inset)
        // Use the empty band under the (invisible) toolbar instead of starting below it.
        .ignoresSafeArea(.container, edges: .top)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
        .contextMenu(forSelectionType: UUID.self) { ids in
            NoteActions(ids: Array(ids))
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { store.expand(id) }
        }
        .onCopyCommand {
            // ⌘C with notes selected (typing inside a note copies text as usual).
            let ids = Array(store.selection)
            DispatchQueue.main.async { store.copyNotes(ids, undoManager: undoManager) }
            return []
        }
        .onDeleteCommand {
            store.deleteNotes(Array(store.selection), undoManager: undoManager)
        }
        .onChange(of: store.selection) {
            if let open = store.expandedTaskID, !store.selection.isEmpty, !store.selection.contains(open) {
                store.collapse(reselect: false)
            }
        }
        // Leaving Notes closes the open note (and drops it if nothing was written).
        .onDisappear { store.collapse(reselect: false) }
    }

    private func row(_ note: Note) -> some View {
        NoteRow(note: note)
            .tag(note.id)
            .selectionDisabled(store.expandedTaskID == note.id)
            .listRowSeparator(.hidden)
            .listRowBackground(store.expandedTaskID == note.id ? Color.clear : nil)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                SidebarRoute.notes.icon(size: 26)
                Text("Notes")
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
        let count = store.activeNoteCount
        return count == 0 ? "Plain text, ready to paste anywhere" : "\(count) waiting to be copied"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(store.searchText.isEmpty ? "No notes waiting" : "No matches")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            if store.searchText.isEmpty {
                Text("Start a line with > in ⌃Space, or press ⌥⌘N. Notes stay plain text, exactly as you typed them.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: 340)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

/// A note in the list. When opened it becomes an editable card in place.
private struct NoteRow: View {
    @Environment(AppStore.self) private var store
    let note: Note

    var body: some View {
        if store.expandedTaskID == note.id {
            NoteCard(noteID: note.id)
        } else {
            CollapsedNoteRow(note: note)
                .modifier(FadeIn(active: store.recentlyAdded.contains(note.id)))
        }
    }
}

private struct CollapsedNoteRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let note: Note
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: note.isArchived ? "archivebox" : "text.alignleft")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(note.isArchived ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.notes))
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(note.firstLine.isEmpty ? "Empty note" : note.firstLine)
                        .foregroundStyle(note.isArchived || note.firstLine.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    if note.source == .agent { AgentMark() }
                }
                HStack(spacing: 6) {
                    Text(when)
                    if !note.remainder.isEmpty {
                        Text(note.remainder).foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                store.copyNotes([note.id], undoManager: undoManager)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)
            .help("Copy as plain text")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var when: String {
        let date = note.archivedAt ?? note.createdAt
        let day = Formatters.day(LocalDate(date), today: store.today)
        return note.isArchived ? "Archived \(day.lowercasedIfRelative) \(Formatters.time(date))" : "\(day) \(Formatters.time(date))"
    }
}

/// A note opened in place: just its text, saved as you type.
private struct NoteCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let noteID: UUID
    @State private var focus = 0

    var body: some View {
        let note = store.note(noteID) ?? Note(text: "")
        CardSurface(onClickOutside: { store.collapse(reselect: false) }) {
            NotesEditor(
                text: Binding(get: { store.note(noteID)?.text ?? "" }, set: { store.updateNote(noteID, text: $0) }),
                placeholder: "Write a note…",
                prominent: true,
                focusRequest: focus,
                onEscape: { store.collapse() }
            )
            .frame(minHeight: 40, alignment: .top)
            HStack(spacing: 14) {
                Text("Written \(Formatters.day(LocalDate(note.createdAt), today: store.today).lowercasedIfRelative) at \(Formatters.time(note.createdAt))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    store.copyNotes([noteID], undoManager: undoManager)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(note.isBlank)
                .help("Copy as plain text")
                if note.isArchived {
                    Button {
                        store.unarchiveNotes([noteID], undoManager: undoManager)
                    } label: {
                        Label("Move Back", systemImage: "arrow.uturn.backward")
                    }
                    .help("Put it back in Notes")
                } else {
                    Button {
                        store.archiveNotes([noteID], undoManager: undoManager)
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .disabled(note.isBlank)
                    .help("Done with it; keep it in Archived")
                }
                Button {
                    store.convertToTasks([noteID], undoManager: undoManager)
                } label: {
                    Label("Make Task", systemImage: "checkmark.square")
                }
                .disabled(note.isBlank)
                .help("Convert to a task in Today")
                Button {
                    store.deleteNotes([noteID], undoManager: undoManager)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.top, 6)
        }
        .onExitCommand { store.collapse() }
        .onAppear {
            for delay in [0.05, 0.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { focus += 1 }
            }
        }
    }
}

/// Actions for one or more notes, used by the context menu.
struct NoteActions: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let ids: [UUID]

    var body: some View {
        let notes = ids.compactMap(store.note)
        if ids.count == 1, let id = ids.first {
            Button("Open") { store.expand(id) }
            Divider()
        }
        Button(notes.count > 1 ? "Copy \(notes.count) Notes" : "Copy") { store.copyNotes(ids, undoManager: undoManager) }
        if notes.contains(where: { !$0.isArchived }) {
            Button("Archive") { store.archiveNotes(ids, undoManager: undoManager) }
        }
        if notes.contains(where: \.isArchived) {
            Button("Move Back to Notes") { store.unarchiveNotes(ids, undoManager: undoManager) }
        }
        Divider()
        Button(notes.count > 1 ? "Convert \(notes.count) Notes to Tasks" : "Convert to Task") {
            store.convertToTasks(ids, undoManager: undoManager)
        }
        .disabled(notes.allSatisfy(\.isBlank))
        Divider()
        Button("Delete", role: .destructive) { store.deleteNotes(ids, undoManager: undoManager) }
    }
}
