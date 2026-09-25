import Foundation

public struct ProcessResult: Sendable {
    public var output: Data
    public var elapsed: Double
}

public struct ProcessFailure: LocalizedError {
    public var message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        self.process = process
        try process.run()
    }
    func cancel() {
        lock.lock(); cancelled = true; let running = process; lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }
}

public enum ProcessRunner {
    /// File-backed output avoids a child blocking forever on a full stdout/stderr pipe.
    public static func run(executable: String, arguments: [String], environment: [String: String] = [:], timeout: TimeInterval = 600) async throws -> ProcessResult {
        let control = ProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let started = Date()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingoplayer-process-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let outputURL = directory.appendingPathComponent("stdout")
            let errorURL = directory.appendingPathComponent("stderr")
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            FileManager.default.createFile(atPath: errorURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: outputURL)
            let error = try FileHandle(forWritingTo: errorURL)
            defer { try? output.close(); try? error.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output; process.standardError = error
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            let deadline = DispatchWorkItem { control.cancel() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            defer { deadline.cancel() }
            let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { child in continuation.resume(returning: child.terminationStatus) }
                do { try control.launch(process) }
                catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
            }
            try Task.checkCancellation()
            let data = try Data(contentsOf: outputURL)
            guard status == 0 else {
                let detail = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
                let fallback = String(data: data.suffix(3000), encoding: .utf8) ?? ""
                throw ProcessFailure(message: "\(URL(fileURLWithPath: executable).lastPathComponent) 运行失败（\(status)）。\n\(String((detail.isEmpty ? fallback : detail).suffix(3000)))")
            }
            return ProcessResult(output: data, elapsed: Date().timeIntervalSince(started))
        }, onCancel: { control.cancel() })
    }
}
