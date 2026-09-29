import AppKit
import PlayerCore

/// Checks the actual switch hit target and composited sidebar edge in native windows.
@MainActor enum LearningToggleSmoke {
    static func run(model: AppModel, window: NSWindow, folder: URL, output: URL,
                    detach: () -> Void, learningWindow: () -> NSWindow?) async {
        var checks: [[String: Any]] = []
        func record(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail]); print(name, passed, detail); fflush(stdout)
        }
        func delay(_ seconds: Double = 0.25) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        func wait(_ predicate: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline { if predicate() { return true }; await delay(0.025) }; return predicate()
        }
        func find(_ root: NSObject, _ id: String, depth: Int = 0) -> NSObject? {
            guard depth < 40 else { return nil }
            let key = NSSelectorFromString("accessibilityIdentifier"), children = NSSelectorFromString("accessibilityChildren")
            if root.responds(to: key), root.perform(key)?.takeUnretainedValue() as? String == id { return root }
            if root.responds(to: children), let items = root.perform(children)?.takeUnretainedValue() as? [NSObject] {
                for item in items { if let found = find(item, id, depth: depth + 1) { return found } }
            }; return nil
        }
        func frame(_ id: String) -> NSRect? { (find(window, id)?.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue }
        func switchMatches(_ enabled: Bool) -> Bool {
            (find(window, "learning-mode-toggle")?.value(forKey: "accessibilityValue") as? NSNumber)?.boolValue == enabled
        }
        @discardableResult func clickSwitch() async -> Bool {
            guard let bounds = frame("learning-mode-toggle") else { return false }
            // The right side of the labeled toggle is the native switch track.
            let point = window.convertPoint(fromScreen: NSPoint(x: bounds.maxX - 12, y: bounds.midY))
            window.makeKeyAndOrderFront(nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                NSApp.postEvent(event, atStart: false); await delay(0.04)
            }
            await delay(); return true
        }
        func attach(_ name: String) async {
            model.importSubtitle(folder.appendingPathComponent(name))
            _ = await wait { model.englishSource == name }; await delay()
        }
        func load(_ name: String) async {
            model.open(folder.appendingPathComponent(name))
            _ = await wait { model.playbackReady && model.duration > 20 }
            await model.openTask?.value
            if model.endGate.wantsPlayback { model.togglePlayback() }
            model.chrome.hold(.keyboard, active: true); await delay()
        }
        func resize(_ size: NSSize) async {
            var next = window.frame; next.size = window.delegate?.windowWillResize?(window, to: size) ?? size
            window.setFrame(next, display: true); await delay(0.4)
        }
        func layout(_ name: String) {
            let stage = window.convertToScreen(model.videoView.convert(model.videoView.bounds, to: nil))
            let toggle = frame("learning-mode-toggle") ?? .zero, title = frame("playback-title") ?? .zero
            record(name + "-toggle-and-title", !toggle.isEmpty && !title.isEmpty && stage.contains(toggle) && stage.contains(title) &&
                abs(title.midX - stage.midX) < 1 && title.maxX + 8 < toggle.minX &&
                // AX exposes the switch track, excluding its label and capsule padding.
                toggle.maxX > stage.maxX - 60 && toggle.maxY > stage.maxY - 65,
                "stage=\(stage), title=\(title), toggle=\(toggle)")
            let sidebar = model.preferences.sidebarCollapsed ? 0.0 : 333.0
            record(name + "-video-width", abs(model.videoView.bounds.width + sidebar - (window.contentView?.bounds.width ?? 0)) < 0.5)
            let version = frame("playback-version") ?? .zero
            record(name + "-version-at-stage-corner", !version.isEmpty && stage.contains(version) &&
                   (0...16).contains(stage.maxX - version.maxX) && (0...12).contains(version.minY - stage.minY),
                   "stage=\(stage), version=\(version)")
            let picture = VideoContentGeometry(size: stage.size, aspect: model.videoAspect).image
            if picture.minY > version.height + 6 {
                record(name + "-version-on-bottom-letterbox", version.maxY < stage.minY + picture.minY)
            }
            let snapshot = output.appendingPathComponent(name + ".png")
            record(name + "-snapshot", WindowSnapshot.save(window, to: snapshot))
            if sidebar > 0, let data = try? Data(contentsOf: snapshot), let bitmap = NSBitmapImageRep(data: data) {
                let scale = Double(bitmap.pixelsWide) / window.frame.width
                let x = Int(((stage.maxX - window.frame.minX) * scale).rounded())
                let y = Int(((window.frame.maxY - stage.midY) * scale).rounded())
                func rgb(_ column: Int) -> [Double] {
                    guard let c = bitmap.colorAt(x: column, y: y)?.usingColorSpace(.sRGB) else { return [] }
                    return [c.redComponent, c.greenComponent, c.blueComponent]
                }
                let panel = rgb(x + Int(8 * scale))
                func difference(_ column: Int) -> Double {
                    let sample = rgb(column)
                    guard sample.count == 3 && panel.count == 3 else { return 1 }
                    return (0..<3).map { abs(sample[$0] - panel[$0]) }.max() ?? 1
                }
                let differences = (0..<Int(4 * scale)).map { difference(x + $0) }
                let videoDifference = difference(x - 1)
                record(name + "-seam-pixels", panel.count == 3 && (differences.max() ?? 1) < 2.0 / 255 && videoDifference > 0.02,
                    "scale=\(scale), sidebarEdgeDelta=\(differences.max() ?? 1), videoEdgeDelta=\(videoDifference)")
            }
        }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        window.ignoresMouseEvents = true
        model.settings.autoSearch = false; model.settings.mfa = "/missing/learning-toggle-smoke"; model.player.set("mute", "yes")
        model.chrome.hold(.keyboard, active: true); await delay()
        record("hidden-without-video", find(window, "learning-mode-toggle") == nil)
        model.viewing.setLearningActivation(.manual)
        await load("Movie.mp4")
        record("hidden-without-english", !model.learningEligible && find(window, "learning-mode-toggle") == nil)
        await attach("English.srt")
        record("manual-qualified-switch-off", model.learningEligible && !model.isLearningMode && switchMatches(false))
        model.setSidebarCollapsed(true); model.sidebarTab = .queue; model.seek(2)
        _ = await wait { model.seekTarget == nil && model.paused }; await delay()
        let position = model.position, revision = model.seekRevision
        record("mouse-enable-keeps-collapsed-layout", await clickSwitch() && model.isLearningMode && switchMatches(true) &&
               model.preferences.sidebarCollapsed && model.sidebarTab == .queue)
        record("enable-keeps-paused-position", model.paused && !model.endGate.wantsPlayback && model.seekRevision == revision && abs(model.position - position) < 0.01)
        model.togglePlayback(); _ = await wait { !model.paused }
        record("mouse-disable-keeps-playing", await clickSwitch() && !model.isLearningMode && switchMatches(false) &&
               !model.paused && model.endGate.wantsPlayback && model.seekRevision == revision)
        model.togglePlayback(); _ = await wait { model.paused }
        model.viewing.setLearningActivation(.automatic); await delay()
        record("automatic-policy-syncs-switch", model.isLearningMode && switchMatches(true))
        _ = await clickSwitch(); await attach("English.srt")
        model.aligner.onChange?([TimedWord(cueID: "late", tokenIndex: 0, start: 0, end: 30)], "late")
        await delay()
        record("manual-off-survives-subtitle-and-late-callback", !model.isLearningMode && switchMatches(false) && model.timings.isEmpty)
        model.chrome.toggle(); await delay()
        record("hidden-with-chrome", !model.chrome.visible && find(window, "learning-mode-toggle") == nil && find(window, "playback-title") == nil)
        model.chrome.show(); model.chrome.hold(.keyboard, active: true); await delay()
        record("revealed-with-chrome", switchMatches(false) && find(window, "playback-title") != nil)
        model.viewing.setFitVideoWindow(false)
        await resize(NSSize(width: 680, height: 360)); layout("minimum-off")
        _ = await clickSwitch(); layout("minimum-on")
        model.setSidebarCollapsed(false); await delay()
        await resize(NSSize(width: 1013, height: 360)); layout("minimum-sidebar")
        let tab = model.sidebarTab, expandedFrame = window.frame
        _ = await clickSwitch(); _ = await clickSwitch()
        record("toggle-keeps-expanded-layout", !model.preferences.sidebarCollapsed && model.sidebarTab == tab && window.frame == expandedFrame)
        model.playerPopover = .subtitles; await delay()
        let popovers = NSApp.windows.filter(\.isVisible)
        record("subtitle-menu-retains-sidebar-only", popovers.contains { find($0, "open-learning") != nil } &&
               popovers.allSatisfy { find($0, "enter-learning") == nil && find($0, "exit-learning") == nil })
        model.playerPopover = nil; await delay()
        model.openSidebar(.learning); detach(); await delay()
        record("learning-window-open", learningWindow() != nil)
        _ = await clickSwitch()
        record("toggle-closes-learning-window-and-tasks", learningWindow() == nil && !model.isDetached && !model.isLearningMode &&
               !model.dictionaryLookup.isAvailable && model.sentenceLoop == nil && model.replayRange == nil)
        await attach("Japanese.srt")
        record("subtitle-replacement-hides-switch", !model.learningEligible && !model.isLearningMode && find(window, "learning-mode-toggle") == nil)
        await load("A Very Long Movie Title About Learning English While Exploring The World With Friends And Finding New Stories Every Day.mp4")
        record("new-movie-clears-override-and-hides-switch", model.learningOverride == nil && find(window, "learning-mode-toggle") == nil)
        await attach("English.srt")
        record("new-movie-auto-on", model.isLearningMode && switchMatches(true))
        model.sidebarTab = .queue
        await resize(NSSize(width: 1013, height: 360)); layout("long-title-sidebar")
        model.setSidebarCollapsed(true); await delay()
        await resize(NSSize(width: 680, height: 360)); layout("long-title-collapsed")
        window.toggleFullScreen(nil)
        let entered = await wait { model.windowPresentation.isFullScreen && !model.windowPresentation.isTransitioning }; await delay(0.6)
        record("entered-fullscreen", entered); layout("fullscreen-collapsed")
        record("fullscreen-switch-click", await clickSwitch() && !model.isLearningMode && switchMatches(false))
        model.setSidebarCollapsed(false); await delay(); layout("fullscreen-sidebar")
        record("fullscreen-sidebar-switch-click", await clickSwitch() && model.isLearningMode && switchMatches(true))
        window.toggleFullScreen(nil)
        let exited = await wait { !model.windowPresentation.isFullScreen && !model.windowPresentation.isTransitioning }; await delay(0.6)
        record("exited-fullscreen", exited)
        model.viewing.setFitVideoWindow(true); await delay(); layout("fitted-sidebar")
        model.stopMedia(); await delay()
        record("stop-hides-switch", !model.learningEligible && find(window, "learning-mode-toggle") == nil)
        await model.store?.flush()
        let result: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("learning-toggle.json"))
        NSApp.terminate(nil)
    }
}
