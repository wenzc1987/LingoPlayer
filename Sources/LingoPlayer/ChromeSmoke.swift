import AppKit
import PlayerCore

@MainActor enum ChromeSmoke {
    static func run(model: AppModel, window: NSWindow, video: URL, output: URL) async {
        window.ignoresMouseEvents = true // Explicitly posted test events still target this window.
        var checks: [[String: Any]] = []
        func record(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail]); print(name, passed, detail); fflush(stdout)
        }
        func delay(_ value: Double = 0.2) async { try? await Task.sleep(nanoseconds: UInt64(value * 1e9)) }
        func wait(_ predicate: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(12)
            while Date() < end { if predicate() { return true }; await delay(0.025) }; return predicate()
        }
        func screenshot(_ name: String) { record("screenshot_" + name, WindowSnapshot.save(window, to: output.appendingPathComponent(name + ".png"))) }
        func element(_ root: NSObject, id: String, depth: Int = 0) -> NSObject? {
            guard depth < 30 else { return nil }
            let identifier = NSSelectorFromString("accessibilityIdentifier"), children = NSSelectorFromString("accessibilityChildren")
            if root.responds(to: identifier), root.perform(identifier)?.takeUnretainedValue() as? String == id { return root }
            if root.responds(to: children), let items = root.perform(children)?.takeUnretainedValue() as? [Any] {
                for item in items { if let item = item as? NSObject, let found = element(item, id: id, depth: depth + 1) { return found } }
            }
            return nil
        }
        func click(_ point: NSPoint, in target: NSWindow? = nil) async {
            let target = target ?? window
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!, atStart: false)
                await delay(0.04)
            }
            await delay()
        }
        func clickButton(_ id: String) async -> Bool {
            for target in [window] + NSApp.windows.filter({ $0 !== window && $0.isVisible }) {
                guard let button = element(target, id: id), let value = button.value(forKey: "accessibilityFrame") as? NSValue else { continue }
                let rect = value.rectValue
                await click(target.convertPoint(fromScreen: CGPoint(x: rect.midX, y: rect.midY)), in: target); return true
            }
            return false
        }
        func press(_ action: PlayerAction, repeatKey: Bool = false) async {
            guard let shortcut = model.preferences.shortcut(for: action) else { return }
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(nil)
            NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shortcut.menuModifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: shortcut.menuKey, charactersIgnoringModifiers: shortcut.menuKey, isARepeat: repeatKey, keyCode: shortcut.keyCode)!, atStart: false)
            await delay(0.12)
        }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        model.settings.autoSearch = false; model.settings.mfa = "/missing/chrome-smoke"; model.setVolume(0); model.player.set("mute", "yes")
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        screenshot("empty")
        model.open(video)
        let loaded = await wait { model.playbackReady && !model.english.isEmpty && model.videoView.renderedFrames > 2 }
        record("video_loaded", loaded)
        if loaded, let cue = model.english.first, let word = cue.tokens.first(where: \.isWord) {
            if model.endGate.wantsPlayback { model.togglePlayback() }
            model.setSidebarCollapsed(true); model.seek(cue.start + 0.1)
            _ = await wait { model.seekTarget == nil && model.paused }; await delay(0.5)
            model.aligner.cancel(); await model.aligner.waitForCancellation()
            let failureKey = model.alignmentTaskStatus.message
            model.chrome.showNotice("字幕任务状态提示", key: failureKey)
            await delay(5.2)
            model.chrome.showNotice("字幕任务状态提示", key: failureKey)
            record("notice_expires_and_repeated_failure_stays_quiet", model.chrome.notice == nil)
            model.timings = [.init(cueID: cue.id, tokenIndex: word.id, start: cue.start, end: cue.end)]
            model.refreshLearning(); model.chrome.show()
            let stage = model.videoView.bounds.size
            record("video_fills_content_without_reserved_bars", stage.width > window.contentView!.bounds.width - 2 && stage.height >= window.contentView!.bounds.height - 2, "video=\(stage), content=\(window.contentView!.bounds.size)")
            screenshot("paused")
            record("title_visible_with_controls", element(window, id: "playback-title") != nil)
            await delay(3.2); record("paused_controls_stay_visible", model.chrome.visible)
            let midpoint = model.videoView.convert(NSPoint(x: stage.width / 2, y: stage.height / 2), to: nil)
            await click(midpoint)
            record("blank_click_hides_without_playing", !model.chrome.visible && model.paused)
            record("title_hides_with_controls", element(window, id: "playback-title") == nil)
            screenshot("immersive")
            model.setVolume(50); model.chrome.resetFeedback()
            await press(.volumeUp)
            record("volume_shortcut_feedback_without_revealing_controls", model.volume == 55 && model.chrome.feedback?.title == "55%" && model.chrome.feedback?.detail == "音量 +5%" && !model.chrome.visible && element(window, id: "playback-feedback") != nil)
            screenshot("volume-hidden")
            await delay(0.7); await press(.volumeDown, repeatKey: true); await delay(0.7)
            record("repeated_shortcut_replaces_feedback_and_restarts_expiry", model.volume == 50 && model.chrome.feedback?.title == "50%" && model.chrome.feedback?.detail == "音量 -5%")
            await delay(0.8)
            record("feedback_expires_without_changing_hidden_controls", model.chrome.feedback == nil && !model.chrome.visible)
            model.setVolume(100); await press(.volumeUp)
            record("volume_feedback_respects_upper_bound", model.volume == 100 && model.chrome.feedback?.title == "100%" && model.chrome.feedback?.detail == "最大音量")
            model.setVolume(0); await press(.volumeDown)
            record("zero_volume_feedback_is_muted", model.volume == 0 && model.chrome.feedback?.volume == 0 && model.chrome.feedback?.detail == "静音")
            model.setSpeed(1); await press(.faster)
            record("speed_shortcut_reports_current_rate", model.speed == 1.25 && model.chrome.feedback?.title == "1.25×")
            screenshot("speed-feedback"); model.setSpeed(1)
            model.seek(8); _ = await wait { model.seekTarget == nil }
            await press(.forward)
            record("forward_shortcut_reports_delta_and_position", model.chrome.feedback?.title == "+5s" && model.chrome.feedback?.detail == "00:13")
            screenshot("seek-feedback")
            await press(.backward)
            record("backward_shortcut_reports_negative_delta", model.chrome.feedback?.title == "-5s")
            model.seek(1); _ = await wait { model.seekTarget == nil }; await press(.backward)
            record("seek_boundary_reports_actual_change", model.chrome.feedback?.title == "-1s" && model.chrome.feedback?.detail == "00:00")
            await press(.cycleSubtitleDisplay)
            record("subtitle_shortcut_reports_result", model.chrome.feedback?.title == model.preferences.subtitleDisplay.title)
            model.setSubtitleDisplay(.bilingual); model.seek(cue.start + 0.1); model.chrome.resetFeedback()
            _ = await wait { model.seekTarget == nil }; await delay(0.2)
            await click(midpoint)
            record("blank_click_reveals_without_playing", model.chrome.visible && model.paused && model.videoView.bounds.size == stage, "visible=\(model.chrome.visible), paused=\(model.paused), holds=\(model.chrome.state.holds)")
            model.chrome.show(); await delay(0.3)
            await press(.volumeUp)
            record("visible_toolbar_volume_updates_with_feedback", model.volume == 5 && model.chrome.feedback?.volume == 5 && model.chrome.visible && element(window, id: "volume-control") != nil)
            screenshot("volume-visible"); model.setVolume(0); model.chrome.resetFeedback()
            let queueClicked = await clickButton("open-queue")
            record("toolbar_queue_opens_shared_sidebar", queueClicked && !model.preferences.sidebarCollapsed && model.sidebarTab == .queue)
            screenshot("queue")
            let menuClicked = await clickButton("subtitle-menu")
            let transcriptClicked = await clickButton("open-transcript")
            await delay(); screenshot("transcript")
            record("transcript_uses_same_sidebar", menuClicked && transcriptClicked && !model.preferences.sidebarCollapsed && model.sidebarTab == .transcript && stage.width - model.videoView.bounds.width > 300)
            model.setSidebarCollapsed(true); await delay()
            let wordClicked = await clickButton("subtitle-word-\(cue.id)-\(word.id)")
            record("floating_word_click_pauses_and_opens_learning", wordClicked && model.learning.isLocked && model.paused && !model.preferences.sidebarCollapsed && model.sidebarTab == .learning, "clicked=\(wordClicked), locked=\(model.learning.isLocked), collapsed=\(model.preferences.sidebarCollapsed), tab=\(model.sidebarTab)")
            await delay(0.5); screenshot("learning")
            model.resumeLearning(); await delay()
            record("continue_keeps_sidebar_and_unfolded_tab", !model.paused && !model.preferences.sidebarCollapsed && model.sidebarTab == .learning && !model.learning.isLocked)
            // Posted button clicks do not move the physical pointer. Explicitly
            // model leaving the controls for this idle-timer assertion.
            model.chrome.hold(.pointer, active: false)
            model.chrome.hold(.windowButtons, active: false)
            _ = await wait { !model.chrome.visible }
            record("playing_controls_auto_hide", !model.chrome.visible, "paused=\(model.paused), holds=\(model.chrome.state.holds)")
            let hiddenWordClicked = await clickButton("subtitle-word-\(cue.id)-\(word.id)")
            record("word_remains_clickable_with_controls_hidden", hiddenWordClicked && model.learning.isLocked && model.paused && model.chrome.visible)
            model.resumeLearning(); await delay()
            model.chrome.show(); await delay(0.3)
            let settingsClicked = await clickButton("quick-settings"); await delay(3.2)
            record("toolbar_settings_opens_popover", settingsClicked && model.showSubtitleControls)
            record("configuration_prevents_auto_hide", model.chrome.visible && model.chrome.state.holds.contains(.presentation))
            screenshot("settings")
            let oldEnglishOffset = model.englishOffset, oldChineseOffset = model.chineseOffset
            let steppers = NSApp.windows.filter(\.isVisible).compactMap { element($0, id: "subtitle-offset-english") }
            let increment = NSSelectorFromString("accessibilityPerformIncrement")
            if let stepper = steppers.first, stepper.responds(to: increment) {
                _ = stepper.perform(increment)
                record("native_subtitle_stepper_changes_draft_by_tenth", abs(model.subtitleOffsetDraft(.english) - oldEnglishOffset - 0.1) < 0.001 && model.englishOffset == oldEnglishOffset)
            } else { record("native_subtitle_stepper_changes_draft_by_tenth", false, "English stepper increment unavailable") }
            model.setOffset(0.25, language: .english)
            record("legacy_precise_offset_is_preserved_until_adjustment", model.englishOffset == 0.25 && model.subtitleOffsetDraft(.english) == 0.3)
            model.scheduleSubtitleOffset(model.subtitleOffsetDraft(.english) + 0.1, language: .english)
            record("legacy_offset_steps_from_displayed_tenth", model.subtitleOffsetDraft(.english) == 0.4 && model.englishOffset == 0.25)
            model.setOffset(oldEnglishOffset, language: .english)
            model.scheduleSubtitleOffset(-0.1, language: .english)
            await delay(0.65)
            model.scheduleSubtitleOffset(-0.2, language: .english)
            model.scheduleSubtitleOffset(0.3, language: .chinese)
            await delay(0.65)
            record("subtitle_offsets_wait_for_last_adjustment", model.englishOffset == oldEnglishOffset && model.chineseOffset == oldChineseOffset && model.subtitleOffsetDraft(.english) == -0.2 && model.subtitleOffsetDraft(.chinese) == 0.3)
            for (index, popup) in NSApp.windows.filter({ $0 !== window && $0.isVisible && $0.frame.width > 200 }).enumerated() {
                record("screenshot_settings_popup_\(index)", WindowSnapshot.save(popup, to: output.appendingPathComponent("settings-popup-\(index).png")))
            }
            model.showSubtitleControls = false
            await delay(0.55)
            record("subtitle_offsets_apply_after_one_second_even_when_closed", model.englishOffset == -0.2 && model.chineseOffset == 0.3 && model.pendingSubtitleOffsets.isEmpty)
            await model.store?.flush()
            let savedOffsets = try? await model.store?.load(SavedPlayback.self, key: model.media!.key, table: "playback")
            record("debounced_subtitle_offsets_persist", savedOffsets?.englishOffset == -0.2 && savedOffsets?.chineseOffset == 0.3)
            model.setOffset(oldEnglishOffset, language: .english); model.setOffset(oldChineseOffset, language: .chinese)
            model.scheduleSubtitleOffset(oldEnglishOffset + 0.1, language: .english)
            model.scheduleSubtitleOffset(oldEnglishOffset, language: .english)
            record("returning_offset_to_original_cancels_pending_work", model.pendingSubtitleOffsets.isEmpty)
            model.showSubtitleControls = true; await delay()
            model.scheduleSubtitleOffset(-0.3, language: .english)
            model.scheduleSubtitleOffset(0.2, language: .chinese)
            let reprepareClicked = await clickButton("reprepare-alignment")
            record("reprepare_button_preserves_pending_offsets_and_delay", reprepareClicked && model.englishOffset == oldEnglishOffset && model.chineseOffset == oldChineseOffset && model.pendingSubtitleOffsets[.english] == -0.3 && model.pendingSubtitleOffsets[.chinese] == 0.2)
            await delay(0.8)
            record("offsets_still_apply_after_reprepare_button", model.englishOffset == -0.3 && model.chineseOffset == 0.2 && model.pendingSubtitleOffsets.isEmpty)
            await model.store?.flush()
            let reprepareOffsets = try? await model.store?.load(SavedPlayback.self, key: model.media!.key, table: "playback")
            record("offsets_after_reprepare_are_persisted", reprepareOffsets?.englishOffset == -0.3 && reprepareOffsets?.chineseOffset == 0.2)
            model.showSubtitleControls = false
            model.setOffset(oldEnglishOffset, language: .english); model.setOffset(oldChineseOffset, language: .chinese)
            if model.endGate.wantsPlayback { model.togglePlayback() }
            model.setSidebarCollapsed(true); model.setSubtitleDisplay(.hidden); await delay()
            record("hidden_subtitles_do_not_resize_video", model.videoView.bounds.size == stage)
            model.setSubtitleDisplay(.bilingual)
            window.setContentSize(NSSize(width: 980, height: 640)); model.openSidebar(.learning); await delay(0.5)
            screenshot("minimum")
            record("minimum_window_keeps_control_actions_available", element(window, id: "action-playPause") != nil && element(window, id: "open-queue") != nil)
            let originalEnglish = model.english
            let longCue = SubtitleCue(id: "layout-long", start: 0, end: model.duration, text: "Sometimes it takes a little time to understand what someone is saying, so we can listen again and learn together.")
            model.english = [longCue]; model.learning.resumeFollowing(); model.refreshLearning(); await delay(0.3)
            let wordRects = longCue.tokens.filter(\.isWord).compactMap { token -> CGRect? in
                (element(window, id: "subtitle-word-\(longCue.id)-\(token.id)")?.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
            }
            let playRect = (element(window, id: "action-playPause")?.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
            record("long_subtitle_wraps_below_controls", wordRects.count == longCue.tokens.filter(\.isWord).count && (wordRects.first?.minY ?? 0) > (wordRects.last?.minY ?? 0) && wordRects.allSatisfy { $0.maxY < playRect.minY && window.frame.contains($0) })
            screenshot("long-subtitle")
            model.english = originalEnglish; model.refreshLearning()
            model.setSidebarCollapsed(true); window.toggleFullScreen(nil)
            let fullscreen = await wait { window.styleMask.contains(.fullScreen) }; await delay(0.4)
            record("native_fullscreen", fullscreen)
            // The style flag changes before the window-server surface finishes
            // moving to its fullscreen space; wait for the capturable surface.
            record("screenshot_fullscreen", await wait { WindowSnapshot.save(window, to: output.appendingPathComponent("fullscreen.png")) })
            if fullscreen { window.toggleFullScreen(nil); _ = await wait { !window.styleMask.contains(.fullScreen) }; await delay(0.4) }
            model.scheduleSubtitleOffset(2, language: .english); model.setVolume(25)
            model.loadMedia(video, restoring: true)
            record("loading_media_clears_old_feedback_and_offset_drafts", model.chrome.feedback == nil && model.pendingSubtitleOffsets.isEmpty)
            _ = await wait { model.playbackReady }; await delay(1.2)
            record("old_offset_draft_does_not_apply_to_loaded_media", model.englishOffset == oldEnglishOffset)
            // Use the application's real shutdown and storage paths. The final
            // NSApp termination will prepare shutdown again, so it must be safe
            // to repeat without overwriting the flushed draft with old values.
            model.setOffset(0.25, language: .english)
            model.scheduleSubtitleOffset(0.2, language: .chinese)
            await model.prepareShutdown()
            let partialShutdown = try? await model.store?.load(SavedPlayback.self, key: model.media!.key, table: "playback")
            record("shutdown_flushes_draft_without_rounding_untouched_offset", partialShutdown?.englishOffset == 0.25 && partialShutdown?.chineseOffset == 0.2)
            let shutdownPosition = model.position, shutdownTail = model.sentenceTailPadding
            model.scheduleSubtitleOffset(-0.3, language: .english)
            model.scheduleSubtitleOffset(0.4, language: .chinese)
            await model.prepareShutdown()
            let shutdownOffsets = try? await model.store?.load(SavedPlayback.self, key: model.media!.key, table: "playback")
            record("shutdown_saves_both_pending_offsets_and_playback_state", shutdownOffsets?.englishOffset == -0.3 && shutdownOffsets?.chineseOffset == 0.4 && shutdownOffsets?.position == shutdownPosition && shutdownOffsets?.sentenceTailPadding == shutdownTail && model.pendingSubtitleOffsets.isEmpty)
            await delay(1.1); await model.prepareShutdown()
            let repeatedShutdown = try? await model.store?.load(SavedPlayback.self, key: model.media!.key, table: "playback")
            record("repeated_shutdown_keeps_flushed_offsets", repeatedShutdown?.englishOffset == -0.3 && repeatedShutdown?.chineseOffset == 0.4 && model.englishOffset == -0.3 && model.chineseOffset == 0.4)
        }
        let result: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("chrome.json"))
        NSApp.terminate(nil)
    }
}
