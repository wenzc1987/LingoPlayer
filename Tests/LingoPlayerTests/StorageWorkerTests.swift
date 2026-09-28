import Foundation
import Testing
@testable import LingoPlayer

struct StorageWorkerTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func preferenceWritesDoNotOpenTheDatabase() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("library.sqlite")
        let destination = folder.appendingPathComponent("viewing.json")
        let worker = StorageWorker(url: database)
        worker.write(["volume": 30], to: destination)
        await worker.flush()
        #expect(try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: destination)) == ["volume": 30])
        #expect(!FileManager.default.fileExists(atPath: database.path))
    }

    @Test func corruptDatabaseDoesNotDiscardPreferenceWritesInTheSameBatch() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("library.sqlite")
        try Data("not a SQLite database".utf8).write(to: database)
        let destination = folder.appendingPathComponent("viewing.json")
        let worker = StorageWorker(url: database)
        let errors = ErrorLog(); worker.onError = { errors.append($0) }
        worker.save(12, key: "video", table: "playback")
        worker.write(["volume": 30], to: destination)
        await worker.flush()
        #expect(!errors.messages.isEmpty)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        if let data = try? Data(contentsOf: destination) {
            #expect(try JSONDecoder().decode([String: Int].self, from: data) == ["volume": 30])
        }
    }

    @Test func aFailedFileWriteDoesNotDiscardOtherWrites() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let blocker = folder.appendingPathComponent("file")
        try Data().write(to: blocker)
        let worker = StorageWorker(url: folder.appendingPathComponent("library.sqlite"))
        let errors = ErrorLog(); worker.onError = { errors.append($0) }
        worker.write(1, to: blocker.appendingPathComponent("invalid.json"))
        let destination = folder.appendingPathComponent("valid.json")
        for value in 0..<20 { worker.write(value, to: destination) }
        await worker.flush()
        #expect(!errors.messages.isEmpty)
        #expect(try JSONDecoder().decode(Int.self, from: Data(contentsOf: destination)) == 19)
    }

    @Test func readsWaitForPendingDatabaseSaves() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let worker = StorageWorker(url: folder.appendingPathComponent("library.sqlite"))
        worker.save(1, key: "video", table: "playback")
        worker.save(2, key: "video", table: "playback")
        #expect(try await worker.load(Int.self, key: "video", table: "playback") == 2)
    }

    @Test func unrelatedWriteFailureDoesNotTurnAValidReadIntoAFailure() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let blocker = folder.appendingPathComponent("file")
        try Data().write(to: blocker)
        let worker = StorageWorker(url: folder.appendingPathComponent("library.sqlite"))
        let errors = ErrorLog(); worker.onError = { errors.append($0) }
        worker.save(42, key: "video", table: "playback")
        worker.write(1, to: blocker.appendingPathComponent("invalid.json"))
        #expect(try await worker.load(Int.self, key: "video", table: "playback") == 42)
        #expect(!errors.messages.isEmpty)
    }
}

private final class ErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
}
