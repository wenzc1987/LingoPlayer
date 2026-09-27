import AppKit
import Foundation
import PlayerCore

/// Explicit developer-only launch mode, exercising the real model, renderer and windows.
/// Does not run during normal use or send any network request.
@MainActor
enum SmokeCheck {
    static func run(model: AppModel, window: NSWindow, video: URL, output: URL, detach: () -> Void, closeDetached: () -> Void) async {
        var checks: [[String: Any]] = []
        let start = Date()
        func record(_ name: String, _ passed: Bool, detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail])
        }
        func wait(_ timeout: Double = 15, until condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return condition()
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            model.settings.autoSearch = false
            model.setVolume(0)
            model.open(video)
            let opened = await wait { model.duration > 1 && model.videoView.rendererReady && !model.english.isEmpty && !model.chinese.isEmpty && model.selectedAudio >= 0 }
            record("video_opens_with_real_renderer_and_english_subtitles", opened, detail: model.alert ?? model.subtitleStatus)
            record("rendered_video_frames", model.videoView.renderedFrames > 0, detail: String(model.videoView.renderedFrames))
            record("bilingual_subtitles_discovered", !model.chinese.isEmpty, detail: "\(model.englishSource) / \(model.chineseSource)")
            model.setOffset(0, language: .english)
            if let cue = model.english.first, let word = cue.tokens.first(where: \.isWord) {
                model.lock(cue: cue, token: word)
                let paused = await wait { model.paused && model.learning.isLocked }
                record("click_word_pauses_and_locks", paused)
                let lookup = await wait { model.dictionaryEntry != nil }
                record("real_ecdict_lookup", lookup, detail: model.dictionaryEntry?.word ?? model.dictionaryStatus)
                let locked = model.selected
                model.togglePlayback()
                _ = await wait { !model.paused }
                let before = model.position
                try await Task.sleep(nanoseconds: 500_000_000)
                record("normal_play_preserves_locked_word", model.learning.isLocked && model.selected == locked && model.position > before)
                model.replaySentence()
                let replayed = await wait(20) { model.paused && model.position >= cue.end - 0.15 }
                record("replay_sentence_stops_at_boundary", replayed && model.selected == locked, detail: "position=\(model.position), end=\(cue.end)")
                detach()
                try await Task.sleep(nanoseconds: 300_000_000)
                record("detached_window_shares_selection", model.isDetached && model.selected == locked)
                closeDetached()
                try await Task.sleep(nanoseconds: 200_000_000)
                record("closing_learning_window_restores_sidebar", !model.isDetached && model.selected == locked)
                if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("app.png"))
                }
                model.player.command(["screenshot-to-file", output.appendingPathComponent("video.png").path, "video"])
                model.resumeLearning()
                _ = await wait { !model.paused }
                record("resume_learning_unlocks_and_plays", model.isFollowing && !model.paused)
                model.setSpeed(1.5)
                model.seek(min(10, model.duration / 2))
                let sought = await wait { abs(model.position - min(10, model.duration / 2)) < 2 }
                record("seek_and_speed_controls", sought && model.speed == 1.5)
                model.player.pause(true)
                let offsetPosition = model.position
                model.setOffset(1000, language: .chinese)
                record("chinese_offset_keeps_english_visible", model.activeChinese.isEmpty && !model.activeEnglish.isEmpty && abs(model.position - offsetPosition) < 0.2)
                model.setOffset(0, language: .chinese)
                let aligned = await wait(180) { model.alignmentStatus.contains("准备完成") || model.alignmentStatus.contains("暂停：") }
                record("local_mfa_alignment_produces_words", aligned && model.alignedWordCount > 0, detail: "\(model.alignedWordCount) words; \(model.alignmentStatus)")
                if let timed = model.firstAlignedWord {
                    model.seek((timed.start + timed.end) / 2)
                    _ = await wait { model.currentWordID != nil }
                    record("playback_clock_drives_word_highlight", model.currentWordID == "\(timed.cueID):\(timed.tokenIndex)")
                    _ = await wait { model.dictionaryEntry != nil }
                    if let frame = model.videoView.diagnosticFrame(), let pixels = frame.bitmapData {
                        var colored = 0
                        for index in stride(from: 0, to: frame.bytesPerRow * frame.pixelsHigh, by: 4 * 101) {
                            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
                            if max(r, g, b) - min(r, g, b) > 60 { colored += 1 }
                        }
                        record("actual_gl_framebuffer_contains_video", colored > 100, detail: "\(colored) colored samples")
                        try frame.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("framebuffer.png"))
                        if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: bitmap)
                            if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                                var rect = model.videoView.convert(model.videoView.bounds, to: view)
                                if view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
                                let image = NSImage(size: frame.size); image.addRepresentation(frame)
                                image.draw(in: rect)
                                NSGraphicsContext.restoreGraphicsState()
                            }
                            try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("app.png"))
                        }
                    } else { record("actual_gl_framebuffer_contains_video", false) }
                }
                let count = model.alignedWordCount
                let cacheStart = Date()
                model.setOffset(model.englishOffset, language: .english)
                let cached = await wait(5) { model.alignmentStatus.contains("已复用缓存") }
                record("reopening_alignment_reuses_cache", cached && model.alignedWordCount == count && count > 0, detail: "\(Date().timeIntervalSince(cacheStart)) seconds")
                model.setOffset(0.5, language: .english)
                record("offset_change_invalidates_word_timings", model.alignedWordCount == 0)
                model.setOffset(0, language: .english)
                if let anotherAudio = model.audioStreams.first(where: { $0.id != model.selectedAudio }) {
                    model.selectAudio(anotherAudio.id)
                    record("audio_change_invalidates_word_timings", model.alignedWordCount == 0 && model.selectedAudio == anotherAudio.id)
                }
                // Exercise missing-runtime and missing-subtitle behavior in the
                // real application without changing the user's saved settings.
                model.settings.mfa = "/missing/validation/mfa"
                model.setOffset(0, language: .english)
                model.resumeLearning()
                let beforeMissingModel = model.position
                try await Task.sleep(nanoseconds: 500_000_000)
                record("model_unavailable_keeps_playback_running", model.alignmentTaskStatus.phase == .environmentFailure && !model.paused && model.position > beforeMissingModel)
                let sibling = video.deletingLastPathComponent()
                let noSubtitles = sibling.appendingPathComponent("no-subtitles.mp4")
                if FileManager.default.fileExists(atPath: noSubtitles.path) {
                    model.open(noSubtitles)
                    let noSubs = await wait { model.duration > 0 && model.subtitleStatus.contains("缺少英文") }
                    record("new_video_clears_old_subtitles_and_timings", noSubs && model.english.isEmpty && model.chinese.isEmpty && model.alignedWordCount == 0 && !model.learning.isLocked)
                    record("missing_subtitles_do_not_stop_playback", noSubs && !model.paused)
                    model.importSubtitle(sibling.appendingPathComponent("manual-bilingual.ass"))
                    let imported = await wait { !model.english.isEmpty && !model.chinese.isEmpty }
                    record("manual_bilingual_ass_import", imported && model.englishSource == "manual-bilingual.ass" && model.chineseSource == "manual-bilingual.ass")
                    model.player.pause(true)
                }
            }
        } catch { record("unexpected_error", false, detail: error.localizedDescription) }
        let report: [String: Any] = ["checks": checks, "passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "elapsed_seconds": Date().timeIntervalSince(start), "subtitle_status": model.subtitleStatus, "alignment_status": model.alignmentStatus]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("smoke.json")) }
        NSApplication.shared.terminate(nil)
    }
}
