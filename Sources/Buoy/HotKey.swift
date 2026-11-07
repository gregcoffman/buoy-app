import Carbon
import Foundation
import os

private let log = Logger(subsystem: "app.buoy.Buoy", category: "hotkey")

/// The global shortcuts offered for Quick Entry.
enum HotKeyPreset: String, CaseIterable, Identifiable {
    case controlSpace
    case controlOptionSpace
    case controlOptionN
    case optionShiftSpace
    case controlOptionCommandB
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .controlSpace: "⌃Space"
        case .controlOptionSpace: "⌃⌥Space"
        case .controlOptionN: "⌃⌥N"
        case .optionShiftSpace: "⌥⇧Space"
        case .controlOptionCommandB: "⌃⌥⌘B"
        case .off: "Off"
        }
    }

    var keyCode: UInt32? {
        switch self {
        case .controlSpace, .controlOptionSpace, .optionShiftSpace: UInt32(kVK_Space)
        case .controlOptionN: UInt32(kVK_ANSI_N)
        case .controlOptionCommandB: UInt32(kVK_ANSI_B)
        case .off: nil
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .controlSpace: UInt32(controlKey)
        case .controlOptionSpace, .controlOptionN: UInt32(controlKey | optionKey)
        case .optionShiftSpace: UInt32(optionKey | shiftKey)
        case .controlOptionCommandB: UInt32(controlKey | optionKey | cmdKey)
        case .off: 0
        }
    }
}

/// A single system-wide hotkey via Carbon's RegisterEventHotKey, which works
/// without Accessibility permissions.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var action: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    /// Returns false if the shortcut couldn't be registered (usually because another app owns it).
    @discardableResult
    func register(_ preset: HotKeyPreset) -> Bool {
        unregister()
        guard let keyCode = preset.keyCode else { return true }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x4255_4F59) /* 'BUOY' */, id: 1)
        let status = RegisterEventHotKey(keyCode, preset.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { hotKeyRef = nil }
        log.notice("register \(preset.label, privacy: .public) status=\(status)")
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { center.action?() }
            return noErr
        }, 1, &spec, context, &handlerRef)
    }
}
