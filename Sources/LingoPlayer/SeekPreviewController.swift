import AppKit
import Combine
import ImageIO
import PlayerCore

@MainActor
final class SeekPreviewController: ObservableObject {
    @Published private(set) var visible = false
    @Published private(set) var target = 0.0
    @Published private(set) var image: NSImage?
    private var media: URL?
    private var ffmpeg = ""
    private var enabled = true
    private var generation = UUID()
    private var pending: Int?
    private var requested: Int?
    private var inFlight: Int?
    private var worker: Task<Void, Never>?
    private var lastStart = -Double.infinity
    private var cache = SeekPreviewCache<NSImage>()
    private(set) var requests = 0, cacheHits = 0, processStarts = 0, failures = 0
    private(set) var startTimes: [Double] = [], elapsed: [Double] = []
    var cacheCount: Int { cache.count }
    var cacheBytes: Int { cache.bytes }
    var isWorking: Bool { worker != nil }

    func setMedia(_ media: URL?, ffmpeg: String) {
        endDrag(); generation = UUID(); self.media = media; self.ffmpeg = ffmpeg
        cache.removeAll()
    }
    func setEnabled(_ enabled: Bool) { self.enabled = enabled; if !enabled { endDrag() } }
    func request(_ time: Double, duration: Double) {
        guard enabled, media != nil, time.isFinite, duration.isFinite, duration > 0 else { return }
        visible = true; target = min(duration, max(0, time)); requests += 1
        let bucket = SeekPreviewCache<NSImage>.bucket(min(target, max(0, duration - 0.001)))
        if requested != bucket { image = nil }
        requested = bucket
        if let cached = cache.value(for: bucket) {
            cacheHits += 1; image = cached; pending = nil
        } else if inFlight != bucket || worker?.isCancelled == true {
            pending = bucket; startWorker()
        } else { pending = nil }
    }
    func endDrag() {
        visible = false; image = nil; requested = nil; pending = nil
        worker?.cancel()
        // Keep ownership until process termination; never overlap a replacement.
    }
    func waitForIdle() async { while let worker { await worker.value } }

    private func startWorker() {
        guard worker == nil, pending != nil, visible, let media else { return }
        let generation = generation, executable = ffmpeg
        worker = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.generation == generation, visible, pending != nil {
                let delay = max(0, lastStart + 0.25 - ProcessInfo.processInfo.systemUptime)
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
                guard !Task.isCancelled, self.generation == generation, visible, let bucket = pending else { break }
                pending = nil; inFlight = bucket
                lastStart = ProcessInfo.processInfo.systemUptime
                processStarts += 1; startTimes.append(lastStart)
                // Retain a bounded diagnostic history as well as a bounded image cache.
                if startTimes.count > 256 { startTimes.removeFirst() }
                do {
                    let data = try await ProcessRunner.preview(executable: executable, arguments: SeekPreviewFrame.arguments(media: media, time: Double(bucket * 2)))
                    let decoded = await Task.detached(priority: .utility) { () -> CGImage? in
                        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                    }.value
                    guard let decoded else { throw ProcessFailure(message: "预览不可用") }
                    if self.generation == generation {
                        let preview = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
                        cache.insert(preview, bucket: bucket, bytes: decoded.bytesPerRow * decoded.height + data.count)
                        if !Task.isCancelled, visible, requested == bucket { image = preview }
                    }
                } catch { if !Task.isCancelled { failures += 1 } }
                elapsed.append(ProcessInfo.processInfo.systemUptime - lastStart)
                if elapsed.count > 256 { elapsed.removeFirst() }
                inFlight = nil
            }
            inFlight = nil; worker = nil
            startWorker()
        }
    }
}
