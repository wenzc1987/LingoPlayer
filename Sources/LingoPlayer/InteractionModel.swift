import AppKit
import PlayerCore

enum SidebarTab: String, CaseIterable {
    case learning = "学习", transcript = "字幕", queue = "播放列表"
    var next: Self { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
}

@MainActor
extension AppModel {
    func updateTranscriptVisibility() { transcript.setVisible(!preferences.sidebarCollapsed && sidebarTab == .transcript) }
    func updateChromePresentation() {
        chrome.hold(.presentation, active: showSettings || showSubtitleSearch || showSubtitleControls || playerPopover != nil || showAlignmentDetails || alert != nil)
    }
    func openSidebar(_ tab: SidebarTab) {
        sidebarTab = tab
        if tab == .learning {
            var updated = preferences; updated.cardHidden = false; updatePreferences(updated)
        }
        setSidebarCollapsed(false)
    }
    static let speedSteps = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    static var preferenceURL: URL { RuntimeSettings.supportDirectory.appendingPathComponent("interaction.json") }
    func loadInteractionState() {
        if let data = try? Data(contentsOf: Self.preferenceURL), let value = try? JSONDecoder().decode(InteractionPreferences.self, from: data) { preferences = value }
        if !preferences.conflictNotices.isEmpty {
            shortcutMessage = "新动作与已有快捷键冲突，已保留旧绑定。请为以下动作设置快捷键：" + preferences.conflictNotices.compactMap { PlayerAction(rawValue: $0)?.title }.joined(separator: "、")
        }
        stateTask = Task { [weak self] in
            guard let self else { return }
            if let state = try? await store?.read({ db -> (PlaybackQueue, [String: PlaybackProgress]) in
                let queue = try db.load(PlaybackQueue.self, key: "main", table: "queue") ?? PlaybackQueue()
                var progress: [String: PlaybackProgress] = [:]
                for item in queue.items { progress[item.id] = try db.load(PlaybackProgress.self, key: item.id, table: "progress") }
                return (queue, progress)
            }) { queueState = state.0; progress = state.1; lastPersistedQueue = state.0 }
            interactionReady = true
        }
    }
    func restoreQueue() {
        Task { await stateTask?.value; if let current = queueState.currentID { playQueueItem(current, restoring: true) } }
    }
    func persistQueue() {
        guard queueState != lastPersistedQueue else { return }
        lastPersistedQueue = queueState; store?.save(queueState, key: "main", table: "queue")
    }
    @discardableResult func updatePreferences(_ updated: InteractionPreferences) -> Bool {
        guard preferences != updated else { return true }
        let bindingsChanged = PlayerAction.allCases.contains { preferences.shortcut(for: $0) != updated.shortcut(for: $0) }
        preferences = updated; store?.write(updated, to: Self.preferenceURL)
        if bindingsChanged { onShortcutsChanged?() }
        refreshDictionary(); return true
    }
    var learningVisible: Bool { !preferences.cardHidden && (isDetached || (!preferences.sidebarCollapsed && sidebarTab == .learning)) }
    func closeLearningCard() {
        learning.resumeFollowing(); lookupTask?.cancel(); lookupID = UUID(); dictionaryEntry = nil; lastDictionaryKey = ""
        var updated = preferences; updated.cardHidden = true; updatePreferences(updated)
    }
    func setSidebarCollapsed(_ value: Bool) {
        var updated = preferences; updated.sidebarCollapsed = value; updatePreferences(updated)
    }
    func revealLearningCard() {
        var updated = preferences; updated.cardHidden = false
        if !isDetached { updated.sidebarCollapsed = false; sidebarTab = .learning }
        updatePreferences(updated)
        if isDetached { onDetach?() }
    }
    func bind(_ shortcut: Shortcut?, to action: PlayerAction) {
        var updated = preferences
        if let message = updated.assign(shortcut, to: action) { shortcutMessage = message; return }
        guard updatePreferences(updated) else { return }; recordingAction = nil; shortcutMessage = "已保存，立即生效。"
    }
    func resetShortcuts() {
        var updated = preferences; updated.resetAll(); guard updatePreferences(updated) else { return }
        recordingAction = nil; shortcutMessage = "已恢复全部默认快捷键。"
    }
    func help(_ action: PlayerAction) -> String {
        action.title + (preferences.shortcut(for: action).map { " · " + $0.label } ?? "")
    }
    func canPerform(_ action: PlayerAction) -> Bool {
        switch action {
        case .toggleSidebar, .toggleSidebarVisibility, .cycleSubtitleDisplay: return true
        case .toggleSentenceLoop: return sentenceLoop != nil || currentLoopCandidate != nil
        case .previousVideo: return queueState.adjacent(-1) != nil
        case .nextVideo: return queueState.adjacent(1) != nil
        case .replaySentence: return playbackReady && selected != nil
        case .previousSentence, .nextSentence:
            guard playbackReady, let target = adjacentSentence(action == .previousSentence ? -1 : 1).map({ max(0, $0.start + englishOffset) }) else { return false }
            return duration <= 0 || target < duration
        default: return playbackReady
        }
    }
    func perform(_ action: PlayerAction) {
        guard canPerform(action) else { return }
        OperationMetrics.shared.begin(action, model: self)
        defer { OperationMetrics.shared.end() }
        switch action {
        case .playPause:
            togglePlayback()
            chrome.showFeedback(paused ? "已暂停" : "继续播放", symbol: paused ? "pause.fill" : "play.fill")
        case .replaySentence:
            replaySentence()
            chrome.showFeedback("回放本句", symbol: "arrow.counterclockwise", detail: clock(position))
        case .resumeLearning:
            resumeLearning()
            chrome.showFeedback("继续学习", symbol: "play.fill")
        case .backward, .forward:
            let previous = position
            seek(position + (action == .forward ? 5 : -5))
            let delta = ((position - previous) * 10).rounded() / 10
            chrome.showFeedback("\(delta > 0 ? "+" : "")\(delta.formatted())s", symbol: action == .forward ? "goforward.5" : "gobackward.5", detail: clock(position))
        case .previousSentence, .nextSentence:
            navigateAdjacentSentence(action == .previousSentence ? -1 : 1)
            chrome.showFeedback(action == .previousSentence ? "上一句" : "下一句", symbol: action == .previousSentence ? "backward.end.fill" : "forward.end.fill", detail: clock(position))
        case .volumeDown: setVolume(volume - 5)
        case .volumeUp: setVolume(volume + 5)
        case .slower: setSpeed(Self.speedSteps.last { $0 < speed } ?? Self.speedSteps[0])
        case .faster: setSpeed(Self.speedSteps.first { $0 > speed } ?? Self.speedSteps.last!)
        case .previousVideo, .nextVideo:
            if let next = queueState.adjacent(action == .previousVideo ? -1 : 1) {
                playQueueItem(next)
                chrome.showFeedback(action == .previousVideo ? "上一部视频" : "下一部视频", symbol: action == .previousVideo ? "backward.fill" : "forward.fill", detail: media?.title)
            }
        case .toggleSidebar: setSidebarCollapsed(false); sidebarTab = sidebarTab.next
        case .toggleSidebarVisibility: setSidebarCollapsed(!preferences.sidebarCollapsed)
        case .toggleSentenceLoop:
            toggleSentenceLoop()
            chrome.showFeedback(sentenceLoop == nil ? "已关闭单句循环" : "单句循环", symbol: "repeat.1", detail: sentenceLoop.map { "\(clock($0.start)) – \(clock($0.end))" })
        case .cycleSubtitleDisplay:
            setSubtitleDisplay(preferences.subtitleDisplay.next)
            chrome.showFeedback(preferences.subtitleDisplay.title, symbol: "captions.bubble", detail: "字幕显示")
        }
    }
    func acceptFiles(_ urls: [URL]) {
        let subtitles = urls.filter { ["srt", "ass", "ssa", "vtt"].contains($0.pathExtension.lowercased()) }
        let videos = urls.filter { !subtitles.contains($0) }
        if !videos.isEmpty { ingest(videos) }
        for subtitle in subtitles { importSubtitle(subtitle) }
    }
    func ingest(_ urls: [URL], adding: Bool = false) {
        guard interactionReady else { Task { await stateTask?.value; ingest(urls, adding: adding) }; return }
        let batch = queueState.append(urls.filter { $0.isFileURL })
        persistQueue()
        if !adding || media == nil, let first = batch.first { playQueueItem(first) }
    }
    func playQueueItem(_ id: String, restoring: Bool = false) {
        savePlayback()
        guard let start = queueState.items.firstIndex(where: { $0.id == id }) else { return }
        for index in start..<queueState.items.count {
            let item = queueState.items[index]
            let url = URL(fileURLWithPath: item.path)
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &directory), !directory.boolValue,
               FileManager.default.isReadableFile(atPath: item.path), (try? MediaIdentity(url: url)) != nil {
                queueState.currentID = item.id; queueState.mark(item.id, failure: nil)
                persistQueue(); loadMedia(url, restoring: restoring); return
            }
            queueState.mark(item.id, failure: "文件缺失或无法读取")
            queueMessage = "已跳过：\(item.name)（文件缺失或无法读取）"
        }
        stopMedia(); queueMessage = "没有可播放的后续文件，请重新添加或检查文件位置。"; persistQueue()
    }
    func failCurrent(_ error: String) {
        guard let id = queueState.currentID else { return }
        queueState.mark(id, failure: error)
        queueMessage = "已跳过无法播放的文件：\(URL(fileURLWithPath: id).lastPathComponent)"
        let next = queueState.adjacent(1), pausedRestore = restoring
        // Never overwrite a previously useful resume point with a failed load.
        awaitingLoad = true
        if let next { playQueueItem(next, restoring: pausedRestore) }
        else { stopMedia(); queueMessage = "没有可播放的后续文件。\(error)"; persistQueue() }
    }
    func removeQueueItem(_ id: String) {
        let current = id == queueState.currentID
        if current { savePlayback() }
        let next = queueState.remove(id)
        if current { stopMedia(); if let next { playQueueItem(next) } }
        persistQueue()
    }
    func clearQueue() {
        savePlayback(); stopMedia(); queueState = PlaybackQueue(); queueMessage = ""; persistQueue()
    }
    func moveQueueItem(_ id: String, before target: String?) { queueState.move(id, before: target); persistQueue() }
    func stopMedia() {
        chrome.resetFeedback(); cancelPendingSubtitleOffsets()
        openTask?.cancel(); searchTask?.cancel(); lookupTask?.cancel(); aligner.cancel()
        sessionID = UUID(); searchID = UUID(); lookupID = UUID(); player.stop()
        sentenceLoop = nil; practiceMessage = ""; transcript.reset(); seekRevision = 0
        endGate.begin(sessionID, purpose: .normal, playing: false)
        media = nil; position = 0; duration = 0; paused = true; awaitingLoad = false
        queueState.currentID = nil; cancelReplay(); seekTarget = nil
        english = []; chinese = []; activeEnglish = []; activeChinese = []; timings = []
        learning.reset(); currentWordID = nil; dictionaryEntry = nil; lastDictionaryKey = ""
        englishPath = nil; chinesePath = nil; englishDigest = ""; audioStreams = []; selectedAudio = -1
        englishSource = "未加载"; chineseSource = "未加载"; subtitleOptions = []
        subtitleStatus = "打开视频后自动发现字幕"; alignmentStatus = "导入英文字幕后可准备逐词高亮"
        isSearching = false; isDownloading = false; searchResults = []
    }
}
