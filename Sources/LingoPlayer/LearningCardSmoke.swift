import AppKit
import PlayerCore

/// Isolated-state native checks for pause selection and locked-card navigation.
@MainActor enum LearningCardSmoke {
    static func run(model: AppModel, window: NSWindow, keyboard: KeyboardRouter, video: URL, output: URL,
                    restore: Bool, detach: () -> Void, learningWindow: () -> NSWindow?, closeDetached: () -> Void) async {
        var checks: [[String: Any]] = []
        func record(_ name: String, _ passed: Bool) {
            checks.append(["name": name, "passed": passed]); print("learning-card", name, passed); fflush(stdout)
        }
        func delay(_ seconds: Double = 0.15) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        func wait(_ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline { if condition() { return true }; await delay(0.025) }; return condition()
        }
        func find(_ root: NSObject, _ id: String, depth: Int = 0) -> NSObject? {
            guard depth < 40 else { return nil }
            let identifier = NSSelectorFromString("accessibilityIdentifier"), children = NSSelectorFromString("accessibilityChildren")
            if root.responds(to: identifier), root.perform(identifier)?.takeUnretainedValue() as? String == id { return root }
            if root.responds(to: children), let items = root.perform(children)?.takeUnretainedValue() as? [NSObject] {
                for item in items { if let found = find(item, id, depth: depth + 1) { return found } }
            }; return nil
        }
        func key(_ action: PlayerAction, in target: NSWindow? = nil) -> NSEvent {
            let shortcut = model.preferences.shortcut(for: action)!
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shortcut.menuModifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: (target ?? window).windowNumber, context: nil,
                characters: shortcut.menuKey, charactersIgnoringModifiers: shortcut.menuKey, isARepeat: false, keyCode: shortcut.keyCode)!
        }
        func press(_ id: String, in target: NSWindow? = nil) async -> Bool {
            // Model actions are synchronous; SwiftUI commits enabled states on
            // the next run-loop turn before an accessibility click can use them.
            await delay()
            guard let control = find(target ?? window, id), control.responds(to: NSSelectorFromString("accessibilityPerformPress")) else { return false }
            _ = control.perform(NSSelectorFromString("accessibilityPerformPress")); await delay(); return true
        }
        func screenshot(_ name: String, in target: NSWindow? = nil) {
            record(name, WindowSnapshot.save(target ?? window, to: output.appendingPathComponent(name + ".png")))
        }
        func play(at time: Double) async {
            model.seek(time)
            if !model.endGate.wantsPlayback { model.togglePlayback() }
            record("playing-at-\(time)", await wait { model.seekTarget == nil && !model.paused && model.position >= time - 0.1 })
        }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        model.settings.autoSearch = false; model.settings.mfa = "/missing/learning-card-smoke"
        model.setVolume(0); model.player.set("mute", "yes"); model.chrome.hold(.keyboard, active: true)
        if restore {
            record("pause-selection-off-survives-restart", !model.viewing.selectWordOnPause)
        } else {
            record("pause-selection-defaults-on", model.viewing.selectWordOnPause)
            model.open(video)
            let loaded = await wait { model.playbackReady && model.duration > 20 && !model.english.isEmpty }
            await model.openTask?.value
            model.aligner.cancel(); await model.aligner.waitForCancellation()
            record("learning-media-loaded", loaded && model.isLearningMode)
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(window.contentView)
            if let cue = model.english.first {
                let words = cue.tokens.filter(\.isWord)
                func timings() -> [TimedWord] {
                    words.enumerated().map { index, token in .init(cueID: cue.id, tokenIndex: token.id, start: 0.5 + Double(index) * 2, end: 2.5 + Double(index) * 2) }
                }
                model.timings = timings()
                model.closeLearningCard(); model.setSidebarCollapsed(true)
                await play(at: 1)
                let highlighted = model.highlightedLearningSelection
                record("pause-shortcut-selects-highlight-and-reveals-card", keyboard.handle(key(.playPause)) == nil &&
                       highlighted != nil && model.selected == highlighted && model.learning.isLocked && model.paused &&
                       !model.preferences.sidebarCollapsed && !model.preferences.cardHidden && model.sidebarTab == .learning)
                _ = await wait { model.paused }; await delay()
                record("first-word-blocks-previous", !model.canPerform(.previousWord) && keyboard.handle(key(.previousWord)) != nil)
                let revision = model.seekRevision, pausedPosition = model.position
                record("next-key-skips-punctuation-and-selects-second-occurrence", keyboard.handle(key(.nextWord)) == nil && model.selected?.token == words[1])
                record("previous-native-button", await press("action-previousWord") && model.selected?.token == words[0])
                record("next-native-button", await press("action-nextWord") && model.selected?.token == words[1])
                record("card-navigation-keeps-paused-position", model.paused && model.seekRevision == revision && abs(model.position - pausedPosition) < 0.08)
                for word in words.dropFirst(2) {
                    record("next-word-\(word.id)", keyboard.handle(key(.nextWord)) == nil && model.selected?.token == word)
                }
                record("last-word-blocks-next", !model.canPerform(.nextWord) && keyboard.handle(key(.nextWord)) != nil)
                let last = model.selected
                model.perform(.nextWord)
                record("last-word-does-not-wrap", model.selected == last)
                model.seek(20); _ = await wait { model.seekTarget == nil && model.paused }
                let distantPosition = model.position, distantRevision = model.seekRevision
                record("navigation-uses-locked-sentence-away-from-playhead", keyboard.handle(key(.previousWord)) == nil && model.selected?.cue == cue &&
                       model.selected?.token == words[words.count - 2] && model.position == distantPosition && model.seekRevision == distantRevision)

                let editor = NSTextView(frame: NSRect(x: 15, y: 15, width: 180, height: 35))
                window.contentView?.addSubview(editor); editor.string = "editable text"; window.makeFirstResponder(editor)
                let selectedBeforeEditing = model.selected
                record("editing-retains-command-arrow-keys", keyboard.handle(key(.previousWord)) != nil && keyboard.handle(key(.nextWord)) != nil && model.selected == selectedBeforeEditing)
                editor.removeFromSuperview(); window.makeFirstResponder(window.contentView)

                model.lock(cue: cue, token: words[0]); await play(at: 3)
                record("normal-play-keeps-existing-lock", model.selected?.token == words[0] && model.currentWordID == "\(cue.id):\(words[1].id)")
                record("pause-replaces-old-lock-with-current-highlight", keyboard.handle(key(.playPause)) == nil && model.selected?.token == words[1] && model.paused)
                model.closeLearningCard(); model.setSidebarCollapsed(true); await play(at: 20)
                model.perform(.playPause)
                record("pause-without-highlight-does-not-select-or-open", model.paused && !model.learning.isLocked && model.selected == nil && model.preferences.sidebarCollapsed && model.preferences.cardHidden)
                model.viewing.setSelectWordOnPause(false); await play(at: 1)
                model.perform(.playPause)
                record("disabled-pause-selection-leaves-card-closed", model.paused && model.currentWordID != nil && !model.learning.isLocked && model.preferences.cardHidden)
                record("unlocked-command-arrows-inactive", keyboard.handle(key(.previousWord)) != nil && keyboard.handle(key(.nextWord)) != nil)
                model.lock(cue: cue, token: words[0]); await play(at: 1)
                let playingRevision = model.seekRevision
                record("navigation-during-playback-keeps-playing", keyboard.handle(key(.nextWord)) == nil && !model.paused && model.endGate.wantsPlayback && model.seekRevision == playingRevision && model.selected?.token == words[1])
                model.perform(.playPause)
                model.chooseLearningMode(false)
                record("ordinary-mode-disables-word-actions", !model.canPerform(.previousWord) && !model.canPerform(.nextWord) && keyboard.handle(key(.nextWord)) != nil)
                model.viewing.setSelectWordOnPause(true); await play(at: 1); model.perform(.playPause)
                record("ordinary-pause-never-selects", model.paused && !model.learning.isLocked)
                model.chooseLearningMode(true); model.aligner.cancel(); await model.aligner.waitForCancellation(); model.timings = timings()
                model.lock(cue: cue, token: words[0]); await delay()
                record("version-label-present", find(window, "playback-version") != nil && find(window, "sidebar-version") == nil)
                screenshot("locked-card")
                var compact = window.frame; compact.size = NSSize(width: 1013, height: 360)
                window.setFrame(compact, display: true); await delay(0.4)
                screenshot("compact-card")
                record("compact-word-controls-and-version-visible", ["action-previousWord", "action-nextWord", "playback-version"].allSatisfy { id in
                    guard let rect = (find(window, id)?.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else { return false }
                    return !rect.isEmpty && window.frame.contains(rect)
                })
                detach(); await delay(0.3)
                if let target = learningWindow() {
                    target.makeKeyAndOrderFront(nil); target.makeFirstResponder(target.contentView)
                    record("detached-word-shortcut", keyboard.handle(key(.nextWord, in: target)) == nil && model.selected?.token == words[1])
                    screenshot("detached-card", in: target)
                    model.closeLearningCard(); await play(at: 1)
                    record("detached-pause-reopens-same-learning-window", keyboard.handle(key(.playPause, in: target)) == nil && model.isDetached &&
                           learningWindow() === target && model.selected?.token == words[0] && !model.preferences.cardHidden)
                } else { record("detached-window-exists", false) }
                closeDetached(); await delay(); window.makeKeyAndOrderFront(nil)
                model.settingsPage = 3; model.showSettings = true; await delay(0.4)
                if let sheet = window.attachedSheet {
                    record("settings-block-word-navigation", keyboard.handle(key(.nextWord)) != nil)
                    record("settings-toggle-updates-pause-selection", await press("select-word-on-pause", in: sheet) && !model.viewing.selectWordOnPause)
                    screenshot("pause-selection-setting", in: sheet)
                } else { record("advanced-settings-opens", false) }
                model.showSettings = false; await delay()
            }
            await model.store?.flush()
        }
        let result: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(restore ? "restore.json" : "learning-card.json"))
        NSApp.terminate(nil)
    }
}
