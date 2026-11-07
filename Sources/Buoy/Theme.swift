import AppKit
import SwiftUI

/// Buoy's palette: neutral surfaces, a colour per list, and the buoy's red.
enum Theme {
    static let buoyRed = Color(red: 0.90, green: 0.29, blue: 0.24)
    static let today = Color(red: 0.98, green: 0.74, blue: 0.16)
    static let sea = Color(red: 0.20, green: 0.52, blue: 0.78)
    static let upcoming = Color(red: 0.93, green: 0.30, blue: 0.33)
    static let logbook = Color(red: 0.30, green: 0.69, blue: 0.40)
    static let showOn = Color(red: 0.96, green: 0.66, blue: 0.14)
    static let due = Color(red: 0.90, green: 0.29, blue: 0.24)
    static let lead = Color(red: 0.93, green: 0.52, blue: 0.20)
    static let repeatTint = Color(red: 0.45, green: 0.47, blue: 0.85)
    static let checkbox = Color(red: 0.24, green: 0.52, blue: 0.95)
    static let notes = Color(red: 0.16, green: 0.62, blue: 0.70)
    static let projects = Color(red: 0.27, green: 0.47, blue: 0.93)
    static let bridge = Color(red: 0.16, green: 0.40, blue: 0.66)
    static let later = Color(red: 0.55, green: 0.58, blue: 0.68)
    /// Marks things an agent added through a buoy:// link.
    static let agent = Color(red: 0.62, green: 0.48, blue: 0.92)

    /// The raised card an expanded task sits on: white in light mode, a lifted grey in dark mode.
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.20, alpha: 1) : NSColor.white
    })

    static let chipFill = Color.primary.opacity(0.06)
}

extension SidebarRoute {
    var tint: Color {
        switch self {
        case .bridge: Theme.bridge
        case .today: Theme.today
        case .later: Theme.later
        case .upcoming: Theme.upcoming
        case .logbook: Theme.logbook
        case .notes: Theme.notes
        case .projects: Theme.projects
        case .tag: .secondary
        }
    }

    /// The list's icon, used in the sidebar and next to the big title.
    @ViewBuilder
    func icon(size: CGFloat) -> some View {
        switch self {
        case .bridge:
            Image(systemName: "binoculars.fill").font(.system(size: size * 0.82)).foregroundStyle(tint)
        case .later:
            Image(systemName: "tray.fill").font(.system(size: size * 0.85)).foregroundStyle(tint)
        case .today:
            Image(systemName: "sun.max.fill").font(.system(size: size * 0.95)).foregroundStyle(tint)
        case .upcoming:
            Image(systemName: "calendar").font(.system(size: size * 0.9, weight: .semibold)).foregroundStyle(tint)
        case .logbook:
            Image(systemName: "checkmark.square.fill").font(.system(size: size * 0.95)).foregroundStyle(tint)
        case .notes:
            Image(systemName: "note.text").font(.system(size: size * 0.9, weight: .semibold)).foregroundStyle(tint)
        case .projects:
            Image(systemName: "rectangle.split.3x1.fill").font(.system(size: size * 0.85, weight: .semibold)).foregroundStyle(tint)
        case .tag:
            Image(systemName: "tag").font(.system(size: size * 0.85)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - The buoy

/// A small red-and-white life ring.
struct BuoyMark: View {
    var size: CGFloat = 16

    var body: some View {
        let line = size * 0.30
        ZStack {
            Circle()
                .stroke(Color(white: 0.97), lineWidth: line)
            ForEach(0..<4) { i in
                Circle()
                    .trim(from: CGFloat(i) * 0.25 + 0.0625, to: CGFloat(i) * 0.25 + 0.1875)
                    .stroke(Theme.buoyRed, lineWidth: line)
            }
            // Hairline edges so the white segments read on light backgrounds.
            Circle().stroke(Color.black.opacity(0.32), lineWidth: max(0.5, size * 0.03))
                .frame(width: size, height: size)
            Circle().stroke(Color.black.opacity(0.26), lineWidth: max(0.5, size * 0.03))
                .frame(width: size - line * 2, height: size - line * 2)
        }
        .frame(width: size - line, height: size - line)
        .frame(width: size, height: size)
        .rotationEffect(.degrees(-12))
        .accessibilityHidden(true)
    }
}

/// A buoy gently bobbing on a wave line; shown when Today is clear.
struct BobbingBuoy: View {
    var size: CGFloat = 54

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: -size * 0.22) {
                BuoyMark(size: size)
                    .offset(y: sin(t * 1.6) * size * 0.07)
                    .rotationEffect(.degrees(sin(t * 1.1) * 5))
                Wave(phase: t * 1.4, amplitude: size * 0.06)
                    .stroke(Theme.sea.opacity(0.55), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: size * 2.6, height: size * 0.3)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct Wave: Shape {
    var phase: Double
    var amplitude: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let steps = 60
        for i in 0...steps {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(steps)
            let y = rect.midY + amplitude * CGFloat(sin(Double(i) / Double(steps) * .pi * 3 + phase))
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

// MARK: - Checkbox

/// Rounded-square checkbox.
struct Checkbox: View {
    var checked: Bool
    var tint: Color = Theme.checkbox

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(checked ? tint : Color.clear)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(checked ? tint : Color.secondary.opacity(0.55), lineWidth: 1.2)
            if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 15, height: 15)
        .contentShape(Rectangle().inset(by: -4))
    }
}

// MARK: - Rising

/// Tasks that newly rise into Today float up into place.
struct RiseIn: ViewModifier {
    let active: Bool
    @State private var settled = false
    @State private var glow = false

    func body(content: Content) -> some View {
        let lifting = active && !settled
        content
            .offset(y: lifting ? 18 : 0)
            .opacity(lifting ? 0 : 1)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.sea.opacity(glow ? 0.12 : 0))
                    .padding(.horizontal, -6)
            )
            .onAppear {
                guard active else { return }
                glow = true
                withAnimation(.spring(response: 0.7, dampingFraction: 0.72).delay(0.05)) { settled = true }
                withAnimation(.easeOut(duration: 1.6).delay(0.9)) { glow = false }
            }
    }
}

// MARK: - New

/// Something just added fades into place.
struct FadeIn: ViewModifier {
    let active: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(active && !shown ? 0 : 1)
            .onAppear {
                guard active else { return }
                withAnimation(.easeOut(duration: 0.45).delay(0.05)) { shown = true }
            }
    }
}

// MARK: - Chips

/// A compact pill used for dates, lead time, repeat and tags inside task cards.
struct Chip: View {
    let icon: String
    let text: String
    var active: Bool
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(active ? tint : .secondary)
            Text(text)
                .foregroundStyle(active ? .primary : .secondary)
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(active ? tint.opacity(0.13) : Theme.chipFill, in: Capsule())
    }
}

// MARK: - Click outside

/// Lets an open card close when the user clicks anywhere else in the window.
/// Popovers and menus are separate windows, so using a card's
/// date picker or menus doesn't count as clicking outside.
@MainActor
final class ClickOutside {
    static let shared = ClickOutside()

    private weak var region: NSView?
    private var onOutside: (() -> Void)?
    private var monitor: Any?

    func watch(_ region: NSView, onOutside: @escaping () -> Void) {
        self.region = region
        self.onOutside = onOutside
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let region = self.region, region.window != nil, event.window === region.window else { return event }
            let point = region.convert(event.locationInWindow, from: nil)
            if !region.bounds.contains(point), let action = self.onOutside {
                // Let the click land first (e.g. selecting another task), then close.
                DispatchQueue.main.async { action() }
            }
            return event
        }
    }

    func stop(_ region: NSView) {
        guard self.region === region else { return }
        self.region = nil
        onOutside = nil
    }
}

/// An invisible view marking a card's bounds for `ClickOutside`.
struct ClickOutsideRegion: NSViewRepresentable {
    let onOutside: () -> Void

    func makeNSView(context: Context) -> RegionView {
        let view = RegionView()
        view.onOutside = onOutside
        return view
    }

    func updateNSView(_ view: RegionView, context: Context) {
        view.onOutside = onOutside
    }

    final class RegionView: NSView {
        var onOutside: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                ClickOutside.shared.watch(self) { [weak self] in self?.onOutside?() }
            } else {
                ClickOutside.shared.stop(self)
            }
        }

        // Never intercept clicks; this view only marks an area.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Project mark

/// A small board glyph beside a project when it shows up in Today, Upcoming or the Logbook.
struct ProjectMark: View {
    var body: some View {
        Image(systemName: "rectangle.split.3x1")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.projects)
            .help("Project")
            .accessibilityLabel("Project")
    }
}

// MARK: - Agent mark

/// A small sparkle beside anything an agent added, so it's recognisable at a glance.
struct AgentMark: View {
    var body: some View {
        Image(systemName: "sparkles")
            .font(.caption2)
            .foregroundStyle(Theme.agent)
            .help("Added by an agent")
            .accessibilityLabel("Added by an agent")
    }
}

// MARK: - Window dragging

/// An invisible area that moves the window when dragged, like a title bar
/// (double-click zooms or minimizes, following System Settings). The lists run up
/// under the title bar, so without this the top of the window couldn't be grabbed.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action == "Minimize" { window.performMiniaturize(nil) } else if action != "None" { window.performZoom(nil) }
            } else {
                window.performDrag(with: event)
            }
        }
    }
}
