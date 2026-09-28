import Foundation
import Combine
import PlayerCore

@MainActor
final class TranscriptController: ObservableObject {
    @Published private(set) var document = TranscriptDocument()
    @Published private(set) var rows: [TranscriptRow] = []
    @Published private(set) var activeIDs = Set<String>()
    @Published private(set) var following = true
    @Published private(set) var isPreparing = false
    @Published private(set) var isSearching = false
    @Published private(set) var rowsVersion = 0
    @Published private(set) var scrollVersion = 0
    @Published var query = "" { didSet { if query != oldValue { searchChanged() } } }
    private(set) var scrollID: String?
    private(set) var rebuildCount = 0
    private var revision = UUID()
    private var searchRevision = UUID()
    private var preparation: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var position = 0.0
    private var lastAnchor: String?
    private var resetting = false
    private var isVisible = false

    func reset() {
        revision = UUID(); searchRevision = UUID(); preparation?.cancel(); searchTask?.cancel()
        resetting = true; query = ""; resetting = false
        document = TranscriptDocument(); rows = []; activeIDs = []; following = true
        isPreparing = false; isSearching = false; lastAnchor = nil; scrollID = nil; rowsVersion += 1
    }
    func rebuild(english: [SubtitleCue], chinese: [SubtitleCue], englishOffset: Double, chineseOffset: Double, resetBrowsing: Bool = false, plain: [SubtitleCue]? = nil) {
        if resetBrowsing { reset() }
        revision = UUID(); let token = revision
        preparation?.cancel(); searchTask?.cancel(); searchRevision = UUID()
        isPreparing = true; rebuildCount += 1
        preparation = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                if let plain { return TranscriptDocument(cues: plain, offset: englishOffset, secondary: chinese, secondaryOffset: chineseOffset) }
                return TranscriptDocument(english: english, chinese: chinese, englishOffset: englishOffset, chineseOffset: chineseOffset)
            }.value
            guard !Task.isCancelled, let self, self.revision == token else { return }
            self.document = result; self.isPreparing = false
            self.searchChanged(preserveFollowing: true)
            self.updatePosition(self.position, forceScroll: true)
        }
    }
    private func searchChanged(preserveFollowing: Bool = false) {
        guard !resetting else { return }
        if !preserveFollowing { following = false }
        searchTask?.cancel(); searchRevision = UUID(); let token = searchRevision
        let query = query, document = document
        if query.isEmpty {
            rows = document.rows; rowsVersion += 1; isSearching = false; return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { document.search(query) }.value
            guard !Task.isCancelled, let self, self.searchRevision == token else { return }
            self.rows = result; self.rowsVersion += 1; self.isSearching = false
        }
    }
    func userScrolled() { if following { following = false } }
    func returnToCurrent() {
        query = ""; following = true
        updatePosition(position, forceScroll: true)
    }
    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if visible { updatePosition(position, forceScroll: true) }
    }
    func updatePosition(_ time: Double, forceScroll: Bool = false) {
        position = time
        // Preserve the clock and reading position without notifying an offscreen table.
        guard isVisible || forceScroll else { return }
        let active = document.activeIDs(at: time)
        if activeIDs != active { activeIDs = active }
        let anchor = document.anchorID(at: time)
        if following && query.isEmpty && (forceScroll || lastAnchor != anchor), let anchor {
            scrollID = anchor; scrollVersion += 1
        }
        lastAnchor = anchor
    }
}
