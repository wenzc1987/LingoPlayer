import AppKit
import SwiftUI
import OpenGL.GL3
import CMpv
import PlayerCore

struct PlaybackSnapshot {
    var generation: UUID
    var path: String
    var position: Double
    var duration: Double
    var paused: Bool
    var loaded: Bool
    var eof: Bool
    var error: String?
    var seekRevision: UInt64 = 0
    var seeking = false
    var avSync = 0.0
    var videoAspect: Double?
    var sampledAt = ProcessInfo.processInfo.systemUptime
}

final class MPVPlayer {
    private(set) var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "LingoPlayer.playback", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var generation = UUID()
    private var expectedPath = ""
    private var expectedEntry: Int64 = -1
    private var activeEntry: Int64 = -2
    private var fileReady = false
    private var seekRevision: UInt64 = 0
    private var lastSnapshot: PlaybackSnapshot?
    private var metadataDirty = true
    private var path = "", duration = 0.0
    private var paused = true, eof = false, seeking = false
    private var videoAspect: Double?
    var onUpdate: ((PlaybackSnapshot) -> Void)?
    var startupError: String?
    init(library: String) {
        var error = [CChar](repeating: 0, count: 1024)
        handle = lp_create(library, &error, error.count)
        guard handle != nil else { startupError = String(cString: error); return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer; timer.resume()
    }
    private func string(_ key: String) -> String {
        guard let handle, let ptr = lp_get_string(handle, key) else { return "" }
        defer { lp_free_string(handle, ptr) }
        return String(cString: ptr)
    }
    private func poll() {
        guard let handle else { return }
        var failure: String?
        for _ in 0..<100 {
            var error: Int32 = 0, entry: Int64 = -1
            let event = lp_poll_event(handle, &error, &entry)
            if event == 0 { break }
            if event == 6 || event == 8 || event == 22 { metadataDirty = true }
            if event == 6 { activeEntry = entry }
            if event == 8 && activeEntry == expectedEntry { fileReady = true }
            if event == 7 && entry == expectedEntry && error < 0 { failure = String(cString: lp_error(handle, error)) }
        }
        if metadataDirty {
            path = string("path"); duration = lp_get_double(handle, "duration", 0)
            paused = string("pause") == "yes"; eof = string("eof-reached") == "yes"
            seeking = string("seeking") == "yes"
            videoAspect = VideoWindowGeometry.displayAspect(width: lp_get_double(handle, "dwidth", 0), height: lp_get_double(handle, "dheight", 0), rotation: lp_get_double(handle, "video-out-params/rotate", 0))
            metadataDirty = false
            PerformanceCounters.shared.hit("playback_metadata_reads")
        }
        let ready = fileReady && activeEntry == expectedEntry && path == expectedPath
        let snapshot = PlaybackSnapshot(generation: generation, path: expectedPath,
            position: lp_get_double(handle, "time-pos", 0), duration: duration,
            paused: paused, loaded: ready, eof: ready && eof, error: failure, seekRevision: seekRevision, seeking: seeking, avSync: lp_get_double(handle, "avsync", 0),
            videoAspect: ready ? videoAspect : nil)
        if let old = lastSnapshot, old.generation == snapshot.generation, old.path == snapshot.path,
           old.position == snapshot.position, old.duration == snapshot.duration, old.paused == snapshot.paused,
           old.loaded == snapshot.loaded, old.eof == snapshot.eof, snapshot.error == nil,
           old.seekRevision == snapshot.seekRevision, old.seeking == snapshot.seeking, old.videoAspect == snapshot.videoAspect { return }
        lastSnapshot = snapshot
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(snapshot) }
    }
    @discardableResult private func execute(_ args: [String]) -> Int32 {
        guard let handle else { return -1 }
        let allocated = args.map { strdup($0) }
        defer { allocated.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = allocated.map { $0.map { UnsafePointer($0) } } + [nil]
        return pointers.withUnsafeBufferPointer { lp_command(handle, $0.baseAddress) }
    }
    func command(_ args: [String]) { queue.async { [weak self] in self?.execute(args) } }
    func set(_ key: String, _ value: String) {
        queue.async { [weak self] in guard let handle = self?.handle else { return }; _ = lp_set_string(handle, key, value) }
    }
    func selectAudio(streamIndex: Int) {
        queue.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            let count = Int(lp_get_double(handle, "track-list/count", 0))
            for index in 0..<count where self.string("track-list/\(index)/type") == "audio" {
                if Int(lp_get_double(handle, "track-list/\(index)/ff-index", -1)) == streamIndex {
                    _ = lp_set_string(handle, "aid", self.string("track-list/\(index)/id")); return
                }
            }
        }
    }
    func load(_ url: URL, generation: UUID, paused: Bool) {
        queue.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            self.generation = generation; self.expectedPath = url.path; self.fileReady = false
            self.activeEntry = -2; self.seekRevision = 0
            _ = lp_set_string(handle, "pause", paused ? "yes" : "no")
            let result = self.execute(["loadfile", url.path, "replace"])
            self.expectedEntry = Int64(lp_get_double(handle, "playlist/0/id", -1))
            if result < 0 {
                let snapshot = PlaybackSnapshot(generation: generation, path: url.path, position: 0, duration: 0, paused: true, loaded: false, eof: false, error: String(cString: lp_error(handle, result)))
                DispatchQueue.main.async { [weak self] in self?.onUpdate?(snapshot) }
            }
        }
    }
    func stop() { command(["stop"]) }
    func synchronize(revision: UInt64) { queue.async { [weak self] in self?.seekRevision = revision } }
    func seek(_ position: Double, revision: UInt64) {
        queue.async { [weak self] in
            guard let self else { return }
            self.seekRevision = revision
            self.execute(["seek", String(max(0, position)), "absolute+exact"])
        }
    }
    func pause(_ value: Bool) { set("pause", value ? "yes" : "no") }
    /// Caller must dispose the render context first, on its GL thread.
    func shutdown() {
        timer?.cancel(); timer = nil
        queue.sync { if let handle { lp_destroy(handle); self.handle = nil } }
    }
}

/// AppKit's backing layer asks for the associated view while committing every
/// window transaction. NSOpenGLContext's getter takes the rendering CGL lock,
/// including while mpv waits for a video frame or the GPU compiles a shader.
/// The association only changes on the main thread, before/after rendering;
/// keep that read independent of the GL state. Actual drawable updates and GL
/// operations still use the renderer's existing serialized handshake.
private final class VideoOpenGLContext: NSOpenGLContext {
    private weak var associatedView: NSView?
    override var view: NSView? {
        get { associatedView }
        set { super.view = newValue; associatedView = newValue }
    }
    override func clearDrawable() { super.clearDrawable(); associatedView = nil }
}

/// All libmpv render calls and GL context use are serialized independently of
/// both AppKit and the mpv command queue. Rendering may wait for presentation.
private final class VideoRenderer: @unchecked Sendable {
    let queue = DispatchQueue(label: "LingoPlayer.render", qos: .userInteractive)
    private var context: NSOpenGLContext?
    private var renderer: OpaquePointer?
    private var notification: UnsafeMutableRawPointer?
    private var size = CGSize(width: 1, height: 1)
    private var drawableUpdating = false
    private let lock = NSLock()
    private var queued = false, stopped = false, ready = false, frames = 0
    // Protected by lock: invalidate synchronously with AppKit geometry changes,
    // before any queued draw can present a viewport for the previous size.
    private var pendingSize = CGSize(width: 1, height: 1)
    private var drawableRevision = 0, drawableDirty = false
    var statistics: (Bool, Int) { lock.lock(); defer { lock.unlock() }; return (ready, frames) }
    func prepare(handle: OpaquePointer, context: NSOpenGLContext, size: CGSize, failure: @escaping (String) -> Void) {
        queue.async { [self] in
            guard !stopped, renderer == nil else { return }
            self.context = context; self.size = size
            CGLLockContext(context.cglContextObj!); defer { CGLUnlockContext(context.cglContextObj!) }
            context.makeCurrentContext()
            var interval: GLint = 1; context.setValues(&interval, for: .swapInterval)
            let note = Unmanaged.passRetained(self).toOpaque(); notification = note
            var error: Int32 = 0
            renderer = lp_render_create(handle, { pointer in
                guard let pointer else { return }
                Unmanaged<VideoRenderer>.fromOpaque(pointer).takeUnretainedValue().requestDraw()
            }, note, &error)
            lock.lock(); ready = renderer != nil; lock.unlock()
            if renderer == nil { DispatchQueue.main.async { failure("视频渲染初始化失败（\(error)）") } }
            NSOpenGLContext.clearCurrentContext(); requestDraw()
        }
    }
    func resize(_ size: CGSize) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        pendingSize = size; drawableRevision += 1; drawableDirty = true
        lock.unlock()
        queue.async { [self] in
            guard !stopped else { return }
            if !drawableUpdating { updateDrawable() }
        }
    }
    private func updateDrawable() {
        guard let context, !stopped else { return }
        drawableUpdating = true
        // Drain previous draws, skip new draws during the main-thread drawable
        // update, then resume. Neither queue waits synchronously for the other.
        RunLoop.main.perform(inModes: [.common]) { [self] in
            lock.lock()
            let stop = stopped, revision = drawableRevision, updatedSize = pendingSize
            lock.unlock()
            if !stop { context.update() }
            queue.async { [self] in
                lock.lock()
                guard !stopped else { lock.unlock(); return }
                let current = revision == drawableRevision
                if current { size = updatedSize; drawableDirty = false }
                lock.unlock()
                if current { drawableUpdating = false; requestDraw() }
                else { updateDrawable() }
            }
        }
    }
    func requestDraw() {
        lock.lock()
        guard !queued && !stopped else { lock.unlock(); return }
        queued = true; lock.unlock()
        queue.async { [self] in
            lock.lock(); queued = false; lock.unlock()
            guard drawableVersion() != nil, !drawableUpdating, let context else { return }
            CGLLockContext(context.cglContextObj!); defer { CGLUnlockContext(context.cglContextObj!) }
            context.makeCurrentContext()
            if let renderer { lp_render_draw(renderer, Int32(max(1, size.width)), Int32(max(1, size.height))) }
            else { glClearColor(0.03, 0.04, 0.05, 1); glClear(GLbitfield(GL_COLOR_BUFFER_BIT)) }
            // Finish the in-flight frame against its matching drawable. The
            // context.update handshake cannot run until this draw completes.
            // Dropping it for every new resize request starves live playback;
            // only queued draws must wait for the latest geometry above.
            context.flushBuffer()
            lock.lock(); frames += 1; lock.unlock()
            NSOpenGLContext.clearCurrentContext()
        }
    }
    private func drawableVersion() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return stopped || drawableDirty ? nil : drawableRevision
    }
    func diagnosticFrame() -> NSBitmapImageRep? {
        queue.sync { readFrame() }
    }
    func captureFrame() async -> NSBitmapImageRep? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: readFrame()) }
        }
    }
    private func readFrame() -> NSBitmapImageRep? {
        guard let revision = drawableVersion(), let renderer, let context, !drawableUpdating else { return nil }
        CGLLockContext(context.cglContextObj!); defer { CGLUnlockContext(context.cglContextObj!) }
        context.makeCurrentContext(); defer { NSOpenGLContext.clearCurrentContext() }
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
              let pixels = bitmap.bitmapData else { return nil }
        lp_render_draw(renderer, Int32(width), Int32(height))
        glReadBuffer(GLenum(GL_BACK)); glPixelStorei(GLenum(GL_PACK_ALIGNMENT), 1)
        glReadPixels(0, 0, Int32(width), Int32(height), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), pixels)
        let stride = width * 4
        for row in 0..<(height / 2) {
            let top = pixels.advanced(by: row * stride), bottom = pixels.advanced(by: (height - 1 - row) * stride)
            let saved = Data(bytes: top, count: stride); memcpy(top, bottom, stride); saved.copyBytes(to: bottom, count: stride)
        }
        guard drawableVersion() == revision else { return nil }
        context.flushBuffer(); return bitmap
    }
    func shutdown() {
        lock.lock(); stopped = true; lock.unlock()
        queue.sync {
            if let context { CGLLockContext(context.cglContextObj!) }
            defer { if let context { CGLUnlockContext(context.cglContextObj!) } }
            context?.makeCurrentContext()
            if let renderer { lp_render_free(renderer); self.renderer = nil }
            NSOpenGLContext.clearCurrentContext()
            if let notification { Unmanaged<VideoRenderer>.fromOpaque(notification).release(); self.notification = nil }
            lock.lock(); ready = false; lock.unlock()
        }
    }
}

/// A plain NSView avoids NSOpenGLView's implicit main-thread CGL locks during
/// layout. Only the renderer updates the drawable, after draining in-flight GL.
final class MPVVideoView: NSView {
    private let player: MPVPlayer
    private let renderer = VideoRenderer()
    private var prepared = false
    private let context: NSOpenGLContext
    private var drawableFrame = CGRect.null
    private var drawableSize = CGSize.zero
    var renderedFrames: Int { renderer.statistics.1 }
    var rendererReady: Bool { renderer.statistics.0 }
    var onRenderError: ((String) -> Void)?
    init(player: MPVPlayer) {
        self.player = player
        let attrs: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile), NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion3_2Core),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAccelerated), NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize), 24, 0
        ]
        context = VideoOpenGLContext(format: NSOpenGLPixelFormat(attributes: attrs)!, share: nil)!
        // Composite below the transparent window so SwiftUI captions and controls
        // remain above the movie, without copying video frames through the CPU.
        var order: GLint = -1
        context.setValues(&order, for: .surfaceOrder)
        super.init(frame: .zero)
        wantsBestResolutionOpenGLSurface = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        guard !prepared, let handle = player.handle else { updateDrawable(); return }
        prepared = true; context.view = self; NSOpenGLContext.clearCurrentContext()
        renderer.prepare(handle: handle, context: context, size: convertToBacking(bounds).size) { [weak self] in self?.onRenderError?($0) }
        updateDrawable()
    }
    override func draw(_ dirtyRect: NSRect) { updateDrawable(); renderer.requestDraw() }
    override func layout() { super.layout(); updateDrawable() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateDrawable() }
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); updateDrawable() }
    override func setBoundsSize(_ newSize: NSSize) { super.setBoundsSize(newSize); updateDrawable() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateDrawable() }
    private func updateDrawable() {
        guard prepared else { return }
        let pixels = convertToBacking(bounds).size
        let frame = window?.convertToScreen(convert(bounds, to: nil)) ?? .null
        guard frame != drawableFrame || pixels != drawableSize else { return }
        drawableFrame = frame; drawableSize = pixels
        // Invalidate immediately; the renderer coalesces changes and samples
        // the matching size during the main-thread context.update handshake.
        renderer.resize(pixels)
    }
    func diagnosticFrame() -> NSBitmapImageRep? { let bitmap = renderer.diagnosticFrame(); bitmap?.size = bounds.size; return bitmap }
    func captureFrame() async -> NSBitmapImageRep? { await renderer.captureFrame() }
    func shutdown() { renderer.shutdown(); context.clearDrawable() }
}

struct VideoSurface: NSViewRepresentable {
    let view: MPVVideoView
    func makeNSView(context: Context) -> MPVVideoView { view }
    func updateNSView(_ nsView: MPVVideoView, context: Context) {}
}
