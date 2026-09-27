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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }; return self.handle(event)
        }
    }
    func uninstall() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    var blocked: Bool {
        presentationBlocked(in: NSApp.keyWindow) || isTextInput(NSApp.keyWindow?.firstResponder)
    }
    private func presentationBlocked(in window: NSWindow?) -> Bool {
        guard let model, isPlayerWindow(window) else { return true }
        if model.showSettings || model.showSubtitleSearch || model.showSubtitleControls || model.playerPopover != nil || model.showAlignmentDetails || model.alert != nil || model.recordingAction != nil { return true }
        return NSApp.modalWindow != nil || window?.attachedSheet != nil
    }
    private func isTextInput(_ responder: NSResponder?) -> Bool {
        // NSControl also includes buttons, sliders and tables. Their focus must
        // not disable every player command (including menu key equivalents).
        if let text = responder as? NSTextView { return text.isEditable || text.hasMarkedText() }
        if let field = responder as? NSTextField { return field.isEditable }
        return (responder as? NSTextInputClient)?.hasMarkedText() == true
    }
    private func leaveTextInputIfNeeded(_ event: NSEvent) {
        guard let window = event.window, !presentationBlocked(in: window),
              isTextInput(window.firstResponder), let content = window.contentView else { return }
        // A video surface or SwiftUI button need not accept first responder.
        // Clicking it can otherwise leave the search field's editor active.
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard let hit = content.hitTest(point) else { return }
        var view: NSView? = hit
        while let current = view {
            if isTextInput(current) { return }
            view = current.superview
        }
        window.makeFirstResponder(nil)
    }
    func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .leftMouseDown {
            if isPlayerWindow(event.window) { model?.chrome.hold(.keyboard, active: false) }
            leaveTextInputIfNeeded(event); return event
        }
        guard event.type == .keyDown else { return event }
        guard let model else { return event }
        if let action = model.recordingAction, model.showSettings, NSApp.modalWindow == nil {
            if event.keyCode == 53 { model.recordingAction = nil; model.shortcutMessage = "已取消录入。"; return nil }
            if !event.isARepeat { model.bind(Shortcut(event: event), to: action) }
            return nil
        }
        guard !blocked else { return event }
        if event.keyCode == 48 { model.chrome.hold(.keyboard, active: true); return event }
        let shortcut = Shortcut(event: event)
        guard let action = PlayerAction.allCases.first(where: { model.preferences.shortcut(for: $0)?.matches(shortcut) == true }), model.canPerform(action) else { return event }
        let repeats: Set<PlayerAction> = [.backward, .forward, .volumeDown, .volumeUp, .slower, .faster]
        if !event.isARepeat || repeats.contains(action) { model.perform(action) }
        return nil // consumed once; AppKit must not also execute the menu equivalent
    }
}
