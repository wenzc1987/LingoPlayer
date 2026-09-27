import SwiftUI
import UniformTypeIdentifiers
import PlayerCore

enum Palette {
    static let background = Color(red: 0.055, green: 0.065, blue: 0.078)
    static let panel = Color(red: 0.085, green: 0.098, blue: 0.112)
    static let accent = Color(red: 0.73, green: 0.89, blue: 0.43)
    static let muted = Color(red: 0.53, green: 0.58, blue: 0.63)
    static let border = Color.white.opacity(0.075)
}

struct PlayerRootView: View {
    @ObservedObject var model: AppModel
    @State private var dropTargeted = false
    var body: some View {
        HStack(spacing: 0) {
            PlayerStage(model: model)
            Rectangle().fill(Palette.border).frame(width: model.preferences.sidebarCollapsed ? 0 : 1)
            SidebarPanel(model: model).frame(width: 332)
                .frame(width: model.preferences.sidebarCollapsed ? 0 : 332, alignment: .leading).clipped()
                .allowsHitTesting(!model.preferences.sidebarCollapsed).accessibilityHidden(model.preferences.sidebarCollapsed)
        }
        .ignoresSafeArea()
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 12).stroke(Palette.accent, lineWidth: 3).padding(8).allowsHitTesting(false) } }
        .tint(Palette.accent)
        .overlay(alignment: .topLeading) { FeedbackProbe(revision: OperationMetrics.shared.revision).frame(width: 1, height: 1).allowsHitTesting(false) }
        .frame(minWidth: 960, minHeight: 610)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            FileDropReader.read(providers) { model.acceptFiles($0) }
            return true
        }
        .sheet(isPresented: $model.showAlignmentDetails) {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("逐词任务诊断").font(.headline); Spacer(); Button("关闭") { model.showAlignmentDetails = false } }
                Text("记录仅保存在本机；最多 20 次、共 20 MB，不保留提取音频。").font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(model.alignmentDetails).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    if let url = model.alignmentTaskStatus.diagnostic { Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                    Spacer(); Button("重新检查并重试") { model.showAlignmentDetails = false; model.retryAlignment() }
                }
            }.padding(24).frame(width: 720, height: 480)
        }
        .sheet(isPresented: $model.showSettings) { SettingsPanel(model: model) }
        .sheet(isPresented: $model.showSubtitleSearch) { SubtitleSearchPanel(model: model) }
        .alert("LingoPlayer", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("知道了") { model.alert = nil }
        } message: { Text(model.alert ?? "") }
    }
}

private struct SubtitleHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PlayerStage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var chrome: PlayerChrome
    @ObservedObject var viewing: ViewingPreferencesStore
    @State private var subtitleHeight: CGFloat = 0
    init(model: AppModel) { self.model = model; chrome = model.chrome; viewing = model.viewing }
    var body: some View {
        GeometryReader { geometry in
            let bottomInset = min(CGFloat(viewing.subtitles.bottomInset), max(8, geometry.size.height - subtitleHeight - 250))
            ZStack(alignment: .bottom) {
                VideoSurface(view: model.videoView)
                Color.clear.contentShape(Rectangle()).onTapGesture { chrome.toggle() }
                    .accessibilityLabel("视频区域，单击显示或隐藏操作面板")
                if model.media == nil { emptyVideo }
                SubtitleStrip(model: model)
                    .frame(maxWidth: geometry.size.width * 0.92)
                    .background(GeometryReader { proxy in Color.clear.preference(key: SubtitleHeightKey.self, value: proxy.size.height) })
                    .padding(.bottom, bottomInset)
                if chrome.visible {
                    if let title = model.media?.title {
                        Text("《\(title)》")
                            .font(.system(size: 16, weight: .medium)).foregroundStyle(.white.opacity(0.94))
                            .lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 90).padding(.top, 34).padding(.bottom, 22)
                            .frame(maxWidth: .infinity)
                            .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
                            .frame(maxHeight: .infinity, alignment: .top)
                            .allowsHitTesting(false).accessibilityIdentifier("playback-title")
                            .transition(.opacity)
                    }
                    PlaybackControls(model: model)
                    .frame(width: min(860, max(0, geometry.size.width - 32)))
                    // Keep native hover tracking out of the subtitle area below.
                    .onHover { chrome.hold(.pointer, active: $0) }
                    .padding(.bottom, model.media == nil ? 24 : bottomInset + max(76, subtitleHeight) + 18)
                    .transition(.opacity)
                }
                PlaybackFeedbackOverlay(chrome: chrome)
                    .padding(.top, 94).frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                if let notice = chrome.notice {
                    Text(notice).font(.system(size: 12)).foregroundStyle(.white)
                        .padding(12).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.bottom, bottomInset + max(76, subtitleHeight) + 148).allowsHitTesting(false)
                }
                Color.clear.frame(height: 28).contentShape(Rectangle())
                    .onHover { chrome.hold(.windowButtons, active: $0) }
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .animation(.easeOut(duration: 0.18), value: chrome.visible)
            .onPreferenceChange(SubtitleHeightKey.self) { subtitleHeight = $0 }
        }
    }
    private var emptyVideo: some View {
        VStack(spacing: 20) {
            BrandIcon().frame(width: 84, height: 84)
            Text("打开视频，开始学习").font(.system(size: 23, weight: .medium))
            Text("拖入本地视频 · 点击字幕单词学习").foregroundStyle(Palette.muted)
            Button { model.chooseVideo() } label: { Label("打开视频", systemImage: "folder").padding(8) }
                .buttonStyle(.borderedProminent).foregroundStyle(.black)
            if !model.hasRuntime { Button("播放库未就绪 · 打开设置") { model.showSettings = true } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.background)
    }
}

struct SubtitleStrip: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: SubtitlePresentation
    @ObservedObject var viewing: ViewingPreferencesStore
    init(model: AppModel) { self.model = model; presentation = model.subtitles; viewing = model.viewing }
    var body: some View {
        let _ = PerformanceCounters.shared.hit("subtitle_body")
        content.opacity(model.preferences.subtitleDisplay == .hidden ? 0 : 1)
            .allowsHitTesting(model.preferences.subtitleDisplay != .hidden)
            .accessibilityHidden(model.preferences.subtitleDisplay == .hidden)
    }
    private var content: some View {
        VStack(spacing: 8) {
            if !model.activeEnglish.isEmpty || !model.activeChinese.isEmpty {
                ForEach(model.activeEnglish) { cue in
                    WordWrap(spacing: 1, lineSpacing: 4) {
                        ForEach(cue.tokens) { token in
                            let spoken = model.currentWordID == "\(cue.id):\(token.id)"
                            let locked = presentation.lockedWordID == "\(cue.id):\(token.id)"
                            if token.isWord {
                                Button { model.lock(cue: cue, token: token) } label: {
                                    Text(token.text).font(.system(size: viewing.subtitles.englishSize, weight: spoken ? .semibold : .medium))
                                        .foregroundStyle(spoken ? .black : .white.opacity(0.93))
                                        .padding(.horizontal, 3).padding(.vertical, 3)
                                        .background(spoken ? Palette.accent : .clear, in: RoundedRectangle(cornerRadius: 5))
                                        .overlay { if locked { RoundedRectangle(cornerRadius: 5).stroke(Palette.accent.opacity(0.75), lineWidth: 1) } }
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).help("暂停并学习 \(token.text)").accessibilityIdentifier("subtitle-word-\(cue.id)-\(token.id)")
                            } else {
                                Text(token.text.replacingOccurrences(of: "\n", with: " ")).font(.system(size: max(14, viewing.subtitles.englishSize - 2))).foregroundStyle(.white.opacity(0.8)).padding(.vertical, 3)
                            }
                        }
                    }
                }
                if !model.bilingualText.isEmpty { Text(model.bilingualText).font(.system(size: viewing.subtitles.chineseSize)).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center).opacity(model.preferences.subtitleDisplay == .bilingual ? 1 : 0).accessibilityHidden(model.preferences.subtitleDisplay != .bilingual) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background {
            if !model.activeEnglish.isEmpty || !model.activeChinese.isEmpty {
                RoundedRectangle(cornerRadius: 10).fill(.black.opacity(viewing.subtitles.backgroundOpacity))
            }
        }
    }
}

struct WordWrap: Layout {
    var spacing: CGFloat = 3
    var lineSpacing: CGFloat = 5
    struct Cache {
        var sizes: [CGSize]
        var width: CGFloat?
        var spacing: CGFloat?
        var lineSpacing: CGFloat?
        var result: (CGSize, [CGPoint])?
    }
    func makeCache(subviews: Subviews) -> Cache { Cache(sizes: measure(subviews)) }
    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        let sizes = measure(subviews)
        if cache.sizes != sizes { cache = Cache(sizes: sizes) }
    }
    private func measure(_ subviews: Subviews) -> [CGSize] {
        PerformanceCounters.shared.hit("word_measurements", count: subviews.count)
        return subviews.map { $0.sizeThatFits(.unspecified) }
    }
    private func layout(width: CGFloat, cache: inout Cache) -> (CGSize, [CGPoint]) {
        if cache.width == width, cache.spacing == spacing, cache.lineSpacing == lineSpacing, let result = cache.result { return result }
        var rows: [[(Int, CGSize)]] = [[]], rowWidth: CGFloat = 0
        for (index, size) in cache.sizes.enumerated() {
            if rowWidth + size.width > width && !rows[rows.count - 1].isEmpty { rows.append([]); rowWidth = 0 }
            rows[rows.count - 1].append((index, size)); rowWidth += size.width + spacing
        }
        var points = [CGPoint](repeating: .zero, count: cache.sizes.count), y: CGFloat = 0
        for row in rows {
            let total = row.reduce(CGFloat(0)) { $0 + $1.1.width } + CGFloat(max(0, row.count - 1)) * spacing
            var x = max(0, (width - total) / 2)
            let height = row.map { $0.1.height }.max() ?? 0
            for (index, size) in row { points[index] = CGPoint(x: x, y: y); x += size.width + spacing }
            y += height + lineSpacing
        }
        let result = (CGSize(width: width, height: max(0, y - lineSpacing)), points)
        cache.width = width; cache.spacing = spacing; cache.lineSpacing = lineSpacing; cache.result = result
        return result
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize { layout(width: proposal.width ?? 600, cache: &cache).0 }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let result = layout(width: bounds.width, cache: &cache)
        for (index, view) in subviews.enumerated() { view.place(at: CGPoint(x: bounds.minX + result.1[index].x, y: bounds.minY + result.1[index].y), proposal: .unspecified) }
    }
}

struct PlaybackControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var playback: PlaybackPresentation
    init(model: AppModel) { self.model = model; playback = model.playback }
    @State private var seeking = false
    @State private var draft = 0.0
    var body: some View {
        let _ = PerformanceCounters.shared.hit("controls_body")
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text(clock(seeking ? draft : playback.position)).monospacedDigit().frame(minWidth: 45, alignment: .leading)
                Slider(value: Binding(get: { seeking ? draft : playback.position }, set: { draft = $0 }), in: 0...max(1, model.duration), onEditingChanged: { active in
                    model.chrome.hold(.scrubbing, active: active)
                    if active { model.cancelSentenceLoop(); draft = playback.position; seeking = true }
                    else { seeking = false; model.seek(draft) }
                }).disabled(!model.canPlay).accessibilityLabel("播放进度")
                Text(clock(model.duration)).monospacedDigit().frame(minWidth: 45, alignment: .trailing)
            }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 8) {
                Button { model.chooseVideo() } label: { icon("folder") }.help(model.media?.title ?? "打开视频")
                Spacer(minLength: 0)
                action(.previousSentence, "backward.end")
                action(.backward, "gobackward.5")
                Button { model.perform(.playPause) } label: {
                    Image(systemName: model.paused ? "play.fill" : "pause.fill").font(.system(size: 18))
                        .foregroundStyle(.black).frame(width: 44, height: 36)
                        .background(Palette.accent, in: RoundedRectangle(cornerRadius: 10))
                }.disabled(!model.canPlay).help(model.help(.playPause)).accessibilityIdentifier("action-playPause")
                action(.forward, "goforward.5")
                action(.nextSentence, "forward.end")
                action(.toggleSentenceLoop, "repeat.1", active: model.sentenceLoop != nil)
                Spacer(minLength: 0)
                Button { model.playerPopover = .subtitles } label: { icon("captions.bubble") }
                    .help("字幕显示、导入、搜索与全文").accessibilityIdentifier("subtitle-menu")
                    .popover(isPresented: popover(.subtitles)) { SubtitleMenuPanel(model: model) }
                Button { model.playerPopover = .speed } label: { Text("\(model.speed.formatted())×").font(.system(size: 12)).frame(width: 32, height: 32) }
                    .help("播放速度").popover(isPresented: popover(.speed)) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("播放速度").font(.headline).padding(.bottom, 6)
                            ForEach(AppModel.speedSteps, id: \.self) { value in
                                Button { model.setSpeed(value); model.playerPopover = nil } label: {
                                    HStack { Text("\(value.formatted())×"); Spacer(); if model.speed == value { Image(systemName: "checkmark") } }.frame(width: 120)
                                }.buttonStyle(.borderless).padding(5)
                            }
                        }.padding(16)
                    }
                Button { model.playerPopover = .volume } label: {
                    VolumeSymbol(volume: playback.volume).font(.system(size: 16)).frame(width: 28, height: 32)
                }
                    .help("音量 \(Int(playback.volume.rounded()))%")
                    .accessibilityLabel("音量 \(Int(playback.volume.rounded()))%")
                    .accessibilityIdentifier("volume-control").popover(isPresented: popover(.volume)) {
                        VStack(spacing: 12) {
                            HStack {
                                VolumeSymbol(volume: playback.volume)
                                Text("音量 \(Int(playback.volume.rounded()))%").monospacedDigit()
                            }.font(.headline)
                            Slider(value: Binding(get: { model.volume }, set: { model.setVolume($0) }), in: 0...100).frame(width: 180)
                                .accessibilityLabel("音量").accessibilityIdentifier("volume-slider")
                        }.padding(20)
                    }
                Button { model.openSidebar(.queue) } label: { icon("list.bullet", active: !model.preferences.sidebarCollapsed && model.sidebarTab == .queue) }
                    .help("展开播放列表").accessibilityIdentifier("open-queue")
                Button { model.perform(.toggleSidebarVisibility) } label: { icon("sidebar.right", active: !model.preferences.sidebarCollapsed) }
                    .help(model.help(.toggleSidebarVisibility)).accessibilityIdentifier("toggle-sidebar")
                Button { model.showSubtitleControls = true } label: {
                    icon("slider.horizontal.3").overlay(alignment: .topTrailing) {
                        if model.alignmentTaskStatus.canRetry { Circle().fill(.orange).frame(width: 5, height: 5) }
                    }
                }.help("播放设置").accessibilityIdentifier("quick-settings")
                    .popover(isPresented: $model.showSubtitleControls) { SubtitleControls(model: model) }
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Palette.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.12), lineWidth: 1).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .overlay(alignment: .topLeading) { FeedbackProbe(revision: OperationMetrics.shared.revision).frame(width: 1, height: 1).allowsHitTesting(false) }
    }
    private func icon(_ name: String, active: Bool = false) -> some View {
        Image(systemName: name).font(.system(size: 16)).foregroundStyle(active ? Palette.accent : .white.opacity(0.9)).frame(width: 28, height: 32)
    }
    private func action(_ action: PlayerAction, _ symbol: String, active: Bool = false) -> some View {
        Button { model.perform(action) } label: { icon(symbol, active: active) }
            .disabled(!model.canPerform(action)).help(model.help(action)).accessibilityIdentifier("action-" + action.rawValue)
    }
    private func popover(_ value: PlayerPopover) -> Binding<Bool> {
        Binding(get: { model.playerPopover == value }, set: { if !$0 && model.playerPopover == value { model.playerPopover = nil } })
    }
}

struct SubtitleMenuPanel: View {
    @ObservedObject var model: AppModel
    private func close(_ action: () -> Void) { model.playerPopover = nil; action() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("字幕").font(.headline)
            Picker("显示", selection: Binding(get: { model.preferences.subtitleDisplay }, set: { model.setSubtitleDisplay($0) })) {
                ForEach(SubtitleDisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Button("字幕全文…") { close { model.openSidebar(.transcript) } }.accessibilityIdentifier("open-transcript")
            Button("学习侧栏…") { close { model.openSidebar(.learning) } }.accessibilityIdentifier("open-learning")
            Divider()
            Group {
                Button("导入双语字幕…") { close { model.chooseSubtitle() } }
                Button("导入英文字幕…") { close { model.chooseSubtitle(.english) } }
                Button("导入中文字幕…") { close { model.chooseSubtitle(.chinese) } }
                Button("搜索英文字幕…") { close { model.searchSubtitles(.english) } }
                Button("搜索中文字幕…") { close { model.searchSubtitles(.chinese) } }
            }.disabled(model.media == nil)
            if !model.subtitleOptions.isEmpty {
                Divider(); Text("同目录字幕").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.subtitleOptions) { option in
                            Button(option.title) { close { model.importSubtitle(option.url) } }.lineLimit(2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 130)
            }
        }.buttonStyle(.borderless).padding(20).frame(width: 300)
    }
}

struct LearningPanel: View {
    @ObservedObject var model: AppModel
    var detached: Bool
    @ObservedObject var presentation: LearningPresentation
    init(model: AppModel, detached: Bool) { self.model = model; self.detached = detached; presentation = model.learningPresentation }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("学习", systemImage: "sparkle").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(model.isFollowing ? "自动跟随" : "已锁定").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.accent).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Palette.accent.opacity(0.1), in: Capsule())
                if !detached {
                    Button { model.onDetach?() } label: { Image(systemName: "arrow.up.forward.square") }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted).help("移至独立学习窗口")
                }
                if !model.preferences.cardHidden {
                    Button { model.closeLearningCard() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted).help("关闭词卡 · 点击字幕单词可重新打开")
                        .accessibilityIdentifier("close-word-card")
                }
            }.padding(22)
            Rectangle().fill(Palette.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if model.preferences.cardHidden {
                        Text("词卡已关闭\n点击视频字幕中的单词，重新开始学习。")
                            .font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(7).padding(.top, 30)
                    } else if model.learningVisible, let selection = model.selected {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("当前单词").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                            Text(selection.token.text).font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(Palette.accent).textSelection(.enabled)
                            if let entry = model.dictionaryEntry {
                                if let lemma = entry.lemma, lemma != selection.token.normalized { Text("原形  \(lemma)").font(.system(size: 13)).foregroundStyle(.secondary) }
                                else if entry.word != selection.token.normalized { Text("原形候选  \(entry.word)").font(.system(size: 13)).foregroundStyle(.secondary) }
                                if !entry.phonetic.isEmpty { Text("/\(entry.phonetic)/").font(.system(size: 14)).foregroundStyle(Palette.muted).textSelection(.enabled) }
                            }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Text(model.dictionaryStatus).font(.system(size: 10)).foregroundStyle(Palette.muted)
                            if let entry = model.dictionaryEntry {
                                if !entry.translation.isEmpty { Text(entry.translation).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled) }
                                if !entry.definition.isEmpty { Text(entry.definition).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5).textSelection(.enabled) }
                            } else {
                                Text("当前台词仍可查阅和回放。").font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text("当前台词").font(.system(size: 10)); Spacer(); Text(clock(selection.playbackStart)).font(.system(size: 10)).monospacedDigit() }.foregroundStyle(Palette.muted)
                            Text(selection.cue.text).font(.system(size: 16, weight: .medium)).lineSpacing(6).textSelection(.enabled)
                            if !selection.chinese.isEmpty { Text(selection.chinese).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5).textSelection(.enabled) }
                            Button { model.perform(.replaySentence) } label: { Label("回放本句", systemImage: "arrow.counterclockwise").font(.system(size: 12)) }.buttonStyle(.borderless).help(model.help(.replaySentence))
                        }
                        .padding(17).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            Image(systemName: "text.magnifyingglass").font(.system(size: 34, weight: .light)).foregroundStyle(Palette.accent.opacity(0.7)).padding(.bottom, 4)
                            Text("从一句对白开始").font(.system(size: 21, weight: .medium))
                            Text("播放时跟随正在说的词。\n点击字幕中的单词，暂停并慢慢读。")
                                .font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(7)
                            if model.dictionaryEntry == nil { Text(model.dictionaryStatus).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                        }.padding(.top, 30)
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                if !model.preferences.cardHidden && model.learning.isLocked {
                    Button { model.perform(.resumeLearning) } label: {
                        Label("继续学习", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).foregroundStyle(.black).help(model.help(.resumeLearning))
                    Text(model.help(.resumeLearning) + " · 恢复自动跟随").font(.system(size: 10)).foregroundStyle(Palette.muted)
                } else {
                    Label("点击单词可暂停并锁定", systemImage: "hand.tap").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }.padding(22)
        }
        .background(Palette.panel).tint(Palette.accent)
    }
}

struct SubtitleControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var viewing: ViewingPreferencesStore
    @State private var page = 0
    init(model: AppModel) { self.model = model; viewing = model.viewing }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("播放设置").font(.headline)
            Picker("设置页", selection: $page) {
                Text("时间与播放").tag(0)
                Text("字幕外观").tag(1)
            }.pickerStyle(.segmented).accessibilityIdentifier("playback-settings-page")
            ScrollView {
                ZStack(alignment: .topLeading) {
                    timingControls.opacity(page == 0 ? 1 : 0)
                        .allowsHitTesting(page == 0).accessibilityHidden(page != 0)
                    SubtitleAppearanceControls(viewing: viewing).opacity(page == 1 ? 1 : 0)
                        .allowsHitTesting(page == 1).accessibilityHidden(page != 1)
                }
            }.frame(height: 440)
            HStack {
                Text("设置自动保存").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("高级设置…") { model.showSettings = true; model.showSubtitleControls = false }
            }
        }.padding(20).frame(width: 380)
    }
    private var timingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.subtitleOffsetStatus, systemImage: model.pendingSubtitleOffsets.isEmpty ? "checkmark.circle" : "clock")
                    .foregroundStyle(model.pendingSubtitleOffsets.isEmpty ? Palette.accent : .orange)
                    .accessibilityIdentifier("subtitle-offset-status")
                Spacer()
                Button("全部归零") { model.resetSubtitleOffsets() }
                    .disabled(model.media == nil || (model.englishOffset == 0 && model.chineseOffset == 0 && model.pendingSubtitleOffsets.isEmpty))
                    .accessibilityIdentifier("reset-subtitle-offsets")
            }.font(.system(size: 12))
            Toggle("联动调整中英文", isOn: Binding(get: { viewing.linkedSubtitleOffsets }, set: { viewing.setLinkedOffsets($0) }))
                .toggleStyle(.switch).controlSize(.small).accessibilityIdentifier("link-subtitle-offsets")
            ForEach(SubtitleLanguage.allCases, id: \.self) { language in
                VStack(alignment: .leading, spacing: 5) {
                    Stepper(value: Binding(get: { model.subtitleOffsetDraft(language) }, set: { model.scheduleSubtitleOffset($0, language: language) }), step: 0.1) {
                        Text("\(language.title)字幕 \(model.subtitleOffsetDraft(language), specifier: "%.1f") 秒").monospacedDigit()
                    }
                    .disabled(model.media == nil).accessibilityIdentifier("subtitle-offset-\(language.rawValue)")
                    Text(language == .english ? model.englishSource : model.chineseSource).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Text("每次 0.1 秒，停止调整 1 秒后生效。正数延后，负数提前；联动时两种字幕同步增减，保留原有时间差。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Stepper(value: Binding(get: { model.sentenceTailPadding }, set: { model.setSentenceTailPadding($0) }), in: 0...3, step: 0.1) {
                Text("句尾多播 \(model.sentenceTailPadding, specifier: "%.1f") 秒")
            }
            Text("回放和单句循环在句尾多播一小段，避免截断尾音；按视频记忆，不改变字幕偏移。")
                .font(.caption).foregroundStyle(.secondary)
            if !model.audioStreams.isEmpty {
                Picker("音轨", selection: Binding(get: { model.selectedAudio }, set: { model.selectAudio($0) })) {
                    ForEach(model.audioStreams) { stream in Text(stream.label).tag(stream.id) }
                }
            }
            Button("重新准备逐词高亮") { model.restartAlignment() }
                .accessibilityIdentifier("reprepare-alignment")
            Text(model.subtitleStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(model.practiceMessage.isEmpty ? model.alignmentStatus : model.practiceMessage)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                if model.alignmentTaskStatus.diagnostic != nil {
                    Button("查看详情") { model.showSubtitleControls = false; model.viewAlignmentDetails() }
                }
                if model.alignmentTaskStatus.canRetry { Button("重试") { model.retryAlignment() } }
            }
        }.padding(.vertical, 2)
    }
}

struct SubtitleSearchPanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("匹配字幕").font(.title2.bold()); Spacer(); Button("关闭") { model.showSubtitleSearch = false }.keyboardShortcut(.cancelAction) }
            HStack {
                TextField("片名", text: $model.searchText).textFieldStyle(.roundedBorder)
                Picker("语言", selection: $model.searchLanguage) { ForEach(SubtitleLanguage.allCases, id: \.self) { Text($0.title).tag($0) } }.frame(width: 130)
                Button("搜索") { model.searchSubtitles(model.searchLanguage) }.disabled(model.isSearching || model.isDownloading)
            }
            HStack {
                TextField("年份（可选）", text: $model.searchYear)
                TextField("季（可选）", text: $model.searchSeason)
                TextField("集（可选）", text: $model.searchEpisode)
            }.textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                if model.isSearching || model.isDownloading { ProgressView().controlSize(.small) }
                Text(model.searchMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            List(model.searchResults) { candidate in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(candidate.filename).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        Text(candidate.release).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack {
                            if candidate.hashMatched { Label("文件匹配", systemImage: "checkmark.seal.fill").foregroundStyle(Palette.accent) }
                            else { Text("片名候选 · 请检查时间") }
                            Text("\(candidate.downloads) 次下载")
                            if candidate.hearingImpaired { Text("含音效描述") }
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("使用") { model.downloadSubtitle(candidate) }.disabled(model.isDownloading)
                }.padding(.vertical, 7)
            }.listStyle(.inset).frame(minHeight: 260)
            HStack {
                Button("手动导入…") { model.chooseSubtitle(model.searchLanguage) }
                    .accessibilityIdentifier("search-manual-import")
                Spacer()
                Text("来源：OpenSubtitles").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(26).frame(width: 660, height: 530).tint(Palette.accent)
    }
}

struct RuntimeSettingsPanel: View {
    @ObservedObject var model: AppModel
    @State private var draft: RuntimeSettings
    @State private var apiKey = ""
    @State private var username = ""
    @State private var password = ""
    @State private var message = ""
    @State private var loggingIn = false
    @State private var loadingCredentials = true
    init(model: AppModel) { self.model = model; _draft = State(initialValue: model.settings) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("字幕服务与本地运行环境").font(.headline)
            Form {
                Section("在线字幕") {
                    SecureField("OpenSubtitles API Key", text: $apiKey)
                        .disabled(loadingCredentials)
                    Toggle("缺少字幕时自动搜索", isOn: $draft.autoSearch)
                    TextField("用户名（下载需要时填写）", text: $username)
                    SecureField("密码（仅用于本次登录）", text: $password)
                    HStack {
                        Button(loggingIn ? "正在登录…" : "登录并保存令牌") {
                            loggingIn = true; message = ""
                            Task {
                                do { try await model.login(apiKey: apiKey, username: username, password: password); password = ""; message = "登录成功，令牌已保存到钥匙串。" }
                                catch { message = error.localizedDescription }
                                loggingIn = false
                            }
                        }.disabled(loggingIn || apiKey.isEmpty || username.isEmpty || password.isEmpty)
                        Button("退出账号") { do { try SecretStore.write("", name: "token"); message = "已移除登录令牌。" } catch { message = error.localizedDescription } }
                    }
                    Text("搜索发送文件特征与片名，不上传视频。API Key 和登录令牌保存到 macOS 钥匙串。").font(.caption).foregroundStyle(.secondary)
                }
                Section("本地运行环境") {
                    pathField("播放库 libmpv", value: $draft.libmpv)
                    pathField("FFmpeg", value: $draft.ffmpeg)
                    pathField("FFprobe", value: $draft.ffprobe)
                    pathField("Python", value: $draft.python)
                    pathField("MFA", value: $draft.mfa)
                    pathField("ECDICT 词库", value: $draft.dictionary)
                    TextField("英文声学模型", text: $draft.acousticModel)
                        .accessibilityIdentifier("settings-acoustic-model")
                    TextField("发音词典", text: $draft.pronunciationDictionary)
                    Text("运行 scripts/setup-runtime.sh 可准备依赖。播放库变更需重启；词库与对齐设置立即生效。").font(.caption).foregroundStyle(.secondary)
                    Button("重新检测已安装依赖") { draft = RuntimeSettings.load(); message = "已重新检测，点击保存应用。" }
                }
            }.formStyle(.grouped)
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4) }
            HStack {
                Text("音频处理与词典查询均在本机完成").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("保存") {
                    do { try model.saveSettings(draft, apiKey: apiKey); model.showSettings = false }
                    catch { message = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(loadingCredentials)
            }
        }.padding(16).task {
            guard loadingCredentials else { return }
            let key = await Task.detached(priority: .userInitiated) { SecretStore.read("api-key") }.value
            guard !Task.isCancelled else { return }
            apiKey = key; loadingCredentials = false
        }
    }
    private func pathField(_ name: String, value: Binding<String>) -> some View {
        HStack {
            TextField(name, text: value)
            Button("选择") {
                model.filePanels.present { $0.message = "选择\(name)" } completion: { urls in
                    if let url = urls.first { value.wrappedValue = url.path }
                }
            }.accessibilityIdentifier("choose-runtime-" + name)
        }
    }
}

func clock(_ value: Double) -> String {
    let seconds = Int(max(0, value.isFinite ? value : 0))
    return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
}
