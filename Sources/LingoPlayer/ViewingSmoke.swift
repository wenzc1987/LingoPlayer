import AppKit
import PlayerCore

@MainActor enum ViewingSmoke {
    static func run(model: AppModel, window: NSWindow, video: URL, output: URL, restore: Bool) async {
        window.ignoresMouseEvents = true
        var checks: [[String: Any]] = []
        func record(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail]); print(name, passed, detail); fflush(stdout)
        }
        func delay(_ seconds: Double = 0.2) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        func wait(_ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline { if condition() { return true }; await delay(0.025) }; return condition()
        }
        func element(_ root: NSObject, id: String, depth: Int = 0) -> NSObject? {
            guard depth < 35 else { return nil }
            let identifier = NSSelectorFromString("accessibilityIdentifier"), children = NSSelectorFromString("accessibilityChildren")
            if root.responds(to: identifier), root.perform(identifier)?.takeUnretainedValue() as? String == id { return root }
            if root.responds(to: children), let items = root.perform(children)?.takeUnretainedValue() as? [Any] {
                for case let item as NSObject in items { if let found = element(item, id: id, depth: depth + 1) { return found } }
            }
            return nil
        }
        func find(_ id: String) -> (NSWindow, NSObject)? {
            for target in NSApp.windows.filter(\.isVisible) { if let found = element(target, id: id) { return (target, found) } }
            return nil
        }
        func click(_ id: String) async -> Bool {
            guard let (target, node) = find(id), let frame = node.value(forKey: "accessibilityFrame") as? NSValue else { return false }
            let rect = frame.rectValue, point = target.convertPoint(fromScreen: CGPoint(x: frame.rectValue.midX, y: frame.rectValue.midY))
            guard !rect.isEmpty else { return false }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!, atStart: false)
                await delay(0.04)
            }
            await delay(); return true
        }
        func increment(_ id: String) -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformIncrement")
            guard let (_, node) = find(id), node.responds(to: selector) else { return false }
            _ = node.perform(selector); return true
        }
        func screenshot(_ name: String) { record("screenshot_" + name, WindowSnapshot.save(window, to: output.appendingPathComponent(name + ".png"))) }
        func settingsScreenshot(_ name: String) {
            let saved = find("playback-settings-page").map { WindowSnapshot.save($0.0, to: output.appendingPathComponent(name + ".png")) } ?? false
            record("screenshot_" + name, saved)
        }
        let expectedStyle = SubtitleAppearance(englishSize: 32, chineseSize: 24, backgroundOpacity: 0.65, bottomInset: 96)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        model.settings.autoSearch = false; model.settings.mfa = "/missing/viewing-smoke"; model.player.set("mute", "yes")
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        if restore {
            record("volume_and_speed_restore_in_new_process", model.volume == 37 && model.speed == 1.5)
            record("appearance_and_link_restore_in_new_process", model.viewing.subtitles == expectedStyle && model.viewing.linkedSubtitleOffsets)
            let size = window.contentView!.bounds.size
            record("window_size_restores_in_new_process", abs(size.width - 1100) < 1 && abs(size.height - 720) < 1, "\(size)")
        }
        model.open(video)
        let loaded = await wait { model.playbackReady && !model.english.isEmpty && model.videoView.renderedFrames > 2 }
        record("video_loaded", loaded)
        if loaded {
            await model.openTask?.value
            if model.endGate.wantsPlayback { model.togglePlayback() }
            model.setSidebarCollapsed(true); model.seek(1)
            _ = await wait { model.seekTarget == nil }; model.chrome.show(); await delay(0.4)
            if restore {
                record("saved_audio_preferences_survive_media_load", model.volume == 37 && model.speed == 1.5)
                record("saved_offsets_restore_independently_of_global_preferences", model.englishOffset == -0.3 && model.chineseOffset == 0.4)
                screenshot("restored")
            } else {
                model.setOffset(-0.25, language: .english); model.setOffset(0.4, language: .chinese)
                record("settings_opens", await click("quick-settings") && model.showSubtitleControls)
                record("offset_status_visible", find("subtitle-offset-status") != nil && model.subtitleOffsetStatus == "已生效")
                settingsScreenshot("timing-settings")
                let linkClicked = await click("link-subtitle-offsets")
                record("native_link_toggle", linkClicked && model.viewing.linkedSubtitleOffsets)
                let first = increment("subtitle-offset-english")
                record("linked_step_keeps_legacy_language_gap_and_waits", first && abs((model.pendingSubtitleOffsets[.english] ?? 0) + 0.15) < 1e-9 && abs((model.pendingSubtitleOffsets[.chinese] ?? 0) - 0.5) < 1e-9 && model.englishOffset == -0.25 && model.chineseOffset == 0.4 && model.subtitleOffsetStatus == "等待生效")
                let second = increment("subtitle-offset-chinese")
                await delay(1.15)
                record("either_language_can_drive_linked_adjustment", second && abs(model.englishOffset + 0.05) < 1e-9 && abs(model.chineseOffset - 0.6) < 1e-9 && model.subtitleOffsetStatus == "已生效")
                let reset = await click("reset-subtitle-offsets")
                record("reset_is_debounced", reset && !model.pendingSubtitleOffsets.isEmpty && model.englishOffset != 0)
                await delay(1.1)
                record("reset_clears_both_offsets", model.englishOffset == 0 && model.chineseOffset == 0 && model.subtitleOffsetStatus == "已生效")
                _ = await click("link-subtitle-offsets")
                model.scheduleSubtitleOffset(-0.2, language: .english); await delay(1.1)
                record("unlinked_adjustment_leaves_other_language_unchanged", !model.viewing.linkedSubtitleOffsets && model.englishOffset == -0.2 && model.chineseOffset == 0)
                // Segmented control children carry their visible labels instead
                // of a stable identifier; find the tab through accessibility.
                if let (_, picker) = find("playback-settings-page") {
                    let children = NSSelectorFromString("accessibilityChildren")
                    if picker.responds(to: children), let segments = picker.perform(children)?.takeUnretainedValue() as? [NSObject], segments.count >= 2, segments[1].responds(to: NSSelectorFromString("accessibilityPerformPress")) {
                        _ = segments[1].perform(NSSelectorFromString("accessibilityPerformPress"))
                    }
                }
                await delay()
                record("appearance_tab_has_live_preview", find("subtitle-appearance-preview") != nil)
                let fontStep = increment("subtitle-english-size")
                record("native_font_slider_changes_style", fontStep && model.viewing.subtitles.englishSize > 23)
                await delay(); settingsScreenshot("appearance-settings")
                model.showSubtitleControls = false
                let originalFrame = model.videoView.bounds.size
                let wordID = "subtitle-word-\(model.english[0].id)-\(model.english[0].tokens.first(where: \.isWord)!.id)"
                func wordFrame() -> CGRect { (element(window, id: wordID)?.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
                await delay(); let before = wordFrame()
                model.viewing.setSubtitles(expectedStyle); await delay(0.4)
                let after = wordFrame()
                record("appearance_changes_live_subtitle_size_and_position", after.height > before.height && after.minY > before.minY && model.videoView.bounds.size == originalFrame, "before=\(before), after=\(after)")
                screenshot("styled")
                model.showSubtitleControls = true; await delay()
                // The same popover retains its page while it stays mounted.
                if find("reset-subtitle-appearance") == nil, let (_, picker) = find("playback-settings-page"), let segments = picker.value(forKey: "accessibilityChildren") as? [NSObject], segments.count >= 2, segments[1].responds(to: NSSelectorFromString("accessibilityPerformPress")) {
                    _ = segments[1].perform(NSSelectorFromString("accessibilityPerformPress")); await delay()
                }
                let defaultClicked = await click("reset-subtitle-appearance")
                record("appearance_reset_restores_only_visual_defaults", defaultClicked && model.viewing.subtitles == SubtitleAppearance() && model.englishOffset == -0.2)
                model.showSubtitleControls = false
                model.viewing.setSubtitles(expectedStyle)
                window.setContentSize(NSSize(width: 980, height: 640)); model.openSidebar(.learning)
                let originalEnglish = model.english
                let longCue = SubtitleCue(id: "viewing-long", start: 0, end: model.duration, text: "Sometimes it takes a little time to understand what someone is saying, so we can listen again and learn together.")
                model.english = [longCue]; model.learning.resumeFollowing(); model.refreshLearning(); await delay(0.4)
                let words = longCue.tokens.filter(\.isWord).compactMap { (element(window, id: "subtitle-word-\(longCue.id)-\($0.id)")?.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue }
                let controls = (element(window, id: "action-playPause")?.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
                // Raised, tall captions may put the controls below them. Both
                // placements are intentional in VideoContentGeometry; overlap
                // and off-window word hit targets are the regressions to catch.
                let separated = words.allSatisfy { $0.maxY < controls.minY } || words.allSatisfy { $0.minY > controls.maxY }
                record("large_subtitles_do_not_overlap_controls_in_small_window", words.count == longCue.tokens.filter(\.isWord).count && separated && words.allSatisfy { window.frame.contains($0) })
                var stableHighlightLayout = !words.isEmpty
                for token in longCue.tokens.filter(\.isWord) {
                    model.currentWordID = "\(longCue.id):\(token.id)"; await delay(0.025)
                    let highlighted = longCue.tokens.filter(\.isWord).compactMap { (element(window, id: "subtitle-word-\(longCue.id)-\($0.id)")?.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue }
                    stableHighlightLayout = stableHighlightLayout && highlighted == words
                }
                model.currentWordID = nil
                record("word_highlights_preserve_wrapping_and_hit_targets", stableHighlightLayout)
                screenshot("large-subtitles")
                model.english = originalEnglish; model.refreshLearning(); model.setSidebarCollapsed(true)
                window.setContentSize(NSSize(width: 1100, height: 720)); await delay(0.3)
                record("normal_window_size_is_remembered", model.viewing.windowSize == PlayerWindowSize(width: 1100, height: 720), "\(model.viewing.windowSize)")
                window.toggleFullScreen(nil); let full = await wait { window.styleMask.contains(.fullScreen) }; await delay(0.8)
                record("fullscreen_does_not_overwrite_normal_size", full && model.viewing.windowSize == PlayerWindowSize(width: 1100, height: 720))
                if full { window.toggleFullScreen(nil); _ = await wait { !window.styleMask.contains(.fullScreen) }; await delay(0.8) }
                model.setVolume(0); await model.store?.flush()
                let muted = (try? Data(contentsOf: ViewingPreferencesStore.url)).flatMap { try? JSONDecoder().decode(ViewingPreferences.self, from: $0) }
                record("zero_volume_is_persisted", muted?.volume == 0)
                model.setVolume(37); model.setSpeed(1.5)
                model.setOffset(-0.3, language: .english); model.setOffset(0.4, language: .chinese)
                model.viewing.setLinkedOffsets(true)
            }
        }
        await model.store?.flush()
        let result: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(restore ? "viewing-restore.json" : "viewing.json"))
        NSApp.terminate(nil)
    }
}
