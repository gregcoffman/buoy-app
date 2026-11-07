import BuoyCore
import SwiftUI

/// Your agent's suggestions for when to do things: park a task in Later, or give it a
/// Show On or due date. They wait at the top of Today; nothing moves until you accept.
struct SuggestionStrip: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let suggested = store.suggestions
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.agent)
                Text("Your agent suggests")
                    .font(.callout.weight(.semibold))
                Text("\(suggested.count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if suggested.count > 1 {
                    Button("Accept All") { store.acceptSuggestions(suggested.map(\.id), undoManager: undoManager) }
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
            }
            .padding(.bottom, 2)
            ForEach(suggested) { task in
                SuggestionRow(task: task)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.agent.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.agent.opacity(0.18)))
        .padding(.bottom, 8)
    }
}

private struct SuggestionRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.undoManager) private var undoManager
    let task: BuoyTask
    @State private var hovering = false

    var body: some View {
        if let suggestion = task.openSuggestion {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(task.title).lineLimit(1)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                        move(suggestion.move)
                    }
                    Text(suggestion.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(suggestion.reason)
                }
                Spacer(minLength: 8)
                Button {
                    store.dismissSuggestions([task.id], undoManager: undoManager)
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                }
                .help("Leave it where it is")
                Button {
                    store.acceptSuggestions([task.id], undoManager: undoManager)
                } label: {
                    Label("Accept", systemImage: "checkmark")
                }
                .help("Do it")
            }
            .buttonStyle(.borderless)
            .labelStyle(.titleAndIcon)
            .font(.callout)
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
    }

    /// "Later", "Show on Tue", "Due Nov 30", in the colour of that kind of date.
    private func move(_ move: SuggestedMove) -> some View {
        let today = store.today
        let (icon, text, tint): (String, String, Color) = switch move {
        case .later: ("tray.fill", "Later", Theme.later)
        case .showOn(let day): ("sunrise.fill", "Show on \(Formatters.shortDay(day, today: today))", Theme.showOn)
        case .dueOn(let day): ("flag.fill", "Due \(Formatters.shortDay(day, today: today))", Theme.due)
        }
        return Label(text, systemImage: icon)
            .font(.callout.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}
