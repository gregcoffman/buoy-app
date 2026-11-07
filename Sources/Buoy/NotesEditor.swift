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
        view.string = text
        view.refreshLinks()
        return view
    }

    func updateNSView(_ view: NotesTextView, context: Context) {
        context.coordinator.parent = self
        view.onEscape = onEscape
        view.placeholder = placeholder
        if view.string != text {
            view.string = text
            view.refreshLinks()
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { view.focusAtEnd() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NotesTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        return CGSize(width: width, height: view.heightFitting(width: width))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotesEditor
        var lastFocusRequest: Int

        init(_ parent: NotesEditor) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NotesTextView else { return }
            view.refreshLinks()
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

    /// Re-marks every link in the text. Links are display-only attributes;
    /// what's saved is still plain text.
    func refreshLinks() {
        guard let storage = textStorage else { return }
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

    func heightFitting(width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layout = layoutManager else { return 17 }
        if container.containerSize.width != width {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
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
