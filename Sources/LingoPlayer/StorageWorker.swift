import Foundation
import PlayerCore

/// The connection, JSON codecs and file writes belong exclusively to this queue.
final class StorageWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LingoPlayer.storage", qos: .utility)
    private let url: URL
    private var database: SQLiteStore?
    private var pending: [String: () throws -> Void] = [:]
    private var scheduled = false
    private let errorLock = NSLock()
    private var errorHandler: ((String) -> Void)?
    var onError: ((String) -> Void)? {
        get { errorLock.lock(); defer { errorLock.unlock() }; return errorHandler }
        set { errorLock.lock(); defer { errorLock.unlock() }; errorHandler = newValue }
    }
    init(url: URL) { self.url = url }
    private func connection() throws -> SQLiteStore {
        if let database { return database }
        let db = try SQLiteStore(url: url); database = db; return db
    }
    func read<T>(_ operation: @escaping (SQLiteStore) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                drainReportingErrors()
                do { continuation.resume(returning: try operation(connection())) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func load<T: Decodable>(_ type: T.Type, key: String, table: String) async throws -> T? {
        try await read { try $0.load(type, key: key, table: table) }
    }
    func save<T: Encodable>(_ value: T, key: String, table: String) {
        enqueue(table + ":" + key) { [self] in try connection().save(value, key: key, table: table) }
    }
    func write<T: Encodable>(_ value: T, to url: URL) {
        enqueue("file:" + url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        }
    }
    private func enqueue(_ key: String, operation: @escaping () throws -> Void) {
        queue.async { [self] in
            pending[key] = operation
            if !scheduled {
                scheduled = true
                queue.asyncAfter(deadline: .now() + 0.15) { [self] in
                    drainReportingErrors()
                }
            }
        }
    }
    private func drain() throws {
        scheduled = false
        guard !pending.isEmpty else { return }
        let values = pending; pending = [:]
        var failure: Error?
        for operation in values.values { do { try operation() } catch { failure = error } }
        if let failure { throw failure }
    }
    private func drainReportingErrors() {
        do { try drain() } catch { onError?(error.localizedDescription) }
    }
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in drainReportingErrors(); continuation.resume() }
        }
    }
}
