import Foundation

public struct QueueItem: Codable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public var failure: String?
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public init(url: URL) { path = url.resolvingSymlinksInPath().standardizedFileURL.path }
}

/// Order and selection are independent of per-file progress.
public struct PlaybackQueue: Codable, Equatable {
    public var items: [QueueItem] = []
    public var currentID: String?
    public init() {}
    public var currentIndex: Int? { items.firstIndex { $0.id == currentID } }
    @discardableResult public mutating func append(_ urls: [URL]) -> [String] {
        let batch = urls.map(QueueItem.init).sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
        var result: [String] = []
        for item in batch {
            if !result.contains(item.id) { result.append(item.id) }
            if !items.contains(where: { $0.id == item.id }) { items.append(item) }
        }
        return result
    }
    public func adjacent(_ direction: Int) -> String? {
        guard let index = currentIndex, items.indices.contains(index + direction) else { return nil }
        return items[index + direction].id
    }
    /// Return the original successor; removing the last item never wraps.
    @discardableResult public mutating func remove(_ id: String) -> String? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let successor = items.indices.contains(index + 1) ? items[index + 1].id : nil
        items.remove(at: index)
        if currentID == id { currentID = successor }
        return successor
    }
    public mutating func move(_ id: String, before target: String?) {
        guard id != target, let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        let destination = target.flatMap { value in items.firstIndex { $0.id == value } } ?? items.endIndex
        items.insert(item, at: destination)
    }
    public mutating func mark(_ id: String, failure: String?) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].failure = failure }
    }
}

public struct PlaybackProgress: Codable, Equatable {
    public var mediaKey: String
    public var position: Double
    public var duration: Double
    public var finished: Bool
    public init(mediaKey: String, position: Double = 0, duration: Double = 0, finished: Bool = false) {
        self.mediaKey = mediaKey; self.position = position; self.duration = duration; self.finished = finished
    }
}

public enum PlaybackPurpose { case normal, sentenceReplay, restoration }

/// An EOF edge is consumed exactly once, including edges suppressed during replay.
public struct PlaybackEndGate {
    public private(set) var generation = UUID()
    public var purpose: PlaybackPurpose = .normal
    public var wantsPlayback = false
    private var sawClear = false
    private var consumed = false
    public init() {}
    public mutating func begin(_ generation: UUID, purpose: PlaybackPurpose, playing: Bool) {
        self.generation = generation; self.purpose = purpose; wantsPlayback = playing
        sawClear = false; consumed = false
    }
    public mutating func observe(generation: UUID, eof: Bool) -> Bool {
        guard self.generation == generation else { return false }
        if !eof { sawClear = true; consumed = false; return false }
        guard sawClear, !consumed else { return false }
        consumed = true
        return purpose == .normal && wantsPlayback
    }
}

public enum SentenceNavigation {
    /// In a gap, previous chooses the last start; within a cue it chooses the preceding cue.
    /// A small tolerance prevents a seek landing a few milliseconds late from skipping a cue.
    public static func target(cues: [SubtitleCue], position: Double, offset: Double, direction: Int) -> Double? {
        let time = position - offset
        let ordered = cues.sorted { $0.start < $1.start }
        if direction > 0 { return ordered.first { $0.start > time + 0.05 }.map { max(0, $0.start + offset) } }
        if let active = ordered.last(where: { $0.start <= time + 0.05 && $0.end > time }) {
            return ordered.last { $0.start < active.start - 0.001 }.map { max(0, $0.start + offset) }
        }
        return ordered.last { $0.start < time - 0.05 }.map { max(0, $0.start + offset) }
    }
}
