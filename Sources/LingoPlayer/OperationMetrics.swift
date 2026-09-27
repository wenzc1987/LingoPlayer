import AppKit
import SwiftUI
import PlayerCore

/// Dormant outside explicit performance diagnostics. No telemetry is uploaded.
@MainActor final class OperationMetrics {
    static let shared = OperationMetrics()
    var enabled = false
    var revision = 0
    var submitted = 0.0
    var started = 0.0
    var executed: Double?
    var maximumAVSync = 0.0
    var feedback: Double?
    var confirmed: Double?
    var action: PlayerAction?
    var expectedPause: Bool?
    var expectedSeek: Double?
    var expectedSession = UUID()
    func arm() { submitted = ProcessInfo.processInfo.systemUptime; started = 0; executed = nil; feedback = nil; confirmed = nil; action = nil; expectedPause = nil; expectedSeek = nil }
    func begin(_ action: PlayerAction, model: AppModel) {
        guard enabled else { return }
        revision += 1
        self.action = action; started = ProcessInfo.processInfo.systemUptime; expectedSession = model.sessionID
        if action == .playPause { expectedPause = model.endGate.wantsPlayback }
        if action == .backward || action == .forward { expectedSeek = max(0, min(model.duration, model.position + (action == .forward ? 5 : -5))) }
    }
    func end() { if enabled { executed = ProcessInfo.processInfo.systemUptime } }
    func painted() { if enabled && started > 0 && feedback == nil { feedback = ProcessInfo.processInfo.systemUptime } }
    func observe(_ snapshot: PlaybackSnapshot) {
        if enabled && !snapshot.seeking && snapshot.avSync.isFinite { maximumAVSync = max(maximumAVSync, abs(snapshot.avSync)) }
        guard enabled, started > 0, confirmed == nil, snapshot.loaded, snapshot.generation == expectedSession, snapshot.sampledAt >= started else { return }
        if let expectedPause, snapshot.paused == expectedPause { confirmed = ProcessInfo.processInfo.systemUptime }
        if let expectedSeek, !snapshot.seeking, abs(snapshot.position - expectedSeek) < 0.3 { confirmed = ProcessInfo.processInfo.systemUptime }
    }
    var row: [String: Any] {
        ["action": action?.rawValue ?? "not-dispatched", "dispatch_ms": (started - submitted) * 1000,
         "execution_ms": executed.map { ($0 - started) * 1000 } ?? -1,
         "feedback_ms": feedback.map { ($0 - submitted) * 1000 } ?? -1,
         "native_confirmation_ms": confirmed.map { ($0 - submitted) * 1000 } ?? -1]
    }
}

struct FeedbackProbe: NSViewRepresentable {
    let revision: Int
    func makeNSView(context: Context) -> FeedbackProbeView { FeedbackProbeView() }
    func updateNSView(_ view: FeedbackProbeView, context: Context) {
        if OperationMetrics.shared.enabled {
            view.needsDisplay = true
            // Explicit diagnostics also measure occluded test windows. Force the
            // native probe to paint after SwiftUI has committed this update.
            view.display()
        }
    }
}
final class FeedbackProbeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { OperationMetrics.shared.painted() }
}
