import Foundation
import Testing
@testable import PlayerCore

struct ResponsivenessTests {
    @Test func cachedTokensRoundTripAndMutation() throws {
        var cue = SubtitleCue(id: "one", start: 0, end: 1, text: "Don't stop!")
        let data = try JSONEncoder().encode(cue)
        #expect(!String(decoding: data, as: UTF8.self).contains("cachedTokens"))
        #expect(try JSONDecoder().decode(SubtitleCue.self, from: data).tokens == cue.tokens)
        cue.text = "Changed text"; #expect(cue.tokens == WordToken.tokenize("Changed text"))
    }
    @Test func indexedTimelineMatchesOverlaps() {
        let cues = (0..<5000).map { SubtitleCue(id: "\($0)", start: Double($0), end: Double($0) + ($0 % 5 == 0 ? 8 : 0.8), text: "word") }
        let index = TimelineIndex(starts: cues.map(\.start), ends: cues.map(\.end))
        for position in stride(from: 0.0, to: 5001, by: 7.3) {
            #expect(index.active(at: position).map { cues[$0] } == Timeline.active(cues, at: position, offset: 0))
        }
    }
    @Test func displayPreferenceUpgradeAndBindingConflict() throws {
        let legacy = Data(#"{"bindings":{"playPause":{"keyCode":37,"key":"l","modifiers":3}},"disabled":[],"autoplay":true}"#.utf8)
        var upgraded = try JSONDecoder().decode(InteractionPreferences.self, from: legacy)
        #expect(!upgraded.cardHidden && !upgraded.sidebarCollapsed)
        #expect(upgraded.shortcut(for: .toggleSidebarVisibility) == nil)
        #expect(upgraded.conflictNotices.contains(PlayerAction.toggleSidebarVisibility.rawValue))
        upgraded.cardHidden = true; upgraded.sidebarCollapsed = true
        let restored = try JSONDecoder().decode(InteractionPreferences.self, from: JSONEncoder().encode(upgraded))
        #expect(restored.cardHidden && restored.sidebarCollapsed)
    }
    @Test func boundedFailureRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskDiagnostics(directory: directory, limit: 3, byteLimit: 2000)
        for i in 0..<10 { _ = try await store.record(summary: "failure \(i)", configuration: "python=test", output: String(repeating: "x", count: 500), logs: "MFA traceback") }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        #expect(files.count <= 3)
        #expect(try files.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! } <= 2000)
        #expect(try files.contains { try String(contentsOf: $0).contains("failure 9") })
        for prefix in ["", "x", "xx"] {
            let newest = try await store.record(summary: "oversize", configuration: "", output: prefix + String(repeating: "错误", count: 2000), logs: "")
            #expect(try Data(contentsOf: newest).count <= 2000)
            let text = try String(contentsOf: newest, encoding: .utf8)
            #expect(text.contains("错误") && text.contains("output truncated"))
        }
    }
    @Test func processExitRetainsCompleteOutputAndTimeout() async throws {
        do { _ = try await ProcessRunner.run(executable: "/usr/bin/python3", arguments: ["-c", "import sys; sys.stderr.write('BEGIN'+('x'*5000)+'END'); sys.exit(7)"]); Issue.record("expected failure") }
        catch let error as ProcessFailure { #expect(error.exitCode == 7); #expect(error.output.contains("BEGIN")); #expect(error.output.contains("END")) }
        let start = Date()
        do { _ = try await ProcessRunner.run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.1); Issue.record("expected timeout") }
        catch let error as ProcessFailure { #expect(error.timedOut) }
        #expect(Date().timeIntervalSince(start) < 3)
    }
    @Test func cancellingWorkerStopsItsChildBeforeReturning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let beat = directory.appendingPathComponent("heartbeat")
        let code = """
        import os,sys,subprocess,time
        if os.getpgrp()!=os.getpid(): os.setsid()
        child="import signal,time,pathlib; signal.signal(signal.SIGTERM,signal.SIG_IGN); p=pathlib.Path(__import__('sys').argv[1]); "+"exec('while True: p.write_text(str(time.time())); time.sleep(0.02)')"
        subprocess.Popen([sys.executable,'-c',child,sys.argv[1]])
        time.sleep(30)
        """
        let task = Task { try await ProcessRunner.run(executable: "/usr/bin/python3", arguments: ["-c", code, beat.path]) }
        for _ in 0..<100 { if FileManager.default.fileExists(atPath: beat.path) { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(FileManager.default.fileExists(atPath: beat.path))
        task.cancel()
        do { _ = try await task.value; Issue.record("expected cancellation") } catch is CancellationError {}
        let stopped = try String(contentsOf: beat)
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(try String(contentsOf: beat) == stopped)
    }

}
