import AppKit
import SwiftUI
import OpenGL.GL3
import CMpv

struct PlaybackSnapshot {
    var generation: UUID
    var path: String
    var position: Double
    var duration: Double
    var paused: Bool
    var loaded: Bool
    var eof: Bool
    var error: String?
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
    var onUpdate: ((PlaybackSnapshot) -> Void)?
    var startupError: String?
    init(library: String) {
        var error = [CChar](repeating: 0, count: 1024)
        handle = lp_create(library, &error, error.count)
        guard handle != nil else { startupError = String(cString: error); return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30)
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
            if event == 6 { activeEntry = entry }
            if event == 8 && activeEntry == expectedEntry { fileReady = true }
            if event == 7 && entry == expectedEntry && error < 0 { failure = String(cString: lp_error(handle, error)) }
        }
        let path = string("path")
        let ready = fileReady && activeEntry == expectedEntry && path == expectedPath
        let snapshot = PlaybackSnapshot(generation: generation, path: expectedPath,
            position: lp_get_double(handle, "time-pos", 0), duration: lp_get_double(handle, "duration", 0),
            paused: string("pause") == "yes", loaded: ready, eof: ready && string("eof-reached") == "yes", error: failure)
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
            self.activeEntry = -2
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
    func seek(_ position: Double) { command(["seek", String(max(0, position)), "absolute+exact"]) }
    func pause(_ value: Bool) { set("pause", value ? "yes" : "no") }
    /// Caller must dispose the render context first, on its GL thread.
    func shutdown() {
        timer?.cancel(); timer = nil
        queue.sync { if let handle { lp_destroy(handle); self.handle = nil } }
    }
}

private final class RenderNotification {
    weak var view: MPVVideoView?
    init(_ view: MPVVideoView) { self.view = view }
}

final class MPVVideoView: NSOpenGLView {
    private let player: MPVPlayer
    private var renderer: OpaquePointer?
    private var notification: UnsafeMutableRawPointer?
    private(set) var renderedFrames = 0
    var rendererReady: Bool { renderer != nil }
    var onRenderError: ((String) -> Void)?
    init(player: MPVPlayer) {
        self.player = player
        let attrs: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile), NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion3_2Core),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAccelerated), NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAColorSize), 24, 0
        ]
        let format = NSOpenGLPixelFormat(attributes: attrs)
        super.init(frame: .zero, pixelFormat: format)!
        wantsBestResolutionOpenGLSurface = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func prepareOpenGL() {
        super.prepareOpenGL()
        guard renderer == nil, let handle = player.handle, let context = openGLContext else { return }
        context.makeCurrentContext()
        var interval: GLint = 1
        context.setValues(&interval, for: .swapInterval)
        let note = Unmanaged.passRetained(RenderNotification(self)).toOpaque()
        notification = note
        var error: Int32 = 0
        renderer = lp_render_create(handle, { pointer in
            guard let pointer else { return }
            let note = Unmanaged<RenderNotification>.fromOpaque(pointer).takeUnretainedValue()
            DispatchQueue.main.async { [weak note] in note?.view?.needsDisplay = true }
        }, note, &error)
        if renderer == nil {
            onRenderError?("视频渲染初始化失败：\(String(cString: lp_error(handle, error)))")
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = openGLContext else { return }
        context.makeCurrentContext()
        let pixels = convertToBacking(bounds)
        if let renderer { lp_render_draw(renderer, Int32(max(1, pixels.width)), Int32(max(1, pixels.height))); renderedFrames += 1 }
        else { glClearColor(0.03, 0.04, 0.05, 1); glClear(GLbitfield(GL_COLOR_BUFFER_BIT)) }
        context.flushBuffer()
    }
    override func reshape() { super.reshape(); openGLContext?.update(); needsDisplay = true }
    /// Native view snapshots omit OpenGL surfaces. Read the actual rendered
    /// framebuffer for the explicit diagnostic launch mode instead.
    func diagnosticFrame() -> NSBitmapImageRep? {
        guard let renderer, let context = openGLContext else { return nil }
        context.makeCurrentContext()
        let size = convertToBacking(bounds).size
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
              let pixels = bitmap.bitmapData else { return nil }
        lp_render_draw(renderer, Int32(width), Int32(height))
        glReadBuffer(GLenum(GL_BACK))
        glPixelStorei(GLenum(GL_PACK_ALIGNMENT), 1)
        glReadPixels(0, 0, Int32(width), Int32(height), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), pixels)
        let stride = width * 4
        for row in 0..<(height / 2) {
            let top = pixels.advanced(by: row * stride)
            let bottom = pixels.advanced(by: (height - 1 - row) * stride)
            let saved = Data(bytes: top, count: stride)
            memcpy(top, bottom, stride)
            saved.copyBytes(to: bottom, count: stride)
        }
        context.flushBuffer()
        bitmap.size = bounds.size
        return bitmap
    }
    func shutdown() {
        openGLContext?.makeCurrentContext()
        if let renderer { lp_render_free(renderer); self.renderer = nil }
        if let notification { Unmanaged<RenderNotification>.fromOpaque(notification).release(); self.notification = nil }
    }
}

struct VideoSurface: NSViewRepresentable {
    let view: MPVVideoView
    func makeNSView(context: Context) -> MPVVideoView { view }
    func updateNSView(_ nsView: MPVVideoView, context: Context) {}
}
