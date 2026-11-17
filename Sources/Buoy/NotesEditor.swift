import AppKit
import SwiftUI

/// Editable notes with clickable links (web addresses, emails, …), sized to fit
/// its text. Built on NSTextView because SwiftUI text fields can't show links
/// while staying editable.
struct NotesEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder = "Notes"
    /// Full-size primary text, for Notes (a task's notes are quieter).
    var prominent = false
    /// Bump to put the cursor at the end of the notes.
    var focusRequest = 0
    /// Keep quotes, dashes and text exactly as typed (no curly quotes or em dashes).
    /// For text an agent reads.
    var plainPunctuation = false
    var onEscape: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NotesTextView {
        let view = NotesTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.prominent = prominent
        view.font = view.bodyFont
        view.textColor = view.bodyAttributes[.foregroundColor] as? NSColor
        view.typingAttributes = view.bodyAttributes
        view.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        view.placeholder = placeholder
        view.onEscape = onEscape
        view.plainPunctuation = plainPunctuation
        view.string = text
        view.refreshLinks()
        return view
    }

    func updateNSView(_ view: NotesTextView, context: Context) {
        context.coordinator.parent = self
        view.onEscape = onEscape
        view.placeholder = placeholder
        view.plainPunctuation = plainPunctuation
        // Only take the binding's value when it really changed from outside. While
        // you're typing, the view holds the newest text; overwriting it here (for
        // example mid-composition, or from an update that hasn't caught up) loses
        // keystrokes and moves the cursor.
        if view.string != text, text != context.coordinator.lastSent,
           !(view.window?.firstResponder === view && view.hasMarkedText()) {
            let selection = view.selectedRanges
            view.string = text
            context.coordinator.lastSent = text
            view.refreshLinks()
            let length = (text as NSString).length
            view.selectedRanges = selection.map {
                let r = $0.rangeValue
                let start = min(r.location, length)
                return NSValue(range: NSRange(location: start, length: min(r.length, length - start)))
            }
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { view.focusAtEnd() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NotesTextView, context: Context) -> CGSize? {
        // Answer only from the proposal and the text, never from the view's current
        // size: an answer that changes when the view is resized makes layout loop.
        let width = proposal.width ?? 300
        return CGSize(width: width, height: view.heightFitting(width: width))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotesEditor
        var lastFocusRequest: Int
        /// The text this view last handed to the binding.
        var lastSent: String

        init(_ parent: NotesEditor) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
            lastSent = parent.text
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NotesTextView else { return }
            view.refreshLinks()
            lastSent = view.string
            parent.text = view.string
        }
    }
}

final class NotesTextView: NSTextView {
    var prominent = false
    var bodyFont: NSFont { NSFont.systemFont(ofSize: NSFont.systemFontSize + (prominent ? 0 : -1)) }
    var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: prominent ? NSColor.labelColor : NSColor.secondaryLabelColor]
    }
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    var placeholder = ""
    var onEscape: () -> Void = {}
    var plainPunctuation = false {
        didSet {
            guard plainPunctuation != oldValue || plainPunctuation else { return }
            isAutomaticQuoteSubstitutionEnabled = !plainPunctuation
            isAutomaticDashSubstitutionEnabled = !plainPunctuation
            isAutomaticTextReplacementEnabled = !plainPunctuation
        }
    }

    /// Re-marks every link in the text. Links are display-only attributes;
    /// what's saved is still plain text.
    func refreshLinks() {
        // Never restyle mid-composition (accents, dictation, other input methods):
        // rewriting attributes then drops the half-typed text. didChangeText runs
        // again once the composition is committed.
        guard let storage = textStorage, !hasMarkedText() else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(bodyAttributes, range: full)
        Self.detector?.enumerateMatches(in: storage.string, range: full) { match, _, _ in
            if let match, let url = match.url { storage.addAttribute(.link, value: url, range: match.range) }
        }
        storage.endEditing()
        typingAttributes = bodyAttributes
        invalidateIntrinsicContentSize()
    }

    // A private copy of the text, used only to measure it.
    private let measureStorage = NSTextStorage()
    private let measureContainer = NSTextContainer(size: .zero)
    private lazy var measureLayout: NSLayoutManager = {
        let layout = NSLayoutManager()
        measureStorage.addLayoutManager(layout)
        layout.addTextContainer(measureContainer)
        return layout
    }()

    /// How tall the text is when wrapped at `width`. SwiftUI asks this at trial
    /// widths while laying out, often on every keystroke. The answer comes from a
    /// separate copy of the text, so asking never touches the text on screen:
    /// - Wrapping the on-screen text at a trial width left it wrapped too narrow.
    /// - Switching it to a trial width and back made it re-layout on every
    ///   question, which asked SwiftUI to lay out again, forever (AppKit then
    ///   aborts: "more Update Constraints in Window passes than there are views").
    func heightFitting(width: CGFloat) -> CGFloat {
        guard let storage = textStorage else { return 17 }
        if !measureStorage.isEqual(to: storage) { measureStorage.setAttributedString(storage) }
        measureContainer.lineFragmentPadding = textContainer?.lineFragmentPadding ?? 0
        measureContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        measureLayout.ensureLayout(for: measureContainer)
        let used = measureLayout.usedRect(for: measureContainer).height
        return max(ceil(used), ceil(bodyFont.boundingRectForFont.height))
    }

    func focusAtEnd() {
        guard let window else { return }
        window.makeFirstResponder(self)
        let end = (string as NSString).length
        setSelectedRange(NSRange(location: end, length: 0))
    }

    override func cancelOperation(_ sender: Any?) { onEscape() }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        (placeholder as NSString).draw(at: .zero, withAttributes: [
            .font: bodyFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }
}
