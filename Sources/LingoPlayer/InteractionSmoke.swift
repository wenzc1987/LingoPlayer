import AppKit
import PlayerCore

/// Explicit, isolated-state diagnostic launch; never executes in normal use.
@MainActor
enum InteractionSmoke {
    static func run(model: AppModel, window: NSWindow, keyboard: KeyboardRouter, folder: URL, output: URL, restoreOnly: Bool,
                    detach: () -> Void, learningWindow: () -> NSWindow?, closeDetached: () -> Void) async {
        var checks: [[String: Any]] = []
        let start = Date()
        func record(_ name: String, _ passed: Bool, _ detail: String = "") { checks.append(["name": name, "passed": passed, "detail": detail]) }
        func delay(_ seconds: Double = 0.2) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        func wait(_ timeout: Double = 8, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline { if condition() { return true }; await delay(0.05) }
            return condition()
        }
        func ready(_ name: String) async -> Bool { await wait { model.media?.title == URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent && model.playbackReady && model.duration > 0 } }
        func event(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], in target: NSWindow? = nil) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: (target ?? window).windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        func press(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], in target: NSWindow? = nil) async {
            let target = target ?? window
            target.makeKeyAndOrderFront(nil); target.makeFirstResponder(target.contentView); target.becomeKey()
            NSApp.postEvent(event(code, characters, flags, in: target), atStart: false); await delay()
        }
        func screenshot(_ target: NSWindow, _ name: String) {
            WindowSnapshot.save(target, to: output.appendingPathComponent(name))
        }
        let one = folder.appendingPathComponent("Episode1.mp4"), two = folder.appendingPathComponent("Episode2.mp4"), ten = folder.appendingPathComponent("Episode10.mp4")
        model.settings.autoSearch = false; model.settings.mfa = "/missing/mfa-for-interaction-test"
        model.setVolume(0)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if restoreOnly {
            model.restoreQueue()
            let loaded = await ready("Episode2.mp4")
            await delay(0.5)
            record("restart_restores_order_current_and_position_paused", loaded && model.paused && abs(model.position - 1.25) < 0.2 && model.queueState.items.map(\.name) == ["Episode10.mp4", "Episode2.mp4", "Episode1.mp4"], "position=\(model.position), paused=\(model.paused), items=\(model.queueState.items.map(\.name))")
            let before = model.position; await delay(0.6)
            record("restart_stays_paused_without_playing", model.position == before && !model.endGate.wantsPlayback)
            record("shortcuts_and_autoplay_restore_in_new_process", !model.preferences.autoplay && model.preferences.shortcut(for: .playPause)?.key == "k")
            screenshot(window, "restored.png")
        } else {
            let appIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            let iconBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 512, bitsPerPixel: 32)!
            if let context = NSGraphicsContext(bitmapImageRep: iconBitmap) {
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                appIcon.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128)); NSGraphicsContext.restoreGraphicsState()
                try? iconBitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("finder-icon.png"))
            }
            var limePixels = 0
            for x in 0..<128 { for y in 0..<128 {
                if let color = iconBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.greenComponent > 0.7 && color.redComponent > 0.5 && color.blueComponent < 0.6 { limePixels += 1 }
            } }
            record("finder_icon_resolves_lime_artwork", limePixels > 500, "\(limePixels) lime pixels")
            record("app_version_and_dock_icon_packaged", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "0.3.1" && NSApp.applicationIconImage != nil && Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil)
            NSApp.orderFrontStandardAboutPanel(nil); await delay(0.3)
            if let about = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.frame.height < 500 }) {
                screenshot(about, "about.png"); about.orderOut(nil)
                record("native_about_window_opens", true)
            } else { record("native_about_window_opens", false) }
            window.makeKeyAndOrderFront(nil)
            model.clearQueue()
            let dropped: [URL] = await withCheckedContinuation { continuation in
                FileDropReader.read([NSItemProvider(object: two as NSURL), NSItemProvider(object: one as NSURL)]) { continuation.resume(returning: $0) }
            }
            record("multi_file_drop_decodes_all_urls", Set(dropped.map(\.path)) == Set([one.path, two.path]))
            var prefs = InteractionPreferences(); prefs.autoplay = false; model.updatePreferences(prefs)
            model.ingest([ten, two, one, two])
            record("batch_natural_sort_dedup_and_first_play", await ready("Episode1.mp4") && model.queueState.items.map(\.name) == ["Episode1.mp4", "Episode2.mp4", "Episode10.mp4"], model.alert ?? model.queueMessage)
            _ = await wait { !model.english.isEmpty }
            await press(35, "p", .command)
            record("main_window_shortcut_toggles_once", model.paused && !model.endGate.wantsPlayback)
            model.ingest([two], adding: true)
            record("add_does_not_interrupt", model.media?.path == one.path && model.paused && model.queueState.items.count == 3)
            model.moveQueueItem(ten.path, before: one.path)
            record("reorder_preserves_current", model.queueState.items.first?.id == ten.path && model.media?.path == one.path)
            model.removeQueueItem(ten.path)
            record("remove_noncurrent_keeps_playback", model.media?.path == one.path && model.paused)
            model.removeQueueItem(one.path)
            record("remove_current_plays_original_successor", await ready("Episode2.mp4"))
            model.clearQueue(); await delay()
            record("clear_stops_and_clears_learning", model.media == nil && model.queueState.items.isEmpty && model.selected == nil && model.paused)
            model.ingest([one, two, ten]); _ = await ready("Episode1.mp4")
            model.perform(.playPause); await delay()
            // The active key recorder consumes both conflicts and Escape.
            model.settingsPage = 1; model.showSettings = true; await delay(0.4)
            model.recordingAction = .playPause
            _ = keyboard.handle(event(15, "r", .command))
            record("recorder_conflict_preserves_existing_binding", model.shortcutMessage.contains("冲突") && model.preferences.shortcut(for: .playPause) == PlayerAction.playPause.defaultShortcut)
            _ = keyboard.handle(event(53, "\u{1b}"))
            record("recorder_escape_cancels", model.recordingAction == nil)
            model.bind(nil, to: .playPause)
            record("clear_binding", model.preferences.shortcut(for: .playPause) == nil)
            model.bind(PlayerAction.playPause.defaultShortcut, to: .playPause)
            model.recordingAction = .playPause
            _ = keyboard.handle(event(40, "k", .command))
            record("recorded_binding_updates_menu_immediately", NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] }.first { ($0.representedObject as? String) == PlayerAction.playPause.rawValue }?.keyEquivalent == "k")
            await delay(0.3)
            screenshot(window.attachedSheet ?? window, "shortcuts.png")
            model.resetShortcuts()
            record("reset_all_defaults", model.preferences.shortcut(for: .playPause) == PlayerAction.playPause.defaultShortcut)
            let pausedBefore = model.paused
            let blockedSheet = keyboard.handle(event(35, "p", .command)) != nil
            record("settings_sheet_blocks_player_keys", blockedSheet && model.paused == pausedBefore)
            model.showSettings = false; await delay(0.4)
            window.makeKeyAndOrderFront(nil)
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 40))
            window.contentView?.addSubview(editor); window.makeFirstResponder(editor)
            editor.string = "English 中文"
            editor.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            record("marked_text_and_editing_keep_native_keys", keyboard.handle(event(123, "\u{f702}")) != nil && keyboard.handle(event(35, "p", .command)) != nil && model.paused == pausedBefore)
            editor.removeFromSuperview(); window.makeFirstResponder(window.contentView)
            model.showSubtitleControls = true
            record("popover_blocks_navigation_keys", keyboard.handle(event(124, "\u{f703}")) != nil)
            model.showSubtitleControls = false
            detach(); await delay(0.3)
            record("detach_selects_queue_tab", model.isDetached && model.sidebarTab == .queue)
            if let target = learningWindow() {
                await press(35, "p", .command, in: target)
                record("detached_window_shortcut", !model.paused)
                await press(35, "p", .command, in: target)
            }
            closeDetached(); await delay(0.2)
            record("close_detached_restores_learning_tab", !model.isDetached && model.sidebarTab == .learning)
            await press(37, "l", .command)
            record("sidebar_shortcut", model.sidebarTab == .transcript)
            await press(37, "l", .command)
            record("sidebar_three_tab_cycle", model.sidebarTab == .queue)
            screenshot(window, "queue.png")
            // Play intent remains paused during sentence navigation, and the locked word survives.
            model.setOffset(0.25, language: .english)
            _ = await wait { model.english.count == 2 }
            if let cue = model.english.first, let word = cue.tokens.first(where: \.isWord) {
                model.lock(cue: cue, token: word); let locked = model.selected
                model.seek(1.6); await delay(0.2); model.perform(.previousSentence)
                let previous = await wait { abs(model.position - (cue.start + 0.25)) < 0.15 }
                model.perform(.nextSentence)
                let next = await wait { abs(model.position - 2.25) < 0.15 }
                record("sentence_navigation_offset_gap_preserves_lock_pause", previous && next && model.paused && model.selected == locked)
            } else { record("sentence_navigation_offset_gap_preserves_lock_pause", false, "No subtitle cues") }
            model.setOffset(0, language: .english)
            // True natural EOF skips corrupt and missing entries, advances once, then stops at tail.
            model.clearQueue(); prefs.autoplay = true; model.updatePreferences(prefs)
            let corrupt = folder.appendingPathComponent("Episode3.mp4"), missing = folder.appendingPathComponent("Episode4.mp4")
            model.ingest([ten, missing, corrupt, one])
            _ = await ready("Episode1.mp4")
            model.seek(model.duration - 0.45)
            let advanced = await wait(12) { model.media?.path == ten.path && model.playbackReady }
            record("natural_eof_skips_unavailable_and_advances_once", advanced && model.queueState.items.filter { $0.failure != nil }.count == 2, model.queueMessage)
            record("natural_finish_remembered", model.progress[one.path]?.finished == true)
            let ended = await wait(8) { model.completed && model.paused }
            await delay(0.3)
            record("queue_tail_stops_without_loop", ended && model.media?.path == ten.path)
            model.playQueueItem(one.path)
            _ = await ready("Episode1.mp4")
            record("completed_video_reopens_from_start", model.position < 1)
            model.seek(model.duration)
            await delay(2.2)
            record("scrub_to_end_does_not_autoplay", model.media?.path == one.path && model.paused && !model.completed)
            let tail = SubtitleCue(id: "tail", start: model.duration - 0.5, end: model.duration + 1, text: "Final word")
            model.lock(cue: tail, token: tail.tokens[0]); let locked = model.selected
            model.replaySentence()
            let replay = await wait(5) { model.paused && model.position > model.duration - 0.15 }
            await delay(0.4)
            record("sentence_replay_at_eof_never_autoplays", replay && model.media?.path == one.path && model.selected == locked && !model.completed)
            model.removeQueueItem(ten.path); model.removeQueueItem(corrupt.path); model.removeQueueItem(missing.path)
            model.removeQueueItem(one.path); await delay()
            record("remove_last_current_stops", model.media == nil && model.paused)
            model.ingest([corrupt, missing]); await delay(1)
            record("all_unavailable_stop_with_message", model.media == nil && !model.queueMessage.isEmpty)
            model.clearQueue(); prefs.autoplay = false; model.updatePreferences(prefs)
            model.ingest([one, two, ten]); model.playQueueItem(two.path); model.playQueueItem(one.path); model.playQueueItem(two.path)
            let rapid = await ready("Episode2.mp4")
            _ = await wait { model.english.first?.text == "Second episode." }
            record("rapid_switch_filters_old_media_and_subtitles", rapid && model.english.first?.text == "Second episode." && !model.learning.isLocked, model.englishSource)
            model.seek(model.duration - 0.3)
            let noAuto = await wait(5) { model.completed && model.paused }
            record("autoplay_off_stays_on_current", noAuto && model.media?.path == two.path)
            // Persist a known order/current/position; the next *process* verifies paused restoration.
            model.playQueueItem(two.path); _ = await ready("Episode2.mp4")
            model.perform(.playPause); model.seek(1.25); await delay(0.4)
            model.moveQueueItem(ten.path, before: one.path); model.moveQueueItem(two.path, before: one.path)
            model.bind(Shortcut(40, "k", .command), to: .playPause)
            model.savePlayback()
            record("resume_position_saved_for_restart", model.paused && abs(model.position - 1.25) < 0.2)
        }
        let result: [String: Any] = ["version": "0.3.1", "passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "elapsed_seconds": Date().timeIntervalSince(start), "checks": checks]
        let name = restoreOnly ? "restore.json" : "interaction.json"
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent(name)) }
        NSApp.terminate(nil)
    }
}
