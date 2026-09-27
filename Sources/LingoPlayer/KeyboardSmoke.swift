import AppKit
import PlayerCore

/// Keep real control focus between events; resetting it before every key hides routing bugs.
@MainActor enum KeyboardSmoke {
    static func run(model: AppModel, window: NSWindow, keyboard: KeyboardRouter, video: URL, output: URL,
                    detach: () -> Void, learningWindow: () -> NSWindow?, closeDetached: () -> Void) async {
        var checks: [[String: Any]] = []
        func record(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail])
            print("keyboard", name, passed, detail); fflush(stdout)
        }
        func delay(_ seconds: Double = 0.15) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        func wait(_ condition: () -> Bool) async -> Bool {
            let until = Date().addingTimeInterval(15)
            while Date() < until { if condition() { return true }; await delay(0.025) }; return condition()
        }
        func event(_ action: PlayerAction, in target: NSWindow) -> NSEvent {
            let key = model.preferences.shortcut(for: action)!
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.menuModifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil,
                characters: key.menuKey, charactersIgnoringModifiers: key.menuKey, isARepeat: false, keyCode: key.keyCode)!
        }
        let metrics = OperationMetrics.shared
        func press(_ action: PlayerAction, in target: NSWindow, name: String) async {
            let revision = metrics.revision
            let responder = String(describing: target.firstResponder.map { type(of: $0) })
            let blocked = keyboard.blocked
            NSApp.postEvent(event(action, in: target), atStart: false)
            await delay()
            record(name, metrics.revision == revision + 1 && metrics.action == action,
                   "focus=\(responder), blocked=\(blocked), dispatched=\(metrics.revision - revision)")
        }
        func click(_ view: NSView, in target: NSWindow) async {
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: kind == .leftMouseDown ? 1 : 0)!, atStart: false)
                await delay(0.025)
            }
            await delay()
        }
        model.settings.autoSearch = false; model.settings.mfa = "/missing/keyboard-smoke"
        model.setVolume(0); model.player.set("mute", "yes")
        var preferences = InteractionPreferences(); preferences.autoplay = false
        _ = preferences.assign(Shortcut(49, " "), to: .playPause)
        model.updatePreferences(preferences); model.open(video)
        let loaded = await wait { model.playbackReady && model.duration > 0 && !model.english.isEmpty }
        record("media_loaded_with_custom_space_binding", loaded && model.preferences.shortcut(for: .playPause)?.keyCode == 49)
        if model.endGate.wantsPlayback { model.togglePlayback() }
        _ = await wait { model.paused && model.seekTarget == nil }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.becomeKey()
        metrics.enabled = true
        if loaded {
            let button = NSButton(title: "焦点按钮", target: nil, action: nil)
            let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
            let table = TranscriptTableView(); table.addTableColumn(NSTableColumn(identifier: .init("test")))
            for (name, control) in [("button", button as NSView), ("slider", slider), ("transcript_table", table)] {
                control.frame = NSRect(x: 15, y: 15, width: 160, height: 35); window.contentView?.addSubview(control)
                record(name + "_receives_focus", window.makeFirstResponder(control) && window.firstResponder === control)
                await press(.playPause, in: window, name: name + "_space_once")
                await press(.playPause, in: window, name: name + "_space_again_once")
                await press(.forward, in: window, name: name + "_right_arrow")
                await press(.backward, in: window, name: name + "_left_arrow")
                await press(.cycleSubtitleDisplay, in: window, name: name + "_command_shortcut")
                control.removeFromSuperview()
            }
            if model.endGate.wantsPlayback { model.togglePlayback() }
            let editor = NSTextView(frame: NSRect(x: 15, y: 15, width: 180, height: 45))
            window.contentView?.addSubview(editor); editor.string = "English 中文"
            window.makeFirstResponder(editor); editor.setSelectedRange(NSRange(location: 0, length: 0))
            let revision = metrics.revision
            NSApp.postEvent(event(.playPause, in: window), atStart: false); await delay()
            record("typing_space_edits_text_without_playback", editor.string == " English 中文" && metrics.revision == revision && keyboard.blocked)
            editor.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            record("ime_and_text_editing_keep_shortcuts", keyboard.handle(event(.backward, in: window)) != nil && keyboard.handle(event(.cycleSubtitleDisplay, in: window)) != nil)
            editor.unmarkText()
            let field = NSTextField(frame: NSRect(x: 220, y: 15, width: 180, height: 35))
            window.contentView?.addSubview(field); field.stringValue = "search"
            await click(field, in: window)
            record("clicking_another_input_keeps_text_editing", field.currentEditor() === window.firstResponder && keyboard.blocked)
            field.removeFromSuperview(); window.makeFirstResponder(editor)
            await click(model.videoView, in: window)
            record("video_click_leaves_text_editing", window.firstResponder !== editor && !keyboard.blocked)
            await press(.playPause, in: window, name: "space_after_leaving_editor")
            if model.endGate.wantsPlayback { model.togglePlayback() }
            editor.isEditable = false; editor.isSelectable = true; window.makeFirstResponder(editor)
            await press(.cycleSubtitleDisplay, in: window, name: "readonly_text_does_not_block_player")
            editor.removeFromSuperview(); window.makeFirstResponder(window.contentView)
            model.showSubtitleControls = true
            record("subtitle_popover_still_blocks_keys", keyboard.handle(event(.playPause, in: window)) != nil)
            model.showSubtitleControls = false
            model.showSettings = true; await delay()
            record("settings_still_blocks_keys", keyboard.handle(event(.playPause, in: window)) != nil)
            model.showSettings = false; await delay(0.3)
            window.makeKeyAndOrderFront(nil); window.becomeKey()
            await press(.cycleSubtitleDisplay, in: window, name: "shortcut_after_closing_settings")
            if let cue = model.english.first, let word = cue.tokens.first(where: \.isWord) {
                model.lock(cue: cue, token: word)
                await press(.replaySentence, in: window, name: "command_r_replays_locked_sentence")
                record("replay_starts_selected_cue", model.replayRange?.lowerBound == cue.start)
                await press(.resumeLearning, in: window, name: "command_return_resumes_learning")
                record("resume_unlocks_and_plays", !model.learning.isLocked && model.endGate.wantsPlayback)
            }
            detach(); await delay(0.3)
            if let target = learningWindow() {
                let control = NSButton(title: "学习窗口焦点", target: nil, action: nil)
                control.frame = NSRect(x: 15, y: 15, width: 150, height: 35); target.contentView?.addSubview(control)
                target.makeKeyAndOrderFront(nil); target.becomeKey()
                record("detached_button_receives_focus", target.makeFirstResponder(control) && target.firstResponder === control)
                await press(.playPause, in: target, name: "detached_space_once")
                await press(.cycleSubtitleDisplay, in: target, name: "detached_command_shortcut")
                control.removeFromSuperview()
            } else { record("detached_window_exists", false) }
            closeDetached(); await delay(); window.makeKeyAndOrderFront(nil); window.becomeKey()
            if model.endGate.wantsPlayback { model.togglePlayback() }
        }
        metrics.enabled = false
        let result: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("keyboard.json"))
        NSApp.terminate(nil)
    }
}
