import AppKit
import SwiftUI
import PlayerCore

struct TranscriptPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var transcript: TranscriptController
    @ObservedObject var playback: MediaPresentation
    init(model: AppModel, transcript: TranscriptController) { self.model = model; self.transcript = transcript; playback = model.mediaPresentation }
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("搜索中英文字幕", text: $transcript.query).textFieldStyle(.plain)
                    .accessibilityIdentifier("transcript-search")
                if !transcript.query.isEmpty {
                    Button { transcript.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("清除搜索")
                }
            }.padding(10).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 16)
            HStack {
                Text(transcript.isPreparing ? "正在整理字幕…" : transcript.isSearching ? "正在搜索…" : transcript.query.isEmpty ? "\(transcript.rows.count) 条字幕" : "\(transcript.rows.count) 条匹配")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                if !transcript.following {
                    Button("回到当前句") { transcript.returnToCurrent() }.font(.system(size: 11)).buttonStyle(.borderless)
                } else { Text("跟随播放").font(.system(size: 10)).foregroundStyle(Palette.accent) }
            }.padding(.horizontal, 18)
            if transcript.rows.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.alignleft").font(.system(size: 30)).foregroundStyle(Palette.accent)
                    Text(transcript.isPreparing ? "正在准备全文" : transcript.query.isEmpty ? "导入字幕后可浏览全文" : "没有找到匹配字幕")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    if !transcript.query.isEmpty { Button("清除搜索") { transcript.query = "" } }
                    else if model.media != nil { Button("导入字幕…") { model.chooseSubtitle() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TranscriptList(transcript: transcript, visible: !model.preferences.sidebarCollapsed && model.sidebarTab == .transcript, loopID: model.sentenceLoop?.cueID, duration: model.duration, ready: model.playbackReady,
                    navigate: { model.navigateTranscript($0) }, loop: { if let cue = $0.english { model.startSentenceLoop(cue) } })
            }
            if let loop = model.sentenceLoop {
                HStack {
                    Label("循环 \(clock(loop.start)) – \(clock(loop.end))", systemImage: "repeat.1").font(.system(size: 11))
                    Spacer(); Button("退出") { model.perform(.toggleSentenceLoop) }.buttonStyle(.borderless)
                }.foregroundStyle(Palette.accent).padding(.horizontal, 18)
            }
            if !model.practiceMessage.isEmpty { Text(model.practiceMessage).font(.caption).foregroundStyle(.orange).padding(.horizontal, 18) }
            Text("点击时间定位 · 英文句子可循环\n中文按时间对应，可能与英文分句不同")
                .font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3).padding(.bottom, 15)
        }
    }
}

/// NSTableView reuses visible cells, so jumping across thousands of multiline
/// captions doesn't instantiate or relayout thousands of SwiftUI text views.
struct TranscriptList: NSViewRepresentable {
    @ObservedObject var transcript: TranscriptController
    let visible: Bool
    let loopID: String?
    let duration: Double
    let ready: Bool
    let navigate: (TranscriptRow) -> Void
    let loop: (TranscriptRow) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> TranscriptScrollView {
        let scroll = TranscriptScrollView()
        let table = TranscriptTableView(frame: NSRect(x: 0, y: 0, width: 332, height: 0))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("subtitle"))
        column.width = 332; column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        table.headerView = nil; table.intercellSpacing = NSSize(width: 0, height: 6)
        table.selectionHighlightStyle = .none; table.allowsEmptySelection = true
        table.backgroundColor = NSColor(srgbRed: 0.085, green: 0.098, blue: 0.112, alpha: 1)
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.setAccessibilityLabel("字幕全文")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let changed: () -> Void = { [weak transcript] in transcript?.userScrolled() }
        scroll.userScroll = changed; table.userScroll = changed
        context.coordinator.table = table
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { _ in
            MainActor.assumeIsolated { changed() }
        }
        return scroll
    }
    func updateNSView(_ scroll: TranscriptScrollView, context: Context) {
        context.coordinator.update(self)
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: TranscriptList
        weak var table: TranscriptTableView?
        var observer: NSObjectProtocol?
        private var rows: [TranscriptRow] = []
        private var indices: [String: Int] = [:]
        private var rowVersion = -1, scrollVersion = -1
        private var active = Set<String>(), loopID: String?
        private var heights: [String: CGFloat] = [:]
        private var width = CGFloat(0)
        private var ready = false, duration = 0.0
        private var heightTask: Task<Void, Never>?
        private var heightRevision = UUID()
        init(_ parent: TranscriptList) { self.parent = parent }
        deinit { heightTask?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
        func update(_ next: TranscriptList) {
            parent = next
            guard next.visible else { return }
            PerformanceCounters.shared.hit("transcript_native_updates")
            guard let table else { return }
            let t = next.transcript
            let resize = abs(table.bounds.width - width) > 1
            let reload = rowVersion != t.rowsVersion || resize
            let enabledChanged = ready != next.ready || duration != next.duration
            ready = next.ready; duration = next.duration
            if reload {
                rows = t.rows; indices = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
                rowVersion = t.rowsVersion; width = table.bounds.width; heights = [:]
                prepareHeights()
            }
            let styleChanged = active != t.activeIDs || loopID != next.loopID
            let changedIDs = styleChanged ? active.symmetricDifference(t.activeIDs).union([loopID, next.loopID].compactMap { $0.map { "en:" + $0 } }) : []
            active = t.activeIDs; loopID = next.loopID
            if reload || enabledChanged { table.reloadData() }
            else if styleChanged {
                let changed = IndexSet(changedIDs.compactMap { indices[$0] })
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
            }
            if scrollVersion != t.scrollVersion || reload && t.following {
                scrollVersion = t.scrollVersion
                if t.following, let id = t.scrollID, let index = indices[id] { table.scrollRowToVisible(index) }
            }
        }
        private func prepareHeights() {
            PerformanceCounters.shared.hit("transcript_height_batches")
            heightTask?.cancel(); heightRevision = UUID(); let revision = heightRevision
            let rows = rows, width = max(180, width)
            heightTask = Task { [weak self] in
                let calculated = await Task.detached(priority: .userInitiated) {
                    Dictionary(uniqueKeysWithValues: rows.map { ($0.id, TranscriptCell.height($0, width: width)) })
                }.value
                guard !Task.isCancelled, let self, heightRevision == revision, let table else { return }
                let clip = table.enclosingScrollView?.contentView
                let origin = clip?.bounds.origin ?? .zero
                let top = max(0, table.row(at: origin))
                let offset = top < rows.count ? origin.y - table.rect(ofRow: top).minY : 0
                heights = calculated
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
                if parent.transcript.following, let id = parent.transcript.scrollID, let index = indices[id] { table.scrollRowToVisible(index) }
                else if top < rows.count, let clip {
                    clip.scroll(to: CGPoint(x: origin.x, y: max(0, table.rect(ofRow: top).minY + offset)))
                    table.enclosingScrollView?.reflectScrolledClipView(clip)
                }
            }
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 80 }
            let item = rows[row]
            if let cached = heights[item.id] { return cached }
            return 100 // Temporary geometry while exact text metrics are prepared off-main.
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            let id = NSUserInterfaceItemIdentifier("caption-row")
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? TranscriptCell ?? TranscriptCell()
            cell.identifier = id
            let item = rows[row], canNavigate = ready && item.end > 0 && item.playbackStart < duration
            let canLoop = ready && item.english.flatMap { SentenceLoop(cue: $0, offset: item.start - $0.start, duration: duration) } != nil
            cell.configure(item, active: active.contains(item.id), looping: item.english?.id == loopID && loopID != nil,
                canNavigate: canNavigate, canLoop: canLoop,
                navigate: { [weak self] in self?.parent.navigate(item) }, loop: { [weak self] in self?.parent.loop(item) })
            return cell
        }
    }
}

final class TranscriptScrollView: NSScrollView {
    var userScroll: (() -> Void)?
    override func scrollWheel(with event: NSEvent) { userScroll?(); super.scrollWheel(with: event) }
}
final class TranscriptTableView: NSTableView {
    var userScroll: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if [49, 115, 116, 119, 121, 123, 124, 125, 126].contains(event.keyCode) { userScroll?() }
        super.keyDown(with: event)
    }
}

final class TranscriptCell: NSTableCellView {
    private let time = NSButton(), repeatButton = NSButton()
    private let english = NSTextField(wrappingLabelWithString: ""), chinese = NSTextField(wrappingLabelWithString: "")
    private var item: TranscriptRow?
    private var highlighted = false, looping = false
    private var navigateAction: (() -> Void)?, loopAction: (() -> Void)?
    private static let lime = NSColor(srgbRed: 0.73, green: 0.89, blue: 0.43, alpha: 1)
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        for button in [time, repeatButton] {
            button.isBordered = false; button.font = .systemFont(ofSize: 11); button.target = self
            addSubview(button)
        }
        time.alignment = .left; time.action = #selector(navigate)
        time.contentTintColor = Self.lime
        repeatButton.image = NSImage(systemSymbolName: "repeat.1", accessibilityDescription: "循环此句")
        repeatButton.action = #selector(startLoop); repeatButton.toolTip = "从句首开始循环，不改变锁定词卡"
        english.font = .systemFont(ofSize: 13, weight: .medium); english.textColor = NSColor.white.withAlphaComponent(0.92)
        chinese.font = .systemFont(ofSize: 12); chinese.textColor = .secondaryLabelColor
        for text in [english, chinese] { text.maximumNumberOfLines = 0; addSubview(text) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func navigate() { navigateAction?() }
    @objc private func startLoop() { loopAction?() }
    func configure(_ row: TranscriptRow, active: Bool, looping: Bool, canNavigate: Bool, canLoop: Bool, navigate: @escaping () -> Void, loop: @escaping () -> Void) {
        item = row; highlighted = active; self.looping = looping; navigateAction = navigate; loopAction = loop
        time.title = clock(row.playbackStart) + (row.english == nil ? " · 中文" : "")
        time.isEnabled = canNavigate; time.toolTip = "定位到这句，保留播放或暂停状态"
        repeatButton.isHidden = row.english == nil; repeatButton.isEnabled = canLoop
        repeatButton.contentTintColor = looping ? Self.lime : .secondaryLabelColor
        english.stringValue = row.english?.text ?? ""; chinese.stringValue = row.chineseText
        english.isHidden = row.english == nil; chinese.isHidden = row.chineseText.isEmpty
        needsLayout = true; needsDisplay = true
    }
    nonisolated static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).boundingRect(with: NSSize(width: max(100, width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height) + 3
    }
    nonisolated static func height(_ row: TranscriptRow, width: CGFloat) -> CGFloat {
        let en = textHeight(row.english?.text ?? "", font: .systemFont(ofSize: 13, weight: .medium), width: width - 44)
        let zh = textHeight(row.chineseText, font: .systemFont(ofSize: 12), width: width - 44)
        return 44 + en + zh + (en > 0 && zh > 0 ? 6 : 0)
    }
    override func layout() {
        super.layout()
        guard let item else { return }
        time.frame = NSRect(x: 18, y: 8, width: 150, height: 22)
        repeatButton.frame = NSRect(x: bounds.width - 45, y: 7, width: 26, height: 24)
        let width = max(100, bounds.width - 44)
        let en = Self.textHeight(item.english?.text ?? "", font: english.font!, width: width)
        english.frame = NSRect(x: 18, y: 34, width: width, height: en)
        let y = en > 0 ? 34 + en + 6 : 34
        chinese.frame = NSRect(x: 18, y: y, width: width, height: Self.textHeight(item.chineseText, font: chinese.font!, width: width))
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: 8, yRadius: 8)
        (highlighted ? Self.lime.withAlphaComponent(0.10) : NSColor.white.withAlphaComponent(0.025)).setFill(); path.fill()
        if looping { Self.lime.withAlphaComponent(0.5).setStroke(); path.lineWidth = 1; path.stroke() }
        super.draw(dirtyRect)
    }
}
