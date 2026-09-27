import Foundation

/// UI activity uses a monotonic clock, independently of the movie's playback position.
public struct ControlVisibility: Equatable {
    public enum Hold: Hashable { case pointer, windowButtons, keyboard, scrubbing, presentation }
    public private(set) var visible = true
    public private(set) var deadline: Double?
    public private(set) var holds: Set<Hold> = []
    public private(set) var paused = true
    public private(set) var ready = false
    public init() {}
    public mutating func playback(paused: Bool, ready: Bool, now: Double) {
        guard self.paused != paused || self.ready != ready else { return }
        self.paused = paused; self.ready = ready
        show(now: now)
    }
    public mutating func show(now: Double) { visible = true; arm(now) }
    public mutating func toggle(now: Double) {
        guard holds.isEmpty else { return }
        visible.toggle(); arm(now)
    }
    public mutating func hold(_ reason: Hold, active: Bool, now: Double) {
        guard holds.contains(reason) != active else { return }
        if active { holds.insert(reason); visible = true } else { holds.remove(reason) }
        arm(now)
    }
    public mutating func expire(now: Double) {
        guard let deadline, now >= deadline else { return }
        visible = false; self.deadline = nil
    }
    private mutating func arm(_ now: Double) {
        deadline = visible && ready && !paused && holds.isEmpty ? now + 3 : nil
    }
}
