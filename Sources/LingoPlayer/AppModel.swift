import AppKit
import Combine
import Foundation
import PlayerCore
import UniformTypeIdentifiers

struct SubtitleOption: Identifiable {
    var id: String { url.path }
    let title: String
    let url: URL
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = RuntimeSettings.load()
    @Published var media: MediaIdentity?
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var paused = true
    @Published var speed = 1.0
    @Published var volume = 80.0
    @Published var english: [SubtitleCue] = []
    @Published var chinese: [SubtitleCue] = []
    @Published var activeEnglish: [SubtitleCue] = []
    @Published var activeChinese: [SubtitleCue] = []
    @Published var englishOffset = 0.0
    @Published var chineseOffset = 0.0
    @Published var englishSource = "未加载"
    @Published var chineseSource = "未加载"
    @Published var audioStreams: [MediaStream] = []
    @Published var selectedAudio = -1
    @Published var subtitleOptions: [SubtitleOption] = []
    @Published var subtitleStatus = "打开视频后自动发现字幕"
    @Published var alignmentStatus = "导入英文字幕后可准备逐词高亮"
    @Published var learning = LearningState()
    @Published var dictionaryEntry: DictionaryEntry?
    @Published var dictionaryStatus = "词典释义 · ECDICT"
    @Published var currentWordID: String?
    @Published var isDetached = false
    @Published var showSettings = false
    @Published var showSubtitleSearch = false
    @Published var showSubtitleControls = false
    @Published var alert: String?
    @Published var isSearching = false
    @Published var searchLanguage: SubtitleLanguage = .english
    @Published var searchText = ""
    @Published var searchYear = ""
    @Published var searchSeason = ""
    @Published var searchEpisode = ""
    @Published var searchResults: [SubtitleCandidate] = []
    @Published var searchMessage = "输入片名后搜索；优先展示与片源文件匹配的字幕。"
    @Published var isDownloading = false

    let player: MPVPlayer
    let videoView: MPVVideoView
    private let aligner = AlignmentCoordinator()
    private var store: SQLiteStore?
    private var dictionary: ECDictionary?
    private var timings: [TimedWord] = []
    private var englishPath: String?
    private var chinesePath: String?
    private var englishDigest = ""
    private var saved = SavedPlayback()
    private var openTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var lookupTask: Task<Void, Never>?
    private var lookupID = UUID()
    private var sessionID = UUID()
    private var searchID = UUID()
    private var lastDictionaryKey = ""
    private var lastSavedAt = Date.distantPast
    private var awaitingLoad = false
    private var replayRange: ClosedRange<Double>?
    private var replayArmed = false
    var onDetach: (() -> Void)?

    init() {
        let loaded = RuntimeSettings.load()
        player = MPVPlayer(library: loaded.libmpv)
        videoView = MPVVideoView(player: player)
        do { store = try SQLiteStore(url: RuntimeSettings.supportDirectory.appendingPathComponent("library.sqlite")) }
        catch { alert = error.localizedDescription }
        player.onUpdate = { [weak self] snapshot in self?.receive(snapshot) }
        videoView.onRenderError = { [weak self] message in self?.alert = message }
        aligner.onChange = { [weak self] words, status in
            self?.timings = words; self?.alignmentStatus = status; self?.refreshLearning()
        }
        configureDictionary()
        if let error = player.startupError { subtitleStatus = error }
        player.set("volume", String(volume))
    }

    var canPlay: Bool { media != nil && player.handle != nil }
    var hasRuntime: Bool { player.handle != nil }
    var mediaURL: URL? { media.map { URL(fileURLWithPath: $0.path) } }
    var bilingualText: String { activeChinese.map(\.text).joined(separator: "\n") }
    var selected: LearningSelection? { learning.selected }
    var isFollowing: Bool { !learning.isLocked }
    var alignedWordCount: Int { timings.count }
    var firstAlignedWord: TimedWord? { timings.first }

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audio, .mpeg4Movie, UTType(filenameExtension: "mkv") ?? .movie]
        panel.allowsMultipleSelection = false
        panel.message = "打开本地视频，开始字幕学习"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func chooseSubtitle(_ language: SubtitleLanguage? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt"].compactMap { UTType(filenameExtension: $0) }
        panel.message = language.map { "导入\($0.title)字幕" } ?? "导入双语字幕或单语字幕"
        if panel.runModal() == .OK, let url = panel.url { importSubtitle(url, language: language) }
    }
    func acceptDrop(_ url: URL) {
        if ["srt", "ass", "ssa", "vtt"].contains(url.pathExtension.lowercased()) { importSubtitle(url) }
        else { open(url) }
    }

    func open(_ url: URL) {
        savePlayback()
        openTask?.cancel(); searchTask?.cancel(); lookupTask?.cancel(); aligner.cancel()
        sessionID = UUID(); searchID = UUID(); lookupID = UUID()
        let session = sessionID
        guard let identity = try? MediaIdentity(url: url) else { alert = "无法读取视频文件。"; return }
        media = identity
        saved = (try? store?.load(SavedPlayback.self, key: identity.key, table: "playback")) ?? SavedPlayback()
        english = []; chinese = []; activeEnglish = []; activeChinese = []; timings = []
        learning.reset(); currentWordID = nil; dictionaryEntry = nil; lastDictionaryKey = ""
        englishPath = nil; chinesePath = nil; englishDigest = ""
        englishSource = "未加载"; chineseSource = "未加载"; subtitleOptions = []
        audioStreams = []; selectedAudio = -1
        englishOffset = saved.englishOffset; chineseOffset = saved.chineseOffset
        position = 0; duration = 0; paused = false; awaitingLoad = true
        replayRange = nil; replayArmed = false
        subtitleStatus = "正在发现字幕…"; alignmentStatus = "等待英文字幕与音轨"
        searchResults = []; isSearching = false; isDownloading = false
        let query = ReleaseQuery(filename: url.lastPathComponent)
        searchText = query.title; searchYear = query.year.map(String.init) ?? ""
        searchSeason = query.season.map(String.init) ?? ""; searchEpisode = query.episode.map(String.init) ?? ""
        player.load(url); player.pause(false)
        if let error = player.startupError { alert = error }
        let settings = settings
        let saved = saved
        openTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Restore previously chosen files before discovery; missing files fall through.
                for (path, language) in [(saved.englishPath, SubtitleLanguage.english), (saved.chinesePath, .chinese)] {
                    if let path, FileManager.default.fileExists(atPath: path) {
                        try? await self.attachSubtitle(URL(fileURLWithPath: path), language: language, onlyMissing: true, session: session)
                    }
                }
                for sidecar in MediaInspector.sidecars(video: url) {
                    try Task.checkCancellation(); guard self.sessionID == session else { return }
                    self.subtitleOptions.append(.init(title: sidecar.lastPathComponent, url: sidecar))
                    try? await self.attachSubtitle(sidecar, language: nil, onlyMissing: true, session: session)
                }
                let streams = try await MediaInspector.inspect(url: url, settings: settings)
                try Task.checkCancellation(); guard self.sessionID == session else { return }
                self.audioStreams = streams.filter { $0.kind == "audio" }
                let preferred = self.audioStreams.first { $0.id == saved.audioStream } ?? self.audioStreams.first { ["en", "eng"].contains($0.language) } ?? self.audioStreams.first { $0.isDefault } ?? self.audioStreams.first
                if let preferred { self.selectedAudio = preferred.id; self.player.selectAudio(streamIndex: preferred.id) }
                let folder = RuntimeSettings.supportDirectory.appendingPathComponent("Subtitles/\(identity.key)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let languageRank: (MediaStream) -> Int = { stream in
                    if ["en", "eng"].contains(stream.language.lowercased()) { return 0 }
                    if ["zh", "zho", "chi", "zh-cn", "zh-tw"].contains(stream.language.lowercased()) { return 1 }
                    return ["", "und"].contains(stream.language.lowercased()) ? 2 : 3
                }
                let textStreams = streams.filter(\.isTextSubtitle).sorted {
                    (languageRank($0), $0.isDefault ? 0 : 1, $0.id) < (languageRank($1), $1.isDefault ? 0 : 1, $1.id)
                }
                for stream in textStreams {
                    try Task.checkCancellation(); guard self.sessionID == session else { return }
                    let extracted = folder.appendingPathComponent("embedded-\(stream.id).srt")
                    if !FileManager.default.fileExists(atPath: extracted.path) { try await MediaInspector.extractSubtitle(video: url, stream: stream, destination: extracted, settings: settings) }
                    guard self.sessionID == session else { return }
                    self.subtitleOptions.append(.init(title: "内嵌 · \(stream.label)", url: extracted))
                    // Keep other language tracks selectable, but never mistake
                    // a known French/Spanish/etc. Latin-script track for English.
                    if languageRank(stream) < 3 { try? await self.attachSubtitle(extracted, language: nil, onlyMissing: true, session: session) }
                }
                self.updateSubtitleStatus(); self.restartAlignment(); self.maybeSearchMissing()
            } catch is CancellationError {}
            catch {
                guard self.sessionID == session else { return }
                self.subtitleStatus = error.localizedDescription
                self.restartAlignment(); self.maybeSearchMissing()
            }
        }
    }

    func importSubtitle(_ url: URL, language: SubtitleLanguage? = nil) {
        guard media != nil else { alert = "请先打开视频，再导入字幕。"; return }
        let session = sessionID
        Task {
            do {
                try await attachSubtitle(url, language: language, onlyMissing: false, session: session)
                if !subtitleOptions.contains(where: { $0.url == url }) { subtitleOptions.append(.init(title: url.lastPathComponent, url: url)) }
                updateSubtitleStatus(); savePlayback()
            } catch { if sessionID == session { alert = error.localizedDescription } }
        }
    }
    private func attachSubtitle(_ url: URL, language: SubtitleLanguage?, onlyMissing: Bool, session: UUID) async throws {
        let result = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            return (try SubtitleParser.parse(data: data, ext: url.pathExtension), Digest.data(data))
        }.value
        try Task.checkCancellation()
        guard sessionID == session else { return }
        let parsed = result.0
        if language == .english && parsed.english.isEmpty { throw ProcessFailure(message: "这份字幕中没有英文台词。") }
        if language == .chinese && parsed.chinese.isEmpty { throw ProcessFailure(message: "这份字幕中没有中文台词。") }
        var replacedEnglish = false
        if language != .chinese, !parsed.english.isEmpty, !onlyMissing || english.isEmpty {
            english = parsed.english; englishPath = url.path; englishSource = url.lastPathComponent; englishDigest = result.1; replacedEnglish = true
        }
        if language != .english, !parsed.chinese.isEmpty, !onlyMissing || chinese.isEmpty {
            chinese = parsed.chinese; chinesePath = url.path; chineseSource = url.lastPathComponent
        }
        if replacedEnglish { learning.reset(); restartAlignment() }
        refreshLearning(); savePlayback()
    }
    func setOffset(_ value: Double, language: SubtitleLanguage) {
        guard value.isFinite else { return }
        if language == .english { englishOffset = value; learning.reset(); replayRange = nil; restartAlignment() }
        else { chineseOffset = value; if let locked = learning.locked { learning.lock(selection(cue: locked.cue, token: locked.token)) } }
        refreshLearning(); savePlayback()
    }
    func selectAudio(_ stream: Int) {
        guard audioStreams.contains(where: { $0.id == stream }) else { return }
        selectedAudio = stream; player.selectAudio(streamIndex: stream)
        learning.reset(); replayRange = nil; restartAlignment(); savePlayback()
    }
    private func restartAlignment() {
        timings = []; currentWordID = nil
        guard selectedAudio >= 0 else { alignmentStatus = "等待可用音轨 · 字幕可点词查阅"; return }
        aligner.configure(media: media, cues: english, sourceDigest: englishDigest, audioStream: selectedAudio, offset: englishOffset, position: position, settings: settings, store: store)
        aligner.updatePosition(position)
    }
    private func receive(_ snapshot: PlaybackSnapshot) {
        guard media != nil else { return }
        if let error = snapshot.error { alert = "播放失败：\(error)" }
        if awaitingLoad {
            guard snapshot.loaded else { return }
            awaitingLoad = false
            if saved.position > 0 { player.seek(saved.position) }
            if selectedAudio >= 0 { player.selectAudio(streamIndex: selectedAudio) }
            player.set("speed", String(speed)); player.set("volume", String(volume))
        }
        position = snapshot.position.isFinite ? max(0, snapshot.position) : 0
        duration = snapshot.duration.isFinite ? max(0, snapshot.duration) : 0
        paused = snapshot.paused
        if let range = replayRange {
            if range.contains(position) { replayArmed = true }
            if replayArmed && position >= range.upperBound - 0.025 { player.pause(true); replayRange = nil; replayArmed = false }
        }
        refreshLearning(); aligner.updatePosition(position)
        if Date().timeIntervalSince(lastSavedAt) > 5 { savePlayback() }
    }
    func togglePlayback() { replayRange = nil; replayArmed = false; player.pause(!paused) }
    func seek(_ time: Double) {
        let target = max(0, duration > 0 ? min(time, duration) : time)
        replayRange = nil; replayArmed = false; player.seek(target); position = target
        aligner.updatePosition(target, seek: true); refreshLearning()
    }
    func setSpeed(_ value: Double) { speed = value; player.set("speed", String(value)) }
    func setVolume(_ value: Double) { volume = value; player.set("volume", String(value)) }
    func lock(cue: SubtitleCue, token: WordToken) {
        guard token.isWord else { return }
        replayRange = nil; replayArmed = false
        learning.lock(selection(cue: cue, token: token)); player.pause(true); paused = true; refreshDictionary()
    }
    func resumeLearning() {
        replayRange = nil; replayArmed = false; learning.resumeFollowing(); player.pause(false); refreshLearning()
    }
    func replaySentence() {
        guard let selected else { return }
        learning.lock(selected)
        let start = selected.playbackStart, end = selected.playbackEnd
        guard end > start else { return }
        replayRange = start...end; replayArmed = false
        player.seek(start); player.pause(false); aligner.updatePosition(start, seek: true)
    }
    private func selection(cue: SubtitleCue, token: WordToken) -> LearningSelection {
        let contextTime = cue.contains(position, offset: englishOffset) ? position : (cue.start + cue.end) / 2 + englishOffset
        let translation = Timeline.active(chinese, at: contextTime, offset: chineseOffset).map(\.text).joined(separator: "\n")
        return LearningSelection(cue: cue, token: token, chinese: translation, offset: englishOffset)
    }
    private func refreshLearning() {
        let en = Timeline.active(english, at: position, offset: englishOffset)
        let zh = Timeline.active(chinese, at: position, offset: chineseOffset)
        if activeEnglish != en { activeEnglish = en }
        if activeChinese != zh { activeChinese = zh }
        if let word = Timeline.spoken(timings, at: position), let cue = en.first(where: { $0.id == word.cueID }), let token = cue.tokens.first(where: { $0.id == word.tokenIndex }) {
            currentWordID = "\(word.cueID):\(word.tokenIndex)"
            let next = selection(cue: cue, token: token)
            if learning.spoken != next { learning.follow(next) }
        } else {
            currentWordID = nil
            if learning.spoken != nil { learning.follow(nil) }
        }
        refreshDictionary()
    }
    private func configureDictionary() {
        do { dictionary = try ECDictionary(path: settings.dictionary); dictionaryStatus = "词典释义 · ECDICT" }
        catch { dictionary = nil; dictionaryStatus = error.localizedDescription }
        lastDictionaryKey = ""; refreshDictionary()
    }
    private func refreshDictionary() {
        let key = selected.map { $0.cue.id + ":" + String($0.token.id) + ":" + $0.token.normalized } ?? ""
        guard key != lastDictionaryKey else { return }
        lastDictionaryKey = key; lookupTask?.cancel(); lookupID = UUID(); dictionaryEntry = nil
        guard let selected, let dictionary else { return }
        let word = selected.token.normalized, token = lookupID
        dictionaryStatus = "正在查询词典…"
        lookupTask = Task { [weak self] in
            do {
                let entry = try await dictionary.lookup(word)
                guard !Task.isCancelled, let self, self.lookupID == token else { return }
                self.dictionaryEntry = entry
                self.dictionaryStatus = entry == nil ? "词库暂无该词 · 可回放当前台词" : "词典释义 · ECDICT"
            } catch { if let self, self.lookupID == token { self.dictionaryStatus = error.localizedDescription } }
        }
    }
    func saveSettings(_ updated: RuntimeSettings, apiKey: String) throws {
        let previousLibrary = settings.libmpv
        try updated.save(); try SecretStore.write(apiKey, name: "api-key")
        settings = updated; configureDictionary(); restartAlignment()
        if previousLibrary != updated.libmpv { alert = "播放库路径已保存。请重新启动 LingoPlayer 以加载新的播放内核。" }
    }
    func login(apiKey: String, username: String, password: String) async throws {
        let token = try await OpenSubtitlesClient(apiKey: apiKey).login(username: username, password: password)
        try SecretStore.write(apiKey, name: "api-key"); try SecretStore.write(token, name: "token")
    }
    private func subtitleClient() -> OpenSubtitlesClient { OpenSubtitlesClient(apiKey: SecretStore.read("api-key"), token: SecretStore.read("token")) }
    private func updateSubtitleStatus() {
        let en = english.isEmpty ? "缺少英文字幕" : "英文 \(english.count) 句"
        let zh = chinese.isEmpty ? "缺少中文字幕" : "中文 \(chinese.count) 句"
        subtitleStatus = "\(en) · \(zh)"
    }
    private func maybeSearchMissing() {
        guard settings.autoSearch, !isSearching, !isDownloading, !SecretStore.read("api-key").isEmpty else { return }
        if english.isEmpty { searchSubtitles(.english, automatic: true) }
        else if chinese.isEmpty { searchSubtitles(.chinese, automatic: true) }
    }
    func searchSubtitles(_ language: SubtitleLanguage, automatic: Bool = false) {
        guard let url = mediaURL else { return }
        searchTask?.cancel(); searchID = UUID()
        let searchID = searchID, session = sessionID
        searchLanguage = language; isSearching = true; searchResults = []
        searchMessage = "正在搜索\(language.title)字幕…"
        if !automatic { showSubtitleSearch = true }
        let client = subtitleClient()
        var query = ReleaseQuery(filename: url.lastPathComponent)
        query.title = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        query.year = Int(searchYear); query.season = Int(searchSeason); query.episode = Int(searchEpisode)
        searchTask = Task { [weak self] in
            do {
                let hash = try await Task.detached { try OpenSubtitlesHash.compute(url: url) }.value
                var results = try await client.search(query: query, hash: hash, language: language)
                if results.isEmpty, hash != nil { results = try await client.search(query: query, hash: nil, language: language) }
                try Task.checkCancellation()
                guard let self, self.searchID == searchID, self.sessionID == session else { return }
                self.searchResults = results; self.isSearching = false
                self.searchMessage = results.isEmpty ? "没有找到合适字幕。可修改片名、年份或季集信息，或手动导入。" : "找到 \(results.count) 个候选。优先选择文件匹配的版本；片名匹配仍需确认时间。"
                let exact = results.filter(\.hashMatched)
                if automatic, exact.count == 1, let candidate = exact.first { self.downloadSubtitle(candidate, language: language, automatic: true) }
                else { self.showSubtitleSearch = true }
            } catch is CancellationError {}
            catch {
                guard let self, self.searchID == searchID, self.sessionID == session else { return }
                self.isSearching = false; self.searchMessage = error.localizedDescription
                if !automatic { self.showSubtitleSearch = true } else { self.subtitleStatus = error.localizedDescription }
            }
        }
    }
    func downloadSubtitle(_ candidate: SubtitleCandidate, language: SubtitleLanguage? = nil, automatic: Bool = false) {
        guard !isDownloading, let media else { return }
        let language = language ?? searchLanguage
        let session = sessionID
        isDownloading = true; searchMessage = "正在下载并检查字幕…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.subtitleClient().download(fileID: candidate.id)
                guard self.sessionID == session else { return }
                let folder = RuntimeSettings.supportDirectory.appendingPathComponent("Subtitles/\(media.key)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("opensubtitles-\(candidate.id)-\(language.rawValue).srt")
                // Validate before persisting a remote body as a subtitle.
                _ = try SubtitleParser.parse(data: data, ext: "srt")
                try data.write(to: url, options: .atomic)
                try await self.attachSubtitle(url, language: language, onlyMissing: automatic, session: session)
                self.isDownloading = false; self.showSubtitleSearch = false
                self.updateSubtitleStatus(); self.savePlayback(); self.maybeSearchMissing()
            } catch {
                guard self.sessionID == session else { return }
                self.isDownloading = false; self.searchMessage = error.localizedDescription; self.showSubtitleSearch = true
            }
        }
    }
    func savePlayback() {
        guard let media else { return }
        var saved = SavedPlayback()
        saved.position = position; saved.englishPath = englishPath; saved.chinesePath = chinesePath
        saved.englishOffset = englishOffset; saved.chineseOffset = chineseOffset
        saved.audioStream = selectedAudio >= 0 ? selectedAudio : nil
        do { try store?.save(saved, key: media.key, table: "playback") }
        catch { subtitleStatus = "本地进度保存失败：\(error.localizedDescription)" }
        lastSavedAt = Date()
    }
    func shutdown() {
        savePlayback(); openTask?.cancel(); searchTask?.cancel(); lookupTask?.cancel(); aligner.cancel()
        videoView.shutdown(); player.shutdown()
    }
}
