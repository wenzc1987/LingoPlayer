import AppKit
import PlayerCore
import Darwin

/// Local diagnostics only; production calls return before locking or allocating.
final class PerformanceCounters: @unchecked Sendable {
    static let shared = PerformanceCounters()
    private let enabled = CommandLine.arguments.contains("--performance-test")
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func hit(_ key: String, count: Int = 1) {
        guard enabled else { return }; lock.lock(); counts[key, default: 0] += count; lock.unlock()
    }
    func reset() { lock.lock(); counts = [:]; lock.unlock() }
    func snapshot() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }
}

@MainActor enum PerformanceSmoke {
    static func run(model: AppModel, window: NSWindow, video: URL, output: URL) async {
        // This runner only measures steady playback. Keep incidental pointer
        // movement/clicks from changing its scenario while the user works.
        window.ignoresMouseEvents = true
        func delay(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
        func wait(_ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(15)
            while Date() < end { if condition() { return true }; await delay(0.025) }; return condition()
        }
        func cpu() -> Double {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        func memory() -> [String: Double] {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return [:] }
            return ["resident_mib": Double(info.resident_size) / 1048576,
                    "footprint_mib": Double(info.phys_footprint) / 1048576]
        }
        model.settings.autoSearch = false; model.settings.mfa = "/missing/performance-smoke"
        model.setVolume(0); model.player.set("mute", "yes"); model.open(video)
        let loaded = await wait { model.playbackReady && model.duration > 20 }
        guard loaded else { NSApp.terminate(nil); return }
        // Discovery can finish after mpv is ready and reset alignment data.
        // Finish it before installing the identical synthetic workload.
        await model.openTask?.value
        model.english = (0..<5000).map { .init(id: "perf-\($0)", start: Double($0) * 1.5, end: Double($0) * 1.5 + 1.4, text: "We can listen again and learn something new together.") }
        model.chinese = (0..<5000).map { .init(id: "zh-\($0)", start: Double($0) * 1.5, end: Double($0) * 1.5 + 1.4, text: "我们可以再听一遍，一起学习新的内容。") }
        // Assigning English can enter learning mode and start a new aligner.
        // Join that producer before supplying synthetic word timings.
        model.aligner.cancel(); await model.aligner.waitForCancellation()
        // Synthetic word times exercise UI updates; they do not measure alignment accuracy.
        model.timings = model.english.prefix(20).flatMap { cue -> [TimedWord] in
            let words = cue.tokens.filter(\.isWord)
            return words.enumerated().map { index, token in .init(cueID: cue.id, tokenIndex: token.id, start: cue.start + Double(index) * 1.4 / Double(words.count), end: cue.start + Double(index + 1) * 1.4 / Double(words.count)) }
        }
        model.refreshTranscript(reset: true); _ = await wait { !model.transcript.isPreparing }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        var scenarios: [[String: Any]] = []
        let requested = ProcessInfo.processInfo.environment["LINGOPLAYER_PERF_SCENARIO"]
        let sampleCount = max(120, min(400, Int(ProcessInfo.processInfo.environment["LINGOPLAYER_PERF_SAMPLES"] ?? "120") ?? 120))
        for name in ["immersive", "controls", "learning", "transcript"] where requested == nil || requested == name {
            model.chrome.hold(.keyboard, active: false)
            model.setSidebarCollapsed(name == "immersive" || name == "controls")
            model.sidebarTab = name == "transcript" ? .transcript : .learning
            model.seek(1)
            if !model.endGate.wantsPlayback { model.togglePlayback() }
            _ = await wait { model.seekTarget == nil && !model.paused }
            // Let native hover/focus callbacks settle after the sidebar resize
            // before choosing the chrome state for the measured interval.
            if name == "immersive" { await delay(0.5) }
            if name == "immersive" { if model.chrome.visible { model.chrome.toggle() } }
            else { model.chrome.hold(.keyboard, active: true) }
            await delay(1)
            let counters = PerformanceCounters.shared
            counters.reset()
            let start = ProcessInfo.processInfo.systemUptime, cpuStart = cpu(), frames = model.videoView.renderedFrames
            var wakeups: [Double] = []
            var resources: [[String: Double]] = []
            var sampleTime = start, sampleCPU = cpuStart
            var highlightedWords = Set<String>()
            for index in 0..<sampleCount {
                let before = ProcessInfo.processInfo.systemUptime
                await delay(0.05)
                wakeups.append(max(0, ProcessInfo.processInfo.systemUptime - before - 0.05) * 1000)
                if let word = model.currentWordID { highlightedWords.insert(word) }
                if (index + 1).isMultiple(of: 20) {
                    let now = ProcessInfo.processInfo.systemUptime, used = cpu()
                    var sample = memory()
                    sample["cpu_percent_one_core"] = (used - sampleCPU) / (now - sampleTime) * 100
                    sample["elapsed_seconds"] = now - start
                    resources.append(sample); sampleTime = now; sampleCPU = used
                }
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - start, cpuSeconds = cpu() - cpuStart
            let counts = counters.snapshot(); wakeups.sort()
            scenarios.append(["name": name, "wall_seconds": elapsed, "cpu_seconds": cpuSeconds, "cpu_percent_one_core": cpuSeconds / elapsed * 100, "rendered_frames": model.videoView.renderedFrames - frames, "main_wakeup_p95_ms": wakeups[Int(Double(wakeups.count - 1) * 0.95)], "main_wakeup_max_ms": wakeups.last!, "counts": counts, "highlighted_words": highlightedWords.count, "word_timing_count": model.timings.count, "english_count": model.english.count, "paused": model.paused, "controls_visible": model.chrome.visible, "resource_samples": resources])
            print("performance", name, cpuSeconds / elapsed * 100, counts); fflush(stdout)
            if ProcessInfo.processInfo.environment["LINGOPLAYER_PERF_SNAPSHOTS"] == "1" {
                WindowSnapshot.save(window, to: output.deletingLastPathComponent().appendingPathComponent(name + ".png"))
            }
        }
        let result: [String: Any] = ["scenarios": scenarios, "subtitle_count": 5000, "synthetic_word_times": true]
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        NSApp.terminate(nil)
    }
}
