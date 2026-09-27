import AppKit
import SwiftUI
import PlayerCore

enum ScreenshotFailure: LocalizedError {
    case unavailable, frameChanged, encoding, directory
    var errorDescription: String? {
        switch self {
        case .unavailable: return "暂时无法读取视频画面，请稍后重试。"
        case .frameChanged: return "视频或窗口尺寸已改变，请重新截图。"
        case .encoding: return "无法生成截图图片。"
        case .directory: return "请为截图设置有效的绝对文件夹路径。"
        }
    }
}

@MainActor final class ScreenshotController: ObservableObject {
    @Published private(set) var isCapturing = false
    private(set) var lastMessage = ""
    private(set) var lastFile: URL?
    let pasteboard: NSPasteboard
    private var task: Task<Void, Never>?
    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }
    static var defaultDirectory: URL {
        (FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures"))
            .appendingPathComponent("LingoPlayer", isDirectory: true)
    }
    static func directory(for preferences: ScreenshotPreferences) throws -> URL {
        let path = preferences.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return defaultDirectory }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.contains("\0") else { throw ScreenshotFailure.directory }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }
    func capture(model: AppModel) {
        guard !isCapturing, model.playbackReady, model.videoAspect != nil else { return }
        isCapturing = true; lastFile = nil; lastMessage = ""
        let session = model.sessionID, size = model.videoView.bounds.size
        let subtitles = SubtitleFrame(model: model), preferences = model.viewing.screenshot
        let filename = ScreenshotPreferences.filename(title: model.media?.title ?? "LingoPlayer", position: model.position)
        task = Task {
            defer { isCapturing = false }
            do {
                var bitmap = await model.videoView.captureFrame()
                for _ in 0..<3 where bitmap == nil {
                    try await Task.sleep(nanoseconds: 20_000_000)
                    bitmap = await model.videoView.captureFrame()
                }
                guard session == model.sessionID, size == model.videoView.bounds.size else { throw ScreenshotFailure.frameChanged }
                guard let video = bitmap?.cgImage, size.width > 0, size.height > 0 else { throw ScreenshotFailure.unavailable }
                let image = try Self.compose(video: video, size: size, subtitles: subtitles)
                // PNG/TIFF encoding and filesystem work stay off the UI thread.
                let destination = preferences.file ? Result { try Self.directory(for: preferences) } : nil
                let saved = await Task.detached(priority: .userInitiated) {
                    Self.encodeAndSave(image, preferences: preferences, destination: destination, filename: filename)
                }.value
                guard let png = saved.png else { throw ScreenshotFailure.encoding }
                var successes: [String] = [], failures: [String] = []
                if preferences.clipboard {
                    let item = NSPasteboardItem(); item.setData(png, forType: .png)
                    if let tiff = saved.tiff { item.setData(tiff, forType: .tiff) }
                    pasteboard.clearContents()
                    if pasteboard.writeObjects([item]) { successes.append("剪贴板") }
                    else { failures.append("剪贴板写入失败") }
                }
                if let file = saved.file { lastFile = file; successes.append("文件：\(file.path)") }
                if let failure = saved.fileError { failures.append("文件保存失败：\(failure)") }
                let success = successes.isEmpty ? "" : "截图保存成功至" + successes.joined(separator: "、")
                report(([success] + failures).filter { !$0.isEmpty }.joined(separator: "\n"), model: model)
            } catch { report("截图失败：\(error.localizedDescription)", model: model) }
        }
    }
    func finishPendingCapture() async { await task?.value }
    private func report(_ message: String, model: AppModel) {
        lastMessage = message
        model.chrome.showNotice(message, key: "screenshot-" + UUID().uuidString)
    }
    static func compose(video: CGImage, size: CGSize, subtitles: SubtitleFrame) throws -> CGImage {
        let scale = CGFloat(video.width) / size.width
        guard let context = CGContext(data: nil, width: video.width, height: video.height, bitsPerComponent: 8, bytesPerRow: video.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotFailure.encoding }
        let bounds = CGRect(x: 0, y: 0, width: video.width, height: video.height)
        context.setFillColor(NSColor.black.cgColor); context.fill(bounds); context.draw(video, in: bounds)
        if subtitles.display != .hidden && subtitles.hasContent {
            let content = SubtitleCaptionContent(frame: subtitles)
                .frame(maxWidth: size.width * 0.92).fixedSize(horizontal: false, vertical: true)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: content)
            renderer.scale = scale; renderer.proposedSize = ProposedViewSize(width: size.width * 0.92, height: nil)
            guard let overlay = renderer.cgImage else { throw ScreenshotFailure.encoding }
            let height = CGFloat(overlay.height) / scale
            let bottom = min(subtitles.appearance.bottomInset, max(8, size.height - height - 250))
            context.draw(overlay, in: CGRect(x: (CGFloat(video.width) - CGFloat(overlay.width)) / 2, y: bottom * scale,
                                             width: CGFloat(overlay.width), height: CGFloat(overlay.height)))
        }
        guard let image = context.makeImage() else { throw ScreenshotFailure.encoding }
        return image
    }
    private struct Saved {
        var png: Data?
        var tiff: Data?
        var file: URL?
        var fileError: String?
    }
    nonisolated private static func encodeAndSave(_ image: CGImage, preferences: ScreenshotPreferences, destination: Result<URL, Error>?, filename: String) -> Saved {
        autoreleasepool {
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return Saved() }
            var result = Saved(png: png)
            if preferences.clipboard { result.tiff = bitmap.representation(using: .tiff, properties: [:]) }
            if let destination {
                do {
                    let directory = try destination.get()
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let temporary = directory.appendingPathComponent(".LingoPlayer-\(UUID().uuidString).tmp")
                    try png.write(to: temporary, options: .atomic)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    let target = directory.appendingPathComponent(filename)
                    // moveItem refuses an existing destination; never replace a user's image.
                    try FileManager.default.moveItem(at: temporary, to: target)
                    result.file = target
                } catch { result.fileError = error.localizedDescription }
            }
            return result
        }
    }
}
