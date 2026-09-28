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
    @Published var preferences = InteractionPreferences() { didSet {
        updateTranscriptVisibility()
        if oldValue.sidebarCollapsed != preferences.sidebarCollapsed { onWindowGeometryChanged?() }
    } }
    var onWindowGeometryChanged: (() -> Void)?
    @Published var videoAspect: Double? { didSet {
        if oldValue != videoAspect { onWindowGeometryChanged?() }
    } }
    @Published var sidebarTab: SidebarTab = .queue { didSet { if sidebarTab != oldValue { refreshDictionary(); updateTranscriptVisibility() } } }
    @Published var recordingAction: PlayerAction?
    @Published var shortcutMessage = ""
    @Published var queueMessage = ""
    var onReattach: (() -> Void)?
    var onShortcutsChanged: (() -> Void)?
    let transcript = TranscriptController()
    let playback = PlaybackPresentation()
    let mediaPresentation = MediaPresentation()
    let subtitles = SubtitlePresentation()
    let learningPresentation: LearningPresentation
    let dictionaryLookup: DictionaryLookupController
    let chrome = PlayerChrome()
    let viewing: ViewingPreferencesStore
    let filePanels = FilePanelPresenter()
    let windowPresentation = PlayerWindowPresentation()
    let screenshots: ScreenshotController
    var onToggleFullScreen: (() -> Void)?
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
    var duration: Double { get { playback.duration } set { if newValue != playback.duration { playback.duration = newValue; mediaPresentation.duration = newValue; updateLearningMode() } } }
    var paused: Bool { get { playback.paused } set { if newValue != playback.paused { playback.paused = newValue }; chrome.playback(paused: newValue, ready: playbackReady); if newValue { playback.updatePosition(position, immediate: true) } } }
    var speed: Double { get { playback.speed } set { if newValue != playback.speed { playback.speed = newValue } } }
    var volume: Double { get { playback.volume } set { if newValue != playback.volume { playback.volume = newValue } } }
    @Published var isLearningMode = false
    @Published var learningEligible = false
    var learningOverride: Bool?
    var appliedLearningPolicy: LearningActivationPolicy = .automatic
    var subtitleSelectionRevision: UInt64 = 0
    var audioSelectionRevision: UInt64 = 0
    var primarySubtitles: [SubtitleCue] = [] { didSet { displaySubtitles = primarySubtitles } }
    var displaySubtitles: [SubtitleCue] = [] { didSet { primaryIndex = TimelineIndex(starts: displaySubtitles.map(\.start), ends: displaySubtitles.map(\.end)) } }
    var primaryIndex = TimelineIndex()
    var primarySubtitlePath: String?
    let seekPreview = SeekPreviewController()
    @Published var english: [SubtitleCue] = [] { didSet { englishIndex = TimelineIndex(starts: english.map(\.start), ends: english.map(\.end)); updateLearningMode() } }
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
    var dictionaryEntry: DictionaryEntry? { learningPresentation.entry }
    var dictionaryStatus: String { learningPresentation.status }
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
    var timings: [TimedWord] = [] { didSet { wordIndex = TimelineIndex(starts: timings.map(\.start), ends: timings.map(\.end)) } }
    var englishPath: String?
    var chinesePath: String?
    var englishDigest = ""
    var saved = SavedPlayback()
    var openTask: Task<Void, Never>?
    var searchTask: Task<Void, Never>?
    var sessionID = UUID()
    var searchID = UUID()
    var lastSavedAt = Date.distantPast
    var awaitingLoad = false { didSet { let value = media != nil && !awaitingLoad; if playback.ready != value { playback.ready = value; mediaPresentation.ready = value }; chrome.playback(paused: paused, ready: value); updateLearningMode() } }
    var replayRange: ClosedRange<Double>?
    var replayArmed = false
    // Keep the practiced subtitle visible through its tail and the final pause.
    var replayCue: SubtitleCue?
    var onDetach: (() -> Void)?

    init(screenshotClipboard: NSPasteboard = .general) {
        let presentation = LearningPresentation()
        learningPresentation = presentation
        dictionaryLookup = DictionaryLookupController(presentation: presentation)
        screenshots = ScreenshotController(pasteboard: screenshotClipboard)
        let loaded = RuntimeSettings.load()
        player = MPVPlayer(library: loaded.libmpv)
        videoView = MPVVideoView(player: player)
        store = StorageWorker(url: RuntimeSettings.supportDirectory.appendingPathComponent("library.sqlite"))
        viewing = ViewingPreferencesStore(storage: store!)
        volume = viewing.volume; speed = viewing.speed
        store?.onError = { [weak self] message in Task { @MainActor in self?.queueMessage = "本地数据保存失败：\(message)" } }
        player.onUpdate = { [weak self] snapshot in self?.receive(snapshot) }
        videoView.onRenderError = { [weak self] message in self?.alert = message }
        aligner.onChange = { [weak self] words, status in
            guard let self, self.isLearningMode else { return }
            if self.timings != words { self.timings = words }
            if self.alignmentStatus != status { self.alignmentStatus = status }
            self.refreshLearning()
        }
        aligner.onStatus = { [weak self] status in
            guard let self, self.isLearningMode else { return }
            if self.alignmentTaskStatus != status { self.alignmentTaskStatus = status }
            if status.phase == .environmentFailure || status.phase == .partialFailure {
                self.chrome.showNotice("逐词准备遇到问题，可在播放设置中查看或重试。", key: status.message)
            }
        }
        loadInteractionState()
        appliedLearningPolicy = viewing.learningActivation
        viewing.onPlaybackPreferencesChanged = { [weak self] in self?.playbackPreferencesChanged() }
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
        filePanels.present { panel in
            panel.allowedContentTypes = [.movie, .video, .audio, .mpeg4Movie, UTType(filenameExtension: "mkv") ?? .movie]
            panel.allowsMultipleSelection = true
            panel.message = "打开本地视频"
        } completion: { [weak self] urls in self?.ingest(urls, adding: adding) }
    }
    func chooseSubtitle(_ language: SubtitleLanguage? = nil) {
        filePanels.present { panel in
            panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt"].compactMap { UTType(filenameExtension: $0) }
            panel.message = language.map { "导入\($0.title)字幕" } ?? "导入双语字幕或单语字幕"
        } completion: { [weak self] urls in
            guard let self, let url = urls.first else { return }
            if self.showSubtitleSearch { self.showSubtitleSearch = false }
            self.importSubtitle(url, language: language)
        }
    }
    func acceptDrop(_ url: URL) { acceptFiles([url]) }
    func open(_ url: URL) { ingest([url]) }
    func loadMedia(_ url: URL, restoring: Bool = false) {
        chrome.resetNotice()
        chrome.resetFeedback(); cancelPendingSubtitleOffsets()
        savePlayback()
        openTask?.cancel(); searchTask?.cancel(); dictionaryLookup.clearSelection(); aligner.cancel()
        awaitingLoad = true; learningOverride = nil
        subtitleSelectionRevision &+= 1; audioSelectionRevision &+= 1
        primarySubtitles = []; primarySubtitlePath = nil; seekPreview.setMedia(nil, ffmpeg: settings.ffmpeg)
        sessionID = UUID(); searchID = UUID()
        sentenceLoop = nil; practiceMessage = ""; seekRevision = 0; transcript.reset()
        cancelReplay()
        let session = sessionID
        guard let identity = try? MediaIdentity(url: url) else { alert = "无法读取视频文件。"; return }
        media = identity
        seekPreview.setMedia(url, ffmpeg: settings.ffmpeg)
        seekPreview.setEnabled(viewing.seekPreviewEnabled)
        videoAspect = nil
        awaitingLoad = true; player.pause(true)
        english = []; chinese = []; activeEnglish = []; activeChinese = []
        learning.reset(); currentWordID = nil; dictionaryLookup.clearSelection()
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
        learning.reset(); currentWordID = nil; dictionaryLookup.clearSelection()
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
        let selectionRevision = subtitleSelectionRevision, audioRevision = audioSelectionRevision
        openTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Restore previously chosen files before discovery; missing files fall through.
                for (path, language) in [(saved.primarySubtitlePath ?? saved.englishPath, Optional<SubtitleLanguage>.none), (saved.chinesePath, .some(.chinese))] {
                    if let path, FileManager.default.fileExists(atPath: path) {
                        // A saved secondary selection takes precedence over any
                        // translation bundled with the restored primary file.
                        try? await self.attachSubtitle(URL(fileURLWithPath: path), language: language, onlyMissing: language != .chinese, session: session, revision: selectionRevision)
                    }
                }
                for sidecar in MediaInspector.sidecars(video: url) {
                    try Task.checkCancellation(); guard self.sessionID == session else { return }
                    self.subtitleOptions.append(.init(title: sidecar.lastPathComponent, url: sidecar))
                    try? await self.attachSubtitle(sidecar, language: nil, onlyMissing: true, session: session, revision: selectionRevision)
                }
                let streams = try await MediaInspector.inspect(url: url, settings: settings)
                try Task.checkCancellation(); guard self.sessionID == session else { return }
                self.audioStreams = streams.filter { $0.kind == "audio" }
                let preferred = self.audioStreams.first { $0.id == saved.audioStream } ?? self.audioStreams.first { $0.isDefault } ?? self.audioStreams.first
                if let preferred, self.audioSelectionRevision == audioRevision { self.selectedAudio = preferred.id; self.player.selectAudio(streamIndex: preferred.id) }
                let folder = RuntimeSettings.supportDirectory.appendingPathComponent("Subtitles/\(identity.key)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let textStreams = streams.filter(\.isTextSubtitle).sorted {
                    ($0.isDefault ? 0 : 1, $0.id) < ($1.isDefault ? 0 : 1, $1.id)
                }
                for stream in textStreams {
                    try Task.checkCancellation(); guard self.sessionID == session else { return }
                    let extracted = folder.appendingPathComponent("embedded-\(stream.id).srt")
                    if !FileManager.default.fileExists(atPath: extracted.path) { try await MediaInspector.extractSubtitle(video: url, stream: stream, destination: extracted, settings: settings) }
                    guard self.sessionID == session else { return }
                    self.subtitleOptions.append(.init(title: "内嵌 · \(stream.label)", url: extracted))
                    try? await self.attachSubtitle(extracted, language: nil, onlyMissing: true, session: session, revision: selectionRevision)
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
        subtitleSelectionRevision &+= 1
        let revision = subtitleSelectionRevision, session = sessionID
        Task {
            do {
                try await attachSubtitle(url, language: language, onlyMissing: false, session: session, revision: revision)
                guard sessionID == session, subtitleSelectionRevision == revision else { return }
                if !subtitleOptions.contains(where: { $0.url == url }) { subtitleOptions.append(.init(title: url.lastPathComponent, url: url)) }
                updateSubtitleStatus(); savePlayback()
            } catch { if sessionID == session && subtitleSelectionRevision == revision { alert = error.localizedDescription } }
        }
    }
    func attachSubtitle(_ url: URL, language: SubtitleLanguage?, onlyMissing: Bool, session: UUID, revision: UInt64? = nil) async throws {
        let revision = revision ?? subtitleSelectionRevision
        let result = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            return (try SubtitleParser.parse(data: data, ext: url.pathExtension), Digest.data(data))
        }.value
        try Task.checkCancellation()
        guard sessionID == session, revision == subtitleSelectionRevision else { return }
        let parsed = result.0
        if (language == .chinese && (parsed.english.isEmpty || !parsed.chinese.isEmpty)) || (onlyMissing && !english.isEmpty && parsed.english.isEmpty && !parsed.chinese.isEmpty) {
            if !onlyMissing || chinese.isEmpty {
                chinese = parsed.english.isEmpty ? parsed.cues : parsed.chinese; chinesePath = url.path; chineseSource = url.lastPathComponent
            }
        } else if !onlyMissing || primarySubtitles.isEmpty {
            // The language menu is an import hint, never evidence of English.
            cancelSentenceLoop(); cancelReplay(); aligner.cancel()
            primarySubtitlePath = url.path; englishSource = url.lastPathComponent
            primarySubtitles = parsed.cues
            displaySubtitles = parsed.primaryCues
            // Replacing only English leaves the independently selected Chinese
            // track intact. A general bilingual import replaces both tracks.
            if parsed.english.isEmpty || (language != .english && !parsed.chinese.isEmpty) {
                chinese = parsed.english.isEmpty ? [] : parsed.chinese
                chinesePath = chinese.isEmpty ? nil : url.path
                chineseSource = chinese.isEmpty ? "未加载" : url.lastPathComponent
            }
            englishPath = parsed.english.isEmpty ? nil : url.path; englishDigest = result.1
            learning.reset(); timings = []; currentWordID = nil
            english = parsed.english
            restartAlignment()
        }
        updateLearningMode(); refreshTranscript(reset: !onlyMissing)
        refreshLearning(); updateSubtitleStatus(); savePlayback()
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
        if viewing.linkedSubtitleOffsets {
            let delta = ((rounded - subtitleOffsetDraft(language)) * 10).rounded() / 10
            func shifted(_ value: Double) -> Double { NSDecimalNumber(decimal: Decimal(value) + Decimal(delta)).doubleValue }
            // Shift both actual values by the same amount, including legacy
            // hundredths, so linking never erases an existing language gap.
            scheduleSubtitleOffsets([
                .english: shifted(pendingSubtitleOffsets[.english] ?? englishOffset),
                .chinese: shifted(pendingSubtitleOffsets[.chinese] ?? chineseOffset)
            ])
        } else { scheduleSubtitleOffsets([language: rounded]) }
    }
    func resetSubtitleOffsets() { scheduleSubtitleOffsets([.english: 0, .chinese: 0]) }
    var subtitleOffsetStatus: String { media == nil ? "未加载视频" : pendingSubtitleOffsets.isEmpty ? "已生效" : "等待生效" }
    private func scheduleSubtitleOffsets(_ adjustments: [SubtitleLanguage: Double]) {
        guard media != nil, adjustments.values.allSatisfy(\.isFinite) else { return }
        for (language, value) in adjustments {
            let applied = language == .english ? englishOffset : chineseOffset
            if abs(value - applied) < 1e-9 { pendingSubtitleOffsets.removeValue(forKey: language) }
            else { pendingSubtitleOffsets[language] = value }
        }
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
        audioSelectionRevision &+= 1
        selectedAudio = stream; player.selectAudio(streamIndex: stream)
        learning.reset(); cancelReplay(); endGate.purpose = .normal; restartAlignment(); refreshLearning(); savePlayback()
    }
    func retryAlignment() { guard isLearningMode else { return }; aligner.retry(settings: settings) }
    func viewAlignmentDetails() {
        guard isLearningMode else { return }
        alignmentDetails = "正在读取诊断记录…"; showAlignmentDetails = true
        let url = alignmentTaskStatus.diagnostic
        Task {
            let text = await Task.detached(priority: .utility) { url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "暂无失败记录。" }.value
            alignmentDetails = text
        }
    }
    func restartAlignment() {
        guard isLearningMode else { return }
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
        if videoAspect != snapshot.videoAspect { videoAspect = snapshot.videoAspect }
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
        refreshLearning(); if isLearningMode { aligner.updatePosition(position) }
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
        if isLearningMode { aligner.updatePosition(target, seek: true) }; refreshLearning()
    }
    func setSpeed(_ value: Double) {
        guard value.isFinite, value > 0 else { return }
        viewing.setSpeed(value); speed = viewing.speed; player.set("speed", String(speed))
        if playbackReady { chrome.showFeedback("\(speed.formatted())×", symbol: "speedometer", detail: "播放速度") }
    }
    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        let previous = Int(volume.rounded())
        volume = min(100, max(0, value)); player.set("volume", String(volume))
        viewing.setVolume(volume)
        let current = Int(volume.rounded()), delta = Int(volume.rounded()) - previous
        let detail = delta == 0 ? (current == 0 ? "静音" : current == 100 ? "最大音量" : "音量") : "音量 \(delta > 0 ? "+" : "")\(delta)%"
        if playbackReady { chrome.showFeedback("\(current)%", symbol: "speaker.wave.3.fill", detail: detail, volume: volume) }
    }
    func lock(cue: SubtitleCue, token: WordToken) {
        guard isLearningMode, token.isWord else { return }
        revealLearningCard()
        cancelReplay()
        learning.lock(selection(cue: cue, token: token)); endGate.wantsPlayback = false; player.pause(true); paused = true; refreshLearning()
    }
    func resumeLearning() {
        guard isLearningMode else { return }
        cancelSentenceLoop()
        cancelReplay(); learning.resumeFollowing()
        endGate.purpose = .normal; endGate.wantsPlayback = true; restoring = false
        if completed || (duration > 0 && position >= duration - 0.05) { completed = false; requestSeek(0) }
        paused = false; player.pause(false); refreshLearning()
    }
    func replaySentence() {
        guard isLearningMode, let selected, let range = loopRange(for: selected.cue) else { return }
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
        // These buttons depend on sentence boundaries, not on every clock tick.
        playback.updatePracticeAvailability(previous: canPerform(.previousSentence), next: canPerform(.nextSentence), loop: canPerform(.toggleSentenceLoop))
        let plain = primaryIndex.active(at: position - englishOffset).map { displaySubtitles[$0] }
        if subtitles.plain != plain { subtitles.plain = plain }
        let practicedCue = isLearningMode ? self.practicedCue : nil
        let en = practicedCue.map { [$0] } ?? englishIndex.active(at: position - englishOffset).map { english[$0] }
        let translationTime = practicedCue.map { ($0.start + $0.end) / 2 + englishOffset } ?? position
        let zh = chineseIndex.active(at: translationTime - chineseOffset).map { chinese[$0] }
        if activeEnglish != en { activeEnglish = en }
        if activeChinese != zh { activeChinese = zh }
        guard isLearningMode else { return }
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
    func refreshDictionary() {
        if learningVisible && learningPresentation.state != learningState { learningPresentation.state = learningState }
        dictionaryLookup.update(selection: selected, visible: learningVisible, path: settings.dictionary)
    }
    func saveSettings(_ updated: RuntimeSettings, apiKey: String) throws {
        let previousLibrary = settings.libmpv
        try updated.save(); try SecretStore.write(apiKey, name: "api-key")
        settings = updated
        dictionaryLookup.reset()
        refreshDictionary(); restartAlignment()
        if previousLibrary != updated.libmpv { alert = "播放库路径已保存。请重新启动 LingoPlayer 以加载新的播放内核。" }
    }
    func login(apiKey: String, username: String, password: String) async throws {
        let token = try await OpenSubtitlesClient(apiKey: apiKey).login(username: username, password: password)
        try SecretStore.write(apiKey, name: "api-key"); try SecretStore.write(token, name: "token")
    }
    func subtitleClient() -> OpenSubtitlesClient { OpenSubtitlesClient(apiKey: SecretStore.read("api-key"), token: SecretStore.read("token")) }
    func updateSubtitleStatus() {
        guard isLearningMode else { subtitleStatus = primarySubtitles.isEmpty && chinese.isEmpty ? "未加载字幕" : "普通播放 · 字幕 \(primarySubtitles.count + chinese.count) 句"; return }
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
        let searchID = searchID, session = sessionID, revision = subtitleSelectionRevision
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
                if automatic && revision != self.subtitleSelectionRevision { self.isSearching = false; return }
                self.searchResults = results; self.isSearching = false
                self.searchMessage = results.isEmpty ? "没有找到合适字幕。可修改片名、年份或季集信息，或手动导入。" : "找到 \(results.count) 个候选。优先选择文件匹配的版本；片名匹配仍需确认时间。"
                let exact = results.filter(\.hashMatched)
                let canAutoAttach = language == .english ? self.primarySubtitles.isEmpty : (self.chinese.isEmpty && !self.english.isEmpty)
                if automatic, canAutoAttach, exact.count == 1, let candidate = exact.first { self.downloadSubtitle(candidate, language: language, automatic: true, revision: revision) }
                else { self.showSubtitleSearch = true }
            } catch is CancellationError {}
            catch {
                guard let self, self.searchID == searchID, self.sessionID == session else { return }
                self.isSearching = false; self.searchMessage = error.localizedDescription
                if !automatic { self.showSubtitleSearch = true } else { self.subtitleStatus = error.localizedDescription }
            }
        }
    }
    func downloadSubtitle(_ candidate: SubtitleCandidate, language: SubtitleLanguage? = nil, automatic: Bool = false, revision: UInt64? = nil) {
        guard revision == nil || revision == subtitleSelectionRevision else { return }
        guard !isDownloading, let media else { return }
        let language = language ?? searchLanguage
        if !automatic { subtitleSelectionRevision &+= 1 }
        let revision = revision ?? subtitleSelectionRevision
        let session = sessionID
        isDownloading = true; searchMessage = "正在下载并检查字幕…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.subtitleClient().download(fileID: candidate.id)
                guard self.sessionID == session else { return }
                guard self.subtitleSelectionRevision == revision else { self.isDownloading = false; return }
                let folder = RuntimeSettings.supportDirectory.appendingPathComponent("Subtitles/\(media.key)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("opensubtitles-\(candidate.id)-\(language.rawValue).srt")
                // Validate before persisting a remote body as a subtitle.
                _ = try SubtitleParser.parse(data: data, ext: "srt")
                try data.write(to: url, options: .atomic)
                try await self.attachSubtitle(url, language: language, onlyMissing: automatic, session: session, revision: revision)
                guard self.sessionID == session else { return }
                guard self.subtitleSelectionRevision == revision else { self.isDownloading = false; return }
                self.isDownloading = false; self.showSubtitleSearch = false
                self.updateSubtitleStatus(); self.savePlayback(); self.maybeSearchMissing()
            } catch {
                guard self.sessionID == session else { return }
                guard self.subtitleSelectionRevision == revision else { self.isDownloading = false; return }
                self.isDownloading = false; self.searchMessage = error.localizedDescription; self.showSubtitleSearch = true
            }
        }
    }
    func savePlayback() {
        guard let media, !awaitingLoad else { return }
        var saved = SavedPlayback()
        saved.position = position; saved.primarySubtitlePath = primarySubtitlePath
        saved.englishPath = englishPath; saved.chinesePath = chinesePath
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
        seekPreview.endDrag(); await seekPreview.waitForIdle()
        await screenshots.finishPendingCapture()
        player.onUpdate = nil; player.pause(true)
        // Preserve the last values the user selected without starting new
        // transcript/alignment work while the application is shutting down.
        if let value = pendingSubtitleOffsets[.english] { englishOffset = value }
        if let value = pendingSubtitleOffsets[.chinese] { chineseOffset = value }
        cancelPendingSubtitleOffsets(); chrome.resetFeedback()
        savePlayback()
        openTask?.cancel(); searchTask?.cancel(); dictionaryLookup.clearSelection(); aligner.cancel()
        await aligner.waitForCancellation(); await store?.flush()
    }
    func shutdown() {
        seekPreview.endDrag()
        cancelPendingSubtitleOffsets(); chrome.resetFeedback()
        openTask?.cancel(); searchTask?.cancel(); dictionaryLookup.clearSelection(); aligner.cancel(); transcript.reset()
        videoView.shutdown(); player.shutdown()
    }
}
