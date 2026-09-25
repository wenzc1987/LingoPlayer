import SwiftUI
import UniformTypeIdentifiers
import PlayerCore

private enum Palette {
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
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.border).frame(height: 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZStack {
                        VideoSurface(view: model.videoView)
                        if model.media == nil { emptyVideo }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 16).stroke(Palette.accent, lineWidth: 3).padding(12) } }
                    SubtitleStrip(model: model)
                    PlaybackControls(model: model)
                }
                if !model.isDetached {
                    Rectangle().fill(Palette.border).frame(width: 1)
                    LearningPanel(model: model, detached: false).frame(width: 332)
                }
            }
            footer
        }
        .background(Palette.background)
        .tint(Palette.accent)
        .frame(minWidth: 960, minHeight: 610)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { model.acceptDrop(url) } }
            }
            return true
        }
        .sheet(isPresented: $model.showSettings) { SettingsPanel(model: model) }
        .sheet(isPresented: $model.showSubtitleSearch) { SubtitleSearchPanel(model: model) }
        .alert("LingoPlayer", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("知道了") { model.alert = nil }
        } message: { Text(model.alert ?? "") }
    }
    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "play.square.stack.fill").font(.system(size: 24)).foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("LingoPlayer").font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(model.media?.title ?? "视频 · 英语学习").font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 10)
            Button { model.chooseVideo() } label: { Label("打开视频", systemImage: "folder") }
            Menu {
                Button("导入双语字幕…") { model.chooseSubtitle() }
                Button("导入英文字幕…") { model.chooseSubtitle(.english) }
                Button("导入中文字幕…") { model.chooseSubtitle(.chinese) }
                Divider()
                Button("搜索英文字幕…") { model.searchSubtitles(.english) }
                Button("搜索中文字幕…") { model.searchSubtitles(.chinese) }
                if !model.subtitleOptions.isEmpty {
                    Divider()
                    ForEach(model.subtitleOptions) { option in
                        Button(option.title) { model.importSubtitle(option.url) }
                    }
                }
            } label: { Label("字幕", systemImage: "captions.bubble") }
            .disabled(model.media == nil)
            Button { model.showSubtitleControls.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .help("调整字幕时间与音轨")
                .popover(isPresented: $model.showSubtitleControls) { SubtitleControls(model: model) }
            if model.isDetached {
                Button { model.onDetach?() } label: { Label("学习窗口", systemImage: "rectangle.on.rectangle") }
            }
            Button { model.showSettings = true } label: { Image(systemName: "gearshape") }.help("设置与运行环境")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 18)
    }
    private var emptyVideo: some View {
        VStack(spacing: 22) {
            Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(Palette.accent.opacity(0.85))
            VStack(spacing: 10) {
                Text("让每一段对白，都成为一次学习").font(.system(size: 23, weight: .medium))
                Text("拖入本地视频，或选择文件开始播放").foregroundStyle(Palette.muted)
            }
            Button { model.chooseVideo() } label: { Label("选择视频", systemImage: "plus").padding(.horizontal, 16).padding(.vertical, 7) }
                .buttonStyle(.borderedProminent).foregroundStyle(.black)
            HStack(spacing: 22) {
                Label("双语字幕", systemImage: "captions.bubble")
                Label("逐词高亮", systemImage: "text.cursor")
                Label("点词学习", systemImage: "hand.tap")
            }.font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 14)
            if !model.hasRuntime {
                Button("播放库尚未就绪 · 打开设置") { model.showSettings = true }
                    .buttonStyle(.plain).font(.footnote).foregroundStyle(.orange)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.background)
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(model.hasRuntime ? Palette.accent : .orange).frame(width: 5, height: 5)
            Text(model.alignmentStatus).lineLimit(1).help(model.alignmentStatus)
            Spacer(minLength: 12)
            Text("音频仅在本机处理").foregroundStyle(Palette.muted)
        }
        .font(.system(size: 10)).foregroundStyle(Palette.muted)
        .padding(.horizontal, 22).padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
    }
}

struct SubtitleStrip: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 8) {
            if model.activeEnglish.isEmpty && model.activeChinese.isEmpty {
                Text(model.media == nil ? "英文字幕中的单词可以直接点击" : model.english.isEmpty ? "导入英文字幕，开启点词学习" : "等待下一句对白…")
                    .font(.system(size: 13)).foregroundStyle(Palette.muted)
            } else {
                ForEach(model.activeEnglish) { cue in
                    WordWrap(spacing: 1, lineSpacing: 4) {
                        ForEach(cue.tokens) { token in
                            let spoken = model.currentWordID == "\(cue.id):\(token.id)"
                            let locked = model.learning.locked?.cue.id == cue.id && model.learning.locked?.token.id == token.id
                            if token.isWord {
                                Button { model.lock(cue: cue, token: token) } label: {
                                    Text(token.text).font(.system(size: 21, weight: spoken ? .semibold : .medium))
                                        .foregroundStyle(spoken ? .black : .white.opacity(0.93))
                                        .padding(.horizontal, 3).padding(.vertical, 3)
                                        .background(spoken ? Palette.accent : .clear, in: RoundedRectangle(cornerRadius: 5))
                                        .overlay { if locked { RoundedRectangle(cornerRadius: 5).stroke(Palette.accent.opacity(0.75), lineWidth: 1) } }
                                }.buttonStyle(.plain).help("暂停并学习 \(token.text)")
                            } else {
                                Text(token.text.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 21)).foregroundStyle(.white.opacity(0.8)).padding(.vertical, 3)
                            }
                        }
                    }
                }
                if !model.bilingualText.isEmpty { Text(model.bilingualText).font(.system(size: 14)).foregroundStyle(Palette.muted).multilineTextAlignment(.center) }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 102)
        .padding(.horizontal, 28).padding(.vertical, 10)
        .background(Palette.background)
    }
}

struct WordWrap: Layout {
    var spacing: CGFloat = 3
    var lineSpacing: CGFloat = 5
    private func layout(_ subviews: Subviews, width: CGFloat) -> (CGSize, [CGPoint]) {
        var rows: [[(Int, CGSize)]] = [[]], rowWidth: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width > width && !rows[rows.count - 1].isEmpty { rows.append([]); rowWidth = 0 }
            rows[rows.count - 1].append((index, size)); rowWidth += size.width + spacing
        }
        var points = [CGPoint](repeating: .zero, count: subviews.count), y: CGFloat = 0
        for row in rows {
            let total = row.reduce(CGFloat(0)) { $0 + $1.1.width } + CGFloat(max(0, row.count - 1)) * spacing
            var x = max(0, (width - total) / 2)
            let height = row.map { $0.1.height }.max() ?? 0
            for (index, size) in row { points[index] = CGPoint(x: x, y: y); x += size.width + spacing }
            y += height + lineSpacing
        }
        return (CGSize(width: width, height: max(0, y - lineSpacing)), points)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { layout(subviews, width: proposal.width ?? 600).0 }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews, width: bounds.width)
        for (index, view) in subviews.enumerated() { view.place(at: CGPoint(x: bounds.minX + result.1[index].x, y: bounds.minY + result.1[index].y), proposal: .unspecified) }
    }
}

struct PlaybackControls: View {
    @ObservedObject var model: AppModel
    @State private var seeking = false
    @State private var draft = 0.0
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Text(clock(seeking ? draft : model.position)).monospacedDigit().frame(width: 52, alignment: .leading)
                Slider(value: Binding(get: { seeking ? draft : model.position }, set: { draft = $0 }), in: 0...max(1, model.duration), onEditingChanged: { active in
                    if active { draft = model.position; seeking = true }
                    else { seeking = false; model.seek(draft) }
                }).disabled(!model.canPlay)
                Text(clock(model.duration)).monospacedDigit().frame(width: 52, alignment: .trailing)
            }.font(.system(size: 11)).foregroundStyle(Palette.muted)
            HStack(spacing: 22) {
                Button { model.seek(model.position - 5) } label: { Image(systemName: "gobackward.5").font(.system(size: 20)) }.help("后退 5 秒")
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.paused ? "play.fill" : "pause.fill").font(.system(size: 18)).foregroundStyle(.black)
                        .frame(width: 44, height: 38).background(Palette.accent, in: RoundedRectangle(cornerRadius: 12))
                }.help("播放 / 暂停 · ⌘P")
                Button { model.seek(model.position + 5) } label: { Image(systemName: "goforward.5").font(.system(size: 20)) }.help("前进 5 秒")
                Spacer()
                Menu {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2.0], id: \.self) { value in Button("\(value.formatted())×") { model.setSpeed(value) } }
                } label: { Text("\(model.speed.formatted())×").monospacedDigit().frame(width: 36) }
                Image(systemName: "speaker.wave.2").foregroundStyle(Palette.muted)
                Slider(value: Binding(get: { model.volume }, set: { model.setVolume($0) }), in: 0...100).frame(width: 80)
            }.buttonStyle(.plain).disabled(!model.canPlay)
        }.padding(.horizontal, 28).padding(.bottom, 22).padding(.top, 8)
    }
}

struct LearningPanel: View {
    @ObservedObject var model: AppModel
    var detached: Bool
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
            }.padding(22)
            Rectangle().fill(Palette.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if let selection = model.selected {
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
                            Button { model.replaySentence() } label: { Label("回放本句", systemImage: "arrow.counterclockwise").font(.system(size: 12)) }.buttonStyle(.borderless)
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
                if model.learning.isLocked {
                    Button { model.resumeLearning() } label: {
                        Label("继续学习", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).foregroundStyle(.black)
                    Text("恢复播放，并跟随当前单词").font(.system(size: 10)).foregroundStyle(Palette.muted)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("字幕与音轨").font(.headline)
            ForEach(SubtitleLanguage.allCases, id: \.self) { language in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(language.title)
                        Spacer()
                        TextField("偏移", value: Binding(get: { language == .english ? model.englishOffset : model.chineseOffset }, set: { model.setOffset($0, language: language) }), format: .number.precision(.fractionLength(2)))
                            .frame(width: 72).textFieldStyle(.roundedBorder)
                        Text("秒").foregroundStyle(.secondary)
                    }
                    Text(language == .english ? model.englishSource : model.chineseSource).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Text("正数延后显示，负数提前显示。调整英文时间后会重新准备逐词高亮。").font(.caption).foregroundStyle(.secondary)
            if !model.audioStreams.isEmpty {
                Picker("音轨", selection: Binding(get: { model.selectedAudio }, set: { model.selectAudio($0) })) {
                    ForEach(model.audioStreams) { stream in Text(stream.label).tag(stream.id) }
                }
            }
            Text(model.subtitleStatus).font(.caption).foregroundStyle(.secondary)
            Button("重新准备逐词高亮") { model.setOffset(model.englishOffset, language: .english) }
        }.padding(22).frame(width: 340)
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
                Button("手动导入…") { model.showSubtitleSearch = false; model.chooseSubtitle(model.searchLanguage) }
                Spacer()
                Text("来源：OpenSubtitles").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(26).frame(width: 660, height: 530).tint(Palette.accent)
    }
}

struct SettingsPanel: View {
    @ObservedObject var model: AppModel
    @State private var draft: RuntimeSettings
    @State private var apiKey = ""
    @State private var username = ""
    @State private var password = ""
    @State private var message = ""
    @State private var loggingIn = false
    init(model: AppModel) { self.model = model; _draft = State(initialValue: model.settings) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("设置").font(.title2.bold()); Spacer(); Button("取消") { model.showSettings = false }.keyboardShortcut(.cancelAction) }
            Form {
                Section("在线字幕") {
                    SecureField("OpenSubtitles API Key", text: $apiKey)
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
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 660, height: 720).onAppear { apiKey = SecretStore.read("api-key") }
    }
    private func pathField(_ name: String, value: Binding<String>) -> some View {
        HStack {
            TextField(name, text: value)
            Button("选择") {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
                if panel.runModal() == .OK, let url = panel.url { value.wrappedValue = url.path }
            }
        }
    }
}

private func clock(_ value: Double) -> String {
    let seconds = Int(max(0, value.isFinite ? value : 0))
    return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
}
