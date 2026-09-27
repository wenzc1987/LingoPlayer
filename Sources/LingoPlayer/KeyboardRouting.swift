import AppKit
import PlayerCore

extension Shortcut {
    init(event: NSEvent) {
        var modifiers: KeyModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        let names: [UInt16: String] = [123: "←", 124: "→", 125: "↓", 126: "↑", 36: "\r", 76: "\r", 49: " "]
        self.init(event.keyCode, names[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased() ?? "", modifiers)
    }
    var menuKey: String {
        ["←": "\u{f702}", "→": "\u{f703}", "↓": "\u{f701}", "↑": "\u{f700}"][key] ?? key
    }
    var menuModifiers: NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }
}

@MainActor
final class KeyboardRouter {
    weak var model: AppModel?
    var isPlayerWindow: (NSWindow?) -> Bool = { _ in false }
    private var monitor: Any?
    init(model: AppModel) { self.model = model }
    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }; return self.handle(event)
        }
    }
    func uninstall() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    var blocked: Bool {
        guard let model, isPlayerWindow(NSApp.keyWindow) else { return true }
        if model.showSettings || model.showSubtitleSearch || model.showSubtitleControls || model.showAlignmentDetails || model.alert != nil || model.recordingAction != nil { return true }
        if NSApp.modalWindow != nil || NSApp.keyWindow?.attachedSheet != nil { return true }
        let responder = NSApp.keyWindow?.firstResponder
        return responder is NSTextView || responder is NSTextField || responder is NSControl
    }
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let model else { return event }
        if let action = model.recordingAction, model.showSettings, NSApp.modalWindow == nil {
            if event.keyCode == 53 { model.recordingAction = nil; model.shortcutMessage = "已取消录入。"; return nil }
            if !event.isARepeat { model.bind(Shortcut(event: event), to: action) }
            return nil
        }
        guard !blocked else { return event }
        let shortcut = Shortcut(event: event)
        guard let action = PlayerAction.allCases.first(where: { model.preferences.shortcut(for: $0)?.matches(shortcut) == true }), model.canPerform(action) else { return event }
        let repeats: Set<PlayerAction> = [.backward, .forward, .volumeDown, .volumeUp, .slower, .faster]
        if !event.isARepeat || repeats.contains(action) { model.perform(action) }
        return nil // consumed once; AppKit must not also execute the menu equivalent
    }
}
