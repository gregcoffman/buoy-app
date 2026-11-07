import BuoyCore
import SwiftUI

/// The menu bar popover: quick capture plus a glance at Today.
struct MenuBarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var entry = QuickEntryModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            QuickEntryField(model: entry, prompt: "Add a task", autofocus: true)
                .padding(12)
            Divider()
            let items = store.todayItems
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "water.waves").font(.title2).foregroundStyle(.tertiary)
                    Text("Nothing needs your attention").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                HStack {
                    Text("Today").font(.headline)
                    Spacer()
                    Text("\(items.count)").foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            MenuBarRow(task: item.task)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("Open Buoy") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Spacer()
                SettingsLink { Image(systemName: "gear") }
                    .help("Settings")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit Buoy")
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
        .frame(width: 340)
    }
}

private struct MenuBarRow: View {
    @Environment(AppStore.self) private var store
    let task: BuoyTask
    @State private var hovering = false
    @State private var checking = false
    @State private var fading = false
    @State private var checkToken = 0

    var body: some View {
        HStack(spacing: 8) {
            Button {
                checkToken += 1
                let token = checkToken
                guard !checking else {
                    withAnimation(.easeOut(duration: 0.15)) { checking = false; fading = false }
                    return
                }
                withAnimation(.easeOut(duration: 0.15)) { checking = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    guard checkToken == token else { return }
                    withAnimation(.easeIn(duration: 0.3)) { fading = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        guard checkToken == token else { return }
                        withAnimation(.easeOut(duration: 0.25)) { store.complete([task.id], undoManager: nil) }
                        checking = false
                        fading = false
                    }
                }
            } label: {
                Checkbox(checked: checking)
            }
            .buttonStyle(.plain)
            .help("Complete")
            Text(task.title)
                .strikethrough(checking, color: .secondary)
                .foregroundStyle(checking ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let badge = DueBadge(task: task, today: store.today) {
                Text(badge.text).font(.caption).foregroundStyle(checking ? Color.secondary : badge.color)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .opacity(fading ? 0 : (checking ? 0.6 : 1))
        .onHover { hovering = $0 }
    }
}
