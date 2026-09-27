import AppKit
import PlayerCore

/// Explicit isolated diagnostics; normal launches never mutate state through this runner.
@MainActor
enum PracticeSmoke {
    static func run(model: AppModel, window: NSWindow, keyboard: KeyboardRouter, folder: URL, output: URL, restoreOnly: Bool,
                    detach: () -> Void, learningWindow: () -> NSWindow?, closeDetached: () -> Void) async {
        var checks: [[String: Any]] = [], metrics: [String: Double] = [:]
        let started = Date()
        func record(_ name: String, _ passed: Bool, _ detail: String = "") { checks.append(["name": name, "passed": passed, "detail": detail]) }
        func delay(_ seconds: Double = 0.2) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        func wait(_ timeout: Double = 8, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline { if condition() { return true }; await delay(0.025) }
            return condition()
        }
        func views(_ root: NSView?) -> [NSView] { guard let root else { return [] }; return [root] + root.subviews.flatMap { views($0) } }
        func event(_ code: UInt16, _ key: String, _ flags: NSEvent.ModifierFlags = [], _ target: NSWindow? = nil) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: (target ?? window).windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
        }
        func press(_ code: UInt16, _ key: String, _ flags: NSEvent.ModifierFlags = [], _ target: NSWindow? = nil) async {
            let target = target ?? window
            NSApp.activate(ignoringOtherApps: true); target.makeKeyAndOrderFront(nil); target.becomeKey()
            _ = await wait { NSApp.keyWindow === target && target.attachedSheet == nil }
            // These are command-behavior checks. The separate KeyboardSmoke keeps
            // real text/control focus and verifies routing without resetting it.
            target.makeFirstResponder(nil); target.makeFirstResponder(target)
            NSApp.postEvent(event(code, key, flags, target), atStart: false); await delay()
        }
        func pause() async {
            if model.endGate.wantsPlayback { model.togglePlayback() }
            _ = await wait { model.seekTarget == nil && model.paused }
            await delay(0.15)
        }
        func screenshot(_ name: String) {
            WindowSnapshot.save(window, to: output.appendingPathComponent(name))
        }
        let one = folder.appendingPathComponent("Practice1.mp4"), two = folder.appendingPathComponent("Practice2.mp4")
        model.settings.autoSearch = false; model.settings.mfa = "/missing/mfa-for-practice-test"; model.setVolume(0)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if restoreOnly {
            model.restoreQueue()
            let loaded = await wait { model.playbackReady && model.media?.path == one.path && model.duration > 0 }
            await delay(0.6)
            record("restart_paused_with_display_preference_and_no_loop", loaded && model.paused && !model.endGate.wantsPlayback && model.sentenceLoop == nil && model.preferences.subtitleDisplay == .hidden)
            record("restart_resets_search_and_following", model.transcript.query.isEmpty && model.transcript.following && model.sidebarTab == .learning)
            record("new_action_custom_bindings_restore", model.preferences.shortcut(for: .toggleSentenceLoop)?.key == "t" && model.preferences.shortcut(for: .cycleSubtitleDisplay)?.key == "d")
            record("restart_keeps_queue_and_unfinished_progress", model.queueState.items.count == 2 && model.progress[one.path]?.finished == false && model.position > 0)
        } else {
            record("v02_custom_bindings_win_new_default_conflicts", model.preferences.shortcut(for: .toggleSentenceLoop) == nil && model.preferences.shortcut(for: .cycleSubtitleDisplay) == nil && model.preferences.conflictNotices.count == 2 && model.shortcutMessage.contains("冲突"))
            model.resetShortcuts(); model.ingest([one, two])
            let loaded = await wait { model.playbackReady && model.english.count == 3 && model.chinese.count == 3 && !model.transcript.isPreparing && model.transcript.document.rows.count == 4 }
            await pause(); model.setSidebarCollapsed(false); model.sidebarTab = .transcript; await delay(0.4)
            record("independent_files_overlap_and_unmatched_chinese", loaded && model.transcript.document.rows.filter { $0.chineseText.contains("跨两句") }.count == 2 && model.transcript.document.rows.filter { $0.english == nil }.count == 1)
            if let first = model.english.first, let second = model.english.dropFirst().first, let tail = model.english.last {
                model.transcript.query = "FIRST [SENTENCE]"
                record("literal_case_insensitive_search", await wait { !model.transcript.isSearching && model.transcript.rows.count == 1 } && !model.transcript.following)
                model.transcript.query = "跨两句"
                record("chinese_search_returns_both_overlaps", await wait { !model.transcript.isSearching && model.transcript.rows.count == 2 })
                model.transcript.query = ".*"
                record("literal_no_results", await wait { !model.transcript.isSearching && model.transcript.rows.isEmpty })
                model.transcript.returnToCurrent(); await delay()
                record("return_current_clears_search_and_resumes_following", model.transcript.query.isEmpty && model.transcript.following && model.transcript.rows.count == 4)
                model.lock(cue: first, token: first.tokens.first(where: \.isWord)!); let locked = model.selected
                if let row = model.transcript.document.rows.first(where: { $0.english?.id == second.id }) { model.navigateTranscript(row) }
                record("timestamp_navigation_preserves_pause_and_locked_card", await wait { model.seekTarget == nil } && model.paused && abs(model.position - 2) < 0.15 && model.selected == locked)
                model.startSentenceLoop(first)
                record("continuous_loop_plays_and_preserves_locked_card", await wait(7) { model.loopIterations >= 3 } && model.sentenceLoop?.cueID == first.id && model.selected == locked)
                await pause(); let pausedPosition = model.position, count = model.loopIterations; await delay(0.4)
                record("pause_preserves_loop_and_position", model.sentenceLoop != nil && model.paused && model.position == pausedPosition && model.loopIterations == count, "position=\(pausedPosition) → \(model.position), loops=\(count) → \(model.loopIterations)")
                model.perform(.nextSentence)
                record("next_sentence_retargets_paused_loop", await wait { model.seekTarget == nil } && model.sentenceLoop?.cueID == second.id && model.paused && model.selected == locked)
                model.perform(.previousSentence)
                record("previous_sentence_retargets_paused_loop", await wait { model.seekTarget == nil } && model.sentenceLoop?.cueID == first.id && model.paused && model.selected == locked)
                if let row = model.transcript.document.rows.first(where: { $0.english?.id == second.id }) { model.navigateTranscript(row) }
                record("timestamp_retargets_existing_loop", await wait { model.seekTarget == nil } && model.sentenceLoop?.cueID == second.id && model.paused && model.selected == locked)
                let beforeCancel = model.position; model.toggleSentenceLoop(); await delay()
                record("toggle_off_preserves_position_and_pause", model.sentenceLoop == nil && model.paused && abs(model.position - beforeCancel) < 0.05)
                model.seek(1.5); _ = await wait { model.seekTarget == nil }
                record("gap_disables_toolbar_loop_but_row_can_start", !model.canPerform(.toggleSentenceLoop))
                model.startSentenceLoop(second); await delay(0.1); model.resumeLearning()
                record("continue_learning_exits_loop_and_unlocks", model.sentenceLoop == nil && !model.learning.isLocked && model.endGate.wantsPlayback)
                model.lock(cue: first, token: first.tokens.first(where: \.isWord)!)
                model.startSentenceLoop(second); model.replaySentence()
                record("one_shot_exits_loop_and_pauses_with_card", await wait(4) { model.paused && model.replayRange == nil } && model.sentenceLoop == nil && model.selected?.cue.id == first.id)
                model.startSentenceLoop(first); model.seek(1.4); await pause()
                record("scrub_exits_loop", model.sentenceLoop == nil)
                model.startSentenceLoop(first); model.perform(.forward); await pause()
                record("five_second_jump_exits_loop", model.sentenceLoop == nil)
                model.startSentenceLoop(first); model.setOffset(0.3, language: .chinese)
                record("chinese_offset_keeps_loop", model.sentenceLoop != nil)
                model.setOffset(0.25, language: .english)
                _ = await wait { !model.transcript.isPreparing }
                record("english_offset_exits_loop_and_updates_jump", model.sentenceLoop == nil && model.transcript.document.rows.first(where: { $0.english?.id == first.id })?.start == 0.45)
                model.startSentenceLoop(first)
                record("loop_uses_english_offset_and_independent_tail", model.sentenceLoop?.start == 0.45 && abs((model.sentenceLoop?.end ?? 0) - 2.05) < 0.001)
                if let audio = model.audioStreams.first { model.selectAudio(audio.id) }
                record("audio_selection_exits_loop", model.sentenceLoop == nil)
                model.setOffset(0, language: .english); model.setOffset(0, language: .chinese)
                model.setSpeed(2); model.startSentenceLoop(tail)
                let tailPassed = await wait(18) { model.loopIterations >= 20 || model.sentenceLoop == nil || model.media?.path != one.path }
                model.savePlayback(); metrics["tail_loop_iterations"] = Double(model.loopIterations)
                record("twenty_tail_loops_at_double_speed_never_autoplay_or_finish", tailPassed && model.loopIterations >= 20 && model.media?.path == one.path && !model.completed && model.progress[one.path]?.finished == false && model.sentenceLoop?.end == model.duration, "iterations=\(model.loopIterations), position=\(model.position), \(model.practiceMessage)")
                await pause(); model.navigateSentence(first); _ = await wait { model.seekTarget == nil }
                let position = model.position, revision = model.seekRevision
                model.receive(PlaybackSnapshot(generation: model.sessionID, path: one.path, position: model.duration, duration: model.duration, paused: false, loaded: true, eof: true, error: nil, seekRevision: revision - 1))
                record("old_loop_seek_result_is_ignored", model.position == position && model.sentenceLoop?.cueID == first.id && model.paused)
                model.cancelSentenceLoop(); model.setSpeed(1)
                model.seek(0.4); _ = await wait { model.seekTarget == nil }; model.refreshLearning()
                let en = model.activeEnglish, zh = model.activeChinese, dictionary = model.dictionaryEntry, viewFrame = model.videoView.frame
                await press(11, "b", .command)
                record("main_shortcut_cycles_to_english_once", model.preferences.subtitleDisplay == .english)
                screenshot("english.png")
                await press(11, "b", .command)
                record("hidden_mode_preserves_learning_and_video_geometry", model.preferences.subtitleDisplay == .hidden && model.activeEnglish == en && model.activeChinese == zh && model.dictionaryEntry == dictionary && model.videoView.frame == viewFrame)
                screenshot("hidden.png")
                await press(11, "b", .command)
                record("bilingual_restores_without_geometry_change", model.preferences.subtitleDisplay == .bilingual && model.videoView.frame == viewFrame)
                model.sidebarTab = .transcript; await delay()
                // Use the actual search field's field editor for native input routing.
                if let search = views(window.contentView).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) {
                    window.makeFirstResponder(search); search.selectText(nil)
                    record("search_field_keeps_player_shortcuts_native", keyboard.blocked && keyboard.handle(event(11, "b", .command)) != nil && keyboard.handle(event(15, "r", [.command, .shift])) != nil && model.sentenceLoop == nil)
                    window.makeFirstResponder(window.contentView)
                } else { record("search_field_keeps_player_shortcuts_native", false, "Search text field not found") }
                model.showSettings = true; await delay(0.3)
                record("settings_blocks_new_actions", keyboard.handle(event(11, "b", .command)) != nil && keyboard.handle(event(15, "r", [.command, .shift])) != nil)
                model.showSettings = false; await delay(0.3)
                await press(15, "r", [.command, .shift])
                record("main_shortcut_starts_loop_once", model.sentenceLoop?.cueID == first.id && model.endGate.wantsPlayback)
                detach(); await delay(0.3); model.sidebarTab = .transcript
                if let target = learningWindow() {
                    await press(15, "r", [.command, .shift], target)
                    await press(11, "b", .command, target)
                    record("detached_shortcuts_share_loop_and_display_state", model.sentenceLoop == nil && model.preferences.subtitleDisplay == .english && model.sidebarTab == .transcript)
                } else { record("detached_shortcuts_share_loop_and_display_state", false) }
                closeDetached(); await pause(); model.setSidebarCollapsed(false); model.sidebarTab = .transcript; model.setSubtitleDisplay(.bilingual)
                model.seek(0.4); _ = await wait { model.seekTarget == nil }; await delay(0.3); screenshot("transcript.png")
                window.setContentSize(NSSize(width: 980, height: 640)); await delay(0.3); screenshot("minimum-window.png")
                window.setContentSize(NSSize(width: 1260, height: 800)); await delay(0.2)
                model.startSentenceLoop(first); model.transcript.query = "First"; model.transcript.userScrolled()
                try? await model.attachSubtitle(folder.appendingPathComponent("replacement.srt"), language: nil, onlyMissing: false, session: model.sessionID)
                _ = await wait { !model.transcript.isPreparing }
                record("bilingual_replacement_resets_loop_search_and_browsing", model.sentenceLoop == nil && model.transcript.query.isEmpty && model.transcript.following && model.transcript.document.rows.first?.chineseText == "替换字幕。")
                model.startSentenceLoop(model.english[0]); let oldSession = model.sessionID
                model.playQueueItem(two.path); model.playQueueItem(one.path); model.playQueueItem(two.path)
                let changed = await wait { model.media?.path == two.path && model.playbackReady && model.english.first?.text == "Different movie." && !model.transcript.isPreparing }
                model.receive(PlaybackSnapshot(generation: oldSession, path: one.path, position: 8, duration: 8, paused: false, loaded: true, eof: true, error: nil, seekRevision: model.seekRevision))
                record("rapid_media_switch_clears_loop_and_stale_transcript", changed && model.sentenceLoop == nil && !model.learning.isLocked && model.transcript.document.rows.first?.english?.text == "Different movie.")
            } else { record("required_fixture_cues_loaded", false) }

            // 5,000 real native rows while the actual mpv clock continues. Keep loops
            // local to this short fixture so the long transcript cannot reach EOF.
            model.playQueueItem(one.path)
            _ = await wait { model.media?.path == one.path && model.playbackReady && !model.english.isEmpty }; await pause()
            checks.append(contentsOf: await ReplayTailSmoke.run(model))
            model.english = (0..<5000).map { SubtitleCue(id: "large-\($0)", start: Double($0), end: Double($0) + 0.9, text: "Sentence \($0): Practice listening while reading the transcript.") }
            model.chinese = (0..<5000).map { SubtitleCue(id: "zh-\($0)", start: Double($0), end: Double($0) + 0.8, text: "第 \($0) 句中文练习。") }
            let prepareStart = Date(); model.refreshTranscript(reset: true)
            let prepared = await wait { !model.transcript.isPreparing && model.transcript.rows.count == 5000 }
            metrics["transcript_5000_prepare_seconds"] = Date().timeIntervalSince(prepareStart)
            model.sidebarTab = .transcript; await delay(0.4)
            model.seek(0.1); _ = await wait { model.seekTarget == nil }; model.togglePlayback()
            let clockBefore = model.position, rebuilds = model.transcript.rebuildCount
            var gaps: [Double] = []; var previousTick = Date()
            let heartbeat = Task { @MainActor in
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 20_000_000); let now = Date(); gaps.append(now.timeIntervalSince(previousTick)); previousTick = now }
            }
            let searchStart = Date(); model.transcript.query = "sentence 4999:"
            let searched = await wait { !model.transcript.isSearching && model.transcript.rows.count == 1 }
            metrics["transcript_5000_search_seconds_including_debounce"] = Date().timeIntervalSince(searchStart)
            record("five_thousand_rows_prepare_and_search", prepared && searched && model.transcript.rows.first?.english?.id == "large-4999")
            model.transcript.returnToCurrent(); await delay(0.3)
            if let table = views(window.contentView).compactMap({ $0 as? TranscriptTableView }).first,
               let scroll = table.enclosingScrollView as? TranscriptScrollView {
                if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -200, wheel2: 0, wheel3: 0), let event = NSEvent(cgEvent: cg) { scroll.scrollWheel(with: event) }
                await delay(0.4) // Let AppKit finish the synthetic wheel's scroll animation.
                table.scrollRowToVisible(4900); await delay(0.3)
                // Text heights finish off-main. A preserved reading position is
                // the same row and offset, even if preceding rows change height.
                func readingAnchor() -> (Int, CGFloat) {
                    let y = scroll.contentView.bounds.minY
                    let row = table.row(at: NSPoint(x: 10, y: y + table.intercellSpacing.height + 1))
                    return (row, row >= 0 ? y - table.rect(ofRow: row).minY : y)
                }
                let bounds = scroll.contentView.bounds.origin, anchor = readingAnchor(); await delay(0.5)
                let after = readingAnchor()
                record("native_manual_scroll_stops_automatic_follow", !model.transcript.following && anchor.0 == after.0 && abs(anchor.1 - after.1) < 2 && bounds.y > 1000, "following=\(model.transcript.following), row=\(anchor.0) → \(after.0), offset=\(anchor.1) → \(after.1)")
                record("native_table_virtualizes_large_transcript", table.numberOfRows == 5000 && views(table).filter { $0 is TranscriptCell }.count < 100, "visible cell views=\(views(table).filter { $0 is TranscriptCell }.count)")
                let beforeHiding = readingAnchor()
                model.setSidebarCollapsed(true); await delay(0.25)
                let hiddenActive = model.transcript.activeIDs
                model.seek(5.1); _ = await wait { model.seekTarget == nil }
                record("hidden_transcript_defers_active_row_updates", model.transcript.activeIDs == hiddenActive)
                model.setSidebarCollapsed(false); await delay(0.25)
                let afterShowing = readingAnchor()
                record("reopening_transcript_preserves_manual_reading_position", !model.transcript.following && beforeHiding.0 == afterShowing.0 && abs(beforeHiding.1 - afterShowing.1) < 2)
                record("reopening_transcript_refreshes_current_highlight", model.transcript.activeIDs == model.transcript.document.activeIDs(at: model.position))
                model.transcript.returnToCurrent(); await delay(0.2)
                record("return_current_scrolls_native_table_back", model.transcript.following && scroll.contentView.bounds.origin.y < 1000)
            } else { record("native_transcript_table_exists", false) }
            heartbeat.cancel(); metrics["main_actor_max_gap_seconds"] = gaps.max() ?? 0
            record("playback_advances_during_search_and_scroll_without_rebuild", model.position > clockBefore + 0.5 && model.transcript.rebuildCount == rebuilds && (gaps.max() ?? 0) < 0.5, "clock delta=\(model.position - clockBefore), maximum main actor gap=\(gaps.max() ?? 0)")
            await pause(); screenshot("large-transcript.png")
            model.english = []; model.chinese = [SubtitleCue(id: "only-zh", start: 1, end: 2, text: "只有中文字幕。")]; model.refreshTranscript(reset: true)
            _ = await wait { !model.transcript.isPreparing }
            record("chinese_only_navigation_and_disabled_loop", model.transcript.rows.count == 1 && model.transcript.rows[0].english == nil && !model.canPerform(.toggleSentenceLoop))
            if let row = model.transcript.rows.first { model.navigateTranscript(row) }
            record("chinese_only_timestamp_preserves_pause", await wait { model.seekTarget == nil } && model.paused && abs(model.position - 1) < 0.1)
            // Save real file subtitles again; leave an active loop and a search to
            // prove neither transient state comes back in the next process.
            try? await model.attachSubtitle(folder.appendingPathComponent("Practice1.en.srt"), language: .english, onlyMissing: false, session: model.sessionID)
            try? await model.attachSubtitle(folder.appendingPathComponent("Practice1.zh.srt"), language: .chinese, onlyMissing: false, session: model.sessionID)
            model.setSubtitleDisplay(.hidden)
            model.bind(Shortcut(17, "t", .option), to: .toggleSentenceLoop)
            model.bind(Shortcut(2, "d", .command), to: .cycleSubtitleDisplay)
            model.startSentenceLoop(model.english[1]); await pause(); model.transcript.query = "sentence"
            model.savePlayback()
        }
        let result: [String: Any] = ["version": "0.3.1", "passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "elapsed_seconds": Date().timeIntervalSince(started), "checks": checks, "metrics": metrics]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent(restoreOnly ? "practice-restore.json" : "practice.json"))
        }
        NSApp.terminate(nil)
    }
}
