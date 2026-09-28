import AppKit
import PlayerCore

@MainActor enum WindowGeometrySmoke {
    /// Exercises the event-tracking run-loop used by AppKit while dragging.
    /// Window geometry is driven programmatically; this is not a mouse-latency test.
    private static func resizeInTrackingMode(model: AppModel, window: NSWindow) -> (frames: Int, samples: Int, error: Double) {
        let first = model.videoView.renderedFrames, initial = window.frame
        var index = 0, error = 0.0
        window.delegate?.windowWillStartLiveResize?(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            index += 1
            var frame = initial
            let proposal = NSSize(width: initial.width + 80 * sin(Double(index) / 12), height: initial.height)
            frame.size = window.delegate?.windowWillResize?(window, to: proposal) ?? proposal
            window.setFrame(frame, display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            let expectedWidth = max(window.minSize.width, min(window.screen?.visibleFrame.width ?? .infinity, proposal.width))
            error = max(error, abs(window.frame.width - expectedWidth))
            let stageWidth = (window.contentView?.bounds.width ?? 0) - (model.preferences.sidebarCollapsed ? 0 : 333)
            error = max(error, abs(model.videoView.bounds.width - stageWidth))
        }
        RunLoop.main.add(timer, forMode: .common)
        let end = Date().addingTimeInterval(2)
        while Date() < end { _ = RunLoop.current.run(mode: .eventTracking, before: end) }
        timer.invalidate()
        window.delegate?.windowDidEndLiveResize?(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        return (model.videoView.renderedFrames - first, index, error)
    }
    static func run(model: AppModel, window: NSWindow, folder: URL, output: URL, restore: Bool) async {
        var checks: [[String: Any]] = []
        func record(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail]); print(name, passed, detail); fflush(stdout)
        }
        func delay(_ seconds: Double = 0.25) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        func wait(_ predicate: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline { if predicate() { return true }; await delay(0.02) }; return predicate()
        }
        func matches(_ aspect: Double) -> Bool {
            let size = model.videoView.bounds.size
            return size.height > 0 && abs(size.width - size.height * aspect) < 2
        }
        func resize(_ proposed: NSSize) async {
            let fitted = window.delegate?.windowWillResize?(window, to: proposed) ?? proposed
            var frame = window.frame; frame.size = fitted
            window.setFrame(frame, display: true); await delay()
        }
        func find(_ root: NSObject, _ id: String, depth: Int = 0) -> NSObject? {
            guard depth < 40 else { return nil }
            let selector = NSSelectorFromString("accessibilityIdentifier"), children = NSSelectorFromString("accessibilityChildren")
            if root.responds(to: selector), root.perform(selector)?.takeUnretainedValue() as? String == id { return root }
            if root.responds(to: children), let items = root.perform(children)?.takeUnretainedValue() as? [NSObject] {
                for item in items { if let found = find(item, id, depth: depth + 1) { return found } }
            }; return nil
        }
        func load(_ name: String, aspect: Double) async {
            model.open(folder.appendingPathComponent(name))
            let ready = await wait { model.playbackReady && abs((model.videoAspect ?? 0) - aspect) < 0.001 }
            await model.openTask?.value; model.aligner.cancel(); await model.aligner.waitForCancellation()
            await delay(0.5)
            record("loaded-" + name, ready, "aspect=\(String(describing: model.videoAspect))")
        }
        func checkCaptions(_ name: String, inset: Double = 8) async {
            if model.endGate.wantsPlayback { model.togglePlayback() }
            model.seek(1); _ = await wait { model.seekTarget == nil && model.paused }
            let cue = SubtitleCue(id: "geometry-caption", start: 0, end: 30, text: "Keep captions inside the video.")
            model.english = [cue]; model.chinese = []; model.setSubtitleDisplay(.english)
            model.learning.resumeFollowing(); model.refreshLearning()
            var appearance = model.viewing.subtitles; appearance.bottomInset = inset
            model.viewing.setSubtitles(appearance); await delay(0.4)
            let size = model.videoView.bounds.size
            let image = VideoContentGeometry(size: size, aspect: model.videoAspect).image
            let stage = window.convertToScreen(model.videoView.convert(model.videoView.bounds, to: nil))
            let video = image.offsetBy(dx: stage.minX, dy: stage.minY)
            let words = cue.tokens.filter(\.isWord).compactMap {
                (find(window, "subtitle-word-\(cue.id)-\($0.id)")?.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
            }
            let distance = (words.map(\.minY).min() ?? 0) - video.minY
            record(name + "-caption-position", words.count == cue.tokens.filter(\.isWord).count &&
                   words.allSatisfy { video.contains($0) } && distance >= inset && distance < inset + 24,
                   "image=\(image), wordInset=\(distance), configured=\(inset)")
            record(name + "-snapshot", WindowSnapshot.save(window, to: output.appendingPathComponent(name + ".png")))
            // Compare an exported caption against the very same raw frame. Any
            // changed pixel outside the image means a caption leaked into a bar.
            guard let bitmap = await model.videoView.captureFrame(), let raw = bitmap.cgImage,
                  let composed = try? ScreenshotController.compose(video: raw, size: size, aspect: model.videoAspect, subtitles: SubtitleFrame(model: model)),
                  let plain = try? ScreenshotController.compose(video: raw, size: size, aspect: model.videoAspect, subtitles: hiddenCaptionFrame()) else {
                record(name + "-export", false, "capture unavailable"); return
            }
            let result = NSBitmapImageRep(cgImage: composed), baseline = NSBitmapImageRep(cgImage: plain)
            let scale = Double(raw.width) / size.width
            var outside = 0, inside = 0
            for y in stride(from: 0, to: raw.height, by: 3) {
                for x in stride(from: 0, to: raw.width, by: 3) {
                    if result.colorAt(x: x, y: y) != baseline.colorAt(x: x, y: y) {
                        let point = CGPoint(x: Double(x) / scale, y: Double(y) / scale)
                        if image.contains(point) { inside += 1 } else { outside += 1 }
                    }
                }
            }
            record(name + "-export", inside > 0 && outside == 0, "changed inside=\(inside), outside=\(outside)")
            try? result.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + "-export.png"))
        }
        func hiddenCaptionFrame() -> SubtitleFrame {
            let mode = model.preferences.subtitleDisplay
            model.preferences.subtitleDisplay = .hidden
            let frame = SubtitleFrame(model: model)
            model.preferences.subtitleDisplay = mode
            return frame
        }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        window.ignoresMouseEvents = true
        model.settings.autoSearch = false; model.settings.mfa = "/missing/window-smoke"; model.player.set("mute", "yes")
        model.chrome.hold(.keyboard, active: true)
        if restore { record("mode-restored", model.viewing.fitVideoWindow) }
        await load("Wide.mp4", aspect: 16.0 / 9)
        if restore {
            record("fitted-size-restored", matches(16.0 / 9) && abs(window.frame.width - 900) < 2, "\(window.frame)")
        } else {
            model.setSidebarCollapsed(true)
            model.chrome.show(); await delay(0.3)
            let toggle = NSApp.windows.filter(\.isVisible).compactMap { find($0, "fit-video-window") }.first
            _ = toggle?.perform(NSSelectorFromString("accessibilityPerformPress")); await delay(0.5)
            record("native-toggle-enables-mode", toggle != nil && model.viewing.fitVideoWindow)
            model.showSubtitleControls = false; await delay()
            record("wide-video-fits-window", matches(16.0 / 9), "\(model.videoView.bounds)")
            for sidebar in [false, true] {
                model.setSidebarCollapsed(sidebar); await delay()
                record("sidebar-\(sidebar)-keeps-video-aspect", matches(16.0 / 9), "\(model.videoView.bounds)")
                await resize(NSSize(width: window.frame.width - 100, height: window.frame.height))
                record("horizontal-resize-\(sidebar)", matches(16.0 / 9))
                await resize(NSSize(width: window.frame.width, height: window.frame.height - 70))
                record("vertical-resize-\(sidebar)", matches(16.0 / 9))
            }
            record("wide-screenshot", WindowSnapshot.save(window, to: output.appendingPathComponent("wide.png")))
            await load("Portrait.mp4", aspect: 9.0 / 16)
            record("portrait-keeps-toolbar-minimum-on-short-screen", model.videoView.bounds.width >= 680 && model.videoView.bounds.height <= (window.screen?.visibleFrame.height ?? 0), "\(model.videoView.bounds)")
            await resize(NSSize(width: 330, height: window.frame.height))
            record("portrait-resize-keeps-toolbar-minimum", model.videoView.bounds.width >= 680)
            record("compact-controls-remain-visible", ["quick-settings", "action-playPause", "toggle-sidebar", "volume-control"].allSatisfy { id in
                guard let node = find(window, id), let frame = node.value(forKey: "accessibilityFrame") as? NSValue else { return false }
                return window.frame.contains(frame.rectValue)
            })
            record("portrait-screenshot", WindowSnapshot.save(window, to: output.appendingPathComponent("portrait.png")))
            await checkCaptions("portrait")
            await load("Anamorphic.mp4", aspect: 32.0 / 9)
            record("pixel-aspect-fits", matches(32.0 / 9), "video=\(model.videoView.frame), window=\(window.frame), content=\(String(describing: window.contentView?.bounds)), minimum=\(window.contentMinSize)")
            _ = WindowSnapshot.save(window, to: output.appendingPathComponent("anamorphic.png"))
            await load("Wide.mp4", aspect: 16.0 / 9)
            window.toggleFullScreen(nil)
            let entered = await wait { window.styleMask.contains(.fullScreen) }; await delay(1)
            record("fullscreen-unconstrained", entered && abs(window.frame.width - (window.screen?.frame.width ?? 0)) < 2)
            await load("Anamorphic.mp4", aspect: 32.0 / 9)
            await checkCaptions("fullscreen-minimum")
            await checkCaptions("fullscreen-raised", inset: 160)
            model.setSidebarCollapsed(false); await delay()
            await checkCaptions("fullscreen-sidebar")
            model.setSidebarCollapsed(true); await delay()
            await load("Wide.mp4", aspect: 16.0 / 9)
            window.toggleFullScreen(nil)
            let exited = await wait { !window.styleMask.contains(.fullScreen) }; await delay(1)
            record("exit-fullscreen-restores-aspect", exited && matches(16.0 / 9))
            model.viewing.setFitVideoWindow(false); await delay()
            let proposal = NSSize(width: 1100, height: 740)
            let minimum = window.delegate?.windowWillResize?(window, to: NSSize(width: 100, height: 100)) ?? .zero
            record("disable-restores-free-resize", window.delegate?.windowWillResize?(window, to: proposal) == proposal && abs(minimum.width - 680) < 1 && abs(minimum.height - 360) < 1, "minimum=\(minimum)")
            await resize(proposal)
            await checkCaptions("window-letterbox")
            model.viewing.setFitVideoWindow(true); await delay()
            for fitted in [true, false] {
                model.viewing.setFitVideoWindow(fitted); await delay()
                for playing in [false, true] {
                    if model.endGate.wantsPlayback != playing { model.togglePlayback() }
                    await delay()
                    let tracking = resizeInTrackingMode(model: model, window: window)
                    record("tracking-fit-\(fitted)-playing-\(playing)", tracking.frames > 8 && tracking.samples > 8 && tracking.error < 2,
                           "frames=\(tracking.frames), samples=\(tracking.samples), maxGeometryError=\(tracking.error)")
                    await delay()
                }
            }
            model.viewing.setFitVideoWindow(true); await delay()
            model.stopMedia(); await delay()
            record("stop-clears-video-geometry", model.videoAspect == nil && window.frame.width >= 680 && window.frame.height >= 360)
            await load("Wide.mp4", aspect: 16.0 / 9)
            await resize(NSSize(width: 900, height: window.frame.height))
            record("final-fitted-size", matches(16.0 / 9) && abs(window.frame.width - 900) < 2)
            let frames = model.videoView.renderedFrames
            let metrics = OperationMetrics.shared
            metrics.maximumAVSync = 0; metrics.enabled = true
            await delay(2)
            metrics.enabled = false
            record("rendering-continues", model.videoView.renderedFrames > frames)
            record("audio-video-sync-after-resize", metrics.maximumAVSync < 0.1, "maximum=\(metrics.maximumAVSync)s")
        }
        await model.store?.flush()
        let result: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(restore ? "window-restore.json" : "window.json"))
        NSApp.terminate(nil)
    }
}
