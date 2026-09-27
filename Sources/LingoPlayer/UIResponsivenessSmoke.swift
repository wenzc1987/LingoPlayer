import AppKit
import PlayerCore
import Darwin

/// Opt-in local measurements of real AppKit windows, using isolated test data.
@MainActor enum UIResponsivenessSmoke {
    static func run(model: AppModel, window: NSWindow, video: URL, output: URL) async {
        func now() -> Double { ProcessInfo.processInfo.systemUptime }
        func delay(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        func wait(_ predicate: () -> Bool) async -> Bool {
            let end = now() + 15
            while now() < end { if predicate() { return true }; await delay(0.01) }; return predicate()
        }
        func distribution(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted(); guard !sorted.isEmpty else { return [:] }
            return ["count": Double(sorted.count), "p95": sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)], "max": sorted.last!]
        }
        func find(_ root: NSObject, _ id: String, depth: Int = 0) -> NSObject? {
            guard depth < 40 else { return nil }
            let identifier = NSSelectorFromString("accessibilityIdentifier"), children = NSSelectorFromString("accessibilityChildren")
            if root.responds(to: identifier), root.perform(identifier)?.takeUnretainedValue() as? String == id { return root }
            if root.responds(to: children), let items = root.perform(children)?.takeUnretainedValue() as? [NSObject] {
                for item in items { if let result = find(item, id, depth: depth + 1) { return result } }
            }
            return nil
        }
        func segment(_ id: String, _ index: Int) -> NSObject? {
            for target in NSApp.windows.filter(\.isVisible) {
                if let picker = find(target, id), let children = picker.value(forKey: "accessibilityChildren") as? [NSObject], children.indices.contains(index), children[index].responds(to: NSSelectorFromString("accessibilityPerformPress")) {
                    return children[index]
                }
            }
            return nil
        }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        window.ignoresMouseEvents = true
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        model.settings.autoSearch = false; model.settings.mfa = "/missing/ui-performance"
        model.player.set("mute", "yes"); model.open(video)
        let loaded = await wait { model.playbackReady && model.videoView.renderedFrames > 3 }
        await model.openTask?.value
        model.aligner.cancel(); await model.aligner.waitForCancellation()
        model.setSidebarCollapsed(true); model.chrome.hold(.keyboard, active: true)
        var rows: [[String: Any]] = []
        var checks: [String: Bool] = ["loaded": loaded]
        var gaps: [Double] = [], lastTick = now(), measuring = true
        let heartbeat = Timer(timeInterval: 0.01, repeats: true) { _ in
            let current = ProcessInfo.processInfo.systemUptime
            if measuring { gaps.append(max(0, current - lastTick - 0.01) * 1000) }; lastTick = current
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        for playing in [false, true] {
            if model.endGate.wantsPlayback != playing { model.togglePlayback() }
            await delay(0.4)
            let name = playing ? "resize-playing" : "resize-paused"
            print("UI_PHASE", name); fflush(stdout)
            gaps = []; lastTick = now(); var durations: [Double] = []
            let frames = model.videoView.renderedFrames, started = now()
            for index in 0..<180 {
                let t = (sin(Double(index) * .pi / 45) + 1) / 2
                let before = now()
                window.setContentSize(NSSize(width: 980 + 320 * t, height: 640 + 180 * t))
                window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                durations.append((now() - before) * 1000)
                await delay(1.0 / 60)
            }
            rows.append(["name": name, "operation_ms": distribution(durations), "main_stall_ms": distribution(gaps), "elapsed": now() - started, "frames": model.videoView.renderedFrames - frames])
        }
        window.setContentSize(NSSize(width: 1260, height: 800)); await delay(0.3)
        for quick in [true, false] {
            let name = quick ? "playback-settings-tabs" : "settings-tabs"
            print("UI_PHASE", name); fflush(stdout)
            if quick { model.showSubtitleControls = true } else { model.showSettings = true }
            await delay(0.7)
            gaps = []; lastTick = now(); var durations: [Double] = []; var selected = true
            for index in 0..<12 {
                // AX traversal can itself materialize every text-field editor.
                // Resolve geometry/targets outside the user-operation interval.
                measuring = false
                let target = segment(quick ? "playback-settings-page" : "settings-page", (index + 1) % 2)
                await delay(0.1)
                let before = now()
                lastTick = before; measuring = true
                if let target { _ = target.perform(NSSelectorFromString("accessibilityPerformPress")) }
                else { selected = false }
                await delay(0.01)
                // Includes SwiftUI's next update, instead of timing only mutation.
                NSApp.windows.filter(\.isVisible).forEach { $0.contentView?.layoutSubtreeIfNeeded(); $0.displayIfNeeded() }
                durations.append((now() - before) * 1000 - 10)
                await delay(0.15)
            }
            checks[name + "-selected"] = selected
            rows.append(["name": name, "operation_ms": distribution(durations), "main_stall_ms": distribution(gaps)])
            model.showSubtitleControls = false; model.showSettings = false; await delay(0.5)
        }
        print("UI_PHASE file-panels"); fflush(stdout)
        model.seek(1); if !model.endGate.wantsPlayback { model.togglePlayback() }
        _ = await wait { model.seekTarget == nil && !model.paused }; await delay(0.3)
        for subtitle in [false, true] {
            var durations: [Double] = [], returnTimes: [Double] = [], progressed = true
            gaps = []; lastTick = now()
            for _ in 0..<3 {
                let start = now(), position = model.position
                var appeared: Double?, cancelled = false
                let watcher = Timer(timeInterval: 0.01, repeats: true) { timer in
                    let current = ProcessInfo.processInfo.systemUptime
                    if let panel = NSApp.windows.first(where: { $0 is NSOpenPanel && $0.isVisible }) as? NSOpenPanel {
                        if appeared == nil { appeared = current }
                        if current - start >= 1.2 { panel.cancel(nil); cancelled = true; timer.invalidate() }
                    } else if current - start > 5 { cancelled = true; timer.invalidate() }
                }
                RunLoop.main.add(watcher, forMode: .common)
                if subtitle { model.chooseSubtitle() } else { model.chooseVideo() }
                returnTimes.append((now() - start) * 1000)
                _ = await wait { cancelled }; watcher.invalidate()
                if let appeared { durations.append((appeared - start) * 1000) }
                progressed = progressed && model.position > position + 0.1
                await delay(0.3)
            }
            checks[(subtitle ? "subtitle" : "video") + "-panels-opened-and-cancelled"] = durations.count == 3
            rows.append(["name": subtitle ? "subtitle-file-panel" : "video-file-panel", "visible_ms": durations, "call_return_ms": returnTimes, "main_stall_ms": distribution(gaps), "playback_clock_progressed": progressed])
        }
        heartbeat.invalidate()
        checks["file-panels-keep-playback-clock-running"] = rows.filter { ($0["name"] as? String)?.contains("file-panel") == true }.allSatisfy { $0["playback_clock_progressed"] as? Bool == true }
        checks["cancelled-panels-release-presentation"] = !model.filePanels.isPresenting
        model.settingsPage = 0; model.showSettings = true; await delay(0.6)
        func settingsElement(_ id: String) -> NSObject? {
            for target in NSApp.windows.filter(\.isVisible) { if let result = find(target, id) { return result } }; return nil
        }
        if let field = settingsElement("settings-acoustic-model"), field.responds(to: NSSelectorFromString("setAccessibilityValue:")) {
            _ = field.perform(NSSelectorFromString("setAccessibilityValue:"), with: "unsaved-test-model")
            await delay(0.1)
            _ = segment("settings-page", 1)?.perform(NSSelectorFromString("accessibilityPerformPress")); await delay(0.1)
            _ = segment("settings-page", 0)?.perform(NSSelectorFromString("accessibilityPerformPress")); await delay(0.1)
            checks["settings-tab-preserves-unsaved-draft"] = settingsElement("settings-acoustic-model")?.value(forKey: "accessibilityValue") as? String == "unsaved-test-model"
        } else { checks["settings-tab-preserves-unsaved-draft"] = false }
        let owner = window.attachedSheet
        if let button = settingsElement("choose-runtime-FFmpeg") {
            _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
            _ = await wait { model.filePanels.activePanel?.isVisible == true }
            let panel = model.filePanels.activePanel
            checks["runtime-file-panel-attaches-to-settings"] = panel != nil && panel?.sheetParent === owner && panel?.allowsMultipleSelection == false && panel?.allowedContentTypes.isEmpty == true
            model.chooseVideo()
            checks["duplicate-open-keeps-existing-panel-and-filter"] = model.filePanels.activePanel === panel && panel?.message == "选择FFmpeg" && panel?.allowedContentTypes.isEmpty == true
            let keyboard = KeyboardRouter(model: model); keyboard.isPlayerWindow = { $0 === window || $0 === owner }
            model.recordingAction = .playPause
            let before = model.preferences.shortcut(for: .playPause)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: now(), windowNumber: panel?.windowNumber ?? window.windowNumber, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40)!
            checks["file-panel-blocks-playback-and-shortcut-recording"] = keyboard.handle(event) != nil && model.preferences.shortcut(for: .playPause) == before
            model.recordingAction = nil; panel?.cancel(nil)
            _ = await wait { !model.filePanels.isPresenting }; await delay(0.3)
            checks["cancel-runtime-panel-keeps-settings-draft"] = model.showSettings && settingsElement("settings-acoustic-model")?.value(forKey: "accessibilityValue") as? String == "unsaved-test-model"
        } else { checks["runtime-file-panel-attaches-to-settings"] = false }
        model.showSettings = false; await delay(0.4)
        model.showSubtitleSearch = true; await delay(0.4)
        let searchOwner = window.attachedSheet
        if let button = settingsElement("search-manual-import") {
            _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
            _ = await wait { model.filePanels.activePanel?.isVisible == true }
            checks["manual-import-keeps-search-sheet-as-owner"] = model.showSubtitleSearch && model.filePanels.activePanel?.sheetParent === searchOwner
            model.filePanels.activePanel?.cancel(nil)
            _ = await wait { !model.filePanels.isPresenting }; await delay(0.3)
            checks["cancel-manual-import-returns-to-search"] = model.showSubtitleSearch && window.attachedSheet === searchOwner
        } else { checks["manual-import-keeps-search-sheet-as-owner"] = false }
        model.showSubtitleSearch = false; await delay(0.4)
        WindowSnapshot.save(window, to: output.appendingPathComponent("final.png"))
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        if let tiff = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: output.appendingPathComponent("finder-icon.png")) }
        let result: [String: Any] = ["checks": checks, "passed": checks.values.allSatisfy { $0 }, "scenarios": rows]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("ui-performance.json"))
        NSApp.terminate(nil)
    }
}
