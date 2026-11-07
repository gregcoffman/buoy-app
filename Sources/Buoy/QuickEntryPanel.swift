import AppKit
import BuoyCore
import SwiftUI

/// A Spotlight-style floating panel for capturing a task from anywhere.
@MainActor
final class QuickEntryPanelController: NSObject, NSWindowDelegate {
    private let store: AppStore
    private var panel: QuickEntryPanel?
    private let model = QuickEntryModel()
    /// Bumped on every show, so a pending "close after confirming" from a previous capture is ignored.
    private var generation = 0

    init(store: AppStore) {
        self.store = store
    }

    func toggle() {
        if let panel, panel.isVisible { close() } else { show() }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Every capture starts fresh, including after Escape.
        generation += 1
        model.reset()
        // Undo any fade-out still running from the previous capture.
        panel.alphaValue = 1
        position(panel)
        // A non-activating panel takes keystrokes without pulling Buoy's other windows forward.
        panel.makeKeyAndOrderFront(nil)
        focusField()
    }

    #if DEBUG
    /// For snapshots: opens the panel with text already typed.
    func show(prefilled text: String) {
        show()
        model.text = text
    }
    #endif

    func close() {
        panel?.orderOut(nil)
        panel?.alphaValue = 1
        model.reset()
    }

    /// Focus only works once the panel is key, which can lag a moment behind
    /// makeKeyAndOrderFront, so ask again until it takes.
    private func focusField() {
        for delay in [0.0, 0.05, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                if !panel.isKeyWindow { panel.makeKey() }
                self.model.focusRequest += 1
            }
        }
    }

    /// Shows where the task went ("Added to Upcoming · rises Thu"), then fades the panel away.
    private func confirmAndClose(_ message: String) {
        model.confirmation = message
        let current = generation
        // Hold the confirmation briefly, then fade over 0.3s. Stepped by hand: a non-activating
        // panel's animator() alpha change completes instantly.
        let hold = 0.35, fade = 0.3, steps = 15
        for step in 1...steps {
            let progress = Double(step) / Double(steps)
            DispatchQueue.main.asyncAfter(deadline: .now() + hold + fade * progress) { [weak self] in
                // ⌃Space pressed again mid-fade: that capture owns the panel now.
                guard let self, let panel = self.panel, self.generation == current else { return }
                panel.alphaValue = CGFloat(1 - progress * progress)
                if step == steps { self.close() }
            }
        }
    }

    private var content: some View {
        QuickEntryPanelView(model: model,
                            onAdded: { [weak self] message in self?.confirmAndClose(message) },
                            onDone: { [weak self] in self?.close() })
            .environment(store)
    }

    private func makePanel() -> QuickEntryPanel {
        let panel = QuickEntryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 120),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        panel.contentView = NSHostingView(rootView: content)
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.72 - size.height / 2))
    }

    func windowDidResignKey(_ notification: Notification) {
        // Stay open while one of our own popovers (the date chips) has focus.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            if let key = NSApp.keyWindow, key === panel || key.parent === panel { return }
            self.close()
        }
    }
}

final class QuickEntryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { orderOut(nil) }
    }
}

private struct QuickEntryPanelView: View {
    @Environment(AppStore.self) private var store
    @Bindable var model: QuickEntryModel
    var onAdded: (String) -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QuickEntryField(
                model: model,
                prompt: "What needs your attention?",
                large: true,
                autofocus: true,
                onSubmit: { task in onAdded(store.placementSummary(for: task)) },
                onNoteSaved: { _ in onAdded("Saved to Notes") },
                onCancel: onDone,
                resetsOnSubmit: false
            )
            Group {
                if let confirmation = model.confirmation {
                    Label(confirmation, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.logbook)
                        .transition(.opacity)
                } else {
                    Text(model.isNote
                         ? "↩ saves it to Notes, exactly as typed"
                         : "Try: “Renew passport due dec 1 lead 30d #finance” · Start with > for a note")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .padding(.leading, 32)
            .animation(.easeOut(duration: 0.15), value: model.confirmation)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
    }
}
