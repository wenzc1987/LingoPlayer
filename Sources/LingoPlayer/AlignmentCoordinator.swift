import Foundation
import PlayerCore

struct AlignmentJob: Codable {
    struct Cue: Codable {
        var id: String
        var start: Double
        var end: Double
        var tokens: [WordToken]
    }
    var video: String
    var stream: Int
    var ffmpeg: String
    var mfa: String
    var acousticModel: String
    var pronunciationDictionary: String
    var modelRoot: String
    var cues: [Cue]
}

struct AlignmentResult: Codable {
    var words: [TimedWord]
    var completed: [String]
    var failures: [String: String]
    var elapsed: Double
    var peakMemoryMB: Double
}

@MainActor
final class AlignmentCoordinator {
    var onChange: (([TimedWord], String) -> Void)?
    var onStatus: ((AlignmentTaskStatus) -> Void)?
    private(set) var status = AlignmentTaskStatus(.idle, "导入英文字幕后可准备逐词高亮")
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var store: StorageWorker?
    private var settings = RuntimeSettings()
    private var media: MediaIdentity?
    private var cues: [SubtitleCue] = []
    private var audioStream = 0
    private var offset = 0.0
    private var position = 0.0
    private var key = ""
    private var completed = Set<String>()
    private var words: [TimedWord] = []
    private var failed = Set<String>()
    private var cacheHits = 0
    private var runningIDs = Set<String>()
    private let diagnostics = TaskDiagnostics(directory: RuntimeSettings.supportDirectory.appendingPathComponent("AlignmentFailures"))
    private var worker: URL? {
        if let resources = Bundle.main.resourceURL,
           let bundle = Bundle(url: resources.appendingPathComponent("LingoPlayer_LingoPlayer.bundle")),
           let url = bundle.url(forResource: "alignment_worker", withExtension: "py") { return url }
        return Bundle.module.url(forResource: "alignment_worker", withExtension: "py")
    }
    private func publish(_ phase: AlignmentPhase, _ message: String, diagnostic: URL? = nil) {
        status = AlignmentTaskStatus(phase, message, diagnostic: diagnostic ?? status.diagnostic)
        onStatus?(status); onChange?(words, message)
    }
    func configure(media: MediaIdentity?, cues: [SubtitleCue], sourceDigest: String, audioStream: Int, offset: Double, position: Double, settings: RuntimeSettings, store: StorageWorker?) {
        cancel()
        self.media = media; self.cues = cues; self.audioStream = audioStream; self.offset = offset; self.settings = settings; self.store = store; self.position = position
        let modelRoot = RuntimeSettings.supportDirectory.appendingPathComponent("MFA/pretrained_models")
        let modelFiles = [settings.mfa, modelRoot.appendingPathComponent("acoustic/\(settings.acousticModel).zip").path, modelRoot.appendingPathComponent("dictionary/\(settings.pronunciationDictionary).dict").path]
        let versions = modelFiles.map { path -> String in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return "\(path)|\(attributes?[.size] ?? 0)|\(attributes?[.modificationDate] ?? "unknown")"
        }.joined(separator: "|")
        let workerDigest = worker.flatMap { try? Data(contentsOf: $0) }.map(Digest.data) ?? "missing"
        key = Digest.string("alignment-v2|\(media?.key ?? "")|\(sourceDigest)|\(audioStream)|\(offset)|\(versions)|\(workerDigest)")
        completed = []; words = []; failed = []; cacheHits = 0; status = AlignmentTaskStatus(.idle, "等待准备")
        guard media != nil, !cues.isEmpty else { publish(.idle, "导入英文字幕后可准备逐词高亮"); return }
        launch(restoreCache: true)
    }
    func updatePosition(_ position: Double, seek: Bool = false) {
        self.position = position
        if seek, status.phase == .preparing, !runningIDs.isEmpty {
            let next = Timeline.nextBatch(cues, completed: completed, position: position, offset: offset).first
            if let next, !runningIDs.contains(next.id) { launch(restoreCache: false) }
        }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); runningIDs = []
        media = nil; cues = []; words = []; completed = []; key = ""
        publish(.cancelled, "逐词任务已取消")
    }
    func waitForCancellation() async { await task?.value }
    func retry(settings: RuntimeSettings) {
        self.settings = settings; completed.subtract(failed); failed = []
        guard media != nil, !cues.isEmpty else { return }
        launch(restoreCache: false)
    }
    private func launch(restoreCache: Bool) {
        let previous = task; previous?.cancel(); generation = UUID(); let token = generation
        task = Task { [weak self] in
            // Task cancellation does not skip this join. Every replacement waits
            // for its predecessor's child-process teardown and disk cleanup.
            await previous?.value
            guard let self, generation == token, !Task.isCancelled else { return }
            runningIDs = []
            if restoreCache, let store {
                let keys = cues.map { ($0.id, cacheKey($0.id)) }
                let cached = try? await store.read { db in
                    try keys.compactMap { pair -> AlignmentResult? in
                        guard let value = try db.load(AlignmentResult.self, key: pair.1, table: "alignment"), value.failures.isEmpty else { return nil }
                        return value
                    }
                }
                guard generation == token, !Task.isCancelled else { return }
                for value in cached ?? [] { words.append(contentsOf: value.words); completed.formUnion(value.completed); cacheHits += 1 }
                words.sort { $0.start < $1.start }
            }
            do {
                publish(.preparing, "正在检查逐词运行环境…")
                let settings = settings, root = RuntimeSettings.supportDirectory
                try await Task.detached(priority: .utility) { try Self.validate(settings, root: root) }.value
                try Task.checkCancellation()
                guard generation == token else { return }
                while !Task.isCancelled && generation == token {
                    let batch = Timeline.nextBatch(cues, completed: completed, position: position, offset: offset)
                    if batch.isEmpty {
                        publish(failed.isEmpty ? .completed : .partialFailure, "逐词准备完成 · \(completed.count - failed.count) 句可用" + (failed.isEmpty ? "" : " · \(failed.count) 句保留整句") + (cacheHits > 0 ? " · 已复用缓存" : ""))
                        break
                    }
                    runningIDs = Set(batch.map(\.id))
                    publish(.preparing, "后台准备逐词高亮 · \(completed.count)/\(cues.count) 句")
                    try await runBatch(batch, token: token)
                    runningIDs = []
                }
            } catch is CancellationError {} catch {
                guard generation == token else { return }
                var record = (error as? AlignmentBatchFailure)?.diagnostic
                if record == nil { record = try? await diagnostics.record(summary: error.localizedDescription, configuration: "python=\(settings.python)\nffmpeg=\(settings.ffmpeg)\nmfa=\(settings.mfa)\nacoustic=\(settings.acousticModel)\ndictionary=\(settings.pronunciationDictionary)", output: (error as? ProcessFailure)?.output ?? "", logs: "") }
                guard generation == token else { return }
                publish(.environmentFailure, "逐词准备暂停：" + error.localizedDescription.components(separatedBy: .newlines)[0], diagnostic: record)
            }
            if generation == token { runningIDs = [] }
        }
    }
    nonisolated static func validate(_ settings: RuntimeSettings, root: URL) throws {
        for (name, path) in [("Python 解释器", settings.python), ("FFmpeg", settings.ffmpeg), ("MFA", settings.mfa)] {
            guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { throw ProcessFailure(message: "\(name) 路径不可执行，请在设置中检查") }
        }
        for (name, path, relative) in [("声学模型", settings.acousticModel, "acoustic/\(settings.acousticModel).zip"), ("发音词典", settings.pronunciationDictionary, "dictionary/\(settings.pronunciationDictionary).dict")] {
            guard FileManager.default.isReadableFile(atPath: path) || FileManager.default.isReadableFile(atPath: root.appendingPathComponent("MFA/pretrained_models/" + relative).path) else { throw ProcessFailure(message: "\(name) 未就绪，请安装模型或检查路径") }
        }
        let output = root.appendingPathComponent("AlignmentJobs")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let probe = output.appendingPathComponent(".write-\(UUID().uuidString)")
        try Data().write(to: probe); try FileManager.default.removeItem(at: probe)
    }
    private func runBatch(_ batch: [SubtitleCue], token: UUID) async throws {
        guard let media, let worker else { throw ProcessFailure(message: "对齐工作脚本缺失") }
        let directory = RuntimeSettings.supportDirectory.appendingPathComponent("AlignmentJobs/\(UUID().uuidString)")
        let job = AlignmentJob(video: media.path, stream: audioStream, ffmpeg: settings.ffmpeg, mfa: settings.mfa, acousticModel: settings.acousticModel, pronunciationDictionary: settings.pronunciationDictionary, modelRoot: RuntimeSettings.supportDirectory.appendingPathComponent("MFA").path, cues: batch.map { .init(id: $0.id, start: max(0, $0.start + offset), end: $0.end + offset, tokens: $0.tokens.filter(\.isWord)) })
        let python = settings.python, diagnostics = diagnostics
        let result: (AlignmentResult, URL?) = try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let input = directory.appendingPathComponent("request.json"), output = directory.appendingPathComponent("result.json")
            let data = try JSONEncoder().encode(job); try data.write(to: input)
            let configuration = "python=\(python)\n" + (String(data: data, encoding: .utf8) ?? "")
            do {
                let process = try await ProcessRunner.run(executable: python, arguments: [worker.path, "--request", input.path, "--output", output.path], timeout: 900)
                let result = try JSONDecoder().decode(AlignmentResult.self, from: Data(contentsOf: output))
                var record: URL?
                if !result.failures.isEmpty {
                    record = try await diagnostics.record(summary: "部分句子无法对齐", configuration: configuration, output: String(data: try JSONEncoder().encode(result.failures), encoding: .utf8) ?? "", logs: process.stderr + ((try? String(contentsOf: output.deletingPathExtension().appendingPathExtension("error.log"), encoding: .utf8)) ?? ""))
                }
                return (result, record)
            } catch is CancellationError { throw CancellationError() }
            catch {
                let log = (try? String(contentsOf: output.deletingPathExtension().appendingPathExtension("error.log"), encoding: .utf8)) ?? ""
                let workerLog = (try? String(contentsOf: directory.appendingPathComponent("result.error.log"), encoding: .utf8)) ?? log
                let record = try? await diagnostics.record(summary: "\(error.localizedDescription)\nexit=\((error as? ProcessFailure)?.exitCode.map(String.init) ?? "launch/decode")", configuration: configuration, output: (error as? ProcessFailure)?.output ?? "", logs: workerLog)
                let detail = (try? Data(contentsOf: output.deletingPathExtension().appendingPathExtension("error.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let stage = detail?["stage"] as? String ?? "任务进程"
                let message = (detail?["message"] as? String)?.components(separatedBy: .newlines).first ?? error.localizedDescription
                throw AlignmentBatchFailure(reason: stage + "：" + message, diagnostic: record)
            }
        }.cancellableValue()
        try Task.checkCancellation(); guard generation == token else { return }
        let value = result.0
        for cueID in value.completed where value.failures[cueID] == nil {
            let cached = AlignmentResult(words: value.words.filter { $0.cueID == cueID }, completed: [cueID], failures: [:], elapsed: value.elapsed, peakMemoryMB: value.peakMemoryMB)
            store?.save(cached, key: cacheKey(cueID), table: "alignment")
        }
        let replacing = Set(value.completed); words.removeAll { replacing.contains($0.cueID) }; words.append(contentsOf: value.words); words.sort { $0.start < $1.start }
        completed.formUnion(value.completed); failed.formUnion(value.failures.keys)
        publish(.preparing, "后台准备逐词高亮 · \(completed.count)/\(cues.count) 句", diagnostic: result.1)
        let metricsURL = RuntimeSettings.supportDirectory.appendingPathComponent("alignment-metrics.jsonl")
        await Task.detached(priority: .utility) {
            let object: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "elapsed_seconds": value.elapsed, "peak_memory_mb": value.peakMemoryMB, "cues": value.completed.count, "words": value.words.count, "failed_cues": value.failures.count]
            guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }; data.append(0x0a)
            if !FileManager.default.fileExists(atPath: metricsURL.path) { FileManager.default.createFile(atPath: metricsURL.path, contents: nil) }
            if let handle = try? FileHandle(forWritingTo: metricsURL) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data) }
        }.value
    }
    private func cacheKey(_ cueID: String) -> String { Digest.string(key + "|" + cueID) }
}

private struct AlignmentBatchFailure: LocalizedError {
    let reason: String
    let diagnostic: URL?
    var errorDescription: String? { reason }
}

private extension Task {
    func cancellableValue() async throws -> Success {
        try await withTaskCancellationHandler(operation: { try await value }, onCancel: { cancel() })
    }
}
