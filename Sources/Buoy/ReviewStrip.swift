import BuoyCore
import SwiftUI

/// Tasks an agent added, waiting at the top of Today for you to accept or dismiss.
/// Until accepted they're in no list, count or notification.
struct ReviewStrip: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let pending = store.pendingReview
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.agent)
                Text("From your agent")
                    .font(.callout.weight(.semibold))
                Text("\(pending.count) to review")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if pending.count > 1 {
                    Button("Accept All") { store.accept(pending.map(\.id), undoManager: undoManager) }
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
            }
            .padding(.bottom, 2)
            ForEach(pending) { task in
                if store.expandedTaskID == task.id {
                    TaskCard(taskID: task.id)
                } else {
                    ReviewRow(task: task)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.agent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.agent.opacity(0.25)))
        .padding(.bottom, 8)
    }
}

private struct ReviewRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let task: BuoyTask
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(task.title).lineLimit(1)
                    if !task.notes.isEmpty {
                        Image(systemName: "doc.text").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                store.dismiss([task.id], undoManager: undoManager)
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
            .help("Don't add it")
            Button {
                store.accept([task.id], undoManager: undoManager)
            } label: {
                Label("Accept", systemImage: "checkmark")
            }
            .help("Add it to your lists")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Open it to edit before accepting.
        .onTapGesture(count: 2) { store.expand(task.id) }
        .help("Double-click to edit before accepting")
    }

    /// "Due Oct 20 · rises Oct 17 · Errands, Family", or where it would go.
    private var summary: String {
        let today = store.today
        var parts: [String] = []
        if let show = task.showOn { parts.append("Shows \(Formatters.day(show, today: today))") }
        if let due = task.dueOn { parts.append("Due \(Formatters.day(due, today: today))") }
        if let lead = task.leadStart(), task.leadDays > 0 {
            parts.append("rises \(Formatters.day(lead, today: today).lowercasedIfRelative)")
        }
        if let rule = task.recurrence { parts.append(rule.summary) }
        if !task.tags.isEmpty { parts.append(task.tags.joined(separator: ", ")) }
        if task.isProject {
            return (["Project · would go to the board"] + parts).joined(separator: " · ")
        }
        return parts.isEmpty ? "No dates · would go to Today" : parts.joined(separator: " · ")
    }
}
