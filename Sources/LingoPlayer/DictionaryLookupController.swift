import Foundation
import PlayerCore

/// Owns dictionary configuration, in-flight requests and their bounded cache.
/// Asynchronous responses must match the active request before updating presentation.
@MainActor final class DictionaryLookupController {
    private struct SelectionKey: Equatable {
        let cueID: String
        let tokenID: Int
        let word: String
    }
    private let presentation: LearningPresentation
    private let makeProvider: (String) throws -> any LearningContentProvider
    private var configuredPath: String?
    private var provider: (any LearningContentProvider)?
    private var cache = DictionaryLookupCache()
    private var selectionKey: SelectionKey?
    private var generation = UUID()
    private(set) var task: Task<Void, Never>?
    var isAvailable: Bool { provider != nil }
    var hasSelection: Bool { selectionKey != nil }
    var cachedWordCount: Int { cache.count }
    private static let readyStatus = ""

    init(presentation: LearningPresentation, makeProvider: @escaping (String) throws -> any LearningContentProvider = { try ECDictionary(path: $0) }) {
        self.presentation = presentation; self.makeProvider = makeProvider
    }
    deinit { task?.cancel() }

    func update(selection: LearningSelection?, visible: Bool, path: String) {
        if let configuredPath, configuredPath != path { reset() }
        guard visible, let selection else { clearSelection(); return }
        if configuredPath == nil {
            configuredPath = path
            do { provider = try makeProvider(path); setStatus(Self.readyStatus) }
            catch { setStatus(error.localizedDescription) }
        }
        let key = SelectionKey(cueID: selection.cue.id, tokenID: selection.token.id, word: selection.token.text)
        guard key != selectionKey else { return }
        let word = selection.token.normalized
        cancelRequest(); selectionKey = key
        guard let provider else { setEntry(nil); return }
        if let cached = cache.value(for: word) {
            PerformanceCounters.shared.hit("dictionary_cache_hits")
            present(cached.entry)
            return
        }
        setEntry(nil); setStatus("正在查询词典…")
        let token = generation
        task = Task { [weak self] in
            do {
                PerformanceCounters.shared.hit("dictionary_queries")
                let entry = try await provider.lookup(word)
                guard !Task.isCancelled, let self, generation == token else { return }
                cache.insert(entry, for: word); present(entry); task = nil
            } catch {
                guard !Task.isCancelled, let self, generation == token else { return }
                setStatus(error.localizedDescription); task = nil
            }
        }
    }

    /// Hide or deselect a word without discarding reusable dictionary results.
    func clearSelection() {
        guard hasSelection || task != nil else { return }
        cancelRequest(); selectionKey = nil; setEntry(nil)
        if isAvailable { setStatus(Self.readyStatus) }
    }
    /// A dictionary change or leaving learning mode invalidates every result.
    func reset() {
        clearSelection(); provider = nil; configuredPath = nil; cache.removeAll()
        setStatus(Self.readyStatus)
    }
    private func cancelRequest() { generation = UUID(); task?.cancel(); task = nil }
    private func present(_ entry: DictionaryEntry?) {
        setEntry(entry)
        setStatus(entry == nil ? "词库暂无该词 · 可回放当前台词" : Self.readyStatus)
    }
    private func setEntry(_ entry: DictionaryEntry?) {
        if presentation.entry != entry { presentation.entry = entry }
    }
    private func setStatus(_ status: String) {
        if presentation.status != status { presentation.status = status }
    }
}
