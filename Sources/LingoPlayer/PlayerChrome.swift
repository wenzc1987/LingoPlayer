import Foundation
import Combine
import PlayerCore

enum PlayerPopover { case subtitles, speed, volume }

@MainActor final class PlayerChrome: ObservableObject {
    @Published private(set) var state = ControlVisibility()
    @Published private(set) var notice: String?
    var visible: Bool { state.visible }
    var onVisibilityChange: ((Bool) -> Void)?
    private var timer: Task<Void, Never>?
    private var noticeTimer: Task<Void, Never>?
    private var noticeKey: String?
    private var revision = UUID()
    private var now: Double { ProcessInfo.processInfo.systemUptime }
    func playback(paused: Bool, ready: Bool) { change { $0.playback(paused: paused, ready: ready, now: now) } }
    func show() { change { $0.show(now: now) } }
    func toggle() {
        // A click on the empty stage supersedes hover/focus left behind by an
        // overlay disappearing or the native tracking areas being rebuilt.
        change {
            $0.hold(.keyboard, active: false, now: now)
            $0.hold(.pointer, active: false, now: now)
            $0.hold(.windowButtons, active: false, now: now)
            $0.toggle(now: now)
        }
    }
    func hold(_ reason: ControlVisibility.Hold, active: Bool) { change { $0.hold(reason, active: active, now: now) } }
    func showNotice(_ message: String, key: String) {
        // Repeated backend failures and view updates must not keep a toast alive.
        guard noticeKey != key else { return }
        noticeKey = key; notice = message; noticeTimer?.cancel()
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
    func resetNotice() { noticeTimer?.cancel(); noticeTimer = nil; notice = nil; noticeKey = nil }
    private func change(_ update: (inout ControlVisibility) -> Void) {
        var next = state; update(&next)
        guard next != state else { return }
        let wasVisible = state.visible
        state = next
        if wasVisible != next.visible { onVisibilityChange?(next.visible) }
        timer?.cancel(); revision = UUID()
        guard let deadline = next.deadline else { timer = nil; return }
        let token = revision
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, deadline - ProcessInfo.processInfo.systemUptime) * 1e9))
            guard !Task.isCancelled, let self, self.revision == token else { return }
            self.change { $0.expire(now: self.now) }
        }
    }
}
