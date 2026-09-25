import Foundation
import PlayerCore

struct MediaStream: Identifiable, Sendable {
    let id: Int
    let codec: String
    let kind: String
    let language: String
    let title: String
    let isDefault: Bool
    var isTextSubtitle: Bool { kind == "subtitle" && ["subrip", "ass", "ssa", "webvtt", "mov_text", "text"].contains(codec) }
    var label: String { "\(language.isEmpty ? "轨道 \(id)" : language) · \(title.isEmpty ? codec : title)" }
}

enum MediaInspector {
    static func inspect(url: URL, settings: RuntimeSettings) async throws -> [MediaStream] {
        guard !settings.ffprobe.isEmpty else { throw ProcessFailure(message: "FFprobe 未就绪；可以播放视频并手动导入字幕。请完成运行环境配置以读取内嵌字幕。") }
        let result = try await ProcessRunner.run(executable: settings.ffprobe, arguments: ["-v", "error", "-show_streams", "-of", "json", url.path], timeout: 30)
        guard let object = try JSONSerialization.jsonObject(with: result.output) as? [String: Any], let rows = object["streams"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["index"] as? Int else { return nil }
            let tags = row["tags"] as? [String: String] ?? [:]
            let disposition = row["disposition"] as? [String: Int] ?? [:]
            return MediaStream(id: id, codec: row["codec_name"] as? String ?? "", kind: row["codec_type"] as? String ?? "", language: tags["language"] ?? "", title: tags["title"] ?? "", isDefault: disposition["default"] == 1)
        }
    }
    static func extractSubtitle(video: URL, stream: MediaStream, destination: URL, settings: RuntimeSettings) async throws {
        guard !settings.ffmpeg.isEmpty else { throw ProcessFailure(message: "FFmpeg 未就绪，暂时无法提取内嵌字幕。") }
        _ = try await ProcessRunner.run(executable: settings.ffmpeg, arguments: ["-nostdin", "-v", "error", "-y", "-i", video.path, "-map", "0:\(stream.id)", "-c:s", "srt", destination.path], timeout: 120)
    }
    static func sidecars(video: URL) -> [URL] {
        let stem = video.deletingPathExtension().lastPathComponent.lowercased()
        let files = (try? FileManager.default.contentsOfDirectory(at: video.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        return files.filter {
            ["srt", "ass", "ssa", "vtt"].contains($0.pathExtension.lowercased()) &&
            ($0.deletingPathExtension().lastPathComponent.lowercased() == stem || $0.lastPathComponent.lowercased().hasPrefix(stem + "."))
        }.sorted { a, b in
            let exactA = a.deletingPathExtension().lastPathComponent.lowercased() == stem
            let exactB = b.deletingPathExtension().lastPathComponent.lowercased() == stem
            return exactA != exactB ? exactA : a.lastPathComponent < b.lastPathComponent
        }
    }
}
