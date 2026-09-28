import AppKit
import PlayerCore
import Darwin

/// Native-window regression with real libmpv playback and independent FFmpeg jobs.
@MainActor enum PlaybackModeSmoke {
    static func run(model: AppModel, window: NSWindow, folder: URL, output: URL, restore: Bool,
                    detach: () -> Void, learningWindow: () -> NSWindow?) async {
        var checks: [[String: Any]] = [], scenarios: [[String: Any]] = []
        func record(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail]); print(name, passed, detail); fflush(stdout)
        }
        func delay(_ seconds: Double = 0.1) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        func wait(_ predicate: () -> Bool, timeout: Double = 12) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline { if predicate() { return true }; await delay(0.02) }; return predicate()
        }
        func find(_ root: NSObject, _ id: String, depth: Int = 0) -> NSObject? {
            guard depth < 40 else { return nil }
            let selector = NSSelectorFromString("accessibilityIdentifier"), children = NSSelectorFromString("accessibilityChildren")
            if root.responds(to: selector), root.perform(selector)?.takeUnretainedValue() as? String == id { return root }
            if root.responds(to: children), let items = root.perform(children)?.takeUnretainedValue() as? [NSObject] {
                for item in items { if let found = find(item, id, depth: depth + 1) { return found } }
            }; return nil
        }
        func attach(_ name: String, language: SubtitleLanguage? = nil) async {
            model.importSubtitle(folder.appendingPathComponent(name), language: language)
            _ = await wait { model.englishSource == name || model.chineseSource == name }
            await delay(); _ = await wait { !model.transcript.isPreparing }
        }
        func load(_ name: String = "Movie.mp4") async {
            model.open(folder.appendingPathComponent(name))
            _ = await wait { model.playbackReady && model.duration > 20 }
            await model.openTask?.value
            if model.endGate.wantsPlayback { model.togglePlayback() }
            await delay(0.2)
        }
        func cpu(_ children: Bool = false) -> Double {
            var usage = rusage(); getrusage(children ? RUSAGE_CHILDREN : RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        func memory() -> Double {
            var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            } }
            return status == KERN_SUCCESS ? Double(info.resident_size) / 1048576 : 0
        }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        window.ignoresMouseEvents = true
        model.settings.autoSearch = false; model.settings.mfa = "/missing/playback-mode-test"; model.player.set("mute", "yes")
        model.chrome.hold(.keyboard, active: true)
        if restore {
            record("restored-new-preferences", model.speed == 3 && !model.viewing.seekPreviewEnabled && model.viewing.learningActivation == .manual)
            await load()
            record("restored-subtitles-rechecked-manual", model.learningEligible && !model.isLearningMode && !model.primarySubtitles.isEmpty)
            record("restored-custom-chinese-overrides-bilingual", model.englishSource == "Bilingual.srt" && model.chineseSource == "Chinese.srt" && model.chineseOffset == 3.4)
            record("restored-user-audio", model.audioStreams.first(where: { $0.id == model.selectedAudio })?.language == "eng")
        } else {
            record("new-defaults", model.viewing.seekPreviewEnabled && model.viewing.learningActivation == .automatic)
            await load()
            record("normal-first-no-learning-work", model.playbackReady && !model.isLearningMode && model.aligner.configurationCount == 0 && model.dictionary == nil)
            record("default-audio-not-english", model.audioStreams.first(where: { $0.id == model.selectedAudio })?.language == "zho")
            for rate in [2.0, 2.5, 3.0, 3.0] {
                if rate == 2 { model.setSpeed(rate) } else { model.perform(.faster) }
                record("faster-\(checks.count)", model.speed == rate)
            }
            for rate in [2.5, 2.0] { model.perform(.slower); record("slower-\(rate)", model.speed == rate) }
            model.setSpeed(0.5); model.perform(.slower); record("speed-lower-bound", model.speed == 0.5)
            model.setSpeed(1)
            for name in ["French.srt", "Spanish.srt", "Japanese.srt", "Chinese.srt", "Short.srt", "Effects.srt"] {
                await attach(name, language: .english) // Intentionally wrong import hint.
                model.seek(2); _ = await wait { model.seekTarget == nil }; model.refreshLearning()
                record("ordinary-\(name)", !model.isLearningMode && !model.learningEligible && !model.subtitles.plain.isEmpty && !model.transcript.rows.isEmpty)
                let revision = model.seekRevision, paused = model.paused
                for action in PlayerAction.allCases where action.requiresLearning { model.perform(action) }
                model.resumeLearning(); model.restartAlignment(); model.retryAlignment(); model.viewAlignmentDetails(); model.replaySentence()
                record("learning-disabled-\(name)", model.seekRevision == revision && model.paused == paused && model.dictionary == nil && model.aligner.configurationCount == 0 && !model.showAlignmentDetails)
                if let row = model.transcript.rows.first { model.navigateTranscript(row); record("ordinary-seek-\(name)", model.seekRevision == revision + 1) }
            }
            await attach("English.srt")
            record("automatic-without-alignment", model.isLearningMode && model.learningEligible && model.timings.isEmpty)
            model.openSidebar(.learning); detach(); await delay()
            record("detached-learning-open", learningWindow() != nil)
            if let cue = model.english.first { model.startSentenceLoop(cue) }
            await delay(0.15)
            let wanted = model.endGate.wantsPlayback, revision = model.seekRevision
            model.chooseLearningMode(false)
            record("exit-preserves-playback", model.endGate.wantsPlayback == wanted && model.seekRevision == revision && model.sentenceLoop == nil && model.replayRange == nil)
            record("exit-cleans-learning", !model.isLearningMode && learningWindow() == nil && model.dictionary == nil && model.learning.selected == nil && model.timings.isEmpty)
            model.aligner.onChange?([TimedWord(cueID: "late", tokenIndex: 0, start: 0, end: 30)], "late")
            model.aligner.onStatus?(AlignmentTaskStatus(.preparing, "late"))
            await attach("English.srt")
            record("manual-exit-survives-callbacks", !model.isLearningMode && model.timings.isEmpty && model.alignmentTaskStatus.phase == .idle)
            model.viewing.setSeekPreviewEnabled(false); model.viewing.setSeekPreviewEnabled(true)
            record("preview-toggle-preserves-mode-override", !model.isLearningMode)
            model.viewing.setLearningActivation(.manual)
            record("manual-policy-stays-normal", !model.isLearningMode && model.learningEligible)
            model.chrome.show(); await delay(0.3)
            _ = await wait { find(window, "learning-mode-toggle") != nil }
            let enter = find(window, "learning-mode-toggle")
            _ = enter?.perform(NSSelectorFromString("accessibilityPerformPress"))
            let enteredLearning = await wait { model.isLearningMode }
            record("native-enter-learning-toggle", enter != nil && enteredLearning, "toggle found=\(enter != nil), learning=\(model.isLearningMode)")
            model.chooseLearningMode(false)
            model.viewing.setLearningActivation(.automatic)
            record("policy-change-reevaluates", model.isLearningMode)
            await attach("Outside.srt")
            record("no-overlapping-interval-no-learning", !model.isLearningMode && !model.learningEligible)
            await attach("French.srt")
            let oldRevision = model.subtitleSelectionRevision
            let stale = Task { try? await model.attachSubtitle(folder.appendingPathComponent("English.srt"), language: nil, onlyMissing: false, session: model.sessionID, revision: oldRevision) }
            await attach("Japanese.srt")
            await stale.value
            record("late-subtitle-cannot-replace-selection", model.englishSource == "Japanese.srt" && !model.isLearningMode)
            model.setSidebarCollapsed(true)
            await delay(0.2)
            record("native-normal-toolbar-hides-learning", find(window, "action-previousSentence") == nil && find(window, "action-toggleSentenceLoop") == nil)
            record("normal-caption-screenshot", WindowSnapshot.save(window, to: output.appendingPathComponent("ordinary-japanese.png")))
            // Feed AppKit's real slider tracking loop, including a drag reversal.
            if let slider = find(window, "playback-progress"), let value = slider.value(forKey: "accessibilityFrame") as? NSValue {
                let rect = window.convertFromScreen(value.rectValue)
                let before = model.seekRevision
                let points = [0.2, 0.7, 0.3, 0.6].map { NSPoint(x: rect.minX + rect.width * $0, y: rect.midY) }
                for (index, point) in points.dropFirst().enumerated() {
                    if let event = NSEvent.mouseEvent(with: .leftMouseDragged, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + Double(index) * 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: index + 1, clickCount: 1, pressure: 1) { NSApp.postEvent(event, atStart: false) }
                }
                if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: points.last!, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.05, windowNumber: window.windowNumber, context: nil, eventNumber: 5, clickCount: 1, pressure: 0) { NSApp.postEvent(up, atStart: false) }
                if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: points[0], modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(down) }
                await delay(0.3)
                record("native-slider-release-seeks-once", model.seekRevision == before + 1 && !model.seekPreview.visible, "seek delta=\(model.seekRevision - before)")
            } else { record("native-slider-release-seeks-once", false, "slider unavailable") }
            model.seek(2); if !model.endGate.wantsPlayback { model.togglePlayback() }
            _ = await wait { model.seekTarget == nil && !model.paused }
            // Same 6-second playback/scrub workload with the feature disabled, then enabled.
            for enabled in [false, true] {
                model.seekPreview.setMedia(model.mediaURL, ffmpeg: model.settings.ffmpeg)
                model.viewing.setSeekPreviewEnabled(enabled)
                model.seek(2); _ = await wait { model.seekTarget == nil }; await delay(0.3)
                let revision = model.seekRevision, starts = model.seekPreview.processStarts, hits = model.seekPreview.cacheHits, requests = model.seekPreview.requests
                let start = ProcessInfo.processInfo.systemUptime, ownCPU = cpu(), childCPU = cpu(true), memoryStart = memory()
                var gaps: [Double] = [], peakMemory = memory()
                let frames = model.videoView.renderedFrames
                for index in 0..<180 {
                    let before = ProcessInfo.processInfo.systemUptime
                    model.seekPreview.request(Double((index / 8) % 10) * 2 + 0.5, duration: model.duration)
                    await delay(1.0 / 30)
                    gaps.append(max(0, ProcessInfo.processInfo.systemUptime - before - 1.0 / 30) * 1000)
                    peakMemory = max(peakMemory, memory())
                }
                let wall = ProcessInfo.processInfo.systemUptime - start
                gaps.sort()
                let count = model.seekPreview.requests - requests, hitCount = model.seekPreview.cacheHits - hits
                scenarios.append(["preview": enabled, "wall_seconds": wall, "cpu_percent_one_core": (cpu() - ownCPU) / wall * 100,
                    "child_cpu_percent_one_core": (cpu(true) - childCPU) / wall * 100, "resident_before_mib": memoryStart, "resident_peak_mib": peakMemory,
                    "main_stall_p95_ms": gaps[Int(Double(gaps.count - 1) * 0.95)], "main_stall_max_ms": gaps.last ?? 0,
                    "starts": model.seekPreview.processStarts - starts, "requests": count, "cache_hits": hitCount,
                    "cache_hit_rate": count == 0 ? 0 : Double(hitCount) / Double(count), "cache_bytes": model.seekPreview.cacheBytes,
                    "rendered_frames": model.videoView.renderedFrames - frames, "decode_seconds": model.seekPreview.elapsed])
                record("preview-workload-\(enabled)", model.seekRevision == revision && !model.paused && (enabled ? model.seekPreview.processStarts > starts : model.seekPreview.processStarts == starts), "max stall=\(gaps.last ?? 0)ms")
                record("main-stall-budget-\(enabled)", (gaps.last ?? 0) < 100)
                model.seekPreview.endDrag(); await model.seekPreview.waitForIdle()
            }
            let preview = model.seekPreview
            preview.request(4.5, duration: model.duration)
            _ = await wait { preview.image != nil }
            record("thumbnail-real-frame", preview.image != nil && (preview.image?.size.width ?? 999) <= 240 && (preview.image?.size.height ?? 999) <= 240)
            record("preview-native-snapshot", WindowSnapshot.save(window, to: output.appendingPathComponent("preview-window.png")))
            let hit = preview.cacheHits, starts = preview.processStarts
            preview.request(5.5, duration: model.duration)
            record("two-second-cache-hit", preview.cacheHits == hit + 1 && preview.processStarts == starts)
            let intervals = zip(preview.startTimes.dropFirst(), preview.startTimes).map { $0.0 - $0.1 }
            record("start-frequency-limit", intervals.allSatisfy { $0 >= 0.249 }, "min=\(intervals.min() ?? 0)")
            record("cache-bounds", preview.cacheCount <= 64 && preview.cacheBytes <= 16 * 1024 * 1024)
            window.toggleFullScreen(nil); _ = await wait { model.windowPresentation.isFullScreen && !model.windowPresentation.isTransitioning }; await delay(0.3)
            preview.request(0.1, duration: model.duration); await delay(0.4)
            record("fullscreen-preview", preview.visible && WindowSnapshot.save(window, to: output.appendingPathComponent("preview-fullscreen.png")))
            window.toggleFullScreen(nil); _ = await wait { !model.windowPresentation.isFullScreen && !model.windowPresentation.isTransitioning }
            model.viewing.setSeekPreviewEnabled(false)
            record("disable-hides-immediately", !preview.visible && preview.image == nil)
            await preview.waitForIdle(); let disabledStarts = preview.processStarts
            preview.request(10, duration: 30000); await delay(0.3)
            record("disabled-never-starts", preview.processStarts == disabledStarts)
            model.viewing.setSeekPreviewEnabled(true)
            preview.setMedia(model.mediaURL, ffmpeg: "/missing/ffmpeg")
            preview.request(5, duration: 30000); await preview.waitForIdle()
            record("missing-ffmpeg-time-only", preview.visible && preview.image == nil && preview.target == 5 && model.alert == nil)
            preview.setMedia(model.mediaURL, ffmpeg: folder.appendingPathComponent("slow-ffmpeg").path)
            let timeoutStart = ProcessInfo.processInfo.systemUptime
            preview.request(3600, duration: 30000); await preview.waitForIdle()
            record("timeout-time-only", preview.visible && preview.image == nil && ProcessInfo.processInfo.systemUptime - timeoutStart < 2.8)
            preview.setMedia(model.mediaURL, ffmpeg: folder.appendingPathComponent("serial-ffmpeg").path)
            preview.request(3, duration: 30)
            _ = await wait { ((try? String(contentsOf: folder.appendingPathComponent("serial.log"))) ?? "").contains("start") }
            preview.endDrag()
            for _ in 0..<5 { preview.request(3, duration: 30); await delay(0.04); preview.endDrag() }
            preview.request(6, duration: 30); await preview.waitForIdle()
            let processLog = (try? String(contentsOf: folder.appendingPathComponent("serial.log"))) ?? ""
            var active = 0, maximum = 0
            for line in processLog.split(separator: "\n") { active += line == "start" ? 1 : -1; maximum = max(maximum, active) }
            record("cancelled-process-never-overlaps-replacement", maximum == 1 && active == 0, processLog)
            preview.setMedia(model.mediaURL, ffmpeg: model.settings.ffmpeg)
            preview.request(8, duration: model.duration)
            await load("Portrait.mp4")
            record("media-switch-clears-preview-cache", !preview.visible && preview.cacheCount == 0 && !model.isLearningMode && model.learningOverride == nil)
            preview.request(5, duration: model.duration); _ = await wait { preview.image != nil }
            record("portrait-frame-aspect", (preview.image?.size.height ?? 0) > (preview.image?.size.width ?? 0))
            record("portrait-snapshot", WindowSnapshot.save(window, to: output.appendingPathComponent("preview-portrait.png")))
            model.stopMedia()
            record("stop-hides-preview", !preview.visible && preview.cacheCount == 0)
            await load(); await attach("English.srt")
            await attach("Chinese.srt", language: .chinese)
            let chosenChinese = model.chinese, chosenChinesePath = model.chinesePath
            for hint: SubtitleLanguage? in [.english, nil] {
                try? await model.attachSubtitle(folder.appendingPathComponent("English.srt"), language: hint, onlyMissing: false, session: model.sessionID)
                record("english-import-preserves-chinese-\(hint?.rawValue ?? "general")", model.chinese == chosenChinese && model.chinesePath == chosenChinesePath && model.chineseSource == "Chinese.srt")
            }
            try? await model.attachSubtitle(folder.appendingPathComponent("Bilingual.srt"), language: .english, onlyMissing: false, session: model.sessionID)
            record("english-only-bilingual-import-preserves-chinese", model.chinese == chosenChinese && model.chinesePath == chosenChinesePath)
            try? await model.attachSubtitle(folder.appendingPathComponent("Bilingual.srt"), language: nil, onlyMissing: false, session: model.sessionID)
            record("general-bilingual-import-replaces-translation", model.chinesePath == model.primarySubtitlePath && model.chinese != chosenChinese)
            await attach("Chinese.srt", language: .chinese)
            model.setOffset(1.2, language: .english); model.setOffset(3.4, language: .chinese)
            model.savePlayback(); await model.store?.flush()
            await load("Portrait.mp4"); await load()
            record("reopening-keeps-custom-chinese", model.chinese == chosenChinese && model.chinesePath == chosenChinesePath && model.englishSource == "Bilingual.srt" && model.chineseOffset == 3.4 && model.englishOffset == 1.2)

            // Exercise the real SwiftUI layout with the largest allowed captions
            // at the common minimum window size in both playback modes.
            let savedAppearance = model.viewing.subtitles, savedFrame = window.frame
            model.viewing.setSubtitles(SubtitleAppearance(englishSize: 36, chineseSize: 28, bottomInset: 160))
            model.viewing.setFitVideoWindow(false); model.setSidebarCollapsed(true)
            let minimum = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 680, height: 360)).size
            var small = window.frame; small.size = window.delegate?.windowWillResize?(window, to: minimum) ?? minimum
            window.setFrame(small, display: true)
            model.seek(6); _ = await wait { model.seekTarget == nil }
            for learning in [false, true] {
                model.chooseLearningMode(learning); model.chrome.show(); await delay(0.4)
                let stage = window.convertToScreen(model.videoView.convert(model.videoView.bounds, to: nil))
                let ids = ["playback-progress", "open-video", "action-backward", "action-playPause", "action-forward", "subtitle-menu", "speed-control", "volume-control", "open-queue", "toggle-sidebar", "fit-video-window", "toggle-fullscreen", "capture-screenshot", "quick-settings"] + (learning ? ["action-previousSentence", "action-nextSentence", "action-toggleSentenceLoop"] : [])
                let frames = ids.compactMap { (find(window, $0)?.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue }
                let title = (find(window, "playback-title")?.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
                let content = window.contentView.map { window.convertToScreen($0.convert($0.bounds, to: nil)) } ?? .zero
                record("large-captions-preserve-stage-and-title-\(learning)", stage == content && !title.isEmpty && stage.contains(title), "stage=\(stage), content=\(content), title=\(title)")
                record("large-captions-keep-all-controls-visible-\(learning)", model.videoView.bounds.size == NSSize(width: 680, height: 360) && frames.count == ids.count && frames.allSatisfy { !$0.isEmpty && stage.contains($0) && window.frame.contains($0) && $0.maxY < title.minY }, "stage=\(stage), controls=\(frames)")
                record("large-captions-snapshot-\(learning)", WindowSnapshot.save(window, to: output.appendingPathComponent("large-captions-\(learning).png")))
            }
            model.viewing.setSubtitles(savedAppearance); window.setFrame(savedFrame, display: true)
            model.viewing.setLearningActivation(.manual); model.viewing.setSeekPreviewEnabled(false); model.setSpeed(3)
            if let englishAudio = model.audioStreams.first(where: { $0.language == "eng" }) { model.selectAudio(englishAudio.id) }
            model.savePlayback()
        }
        await model.prepareShutdown()
        let result: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks, "scenarios": scenarios,
            "method": "Native AppKit/SwiftUI window; real libmpv and FFmpeg; deterministic controller requests at 30 Hz. Does not measure physical mouse latency."]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(restore ? "restore.json" : "playback-mode.json"))
        NSApp.terminate(nil)
    }
}
