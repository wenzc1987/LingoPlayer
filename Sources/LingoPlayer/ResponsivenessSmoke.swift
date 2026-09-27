import AppKit
import PlayerCore

@MainActor enum ResponsivenessSmoke {
    static func run(model: AppModel, window: NSWindow, request: URL, output: URL) async {
        func delay(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        func wait(_ timeout: Double = 30, _ predicate: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline { if predicate() { return true }; await delay(0.005) }; return predicate()
        }
        let data = (try? Data(contentsOf: request)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard let path = data["video"] as? String else { NSApp.terminate(nil); return }
        let buttonInput = data["input"] as? String == "button"
        func findButton(_ root: NSObject, id: String, depth: Int = 0) -> NSObject? {
            guard depth < 25 else { return nil }
            let identifier = NSSelectorFromString("accessibilityIdentifier"), children = NSSelectorFromString("accessibilityChildren")
            if root.responds(to: identifier), root.perform(identifier)?.takeUnretainedValue() as? String == id { return root }
            let descendants: [Any]
            if root.responds(to: children) { descendants = root.perform(children)?.takeUnretainedValue() as? [Any] ?? [] }
            else { descendants = root.accessibilityAttributeValue(.children) as? [Any] ?? [] }
            for child in descendants {
                if let child = child as? NSObject, let result = findButton(child, id: id, depth: depth + 1) { return result }
            }
            return nil
        }
        let actualMFA = model.settings.mfa
        model.settings.autoSearch = false; model.settings.mfa = "/missing/performance-baseline"; model.setVolume(0); model.player.set("mute", "yes")
        model.open(URL(fileURLWithPath: path))
        _ = await wait { model.playbackReady && model.duration > 0 && model.selectedAudio >= 0 }
        if let subtitle = data["subtitle"] as? String { try? await model.attachSubtitle(URL(fileURLWithPath: subtitle), language: nil, onlyMissing: false, session: model.sessionID) }
        let base = min(max(1, data["position"] as? Double ?? 1), model.duration - 15)
        let english = model.english, chinese = model.chinese, digest = model.englishDigest
        let metrics = OperationMetrics.shared
        var scenarios: [[String: Any]] = []
        var buttonPoints: [PlayerAction: NSPoint] = [:]
        if buttonInput {
            if model.endGate.wantsPlayback { model.togglePlayback() }
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.becomeKey()
            await delay(0.5)
            for action in [PlayerAction.forward, .backward, .playPause, .toggleSidebarVisibility] {
                if let button = findButton(window, id: action == .toggleSidebarVisibility ? "toggle-sidebar" : "action-" + action.rawValue),
                   button.responds(to: NSSelectorFromString("accessibilityFrame")),
                   let rect = (button.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue, !rect.isEmpty {
                    buttonPoints[action] = window.convertPoint(fromScreen: CGPoint(x: rect.midX, y: rect.midY))
                }
            }
            // AX geometry setup can initialize text/input services. Drain that
            // setup before measuring mouse events; users do not perform AX walks.
            await delay(2)
        }
        metrics.enabled = true
        for large in [false, true] {
            model.aligner.cancel()
            if large {
                model.english = (0..<5000).map { .init(id: "perf-\($0)", start: Double($0) * 1.5, end: Double($0) * 1.5 + 1.4, text: "This is a listening practice sentence number \($0).") }
                model.chinese = (0..<5000).map { .init(id: "perf-zh-\($0)", start: Double($0) * 1.5, end: Double($0) * 1.5 + 1.4, text: "用于滚动与搜索性能检查的中文字幕。") }
                model.englishDigest = "performance-5000"
            } else { model.english = english; model.chinese = chinese; model.englishDigest = digest }
            model.refreshTranscript(reset: true)
            _ = await wait { !model.transcript.isPreparing }
            for state in ["paused", "playing", "aligning"] {
                model.aligner.cancel(); model.seek(base)
                if model.endGate.wantsPlayback { model.togglePlayback() }
                _ = await wait { model.seekTarget == nil && model.paused }
                if state != "paused" { model.togglePlayback() }
                if state == "aligning" { model.settings.mfa = actualMFA; model.restartAlignment() }
                else { model.settings.mfa = "/missing/performance-baseline" }
                model.sidebarTab = .learning
                await delay(0.4)
                var rows: [[String: Any]] = []
                // 60 events per condition: actual keyboard routes, including 20
                // native pause acknowledgements when the condition permits it.
                for i in 0..<60 {
                    let action: PlayerAction
                    if buttonInput {
                        action = state == "paused" ? [.forward, .backward, .toggleSidebarVisibility, .toggleSidebarVisibility][i % 4]
                            : [.playPause, .playPause, .forward, .backward, .toggleSidebarVisibility, .toggleSidebarVisibility][i % 6]
                    } else if state == "paused" { action = [.volumeUp, .volumeDown, .toggleSidebar, .cycleSubtitleDisplay][i % 4] }
                    else { action = [.playPause, .playPause, .toggleSidebar, .cycleSubtitleDisplay, .forward, .backward][i % 6] }
                    let shortcut = model.preferences.shortcut(for: action)!
                    NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(nil); window.becomeKey()
                    await delay(0.03)
                    window.becomeKey(); window.makeFirstResponder(window)
                    // Floating controls move when the sidebar or subtitle height
                    // changes. Resolve each target before starting its timing.
                    if buttonInput {
                        model.chrome.show(); await delay(0.05)
                        if let button = findButton(window, id: action == .toggleSidebarVisibility ? "toggle-sidebar" : "action-" + action.rawValue),
                           button.responds(to: NSSelectorFromString("accessibilityFrame")),
                           let rect = (button.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue, !rect.isEmpty {
                            buttonPoints[action] = window.convertPoint(fromScreen: CGPoint(x: rect.midX, y: rect.midY))
                        } else { print("missing native button", action.rawValue); fflush(stdout); break }
                    }
                    metrics.arm()
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shortcut.menuModifiers, timestamp: metrics.submitted,
                        windowNumber: window.windowNumber, context: nil, characters: shortcut.menuKey, charactersIgnoringModifiers: shortcut.menuKey, isARepeat: false, keyCode: shortcut.keyCode)!
                    if buttonInput, let point = buttonPoints[action] {
                        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: metrics.submitted, windowNumber: window.windowNumber, context: nil, eventNumber: i * 2, clickCount: 1, pressure: 1)!
                        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: metrics.submitted + 0.008, windowNumber: window.windowNumber, context: nil, eventNumber: i * 2 + 1, clickCount: 1, pressure: 0)!
                        NSApp.postEvent(down, atStart: false)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { NSApp.postEvent(up, atStart: false) }
                    } else { NSApp.postEvent(event, atStart: false) }
                    _ = await wait(4) { metrics.feedback != nil && (metrics.expectedPause == nil && metrics.expectedSeek == nil || metrics.confirmed != nil) }
                    rows.append(metrics.row)
                    if i % 10 == 0 { print("response", large, state, i, metrics.row, "key", NSApp.keyWindow === window, "responder", String(describing: window.firstResponder), "alert", model.alert ?? "none"); fflush(stdout) }
                    // Keep collecting after a focus interruption; retain the failed row.
                    await delay(0.04)
                }
                func distribution(_ key: String, _ onlyPause: Bool = false) -> [String: Double] {
                    let values = rows.filter { !onlyPause || $0["action"] as? String == "playPause" }.compactMap { $0[key] as? Double }.filter { $0 >= 0 }.sorted()
                    guard !values.isEmpty else { return [:] }
                    return ["p95": values[min(values.count - 1, Int(ceil(Double(values.count) * 0.95)) - 1)], "max": values.last!, "count": Double(values.count)]
                }
                scenarios.append(["subtitles": large ? "5000" : "user-film", "state": state, "operations": rows,
                    "feedback_ms": distribution("feedback_ms"), "dispatch_ms": distribution("dispatch_ms"),
                    "pause_confirmation_ms": distribution("native_confirmation_ms", true), "execution_ms": distribution("execution_ms"),
                    "seek_confirmation_ms": rows.filter { ["forward", "backward"].contains($0["action"] as? String ?? "") }.compactMap { $0["native_confirmation_ms"] as? Double },
                    "alignment_status": model.alignmentStatus])
            }
        }
        metrics.enabled = false; model.aligner.cancel()
        let result: [String: Any] = ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "", "input": buttonInput ? "native-mouse-button" : "keyboard", "scenarios": scenarios, "maximum_observed_avsync_seconds": metrics.maximumAVSync]
        if let encoded = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? encoded.write(to: output) }
        NSApp.terminate(nil)
    }
}
