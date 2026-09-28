import Foundation
import Darwin

public struct ProcessResult: Sendable {
    public var output: Data
    public var elapsed: Double
    public var stderr: String = ""
}

public struct ProcessFailure: LocalizedError {
    public var message: String
    public var exitCode: Int32?
    public var output = ""
    public var timedOut = false
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var group: pid_t?
    private var timeoutFlag = false
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return timeoutFlag }
    func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        self.process = process
        try process.run()
    }
    func cancel(timeout: Bool = false) {
        lock.lock(); cancelled = true; timeoutFlag = timeoutFlag || timeout; let running = process
        let pid = running?.processIdentifier ?? 0
        if pid > 0 && getpgid(pid) == pid { group = pid }
        let group = group; lock.unlock()
        if let group { kill(-group, SIGTERM) }
        else if let running, running.isRunning { running.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if let group { kill(-group, SIGKILL) }
            else if let running, running.isRunning { kill(running.processIdentifier, SIGKILL) }
        }
    }
    private func cancellationState() -> (pid_t?, Bool) { lock.lock(); defer { lock.unlock() }; return (group, cancelled) }
    func finishCancellation() async {
        let (group, cancelled) = cancellationState()
        if cancelled {
            // Let graceful exits reap their children, then ensure the owned group
            // cannot overlap a replacement job. Never signal the host's group.
            await withCheckedContinuation { continuation in DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { continuation.resume() } }
            if let group { kill(-group, SIGKILL) }
        }
    }
}

public enum ProcessRunner {
    /// Small in-memory image output. The consumer drains the pipe off the main
    /// thread, and cancellation returns only after the owned process has exited.
    public static func preview(executable: String, arguments: [String]) async throws -> Data {
        let control = ProcessControl()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            let deadline = DispatchWorkItem { control.cancel(timeout: true) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: deadline)
            defer { deadline.cancel(); try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
            let output = Task.detached(priority: .utility) { () -> Data in
                var data = Data()
                while let chunk = try? pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                    if data.count + chunk.count <= 2 * 1024 * 1024 { data.append(chunk) }
                }
                return data
            }
            let status: Int32
            do {
                status = try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                    do { try control.launch(process); try? pipe.fileHandleForWriting.close() }
                    catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
                }
            } catch {
                try? pipe.fileHandleForWriting.close(); _ = await output.value
                throw error
            }
            let data = await output.value
            try Task.checkCancellation()
            guard status == 0, !control.timedOut, !data.isEmpty else { throw ProcessFailure(message: "预览不可用") }
            return data
        }, onCancel: { control.cancel() })
    }
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
            let deadline = DispatchWorkItem { control.cancel(timeout: true) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            defer { deadline.cancel() }
            let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { child in continuation.resume(returning: child.terminationStatus) }
                do { try control.launch(process) }
                catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
            }
            await control.finishCancellation()
            try Task.checkCancellation()
            let data = try Data(contentsOf: outputURL)
            let detail = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
            if status != 0 || control.timedOut {
                var failure = ProcessFailure(message: control.timedOut ? "任务超时" : "\(URL(fileURLWithPath: executable).lastPathComponent) 子进程退出（\(status)）")
                failure.message += detail.isEmpty ? "" : "\n" + String(detail.prefix(2000))
                failure.exitCode = status; failure.timedOut = control.timedOut
                failure.output = "STDOUT\n" + (String(data: data, encoding: .utf8) ?? "") + "\nSTDERR\n" + detail
                throw failure
            }
            return ProcessResult(output: data, elapsed: Date().timeIntervalSince(started), stderr: detail)
        }, onCancel: { control.cancel() })
    }
}
