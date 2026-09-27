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
    @Published var queueState = PlaybackQueue()
    @Published var progress: [String: PlaybackProgress] = [:]
    @Published var preferences = InteractionPreferences() { didSet { updateTranscriptVisibility() } }
    @Published var sidebarTab: SidebarTab = .learning { didSet { if sidebarTab != oldValue { refreshDictionary(); updateTranscriptVisibility() } } }
    @Published var recordingAction: PlayerAction?
    @Published var shortcutMessage = ""
    @Published var queueMessage = ""
    var onReattach: (() -> Void)?
    var onShortcutsChanged: (() -> Void)?
    let transcript = TranscriptController()
    let playback = PlaybackPresentation()
    let mediaPresentation = MediaPresentation()
    let subtitles = SubtitlePresentation()
    let learningPresentation = LearningPresentation()
    let chrome = PlayerChrome()
    @Published var sentenceLoop: SentenceLoop?
    @Published var practiceMessage = ""
    var loopIterations = 0
    var seekRevision: UInt64 = 0
    var endGate = PlaybackEndGate()
    var restoring = false
    var completed = false
    var seekTarget: Double?
    var seekDeadline = Date.distantPast
    var playbackReady: Bool { media != nil && !awaitingLoad }
    @Published var settings = RuntimeSettings.load()
    @Published var media: MediaIdentity?
    var position = 0.0 { didSet { playback.updatePosition(position) } }
    var duration: Double { get { playback.duration } set { if newValue != playback.duration { playback.duration = newValue; mediaPresentation.duration = newValue } } }
    var paused: Bool { get { playback.paused } set { if newValue != playback.paused { playback.paused = newValue }; chrome.playback(paused: newValue, ready: playbackReady); if newValue { playback.updatePosition(position, immediate: true) } } }
    var speed: Double { get { playback.speed } set { if newValue != playback.speed { playback.speed = newValue } } }
    var volume: Double { get { playback.volume } set { if newValue != playback.volume { playback.volume = newValue } } }
    @Published var english: [SubtitleCue] = [] { didSet { englishIndex = TimelineIndex(starts: english.map(\.start), ends: english.map(\.end)) } }
    @Published var chinese: [SubtitleCue] = [] { didSet { chineseIndex = TimelineIndex(starts: chinese.map(\.start), ends: chinese.map(\.end)) } }
    var englishIndex = TimelineIndex(), chineseIndex = TimelineIndex(), wordIndex = TimelineIndex()
    var activeEnglish: [SubtitleCue] { get { subtitles.english } set { if newValue != subtitles.english { subtitles.english = newValue } } }
    var activeChinese: [SubtitleCue] { get { subtitles.chinese } set { if newValue != subtitles.chinese { subtitles.chinese = newValue } } }
    @Published var englishOffset = 0.0
    @Published var chineseOffset = 0.0
    @Published private(set) var pendingSubtitleOffsets: [SubtitleLanguage: Double] = [:]
    private var subtitleOffsetTask: Task<Void, Never>?
    @Published var sentenceTailPadding = SentenceLoop.defaultTailPadding
    @Published var englishSource = "未加载"
    @Published var chineseSource = "未加载"
    @Published var audioStreams: [MediaStream] = []
    @Published var selectedAudio = -1
    @Published var subtitleOptions: [SubtitleOption] = []
    @Published var subtitleStatus = "打开视频后自动发现字幕"
    @Published var alignmentTaskStatus = AlignmentTaskStatus(.idle, "")
    @Published var showAlignmentDetails = false { didSet { updateChromePresentation() } }
    @Published var alignmentDetails = ""
    @Published var alignmentStatus = "导入英文字幕后可准备逐词高亮"
    var learningState = LearningState()
    var learning: LearningState {
        get { learningState }
        set {
            learningState = newValue
            let locked = newValue.locked.map { "\($0.cue.id):\($0.token.id)" }
            if subtitles.lockedWordID != locked { subtitles.lockedWordID = locked }
            if learningVisible && newValue != learningPresentation.state { learningPresentation.state = newValue }
        }
    }
    var dictionaryEntry: DictionaryEntry? { get { learningPresentation.entry } set { if newValue != learningPresentation.entry { learningPresentation.entry = newValue } } }
    var dictionaryStatus: String { get { learningPresentation.status } set { if newValue != learningPresentation.status { learningPresentation.status = newValue } } }
    var currentWordID: String? { get { subtitles.wordID } set { if newValue != subtitles.wordID { subtitles.wordID = newValue } } }
    @Published var isDetached = false { didSet { if oldValue != isDetached { refreshDictionary() } } }
    @Published var showSettings = false { didSet { updateChromePresentation() } }
    @Published var settingsPage = 0
    @Published var showSubtitleSearch = false { didSet { updateChromePresentation() } }
    @Published var showSubtitleControls = false { didSet { updateChromePresentation() } }
    @Published var playerPopover: PlayerPopover? { didSet { updateChromePresentation() } }
    @Published var alert: String? { didSet { updateChromePresentation() } }
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
    let aligner = AlignmentCoordinator()
    var store: StorageWorker?
    var stateTask: Task<Void, Never>?
    var interactionReady = false
    var lastPersistedQueue: PlaybackQueue?
    var dictionary: ECDictionary?
    var timings: [TimedWord] = [] { didSet { wordIndex = TimelineIndex(starts: timings.map(\.start), ends: timings.map(\.end)) } }
    var englishPath: String?
    var chinesePath: String?
    var englishDigest = ""
    var saved = SavedPlayback()
    var openTask: Task<Void, Never>?
    var searchTask: Task<Void, Never>?
    var lookupTask: Task<Void, Never>?
    var lookupID = UUID()
    var sessionID = UUID()
    var searchID = UUID()
    var lastDictionaryKey = ""
    var lastSavedAt = Date.distantPast
    var awaitingLoad = false { didSet { let value = media != nil && !awaitingLoad; if playback.ready != value { playback.ready = value; mediaPresentation.ready = value }; chrome.playback(paused: paused, ready: value) } }
    var replayRange: ClosedRange<Double>?
    var replayArmed = false
    // Keep the practiced subtitle visible through its tail and the final pause.
    var replayCue: SubtitleCue?
    var onDetach: (() -> Void)?

    init() {
        let loaded = RuntimeSettings.load()
        player = MPVPlayer(library: loaded.libmpv)
        videoView = MPVVideoView(player: player)
        store = StorageWorker(url: RuntimeSettings.supportDirectory.appendingPathComponent("library.sqlite"))
        store?.onError = { [weak self] message in Task { @MainActor in self?.queueMessage = "本地数据保存失败：\(message)" } }
        player.onUpdate = { [weak self] snapshot in self?.receive(snapshot) }
        videoView.onRenderError = { [weak self] message in self?.alert = message }
        aligner.onChange = { [weak self] words, status in
            guard let self else { return }
            if self.timings != words { self.timings = words }
            if self.alignmentStatus != status { self.alignmentStatus = status }
            self.refreshLearning()
        }
        aligner.onStatus = { [weak self] status in
            guard let self else { return }
            if self.alignmentTaskStatus != status { self.alignmentTaskStatus = status }
            if status.phase == .environmentFailure || status.phase == .partialFailure {
                self.chrome.showNotice("逐词准备遇到问题，可在播放设置中查看或重试。", key: status.message)
            }
        }
        loadInteractionState()
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

    func chooseVideo(adding: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audio, .mpeg4Movie, UTType(filenameExtension: "mkv") ?? .movie]
        panel.allowsMultipleSelection = true
        panel.message = "打开本地视频，开始字幕学习"
        if panel.runModal() == .OK { ingest(panel.urls, adding: adding) }
    }
    func chooseSubtitle(_ language: SubtitleLanguage? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt"].compactMap { UTType(filenameExtension: $0) }
        panel.message = language.map { "导入\($0.title)字幕" } ?? "导入双语字幕或单语字幕"
        if panel.runModal() == .OK, let url = panel.url { importSubtitle(url, language: language) }
    }
    func acceptDrop(_ url: URL) { acceptFiles([url]) }
    func open(_ url: URL) { ingest([url]) }
    func loadMedia(_ url: URL, restoring: Bool = false) {
        chrome.resetNotice()
        chrome.resetFeedback(); cancelPendingSubtitleOffsets()
        savePlayback()
        openTask?.cancel(); searchTask?.cancel(); lookupTask?.cancel(); aligner.cancel()
        sessionID = UUID(); searchID = UUID(); lookupID = UUID()
        sentenceLoop = nil; practiceMessage = ""; seekRevision = 0; transcript.reset()
        cancelReplay()
        let session = sessionID
        guard let identity = try? MediaIdentity(url: url) else { alert = "无法读取视频文件。"; return }
        media = identity
        awaitingLoad = true; player.pause(true)
        english = []; chinese = []; activeEnglish = []; activeChinese = []
        learning.reset(); currentWordID = nil; dictionaryEntry = nil; lastDictionaryKey = ""
        openTask = Task { [weak self] in
            guard let self else { return }
            let restored = try? await store?.load(SavedPlayback.self, key: identity.key, table: "playback")
            guard !Task.isCancelled, sessionID == session else { return }
            saved = restored ?? SavedPlayback()
            finishLoadMedia(url, identity: identity, session: session, restoring: restoring)
        }
    }
    private func finishLoadMedia(_ url: URL, identity: MediaIdentity, session: UUID, restoring: Bool) {
        english = []; chinese = []; activeEnglish = []; activeChinese = []; timings = []
        learning.reset(); currentWordID = nil; dictionaryEntry = nil; lastDictionaryKey = ""
        englishPath = nil; chinesePath = nil; englishDigest = ""
        englishSource = "未加载"; chineseSource = "未加载"; subtitleOptions = []
        audioStreams = []; selectedAudio = -1
        englishOffset = saved.englishOffset; chineseOffset = saved.chineseOffset
        sentenceTailPadding = saved.sentenceTailPadding
        self.restoring = restoring; completed = false
        let previous = progress[url.path]
        if previous?.mediaKey == identity.key && previous?.finished == true { saved.position = 0 }
        position = saved.position; duration = previous?.mediaKey == identity.key ? previous?.duration ?? 0 : 0
        paused = restoring; awaitingLoad = true; seekTarget = nil
        endGate.begin(session, purpose: restoring ? .restoration : .normal, playing: !restoring)
        cancelReplay()
        subtitleStatus = "正在发现字幕…"; alignmentStatus = "等待英文字幕与音轨"
        searchResults = []; isSearching = false; isDownloading = false
        let query = ReleaseQuery(filename: url.lastPathComponent)
        searchText = query.title; searchYear = query.year.map(String.init) ?? ""
        searchSeason = query.season.map(String.init) ?? ""; searchEpisode = query.episode.map(String.init) ?? ""
        player.load(url, generation: session, paused: true)
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
                guard sessionID == session else { return }
                if !subtitleOptions.contains(where: { $0.url == url }) { subtitleOptions.append(.init(title: url.lastPathComponent, url: url)) }
                updateSubtitleStatus(); savePlayback()
            } catch { if sessionID == session { alert = error.localizedDescription } }
        }
    }
    func attachSubtitle(_ url: URL, language: SubtitleLanguage?, onlyMissing: Bool, session: UUID) async throws {
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
        if replacedEnglish {
            cancelSentenceLoop(); cancelReplay()
            endGate.purpose = .normal; learning.reset(); restartAlignment()
        }
        refreshTranscript(reset: replacedEnglish)
        refreshLearning(); savePlayback()
    }
    func setOffset(_ value: Double, language: SubtitleLanguage) {
        guard value.isFinite else { return }
        pendingSubtitleOffsets.removeValue(forKey: language)
        if pendingSubtitleOffsets.isEmpty { subtitleOffsetTask?.cancel(); subtitleOffsetTask = nil }
        if language == .english { cancelSentenceLoop(); englishOffset = value; learning.reset(); cancelReplay(); endGate.purpose = .normal; restartAlignment() }
        else { chineseOffset = value; if let locked = learning.locked { learning.lock(selection(cue: locked.cue, token: locked.token)) } }
        refreshTranscript(); refreshLearning(); savePlayback()
    }
    func subtitleOffsetDraft(_ language: SubtitleLanguage) -> Double {
        let value = pendingSubtitleOffsets[language] ?? (language == .english ? englishOffset : chineseOffset)
        // Older versions allowed hundredths. Step from the displayed tenth,
        // while keeping the saved precision until the user actually adjusts it.
        let rounded = (value * 10).rounded() / 10
        return rounded == 0 ? 0 : rounded
    }
    func scheduleSubtitleOffset(_ value: Double, language: SubtitleLanguage) {
        guard value.isFinite, media != nil else { return }
        let rounded = (value * 10).rounded() / 10
        guard rounded.isFinite else { return }
        let applied = language == .english ? englishOffset : chineseOffset
        if rounded == applied { pendingSubtitleOffsets.removeValue(forKey: language) }
        else { pendingSubtitleOffsets[language] = rounded }
        subtitleOffsetTask?.cancel(); subtitleOffsetTask = nil
        guard !pendingSubtitleOffsets.isEmpty else { return }
        let session = sessionID
        // Keep the draft in the model so dismissing the popover does not lose it.
        // Both languages share the quiet period; switching media cancels it.
        subtitleOffsetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self, self.sessionID == session else { return }
            let pending = self.pendingSubtitleOffsets
            self.subtitleOffsetTask = nil; self.pendingSubtitleOffsets = [:]
            for language in SubtitleLanguage.allCases {
                if let value = pending[language] { self.setOffset(value, language: language) }
            }
        }
    }
    func cancelPendingSubtitleOffsets() {
        subtitleOffsetTask?.cancel(); subtitleOffsetTask = nil; pendingSubtitleOffsets = [:]
    }
    func setSentenceTailPadding(_ value: Double) {
        guard value.isFinite else { return }
        sentenceTailPadding = SentenceLoop.clampedTailPadding(value)
        if replayRange != nil, let cue = replayCue, let range = loopRange(for: cue) {
            replayRange = range.start...range.end
        }
        if let loop = sentenceLoop, let cue = english.first(where: { $0.id == loop.cueID }) {
            sentenceLoop = loopRange(for: cue)
        }
        savePlayback()
    }
    func selectAudio(_ stream: Int) {
        guard audioStreams.contains(where: { $0.id == stream }) else { return }
        cancelSentenceLoop()
        selectedAudio = stream; player.selectAudio(streamIndex: stream)
        learning.reset(); cancelReplay(); endGate.purpose = .normal; restartAlignment(); refreshLearning(); savePlayback()
    }
    func retryAlignment() { aligner.retry(settings: settings) }
    func viewAlignmentDetails() {
        alignmentDetails = "正在读取诊断记录…"; showAlignmentDetails = true
        let url = alignmentTaskStatus.diagnostic
        Task {
            let text = await Task.detached(priority: .utility) { url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "暂无失败记录。" }.value
            alignmentDetails = text
        }
    }
    func restartAlignment() {
        timings = []; currentWordID = nil
        guard selectedAudio >= 0 else { alignmentStatus = "等待可用音轨 · 字幕可点词查阅"; return }
        aligner.configure(media: media, cues: english, sourceDigest: englishDigest, audioStream: selectedAudio, offset: englishOffset, position: position, settings: settings, store: store)
        aligner.updatePosition(position)
    }
    func receive(_ snapshot: PlaybackSnapshot) {
        OperationMetrics.shared.observe(snapshot)
        guard let media, snapshot.generation == sessionID, snapshot.path == media.path else { return }
        if let error = snapshot.error { failCurrent(error); return }
        guard snapshot.loaded, snapshot.seekRevision == seekRevision else { return }
        if awaitingLoad {
            awaitingLoad = false
            duration = max(0, snapshot.duration)
            // A paused initial load prevents even a brief burst of sound on restoration.
            if saved.position > 0 {
                let target = min(saved.position, max(0, duration - 0.1))
                requestSeek(target)
            }
            if selectedAudio >= 0 { player.selectAudio(streamIndex: selectedAudio) }
            player.set("speed", String(speed)); player.set("volume", String(volume))
            player.pause(!endGate.wantsPlayback)
            queueState.mark(media.path, failure: nil); persistQueue()
            if seekTarget != nil { return }
        }
        if let target = seekTarget {
            if abs(snapshot.position - target) < max(0.08, speed * 0.12) && !snapshot.seeking && !snapshot.eof { seekTarget = nil }
            else if Date() < seekDeadline { return }
            else {
                seekTarget = nil
                if sentenceLoop != nil {
                    cancelSentenceLoop(); endGate.wantsPlayback = false; paused = true; player.pause(true)
                    practiceMessage = "无法定位循环句首，已暂停。请重试或选择另一句。"
                    return
                }
            }
        }
        if position == snapshot.position && duration == snapshot.duration && paused == snapshot.paused && !snapshot.eof && replayRange == nil && sentenceLoop == nil { return }
        position = snapshot.position.isFinite ? max(0, snapshot.position) : 0
        duration = snapshot.duration.isFinite ? max(0, snapshot.duration) : 0
        paused = snapshot.paused
        let naturalEnd = endGate.observe(generation: snapshot.generation, eof: snapshot.eof)
        if let loop = sentenceLoop {
            if endGate.wantsPlayback && loop.reachedEnd(at: position, eof: snapshot.eof) {
                loopIterations += 1
                requestSeek(loop.start); player.pause(false); paused = false
                refreshLearning(); return
            }
        } else if let range = replayRange {
            if range.contains(position) { replayArmed = true }
            if (replayArmed && position >= range.upperBound) || snapshot.eof {
                player.pause(true); paused = true; endGate.wantsPlayback = false
                replayRange = nil; replayArmed = false
            }
        } else if naturalEnd {
            completed = true; paused = true; endGate.wantsPlayback = false
            savePlayback()
            if preferences.autoplay, let next = queueState.adjacent(1) { playQueueItem(next); return }
        }
        refreshLearning(); aligner.updatePosition(position)
        if Date().timeIntervalSince(lastSavedAt) > 5 { savePlayback() }
    }
    func requestSeek(_ time: Double) {
        seekTarget = time; seekDeadline = Date().addingTimeInterval(2)
        seekRevision &+= 1
        player.seek(time, revision: seekRevision); position = time; playback.updatePosition(time, immediate: true)
        transcript.updatePosition(time)
    }
    func togglePlayback() {
        guard canPlay else { return }
        cancelReplay()
        let playing = !endGate.wantsPlayback
        endGate.purpose = sentenceLoop == nil ? .normal : .sentenceLoop
        endGate.wantsPlayback = playing; restoring = false
        if playing, let loop = sentenceLoop, loop.reachedEnd(at: position, eof: false) { requestSeek(loop.start) }
        else if playing && (completed || (duration > 0 && position >= duration - 0.05)) { completed = false; requestSeek(0) }
        paused = !playing; player.pause(paused); refreshLearning()
    }
    func seek(_ time: Double) {
        cancelSentenceLoop()
        let target = max(0, duration > 0 ? min(time, duration) : time)
        cancelReplay(); completed = false
        endGate.purpose = .normal
        // A direct scrub to the endpoint is a navigation operation, not natural completion.
        if duration > 0 && target >= duration {
            endGate.wantsPlayback = false; player.pause(true); paused = true
        }
        requestSeek(target)
        aligner.updatePosition(target, seek: true); refreshLearning()
    }
    func setSpeed(_ value: Double) {
        guard value.isFinite, value > 0 else { return }
        speed = value; player.set("speed", String(value))
        if playbackReady { chrome.showFeedback("\(value.formatted())×", symbol: "speedometer", detail: "播放速度") }
    }
    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        let previous = Int(volume.rounded())
        volume = min(100, max(0, value)); player.set("volume", String(volume))
        let current = Int(volume.rounded()), delta = Int(volume.rounded()) - previous
        let detail = delta == 0 ? (current == 0 ? "静音" : current == 100 ? "最大音量" : "音量") : "音量 \(delta > 0 ? "+" : "")\(delta)%"
        if playbackReady { chrome.showFeedback("\(current)%", symbol: "speaker.wave.3.fill", detail: detail, volume: volume) }
    }
    func lock(cue: SubtitleCue, token: WordToken) {
        guard token.isWord else { return }
        revealLearningCard()
        cancelReplay()
        learning.lock(selection(cue: cue, token: token)); endGate.wantsPlayback = false; player.pause(true); paused = true; refreshLearning()
    }
    func resumeLearning() {
        cancelSentenceLoop()
        cancelReplay(); learning.resumeFollowing()
        endGate.purpose = .normal; endGate.wantsPlayback = true; restoring = false
        if completed || (duration > 0 && position >= duration - 0.05) { completed = false; requestSeek(0) }
        paused = false; player.pause(false); refreshLearning()
    }
    func replaySentence() {
        guard let selected, let range = loopRange(for: selected.cue) else { return }
        cancelSentenceLoop()
        learning.lock(selected)
        let start = range.start
        replayRange = start...range.end; replayArmed = false; replayCue = selected.cue
        endGate.purpose = .sentenceReplay; endGate.wantsPlayback = true; completed = false
        requestSeek(start); paused = false; player.pause(false); aligner.updatePosition(start, seek: true); refreshLearning()
    }
    func cancelReplay() {
        replayRange = nil; replayArmed = false; replayCue = nil
    }
    func selection(cue: SubtitleCue, token: WordToken) -> LearningSelection {
        let contextTime = cue.contains(position, offset: englishOffset) ? position : (cue.start + cue.end) / 2 + englishOffset
        let translation = chineseIndex.active(at: contextTime - chineseOffset).map { chinese[$0] }.map(\.text).joined(separator: "\n")
        return LearningSelection(cue: cue, token: token, chinese: translation, offset: englishOffset)
    }
    func refreshLearning() {
        transcript.updatePosition(position)
        let practicedCue = self.practicedCue
        let en = practicedCue.map { [$0] } ?? englishIndex.active(at: position - englishOffset).map { english[$0] }
        let translationTime = practicedCue.map { ($0.start + $0.end) / 2 + englishOffset } ?? position
        let zh = chineseIndex.active(at: translationTime - chineseOffset).map { chinese[$0] }
        if activeEnglish != en { activeEnglish = en }
        if activeChinese != zh { activeChinese = zh }
        if let word = wordIndex.active(at: position).map({ timings[$0] }).first(where: { word in en.contains { $0.id == word.cueID } }), let cue = en.first(where: { $0.id == word.cueID }), let token = cue.tokens.first(where: { $0.id == word.tokenIndex }) {
            currentWordID = "\(word.cueID):\(word.tokenIndex)"
            let next = selection(cue: cue, token: token)
            if learning.spoken != next { learning.follow(next) }
        } else {
            currentWordID = nil
            if learning.spoken != nil { learning.follow(nil) }
        }
        refreshDictionary()
    }
    func configureDictionary() {
        do { dictionary = try ECDictionary(path: settings.dictionary); dictionaryStatus = "词典释义 · ECDICT" }
        catch { dictionary = nil; dictionaryStatus = error.localizedDescription }
        lastDictionaryKey = ""; refreshDictionary()
    }
    func refreshDictionary() {
        guard learningVisible else {
            if !lastDictionaryKey.isEmpty { lookupTask?.cancel(); lookupID = UUID(); lastDictionaryKey = ""; dictionaryEntry = nil }
            return
        }
        if learningPresentation.state != learningState { learningPresentation.state = learningState }
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
    func subtitleClient() -> OpenSubtitlesClient { OpenSubtitlesClient(apiKey: SecretStore.read("api-key"), token: SecretStore.read("token")) }
    func updateSubtitleStatus() {
        let en = english.isEmpty ? "缺少英文字幕" : "英文 \(english.count) 句"
        let zh = chinese.isEmpty ? "缺少中文字幕" : "中文 \(chinese.count) 句"
        subtitleStatus = "\(en) · \(zh)"
    }
    func maybeSearchMissing() {
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
                guard self.sessionID == session else { return }
                self.isDownloading = false; self.showSubtitleSearch = false
                self.updateSubtitleStatus(); self.savePlayback(); self.maybeSearchMissing()
            } catch {
                guard self.sessionID == session else { return }
                self.isDownloading = false; self.searchMessage = error.localizedDescription; self.showSubtitleSearch = true
            }
        }
    }
    func savePlayback() {
        guard let media, !awaitingLoad else { return }
        var saved = SavedPlayback()
        saved.position = position; saved.englishPath = englishPath ?? self.saved.englishPath; saved.chinesePath = chinesePath ?? self.saved.chinesePath
        saved.englishOffset = englishOffset; saved.chineseOffset = chineseOffset
        saved.sentenceTailPadding = sentenceTailPadding
        saved.audioStream = selectedAudio >= 0 ? selectedAudio : nil
        store?.save(saved, key: media.key, table: "playback")
        let record = PlaybackProgress(mediaKey: media.key, position: position, duration: duration, finished: completed)
        progress[media.path] = record
        store?.save(record, key: media.path, table: "progress")
        persistQueue()
        lastSavedAt = Date()
    }
    func prepareShutdown() async {
        player.onUpdate = nil; player.pause(true)
        // Preserve the last values the user selected without starting new
        // transcript/alignment work while the application is shutting down.
        if let value = pendingSubtitleOffsets[.english] { englishOffset = value }
        if let value = pendingSubtitleOffsets[.chinese] { chineseOffset = value }
        cancelPendingSubtitleOffsets(); chrome.resetFeedback()
        savePlayback()
        openTask?.cancel(); searchTask?.cancel(); lookupTask?.cancel(); aligner.cancel()
        await aligner.waitForCancellation(); await store?.flush()
    }
    func shutdown() {
        cancelPendingSubtitleOffsets(); chrome.resetFeedback()
         openTask?.cancel(); searchTask?.cancel(); lookupTask?.cancel(); aligner.cancel(); transcript.reset()
        videoView.shutdown(); player.shutdown()
    }
}
