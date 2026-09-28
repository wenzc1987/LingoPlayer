import SwiftUI
import UniformTypeIdentifiers
import PlayerCore

struct BrandIcon: View {
    private static let image: NSImage? = {
        let packaged = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("LingoPlayer_LingoPlayer.bundle")) }
        guard let url = (packaged ?? Bundle.module).url(forResource: "AppIcon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
    var body: some View {
        if let image = Self.image { Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit) }
    }
}

struct SidebarPanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("右侧面板", selection: $model.sidebarTab) {
                    ForEach(model.availableSidebarTabs, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().help(model.help(.toggleSidebar))
                Button { model.setSidebarCollapsed(true) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("收起侧栏").accessibilityIdentifier("collapse-sidebar")
            }.padding(16)
            ZStack {
                TranscriptPanel(model: model, transcript: model.transcript)
                    .opacity(model.sidebarTab == .transcript ? 1 : 0)
                    .allowsHitTesting(model.sidebarTab == .transcript).accessibilityHidden(model.sidebarTab != .transcript)
                if model.sidebarTab == .queue { QueuePanel(model: model) }
                else if model.sidebarTab == .learning && model.isLearningMode {
                    if model.isDetached {
                VStack(spacing: 18) {
                    Image(systemName: "macwindow.on.rectangle").font(.system(size: 32)).foregroundStyle(Palette.accent)
                    Text("学习区已在独立窗口中打开").foregroundStyle(.secondary)
                    Button("定位学习窗口") { model.onDetach?() }
                    Button("收回到侧栏") { model.onReattach?() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else { LearningPanel(model: model, detached: false) }
                }
            }
        }.background(Palette.panel)
    }
}

struct QueuePanel: View {
    @ObservedObject var model: AppModel
    @State private var dragging: String?
    private let queueType = UTType(exportedAs: "local.lingoplayer.queue-item")
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.queueState.items.count) 个视频").foregroundStyle(.secondary)
                Spacer()
                Button { model.chooseVideo(adding: true) } label: { Label("添加", systemImage: "plus") }
                Button("清空") { model.clearQueue() }.disabled(model.queueState.items.isEmpty)
            }.font(.system(size: 12)).buttonStyle(.borderless).padding(.horizontal, 18).padding(.bottom, 14)
            if model.queueState.items.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "list.bullet.rectangle").font(.system(size: 32)).foregroundStyle(Palette.accent)
                    Text("把下一段对白加入列表").font(.headline)
                    Text("可多选文件，或一次拖入多个视频。\n双击播放，拖动调整顺序。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(model.queueState.items) { item in
                            queueRow(item)
                                .onDrag {
                                    dragging = item.id
                                    let provider = NSItemProvider()
                                    provider.registerDataRepresentation(forTypeIdentifier: queueType.identifier, visibility: .ownProcess) { complete in
                                        complete(Data(item.id.utf8), nil); return nil
                                    }
                                    return provider
                                }
                                .onDrop(of: [queueType], isTargeted: nil) { _ in
                                    guard let dragging else { return false }
                                    model.moveQueueItem(dragging, before: item.id); self.dragging = nil; return true
                                }
                        }
                        Text("拖到这里移至末尾").font(.system(size: 10)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .onDrop(of: [queueType], isTargeted: nil) { _ in
                                guard let dragging else { return false }
                                model.moveQueueItem(dragging, before: nil); self.dragging = nil; return true
                            }
                    }.padding(.horizontal, 10)
                }
            }
            if !model.queueMessage.isEmpty {
                Text(model.queueMessage).font(.system(size: 11)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            Divider()
            HStack {
                Button { model.perform(.previousVideo) } label: { Image(systemName: "backward.end.fill") }
                    .disabled(!model.canPerform(.previousVideo)).help(model.help(.previousVideo))
                Button { model.perform(.nextVideo) } label: { Image(systemName: "forward.end.fill") }
                    .disabled(!model.canPerform(.nextVideo)).help(model.help(.nextVideo))
                Spacer()
                Toggle("自动连播", isOn: Binding(get: { model.preferences.autoplay }, set: {
                    var preferences = model.preferences; preferences.autoplay = $0; model.updatePreferences(preferences)
                })).toggleStyle(.switch).controlSize(.small)
            }.font(.system(size: 12)).buttonStyle(.borderless).padding(18)
        }
    }
    private func queueRow(_ item: QueueItem) -> some View {
        let current = model.queueState.currentID == item.id
        let record = model.progress[item.id]
        let position = current ? model.position : record?.position ?? 0
        let duration = current ? model.duration : record?.duration ?? 0
        return HStack(spacing: 10) {
            Image(systemName: item.failure != nil ? "exclamationmark.triangle" : current ? "play.fill" : "film")
                .font(.system(size: 12)).foregroundStyle(item.failure != nil ? .orange : current ? Palette.accent : Palette.muted)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 7) {
                Text(item.name).font(.system(size: 12, weight: current ? .semibold : .regular)).lineLimit(2)
                if let failure = item.failure { Text(failure).foregroundStyle(.orange).font(.system(size: 10)).lineLimit(2) }
                else if duration > 0 {
                    ProgressView(value: min(position / duration, 1)).tint(Palette.accent)
                    Text(record?.finished == true && !current ? "已看完 · " + clock(duration) : clock(position) + " / " + clock(duration))
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                } else { Text("未播放").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            Button { model.removeQueueItem(item.id) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                .buttonStyle(.borderless).foregroundStyle(Palette.muted).help("从列表移除，不删除文件")
        }
        .padding(12).background(current ? Palette.accent.opacity(0.085) : .white.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle()).onTapGesture(count: 2) { model.playQueueItem(item.id) }
        .contextMenu {
            Button("播放") { model.playQueueItem(item.id) }
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
            Button("移除") { model.removeQueueItem(item.id) }
        }
        .help(item.path + "\n双击播放 · 拖动排序")
    }
}

struct SettingsPanel: View {
    @ObservedObject var model: AppModel
    @State private var page: Int
    init(model: AppModel) { self.model = model; _page = State(initialValue: model.settingsPage) }
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                BrandIcon().frame(width: 32, height: 32)
                Text("设置").font(.title2.bold()); Spacer()
                Button("关闭") { model.showSettings = false }.keyboardShortcut(.cancelAction)
            }
            Picker("设置页面", selection: $page) {
                Text("字幕与环境").tag(0)
                Text("快捷键").tag(1)
                Text("截图").tag(2)
                Text("播放").tag(3)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 360).accessibilityIdentifier("settings-page")
            ZStack {
                RuntimeSettingsPanel(model: model)
                    .opacity(page == 0 ? 1 : 0)
                    .allowsHitTesting(page == 0).accessibilityHidden(page != 0).disabled(page != 0)
                ShortcutSettingsPanel(model: model)
                    .opacity(page == 1 ? 1 : 0)
                    .allowsHitTesting(page == 1).accessibilityHidden(page != 1)
                ScreenshotSettingsPanel(model: model)
                    .opacity(page == 2 ? 1 : 0)
                    .allowsHitTesting(page == 2).accessibilityHidden(page != 2).disabled(page != 2)
                PlaybackSettingsPanel(viewing: model.viewing)
                    .opacity(page == 3 ? 1 : 0)
                    .allowsHitTesting(page == 3).accessibilityHidden(page != 3).disabled(page != 3)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(22).frame(width: 690, height: 670).background(Palette.background)
            .onChange(of: page) { _, _ in if model.recordingAction != nil { model.recordingAction = nil } }
            .onDisappear { model.settingsPage = page; model.recordingAction = nil }
    }
}

struct ShortcutSettingsPanel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.preferences.conflictNotices.isEmpty {
                Text("已有绑定已保留，以下新动作需要设置快捷键：" + model.preferences.conflictNotices.compactMap { PlayerAction(rawValue: $0)?.title }.joined(separator: "、"))
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("点击组合键后按下新按键，Esc 取消。更改立即保存。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(PlayerAction.allCases) { action in
                        HStack {
                            Text(action.title).font(.system(size: 12)); Spacer()
                            Button {
                                model.recordingAction = action; model.shortcutMessage = "请按下新的组合键；Esc 取消。"
                            } label: {
                                Text(model.recordingAction == action ? "请按键…" : model.preferences.shortcut(for: action)?.label ?? "未绑定")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced)).frame(width: 115)
                                    .foregroundStyle(model.recordingAction == action ? Palette.accent : .primary)
                            }.accessibilityIdentifier("shortcut-binding-" + action.rawValue).help("为“\(action.title)”设置快捷键")
                            Button("清除") { model.bind(nil, to: action) }.disabled(model.preferences.shortcut(for: action) == nil)
                            Button("恢复") { model.bind(action.defaultShortcut, to: action) }
                        }.padding(.vertical, 7)
                        Divider().opacity(0.4)
                    }
                }
            }
            Text(model.shortcutMessage.isEmpty ? "仅在播放器与学习窗口生效；输入文字和打开弹窗时保留原生键盘行为。" : model.shortcutMessage)
                .font(.system(size: 12)).foregroundStyle(model.shortcutMessage.contains("冲突") || model.shortcutMessage.contains("保留") ? .orange : .secondary)
                .frame(minHeight: 34, alignment: .topLeading)
            HStack {
                if model.recordingAction != nil { Button("取消录入") { model.recordingAction = nil } }
                Spacer(); Button("全部恢复默认") { model.resetShortcuts() }
            }
        }.padding(18).onDisappear { model.recordingAction = nil }
    }
}

enum FileDropReader {
    static func read(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup(), lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }
}
