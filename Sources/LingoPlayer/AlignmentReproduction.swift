import AppKit
import PlayerCore

@MainActor enum AlignmentReproduction {
    static func run(model: AppModel, request: URL, output: URL) async {
        func wait(_ seconds: Double, _ predicate: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if predicate() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }; return predicate()
        }
        let input = (try? Data(contentsOf: request)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard let path = input["video"] as? String else { NSApp.terminate(nil); return }
        let mfa = model.settings.mfa
        model.settings.autoSearch = false; model.settings.mfa = "/missing/await-reproduction"; model.setVolume(0); model.player.set("mute", "yes")
        model.open(URL(fileURLWithPath: path))
        let loaded = await wait(30) { model.playbackReady && model.selectedAudio >= 0 }
        if let path = input["subtitle"] as? String { try? await model.attachSubtitle(URL(fileURLWithPath: path), language: nil, onlyMissing: false, session: model.sessionID) }
        model.seek(input["position"] as? Double ?? 0)
        if model.endGate.wantsPlayback { model.togglePlayback() }
        _ = await wait(10) { model.seekTarget == nil }
        model.settings.mfa = mfa
        let started = Date()
        let metrics = RuntimeSettings.supportDirectory.appendingPathComponent("alignment-metrics.jsonl")
        model.restartAlignment()
        let finished = await wait(150) { FileManager.default.fileExists(atPath: metrics.path) || model.alignmentTaskStatus.phase == .environmentFailure }
        let status = model.alignmentTaskStatus
        let result: [String: Any] = ["video_loaded": loaded, "batch_finished": finished, "elapsed_seconds": Date().timeIntervalSince(started), "phase": status.phase.rawValue, "status": status.message, "diagnostic": status.diagnostic?.path ?? "", "words": model.alignedWordCount, "python": model.settings.python,
            "metrics": (try? String(contentsOf: metrics, encoding: .utf8)) ?? ""]
        model.aligner.cancel(); await model.aligner.waitForCancellation()
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        NSApp.terminate(nil)
    }
}
