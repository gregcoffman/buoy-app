#if DEBUG
import AppKit
import BuoyCore
import SwiftUI

/// Development aid: `BUOY_SNAPSHOT_DIR=/some/dir swift run Buoy` walks through the main
/// screens and writes a PNG of each window to that folder, then quits.
/// The app renders its own windows, so no Screen Recording permission is needed.
@MainActor
enum DebugSnapshots {
    static func runIfRequested(store: AppStore, quickEntry: QuickEntryPanelController) {
        guard let dir = ProcessInfo.processInfo.environment["BUOY_SNAPSHOT_DIR"] else { return }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let first = store.todayItems.first?.task.id
        let steps: [(String, () -> Void)] = [
            ("0-bridge", { store.route = .bridge }),
            ("1-today", { store.route = .today }),
            ("2-upcoming", { store.route = .upcoming }),
            ("2b-later", { store.route = .later }),
            ("3-logbook", { store.route = .logbook }),
            ("4-tag", { store.route = .tag(store.sidebarTags.first ?? "") }),
            ("5-open-task", {
                store.route = .today
                let recurring = store.todayItems.first { $0.task.recurrence != nil }?.task.id
                if let id = recurring ?? first { store.expand(id) }
            }),
            ("5b-new-task", {
                store.collapse()
                store.startComposing()
            }),
            ("5c-light", {
                store.composing = false
                NSApp.appearance = NSAppearance(named: .aqua)
            }),
            ("5d-search", {
                NSApp.appearance = nil
                store.focusSearchRequest += 1
                store.searchText = "re"
            }),
            ("6-quick-entry", {
                store.searchText = ""
                store.searching = false
                quickEntry.show()
            }),
            ("6b-notes", {
                quickEntry.close()
                store.route = .notes
            }),
            ("6c-note-open", {
                if let id = store.activeNotes.first?.id { store.expand(id) }
            }),
            ("6d-quick-note", {
                store.collapse()
                quickEntry.show(prefilled: "> gate code is 4471, buzz #2")
            }),
            ("6e-projects", {
                quickEntry.close()
                store.route = .projects
            }),
            ("6f-project-open", {
                if let first = store.board(.inProgress).first ?? store.board(.shaping).first {
                    store.openProject(first.id)
                }
            }),
            ("6g-new-project", {
                store.projectDraft = nil
                store.startProject()
            }),
        ]

        // Exercise the main loop through the same store methods the UI calls.
        let undo = UndoManager()
        undo.groupsByEvent = false
        let scenario: [(String, () -> Void)] = ProcessInfo.processInfo.environment["BUOY_SNAPSHOT_SCENARIO"] == nil ? [] : [
            ("7-after-add", {
                quickEntry.close()
                store.add(QuickEntryParser().parse("Water plants every 3 days #home"), undoManager: undo)
                store.add(QuickEntryParser().parse("File taxes due apr 15 lead 3 weeks #finance"), undoManager: undo)
            }),
            ("8-complete-recurring", {
                if let mortgage = store.tasks.first(where: { $0.title == "Pay mortgage" && !$0.isCompleted }) {
                    store.complete([mortgage.id], undoManager: undo)
                }
                store.route = .upcoming
            }),
            ("9-snoozed", {
                if let bulbs = store.tasks.first(where: { $0.title == "Buy light bulbs" }) {
                    store.snooze([bulbs.id], .tomorrow, undoManager: undo)
                }
                store.route = .today
            }),
            ("10-undo-snooze", { if undo.canUndo { undo.undo() } }),
            ("11-new-note", {
                store.route = .notes
                store.startNote()
            }),
            ("12-blank-note-discarded", {
                store.collapse()
                store.addNote("Parking: level 3, row G", undoManager: undo)
            }),
            ("13-archived", {
                if let parking = store.activeNotes.first(where: { $0.text.hasPrefix("Parking") }) {
                    store.archiveNotes([parking.id], undoManager: undo)
                }
            }),
            ("14-undo-archive", { if undo.canUndo { undo.undo() } }),
            ("15-cmdN-on-notes", {
                store.route = .notes
            }),
            ("16-cmdN-pressed", { store.startComposing() }),
            ("17-task-to-note", {
                store.collapse()
                if let rent = store.tasks.first(where: { $0.title == "Pay rent" && !$0.isCompleted }) {
                    store.convertToNotes([rent.id], undoManager: undo)
                }
            }),
            ("18-note-to-task", {
                if let retro = store.activeNotes.first(where: { $0.text.hasPrefix("Retro ideas") }) {
                    store.convertToTasks([retro.id], undoManager: undo)
                }
                store.route = .today
            }),
            ("19-undo-note-to-task", { if undo.canUndo { undo.undo() } }),
            ("20-review-strip", {
                store.collapse()
                store.route = .today
            }),
            ("21-accepted", {
                if let first = store.pendingReview.first { store.accept([first.id], undoManager: undo) }
            }),
            ("22-dismissed", {
                if let next = store.pendingReview.first { store.dismiss([next.id], undoManager: undo) }
            }),
            ("23-undo-dismiss", { if undo.canUndo { undo.undo() } }),
        ]

        // BUOY_SNAPSHOT_CLICK: click sidebar rows like a person would, and log where the app ends up.
        if ProcessInfo.processInfo.environment["BUOY_SNAPSHOT_CLICK"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else {
                    NSApp.terminate(nil)
                    return
                }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(0.5))
                // Row centres, in points from the top-left of the window (Today, Upcoming, Notes, Upcoming, Notes).
                for (label, y) in [("upcoming", 97.0), ("today", 74.0), ("notes", 165.5), ("upcoming", 97.0), ("notes", 165.5), ("tag", 225.5), ("today", 74.0)] {
                    click(window, at: NSPoint(x: 100, y: window.frame.height - y))
                    try? await Task.sleep(for: .seconds(1.0))
                    print("CLICK \(label) -> route=\(String(describing: store.route))")
                    snapshot(window, to: out.appendingPathComponent("click-\(label)-\(Int(Date().timeIntervalSince1970 * 10) % 1000).png"))
                }
                NSApp.terminate(nil)
            }
            return
        }

        // BUOY_SNAPSHOT_HITTEST: what a click near the top of each screen lands on (window drag area or not).
        if ProcessInfo.processInfo.environment["BUOY_SNAPSHOT_HITTEST"] != nil {
            setvbuf(stdout, nil, _IONBF, 0)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
                      let frameView = window.contentView?.superview else { NSApp.terminate(nil); return }
                for route in [SidebarRoute.bridge, .today, .later, .notes, .projects] {
                    store.route = route
                    try? await Task.sleep(for: .seconds(0.8))
                    // Points from the window's top-left: the title strip, the big title, a list row; plus the sidebar.
                    let results = [("strip", 400.0, 10.0), ("strip", 700.0, 22.0), ("title", 330.0, 48.0),
                                   ("subtitle", 600.0, 74.0), ("row", 400.0, 135.0), ("sidebar", 100.0, 10.0)].map { name, x, y in
                        let point = NSPoint(x: x, y: window.frame.height - y)
                        var view = frameView.hitTest(point)
                        var drags = false
                        while let v = view {
                            if v is WindowDragArea.DragView { drags = true; break }
                            view = v.superview
                        }
                        let hit = frameView.hitTest(point).map { String(describing: type(of: $0)) } ?? "nothing"
                        return "\(name)@\(Int(y))=\(drags ? "DRAG" : "content(\(hit.prefix(28)))")"
                    }
                    print("HIT \(route.title): \(results.joined(separator: ", "))")
                }
                NSApp.terminate(nil)
            }
            return
        }

        // BUOY_SNAPSHOT_LINKS=<file>: send each line of the file (a buoy:// link, with KEY standing
        // in for the real key) through the agent link handler, printing Today and the board after each.
        if let path = ProcessInfo.processInfo.environment["BUOY_SNAPSHOT_LINKS"] {
            setvbuf(stdout, nil, _IONBF, 0)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
                    .split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }
                for line in lines {
                    print("LINK \(line)")
                    // "ACCEPT <title>" / "DISMISS <title>" click a suggestion's buttons instead, and
                    // "MOVE <column>|<title>" drags a card to the top of a column.
                    if line.hasPrefix("MOVE ") {
                        let parts = line.dropFirst(5).split(separator: "|", maxSplits: 1).map(String.init)
                        if parts.count == 2, let card = store.tasks.first(where: { $0.title == parts[1] && !$0.isCompleted }) {
                            store.moveProject(card.id, to: BoardColumn(rawValue: parts[0]), at: 0, undoManager: nil)
                        }
                    } else if line.hasPrefix("ACCEPT ") || line.hasPrefix("DISMISS ") {
                        let title = line.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
                        let ids = store.suggestions.filter { $0.title == title }.map(\.id)
                        if line.hasPrefix("ACCEPT ") { store.acceptSuggestions(ids, undoManager: nil) } else { store.dismissSuggestions(ids, undoManager: nil) }
                    } else if let url = URL(string: line.replacingOccurrences(of: "KEY", with: store.agentKey)) {
                        AgentLinkHandler.handle(url, store: store)
                    }
                    print("  Today: \(store.todayItems.map(\.task.title).joined(separator: " | "))")
                    for c in BoardColumn.allCases {
                        print("  \(c.title): \(Board.column(c, of: store.tasks).map { "\($0.title)\($0.effortHours.map { " ~\(Effort.format($0))" } ?? "")\($0.status.isEmpty ? "" : " [\($0.status)]")" }.joined(separator: " | "))")
                    }
                    print("  Done: \(store.doneProjects.map(\.title).joined(separator: " | ")) · toast: \(store.toast?.message ?? "-")")
                    print("  Suggestions: \(store.suggestions.map { "\($0.title) → \($0.openSuggestion!.move.summary)" }.joined(separator: " | "))")
                }
                store.route = .today
                try? await Task.sleep(for: .seconds(1))
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) {
                    snapshot(window, to: out.appendingPathComponent("links-end.png"))
                }
                NSApp.terminate(nil)
            }
            return
        }

        // BUOY_SNAPSHOT_BOARD: run the board's move / convert / delete actions (what drag and drop
        // and the menus call) and print the board after each, then snapshot it.
        if ProcessInfo.processInfo.environment["BUOY_SNAPSHOT_BOARD"] != nil {
            setvbuf(stdout, nil, _IONBF, 0)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                let undo = UndoManager()
                undo.groupsByEvent = false
                @MainActor func titles(_ c: BoardColumn?) -> String {
                    (c.map { store.board($0) } ?? store.doneProjects).map(\.title).joined(separator: ", ")
                }
                @MainActor func show(_ step: String) {
                    print("BOARD \(step)")
                    for c in BoardColumn.allCases { print("BOARD   \(c.title): \(titles(c))") }
                    print("BOARD   Done: \(titles(nil))")
                }
                @MainActor func id(_ title: String) -> UUID? { store.tasks.first { $0.title == title }?.id }
                @MainActor func step(_ name: String, _ action: () -> Void) {
                    undo.beginUndoGrouping(); action(); undo.endUndoGrouping()
                    show(name)
                }
                // Later.
                if let ink = id("Order printer ink") {
                    undo.beginUndoGrouping(); store.moveToLater([ink], undoManager: undo); undo.endUndoGrouping()
                    print("BOARD later: ink in Later=\(store.laterItems.contains { $0.id == ink }) in Today=\(store.todayItems.contains { $0.task.id == ink })")
                    undo.beginUndoGrouping(); store.surface([ink], undoManager: undo); undo.endUndoGrouping()
                    print("BOARD later: after Move to Today, in Later=\(store.laterItems.contains { $0.id == ink }) in Today=\(store.todayItems.contains { $0.task.id == ink }) flag=\(store.task(ink)?.later ?? true)")
                }
                if let hammock = store.add(QuickEntryParser().parse("Buy a hammock later")) {
                    print("BOARD later: typed “Buy a hammock later” → title “\(hammock.title)”, in Later=\(store.laterItems.contains { $0.id == hammock.id }), says “\(store.placementSummary(for: hammock))”")
                }
                store.route = .projects
                show("start")
                step("last Shaping to the top") { if let p = store.board(.shaping).last { store.moveProject(p.id, to: .shaping, at: 0, undoManager: undo) } }
                step("Kitchen remodel to the end of In progress") {
                    if let k = id("Kitchen remodel") { store.moveProject(k, to: .inProgress, at: store.board(.inProgress).count, undoManager: undo) }
                }
                step("Redo the garden beds to Ready, top") { if let g = id("Redo the garden beds") { store.moveProject(g, to: .ready, at: 0, undoManager: undo) } }
                step("Draft the Q4 roadmap to Done") { if let r = id("Draft the Q4 roadmap") { store.moveProject(r, to: nil, at: 0, undoManager: undo) } }
                step("Launch the family website out of Done to In progress, top") {
                    if let w = id("Launch the family website") { store.moveProject(w, to: .inProgress, at: 0, undoManager: undo) }
                }
                step("convert task Order printer ink to a project; project Find a garage organizer to a task") {
                    if let ink = id("Order printer ink") { store.convertKind([ink], to: .project, undoManager: undo) }
                    if let garage = id("Find a garage organizer") { store.convertKind([garage], to: .task, undoManager: undo) }
                }
                print("BOARD   garage is in Today: \(store.todayItems.contains { $0.task.title == "Find a garage organizer" })")
                step("an agent deletes Summarize Swift concurrency changes") { if let l = id("Summarize Swift concurrency changes") { store.agentDelete(l) } }
                print("BOARD   deleted list: \(store.deletedTasks.map(\.title))")
                if let l = store.deletedTasks.first?.id { store.restoreDeleted(l) }
                show("restored")
                step("Digitize old photos to Ready") { if let p = id("Digitize old photos") { store.moveProject(p, to: .ready, at: 0, undoManager: undo) } }
                if undo.canUndo { undo.undo() }
                show("after undo (Digitize old photos should be back in Shaping)")
                try? await Task.sleep(for: .seconds(1))
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) {
                    snapshot(window, to: out.appendingPathComponent("board-after.png"))
                }
                NSApp.terminate(nil)
            }
            return
        }

        // BUOY_SNAPSHOT_ANIM: check off the first task in Today and add a task from ⌃Space,
        // capturing frames (and the panel's opacity) as the animations run.
        if ProcessInfo.processInfo.environment["BUOY_SNAPSHOT_ANIM"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else {
                    NSApp.terminate(nil)
                    return
                }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(0.5))
                let first = store.todayItems.first?.task.title ?? "?"
                // The first row's checkbox, in points from the window's top-left.
                let checkY = Double(ProcessInfo.processInfo.environment["BUOY_SNAPSHOT_CHECK_Y"] ?? "") ?? 130.5
                click(window, at: NSPoint(x: 224.5, y: window.frame.height - checkY))
                let start = Date()
                for at in [0.25, 0.7, 0.8, 1.4] {
                    try? await Task.sleep(for: .seconds(at - Date().timeIntervalSince(start)))
                    let done = store.tasks.first { $0.title == first }?.isCompleted ?? false
                    print("ANIM check t=\(at) completed=\(done)")
                    // A real on-screen capture: layer snapshots don't show opacity.
                    screenCapture(window, to: out.appendingPathComponent("anim-check-\(at).png"))
                }

                quickEntry.show(prefilled: "Buy stamps")
                try? await Task.sleep(for: .seconds(0.4))
                guard let panel = NSApp.windows.first(where: { $0 is QuickEntryPanel }) else { return }
                if let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: panel.windowNumber, context: nil, characters: "\r",
                                                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                    panel.sendEvent(enter)
                }
                let pressed = Date()
                for at in [0.1, 0.3, 0.5, 0.7, 0.9] {
                    try? await Task.sleep(for: .seconds(at - Date().timeIntervalSince(pressed)))
                    print("ANIM panel t=\(at) visible=\(panel.isVisible) alpha=\(String(format: "%.2f", panel.alphaValue))")
                    if at <= 0.5 { screenCapture(panel, to: out.appendingPathComponent("anim-panel-\(at).png")) }
                    // The new task fading into Today behind the panel.
                    screenCapture(window, to: out.appendingPathComponent("anim-added-\(at).png"))
                }
                let order = store.todayItems.map(\.task.title)
                print("ANIM added=\(order.contains("Buy stamps")) position=\(order.firstIndex(of: "Buy stamps") ?? -1) of \(order.count): \(order)")
                NSApp.terminate(nil)
            }
            return
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            for (name, action) in steps + scenario {
                if name.contains("-undo-") {
                    action()
                } else {
                    undo.beginUndoGrouping()
                    action()
                    undo.endUndoGrouping()
                }
                try? await Task.sleep(for: .seconds(1.2))
                for (i, window) in NSApp.windows.enumerated() where window.isVisible && window.frame.width > 200 {
                    snapshot(window, to: out.appendingPathComponent("\(name)-\(i).png"))
                }
            }
            NSApp.terminate(nil)
        }
    }

    /// What's actually on screen for `window` (including transparency), via screencapture.
    private static func screenCapture(_ window: NSWindow, to url: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try? task.run()
    }

    /// Clicks at `point` (window coordinates) the way the mouse would.
    private static func click(_ window: NSWindow, at point: NSPoint) {
        let number = window.windowNumber
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: number, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        // Controls track the mouse until they see the mouse-up, so queue that first.
        if let up = event(.leftMouseUp), let down = event(.leftMouseDown) {
            NSApp.postEvent(up, atStart: false)
            window.sendEvent(down)
        }
        // Nudge the event loop so the click's effects are applied before anyone looks.
        if let nudge = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(nudge, atStart: false)
        }
    }

    private static func snapshot(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        // Render the layer tree: unlike cacheDisplay, it reflects views that are
        // first responder (e.g. the notes editor) instead of a stale drawing.
        if let layer = view.layer, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            layer.render(in: ctx.cgContext)
        } else {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
