import AppKit
import PlayerCore

@MainActor enum DisplaySmoke {
    static func run(model: AppModel, window: NSWindow, folder: URL, output: URL, restore: Bool,
                    detach: () -> Void, closeDetached: () -> Void) async {
        var checks: [[String: Any]] = []
        func record(_ name: String, _ passed: Bool, _ detail: String = "") { checks.append(["name": name, "passed": passed, "detail": detail]) }
        func delay(_ seconds: Double = 0.15) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        func wait(_ seconds: Double = 12, _ predicate: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { if predicate() { return true }; await delay(0.03) }; return predicate()
        }
        func screenshot(_ name: String) {
            WindowSnapshot.save(window, to: output.appendingPathComponent(name))
        }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        model.settings.autoSearch = false; model.settings.mfa = "/missing/display-test"; model.setVolume(0)
        await model.stateTask?.value
        if restore {
            record("hidden_card_and_collapsed_sidebar_survive_restart", model.preferences.cardHidden && model.preferences.sidebarCollapsed)
            model.restoreQueue(); _ = await wait { model.playbackReady && !model.english.isEmpty }
            record("restored_video_paused_without_loop", model.paused && model.sentenceLoop == nil)
            record("loading_video_does_not_reopen_card", model.preferences.cardHidden && model.preferences.sidebarCollapsed)
        } else {
            model.open(folder.appendingPathComponent("Practice1.mp4"))
            let loaded = await wait { model.playbackReady && !model.english.isEmpty }
            record("video_and_subtitles_loaded", loaded)
            if let cue = model.english.first, let token = cue.tokens.first(where: \.isWord) {
                model.startSentenceLoop(cue); model.lock(cue: cue, token: token)
                let loop = model.sentenceLoop; let position = model.position
                model.closeLearningCard()
                record("closing_card_preserves_pause_position_loop", model.paused && model.position == position && model.sentenceLoop == loop && !model.learning.isLocked)
                model.timings = [.init(cueID: cue.id, tokenIndex: token.id, start: cue.start, end: cue.end)]
                model.position = cue.start + 0.05; model.refreshLearning()
                record("closed_card_stays_hidden_but_highlight_updates", model.preferences.cardHidden && model.currentWordID != nil && !model.dictionaryLookup.hasSelection)
                model.setSidebarCollapsed(true); await delay()
                let wide = model.videoView.bounds.width
                model.lock(cue: cue, token: token); await delay()
                record("word_click_reopens_sidebar_card_and_locks", !model.preferences.cardHidden && !model.preferences.sidebarCollapsed && model.sidebarTab == .learning && model.learning.isLocked && model.paused)
                record("collapsed_video_gains_sidebar_width", wide - model.videoView.bounds.width > 300)
                model.sidebarTab = .transcript; model.transcript.query = "First"; await delay(0.3)
                model.setSidebarCollapsed(true); model.setSidebarCollapsed(false)
                record("collapse_preserves_tab_search_and_browsing", model.sidebarTab == .transcript && model.transcript.query == "First" && !model.transcript.following)
                model.setSidebarCollapsed(true); model.perform(.toggleSidebar)
                record("cycle_tabs_unfolds_and_keeps_order", !model.preferences.sidebarCollapsed && model.sidebarTab == .queue)
                detach(); model.setSidebarCollapsed(true); model.closeLearningCard(); model.lock(cue: cue, token: token)
                record("detached_word_click_does_not_unfold_main", model.isDetached && model.preferences.sidebarCollapsed && !model.preferences.cardHidden && model.learning.isLocked)
                closeDetached(); record("reattach_respects_collapsed_sidebar", !model.isDetached && model.preferences.sidebarCollapsed && model.sidebarTab == .learning)
                model.setSidebarCollapsed(false); model.closeLearningCard(); screenshot("card-closed.png")
                model.setSidebarCollapsed(true); await delay(); screenshot("sidebar-collapsed.png")
                model.cancelSentenceLoop(); model.seek(2); if !model.endGate.wantsPlayback { model.togglePlayback() }
                let frames = model.videoView.renderedFrames
                for index in 0..<6 { model.setSidebarCollapsed(index % 2 == 0); await delay(0.1) }
                record("video_keeps_drawing_during_resize", model.videoView.renderedFrames > frames && model.videoView.rendererReady)
                if model.endGate.wantsPlayback { model.togglePlayback() }
            }
            let original = model.settings
            model.settings.python = "/missing/python"
            model.settings.mfa = RuntimeSettings.load().mfa
            model.restartAlignment()
            _ = await wait { model.alignmentTaskStatus.phase == .environmentFailure }
            record("missing_python_has_structured_status_and_log", model.alignmentTaskStatus.message.contains("Python") && model.alignmentTaskStatus.diagnostic != nil)
            model.viewAlignmentDetails(); _ = await wait { model.alignmentDetails.contains("CONFIGURATION") }
            record("details_retain_task_configuration", model.alignmentDetails.contains("/missing/python")); model.showAlignmentDetails = false
            model.settings.python = original.python; model.settings.acousticModel = "/missing/acoustic-model"
            model.restartAlignment(); _ = await wait { model.alignmentTaskStatus.phase == .environmentFailure }
            record("missing_model_is_not_reported_as_python_failure", model.alignmentTaskStatus.message.contains("声学模型"))
            model.settings.acousticModel = original.acousticModel
            let fake = output.appendingPathComponent("diagnostic-worker.py")
            let script = """
            #!/usr/bin/python3
            import sys,json,os,time
            from pathlib import Path
            if os.getpgrp() != os.getpid(): os.setsid()
            request=Path(sys.argv[sys.argv.index('--request')+1]); output=Path(sys.argv[sys.argv.index('--output')+1])
            job=json.loads(request.read_text())
            time.sleep(0.3)
            output.write_text(json.dumps({'words':[],'completed':[c['id'] for c in job['cues']],'failures':{c['id']:'fixture unalignable content' for c in job['cues']},'elapsed':0.3,'peakMemoryMB':1}))
            """
            try? script.write(to: fake, atomically: true, encoding: .utf8); try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            model.settings.python = fake.path; model.retryAlignment()
            _ = await wait { model.alignmentTaskStatus.phase == .partialFailure }
            record("retry_rechecks_environment_and_continues_content_failures", model.alignmentTaskStatus.phase == .partialFailure && model.settings.mfa == RuntimeSettings.load().mfa)
            record("failed_alignment_does_not_block_playback", model.playbackReady)
            model.aligner.cancel(); await model.aligner.waitForCancellation()
            let jobs = (try? FileManager.default.contentsOfDirectory(atPath: RuntimeSettings.supportDirectory.appendingPathComponent("AlignmentJobs").path)) ?? []
            record("cancel_waits_for_job_audio_cleanup", jobs.isEmpty)
            model.settings = original; model.closeLearningCard(); model.setSidebarCollapsed(true); model.savePlayback(); await model.store?.flush()
        }
        let result: [String: Any] = ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "", "passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(restore ? "display-restore.json" : "display.json"))
        NSApp.terminate(nil)
    }
}
