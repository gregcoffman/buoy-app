#if DEBUG
import AppKit
import BuoyCore
import SwiftUI

/// Development aid: `BUOY_SNAPSHOT_DIR=<dir> BUOY_SNAPSHOT_TYPING=1 BUOY_DATA_DIR=<scratch> swift run Buoy`
/// (or `BUOY_SNAPSHOT_TYPING=1100x820` for a window size). Check the exit status too: a crash
/// after the last line of output is still a failure.
/// opens a Delegated card and types into "Why / context" and "Delivery expectations" with real key
/// events: long paragraphs, quotes and dashes, line breaks, a link, arrow-key edits in the middle,
/// bursts with no pause, and an accent composed the way input methods do it. After every key it
/// checks the text, the cursor, the saved draft, the wrap width and the styling, prints what it
/// finds, saves window pictures, then cancels the edit (nothing is saved) and quits.
/// Use a throwaway BUOY_DATA_DIR.
@MainActor
enum DebugTypingCheck {
    static func run(store: AppStore, out: URL) {
        setvbuf(stdout, nil, _IONBF, 0)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
                  let card = store.board(.shaping).first ?? store.board(.inProgress).first else {
                print("TYPE no window or no card"); NSApp.terminate(nil); return
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            // BUOY_SNAPSHOT_TYPING=WxH sets the window size; anything else keeps the default.
            let size = (ProcessInfo.processInfo.environment["BUOY_SNAPSHOT_TYPING"] ?? "").split(separator: "x").compactMap { Double($0) }
            if size.count == 2 { window.setContentSize(NSSize(width: size[0], height: size[1])) }
            store.route = .projects
            store.openProject(card.id)
            try? await Task.sleep(for: .seconds(1))
            let editors = textViews(in: window.contentView).sorted { a, b in
                a.convert(NSPoint.zero, to: nil).y > b.convert(NSPoint.zero, to: nil).y
            }
            print("TYPE card=\(card.title) editors=\(editors.count) window=\(Int(window.frame.width))")
            guard editors.count >= 2 else { NSApp.terminate(nil); return }
            snapshot(window, out.appendingPathComponent("typing-0-open.png"))

            let fields: [(String, WritableKeyPath<BuoyTask, String>)] = [("why", \.notes), ("expect", \.expectations)]
            var problems = 0
            for (index, (name, key)) in fields.enumerated() {
                let view = editors[index]
                let checker = Checker(name: name, view: view, store: store, key: key, window: window)
                await checker.focus()
                problems += await checker.script()
                snapshot(window, out.appendingPathComponent("typing-\(index + 1)-\(name).png"))
            }
            // Scroll back up so both boxes are in one picture.
            if let scroll = editors[0].enclosingScrollView { scroll.contentView.scroll(to: .zero) }
            try? await Task.sleep(for: .seconds(0.5))
            snapshot(window, out.appendingPathComponent("typing-3-both.png"))
            print("TYPE DONE problems=\(problems)")
            store.projectDraft = nil // Cancel: nothing is written.
            try? await Task.sleep(for: .seconds(0.3))
            NSApp.terminate(nil)
        }
    }

    @MainActor
    final class Checker {
        let name: String, view: NSTextView, store: AppStore, key: WritableKeyPath<BuoyTask, String>, window: NSWindow
        var expected: String
        var caret: Int
        var problems = 0
        var reported = Set<String>()

        init(name: String, view: NSTextView, store: AppStore, key: WritableKeyPath<BuoyTask, String>, window: NSWindow) {
            self.name = name; self.view = view; self.store = store; self.key = key; self.window = window
            expected = view.string
            caret = (view.string as NSString).length
        }

        func focus() async {
            // Click in the box like a person, then make sure the cursor is at the end.
            let p = view.convert(NSPoint(x: 20, y: 5), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(e)
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
            if window.firstResponder !== view { window.makeFirstResponder(view) }
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            caret = view.selectedRange().location
            expected = view.string
            print("TYPE \(name) focused=\(window.firstResponder === view) start=\(expected.count) chars")
        }

        func script() async -> Int {
            let para = "We're redoing the kitchen \"before the holidays\" -- budget is about 20k, and it's firm. "
            // 1. A long paragraph, one key at a time with the app updating in between.
            await type(String(repeating: para, count: 3), burst: 1)
            check("long paragraph")
            // 2. Line breaks and a link.
            await type("\n\nSee https://example.com/brief?id=42 for photos.\nCall Sam first.", burst: 1)
            check("line breaks + link")
            // 3. Edit in the middle: arrow left 30, type, keep going.
            await arrows(left: 30)
            await type(" [mid-edit]", burst: 1)
            check("edit in the middle")
            // 4. Fast typing: 25 keys at a time with no pause, so updates land between bursts.
            await type(String(repeating: "fast typing keeps every letter ", count: 4), burst: 25)
            check("fast bursts")
            // 5. An accent composed like an input method (mark, app update, then commit).
            view.setMarkedText("e", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            edit { $0.title += "" } // something else on the screen changes mid-composition
            try? await Task.sleep(for: .milliseconds(60))
            view.insertText("é", replacementRange: view.markedRange())
            apply("é")
            try? await Task.sleep(for: .milliseconds(60))
            check("composed accent")
            // 6. Another field changing while you type here.
            for c in " café notes" {
                await type(String(c), burst: 1)
                edit { $0.title = $0.title }
            }
            check("other field updating")
            try? await Task.sleep(for: .milliseconds(300))
            check("settled")
            // 7. Much longer text: the box must grow, not cut lines off.
            await type(String(repeating: "\nAnother long line of notes so the box has to grow taller than it started.", count: 12), burst: 25)
            try? await Task.sleep(for: .milliseconds(300))
            check("long text grows")
            print("TYPE \(name) final text: \(view.string.debugDescription.prefix(160))…")
            return problems
        }

        // MARK: Keys

        func type(_ text: String, burst: Int) async {
            var n = 0
            for ch in text {
                let s = ch == "\n" ? "\r" : String(ch)
                send(s, code: ch == "\n" ? 36 : 0)
                apply(String(ch))
                n += 1
                if n % burst == 0 {
                    try? await Task.sleep(for: .milliseconds(8))
                    watch("typing")
                }
            }
            try? await Task.sleep(for: .milliseconds(30))
        }

        func arrows(left: Int) async {
            let s = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
            for _ in 0..<left {
                send(s, code: 123, flags: [.numericPad, .function])
                caret = max(0, caret - 1)
                try? await Task.sleep(for: .milliseconds(8))
                watch("arrow")
            }
        }

        func send(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    window.sendEvent(e)
                }
            }
        }

        func apply(_ s: String) {
            let ns = expected as NSString
            expected = ns.replacingCharacters(in: NSRange(location: caret, length: 0), with: s)
            caret += (s as NSString).length
        }

        func edit(_ change: (inout BuoyTask) -> Void) {
            guard var d = store.projectDraft else { return }
            change(&d.task)
            store.projectDraft = d
        }

        // MARK: Checks

        /// Cheap check after each key: text and cursor only, each kind reported once.
        func watch(_ when: String) {
            if view.string != expected { flag("text", "\(when): text differs from what was typed (\(diff(expected, view.string)))") }
            if view.selectedRange().location != caret {
                flag("caret", "\(when): cursor at \(view.selectedRange().location), expected \(caret)")
                caret = view.selectedRange().location // follow it so one jump isn't reported forever
            }
        }

        func check(_ step: String) {
            watch(step)
            let saved = store.projectDraft?.task[keyPath: key] ?? "<no draft>"
            if saved != view.string { flag("draft-\(step)", "\(step): draft holds different text than the box (\(diff(view.string, saved)))") }
            let wrap = view.textContainer?.containerSize.width ?? 0
            if abs(wrap - view.bounds.width) > 1 {
                flag("wrap-\(step)", "\(step): text wraps at \(Int(wrap))pt but the box is \(Int(view.bounds.width))pt wide")
            }
            if let lm = view.layoutManager, let tc = view.textContainer {
                let used = lm.usedRect(for: tc).height
                if used > view.bounds.height + 1 { flag("clip-\(step)", "\(step): text is \(Int(used))pt tall but the box shows \(Int(view.bounds.height))pt") }
            }
            if let storage = view.textStorage, storage.length > 0 {
                var fonts = Set<String>(), colors = Set<String>(), links = 0
                storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, _, _ in
                    if let f = attrs[.font] as? NSFont { fonts.insert("\(f.fontName) \(f.pointSize)") } else { fonts.insert("none") }
                    colors.insert((attrs[.foregroundColor] as? NSColor)?.description.prefix(40).description ?? "none")
                    if attrs[.link] != nil { links += 1 }
                }
                if fonts.count > 1 || colors.count > 1 { flag("style-\(step)", "\(step): mixed styling, fonts=\(fonts) colors=\(colors.count)") }
                if view.string.contains("https://") && links == 0 { flag("link-\(step)", "\(step): link is not clickable") }
            }
            if view.string.contains(where: { "“”‘’—".contains($0) }) {
                flag("punct", "\(step): typed punctuation was changed (curly quotes / em dash)")
            }
            print("TYPE \(name) \(step): chars=\(view.string.count) caret=\(view.selectedRange().location)/\(caret) box=\(Int(view.bounds.width))pt wrap=\(Int(wrap))pt height=\(Int(view.bounds.height))")
        }

        func flag(_ kind: String, _ message: String) {
            guard reported.insert(kind).inserted else { return }
            problems += 1
            print("TYPE \(name) PROBLEM \(message)")
        }

        func diff(_ a: String, _ b: String) -> String {
            let x = Array(a), y = Array(b)
            var i = 0
            while i < min(x.count, y.count), x[i] == y[i] { i += 1 }
            return "expected \(x.count) chars, got \(y.count); first difference at \(i): expected \(String(x[i..<min(i + 12, x.count)]).debugDescription) got \(String(y[i..<min(i + 12, y.count)]).debugDescription)"
        }
    }

    private static func textViews(in view: NSView?) -> [NSTextView] {
        guard let view else { return [] }
        if let t = view as? NotesTextView { return [t] }
        return view.subviews.flatMap { textViews(in: $0) }
    }

    private static func snapshot(_ window: NSWindow, _ url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        if let layer = view.layer, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            layer.render(in: ctx.cgContext)
        } else {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
