import Foundation

public enum AlignmentPhase: String, Codable, Sendable { case idle, preparing, completed, partialFailure, environmentFailure, cancelled }
public struct AlignmentTaskStatus: Equatable, Sendable {
    public var phase: AlignmentPhase
    public var message: String
    public var diagnostic: URL?
    public init(_ phase: AlignmentPhase, _ message: String, diagnostic: URL? = nil) { self.phase = phase; self.message = message; self.diagnostic = diagnostic }
    public var canRetry: Bool { phase == .environmentFailure || phase == .partialFailure || phase == .cancelled }
}

/// Only text/JSON are accepted. Extracted audio never enters diagnostic storage.
public actor TaskDiagnostics {
    public let directory: URL
    private let limit: Int, byteLimit: Int
    public init(directory: URL, limit: Int = 20, byteLimit: Int = 20 * 1024 * 1024) { self.directory = directory; self.limit = limit; self.byteLimit = byteLimit }
    public func record(summary: String, configuration: String, output: String, logs: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).txt")
        let header = "LingoPlayer alignment diagnostic\n\(ISO8601DateFormatter().string(from: Date()))\n\(summary)\n\nCONFIGURATION\n\(configuration)\n\nPROCESS OUTPUT\n"
        var data = Data((header + output + "\n\nMFA LOGS\n" + logs).utf8)
        if data.count > byteLimit {
            let notice = Data("\n[20 MB local retention limit: output truncated]\n".utf8)
            data = data.prefix(max(0, byteLimit - notice.count))
            // Keep the file readable when the byte budget cuts a UTF-8 scalar.
            // The original input is valid UTF-8, so at most three bytes drop.
            while String(data: data, encoding: .utf8) == nil { data.removeLast() }
            data.append(notice)
        }
        try data.write(to: url, options: .atomic)
        var files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        // Always retain the record just produced when timestamps collide.
        files.removeAll { $0.lastPathComponent == url.lastPathComponent }; files.insert(url, at: 0)
        var bytes = 0
        for (index, file) in files.enumerated() {
            let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            if index >= limit || bytes + size > byteLimit { try FileManager.default.removeItem(at: file) }
            else { bytes += size }
        }
        return url
    }
}
