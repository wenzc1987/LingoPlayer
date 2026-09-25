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
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var store: SQLiteStore?
    private var settings = RuntimeSettings()
    private var media: MediaIdentity?
    private var cues: [SubtitleCue] = []
    private var audioStream = 0
    private var offset = 0.0
    private var position = 0.0
    private var key = ""
    private var completed = Set<String>()
    private var words: [TimedWord] = []
    private var failures = 0
    private var cacheHits = 0
    private var runningIDs = Set<String>()
    private var worker: URL? {
        if let resources = Bundle.main.resourceURL,
           let bundle = Bundle(url: resources.appendingPathComponent("LingoPlayer_LingoPlayer.bundle")),
           let url = bundle.url(forResource: "alignment_worker", withExtension: "py") { return url }
        return Bundle.module.url(forResource: "alignment_worker", withExtension: "py")
    }

    func configure(media: MediaIdentity?, cues: [SubtitleCue], sourceDigest: String, audioStream: Int, offset: Double, position: Double, settings: RuntimeSettings, store: SQLiteStore?) {
        cancel()
        self.media = media; self.cues = cues; self.audioStream = audioStream; self.offset = offset; self.settings = settings; self.store = store
        let modelRoot = RuntimeSettings.supportDirectory.appendingPathComponent("MFA/pretrained_models")
        let modelFiles = [settings.mfa, modelRoot.appendingPathComponent("acoustic/\(settings.acousticModel).zip").path, modelRoot.appendingPathComponent("dictionary/\(settings.pronunciationDictionary).dict").path]
        let versions = modelFiles.map { path -> String in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return "\(path)|\(attributes?[.size] ?? 0)|\(attributes?[.modificationDate] ?? "unknown")"
        }.joined(separator: "|")
        let workerDigest = worker.flatMap { try? Data(contentsOf: $0) }.map(Digest.data) ?? "missing"
        self.key = Digest.string("alignment-v2|\(media?.key ?? "")|\(sourceDigest)|\(audioStream)|\(offset)|\(versions)|\(workerDigest)")
        completed = []; words = []; failures = 0; cacheHits = 0; self.position = position
        guard media != nil, !cues.isEmpty else { onChange?([], "导入英文字幕后可准备逐词高亮"); return }
        guard !settings.mfa.isEmpty, FileManager.default.isExecutableFile(atPath: settings.mfa), !settings.ffmpeg.isEmpty, FileManager.default.isExecutableFile(atPath: settings.ffmpeg) else {
            onChange?([], "逐词模型未就绪 · 可点词查阅"); return
        }
        // Cache each cue independently so a seek never changes its cache identity.
        for cue in cues {
            if let cached = try? store?.load(AlignmentResult.self, key: cacheKey(cue.id), table: "alignment"), cached.failures.isEmpty {
                words.append(contentsOf: cached.words); completed.insert(cue.id); cacheHits += 1
            }
        }
        words.sort { $0.start < $1.start }
        onChange?(words, "已恢复 \(cacheHits) 句逐词缓存")
        schedule()
    }
    func updatePosition(_ position: Double, seek: Bool = false) {
        self.position = position
        if seek, !runningIDs.isEmpty {
            let next = Timeline.nextBatch(cues, completed: completed, position: position, offset: offset).first
            // Include the next line when a seek lands in a silent gap.
            if let next, !runningIDs.contains(next.id) {
                task?.cancel(); task = nil; generation = UUID(); runningIDs = []
            }
        }
        schedule()
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; runningIDs = [] }
    private func schedule() {
        guard task == nil, let media, !cues.isEmpty, !settings.mfa.isEmpty, FileManager.default.isExecutableFile(atPath: settings.mfa), !settings.ffmpeg.isEmpty, let worker else { return }
        let batch = Timeline.nextBatch(cues, completed: completed, position: position, offset: offset)
        guard !batch.isEmpty else {
            onChange?(words, "逐词准备完成 · \(completed.count - failures) 句可用\(failures > 0 ? " · \(failures) 句保留整句" : "")\(cacheHits > 0 ? " · 已复用缓存" : "")")
            return
        }
        let batchKey = Digest.string(key + "|" + batch.map(\.id).joined(separator: ","))
        let token = generation
        let settings = settings
        let offset = offset
        let stream = audioStream
        runningIDs = Set(batch.map(\.id))
        onChange?(words, "后台准备逐词高亮 · \(completed.count)/\(cues.count) 句")
        task = Task { [weak self] in
            guard let self else { return }
            let directory = RuntimeSettings.supportDirectory.appendingPathComponent("AlignmentJobs/\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let job = AlignmentJob(video: media.path, stream: stream, ffmpeg: settings.ffmpeg, mfa: settings.mfa, acousticModel: settings.acousticModel, pronunciationDictionary: settings.pronunciationDictionary, modelRoot: RuntimeSettings.supportDirectory.appendingPathComponent("MFA").path, cues: batch.map { .init(id: $0.id, start: max(0, $0.start + offset), end: $0.end + offset, tokens: $0.tokens.filter(\.isWord)) })
                let input = directory.appendingPathComponent("request.json")
                let output = directory.appendingPathComponent("result.json")
                try JSONEncoder().encode(job).write(to: input)
                _ = try await ProcessRunner.run(executable: settings.python, arguments: [worker.path, "--request", input.path, "--output", output.path], timeout: 900)
                try Task.checkCancellation()
                guard self.generation == token else { return }
                let result = try JSONDecoder().decode(AlignmentResult.self, from: Data(contentsOf: output))
                for cueID in result.completed where result.failures[cueID] == nil {
                    let cached = AlignmentResult(words: result.words.filter { $0.cueID == cueID }, completed: [cueID], failures: [:], elapsed: result.elapsed, peakMemoryMB: result.peakMemoryMB)
                    try self.store?.save(cached, key: self.cacheKey(cueID), table: "alignment")
                }
                self.consume(result)
                self.appendMetrics(result, batchKey: batchKey)
                self.task = nil; self.runningIDs = []; self.schedule()
            } catch is CancellationError { /* New configuration/seek owns the next task. */ }
            catch {
                guard self.generation == token else { return }
                self.task = nil; self.runningIDs = []
                // Infrastructure failures stop retries; malformed cues are returned as per-cue failures.
                self.onChange?(self.words, "逐词准备暂停：\(error.localizedDescription.prefix(220))")
                self.settings.mfa = ""
            }
        }
    }
    private func cacheKey(_ cueID: String) -> String { Digest.string(key + "|" + cueID) }
    private func consume(_ result: AlignmentResult) {
        let replacing = Set(result.completed)
        words.removeAll { replacing.contains($0.cueID) }
        words.append(contentsOf: result.words)
        words.sort { $0.start < $1.start }
        completed.formUnion(result.completed); failures += result.failures.count
        onChange?(words, "后台准备逐词高亮 · \(completed.count)/\(cues.count) 句")
    }
    private func appendMetrics(_ result: AlignmentResult, batchKey: String) {
        let url = RuntimeSettings.supportDirectory.appendingPathComponent("alignment-metrics.jsonl")
        let object: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "batch": batchKey, "elapsed_seconds": result.elapsed, "peak_memory_mb": result.peakMemoryMB, "cues": result.completed.count, "words": result.words.count, "failed_cues": result.failures.count]
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data) }
    }
}
