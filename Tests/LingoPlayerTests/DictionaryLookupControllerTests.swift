import Foundation
import Testing
import PlayerCore
@testable import LingoPlayer

@MainActor struct DictionaryLookupControllerTests {
    private func selection(_ word: String, cueID: String = "cue") -> LearningSelection {
        let cue = SubtitleCue(id: cueID, start: 0, end: 1, text: word)
        return LearningSelection(cue: cue, token: cue.tokens[0], chinese: "", offset: 0)
    }

    private func waitForRequests(_ count: Int, from provider: DeferredDictionary) async throws {
        let deadline = Date().addingTimeInterval(2)
        while await provider.requestCount < count && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        try #require(await provider.requestCount == count)
    }

    @Test func hiddenAndEmptySelectionsDoNotInitializeTheDictionary() {
        var creations = 0
        let presentation = LearningPresentation()
        let controller = DictionaryLookupController(presentation: presentation) { _ in creations += 1; return DeferredDictionary() }
        controller.update(selection: selection("one"), visible: false, path: "dictionary")
        controller.update(selection: nil, visible: true, path: "dictionary")
        #expect(creations == 0 && !controller.isAvailable && !controller.hasSelection)
    }

    @Test func supersededSuccessAndFailureCannotReplaceTheCurrentWord() async throws {
        let provider = DeferredDictionary(), presentation = LearningPresentation()
        let controller = DictionaryLookupController(presentation: presentation) { _ in provider }
        controller.update(selection: selection("old"), visible: true, path: "dictionary")
        let oldest = controller.task
        try await waitForRequests(1, from: provider)
        controller.update(selection: selection("stale"), visible: true, path: "dictionary")
        let stale = controller.task
        try await waitForRequests(2, from: provider)
        controller.update(selection: selection("current"), visible: true, path: "dictionary")
        let current = controller.task
        try await waitForRequests(3, from: provider)
        await provider.complete(2, with: .success(DictionaryEntry(word: "current")))
        await current?.value
        let status = presentation.status
        await provider.complete(0, with: .success(DictionaryEntry(word: "old")))
        await provider.complete(1, with: .failure(LookupFailure.example))
        await oldest?.value; await stale?.value
        #expect(presentation.entry?.word == "current" && presentation.status == status)
        #expect(controller.cachedWordCount == 1)
    }

    @Test func hidingTheCardInvalidatesANonCooperativeLookup() async throws {
        let provider = DeferredDictionary(), presentation = LearningPresentation()
        let controller = DictionaryLookupController(presentation: presentation) { _ in provider }
        controller.update(selection: selection("one"), visible: true, path: "dictionary")
        let pending = controller.task
        try await waitForRequests(1, from: provider)
        controller.clearSelection()
        await provider.complete(0, with: .success(DictionaryEntry(word: "one")))
        await pending?.value
        #expect(presentation.entry == nil && !controller.hasSelection && controller.cachedWordCount == 0)
        #expect(presentation.status != "正在查询词典…")
    }

    @Test func repeatedWordsAndMissesArePresentedSynchronously() async throws {
        let provider = DeferredDictionary(), presentation = LearningPresentation()
        let controller = DictionaryLookupController(presentation: presentation) { _ in provider }
        controller.update(selection: selection("Known"), visible: true, path: "dictionary")
        try await waitForRequests(1, from: provider)
        await provider.complete(0, with: .success(DictionaryEntry(word: "known")))
        await controller.task?.value
        controller.update(selection: selection("missing"), visible: true, path: "dictionary")
        try await waitForRequests(2, from: provider)
        await provider.complete(1, with: .success(nil))
        await controller.task?.value
        let missingStatus = presentation.status
        controller.update(selection: selection("KNOWN", cueID: "other"), visible: true, path: "dictionary")
        #expect(presentation.entry?.word == "known" && controller.task == nil)
        controller.update(selection: selection("missing", cueID: "other"), visible: true, path: "dictionary")
        #expect(presentation.entry == nil && presentation.status == missingStatus && controller.task == nil)
        #expect(await provider.requestCount == 2)
    }

    @Test func changingTheDictionaryRejectsOldResultsAndClearsTheCache() async throws {
        let old = DeferredDictionary(), new = DeferredDictionary(), presentation = LearningPresentation()
        let controller = DictionaryLookupController(presentation: presentation) { $0 == "old" ? old : new }
        controller.update(selection: selection("one"), visible: true, path: "old")
        try await waitForRequests(1, from: old)
        await old.complete(0, with: .success(DictionaryEntry(word: "one", translation: "old")))
        await controller.task?.value
        controller.update(selection: selection("pending"), visible: true, path: "old")
        let pending = controller.task
        try await waitForRequests(2, from: old)
        controller.update(selection: selection("one"), visible: true, path: "new")
        #expect(controller.cachedWordCount == 0 && presentation.entry == nil)
        try await waitForRequests(1, from: new)
        await new.complete(0, with: .success(DictionaryEntry(word: "one", translation: "new")))
        await controller.task?.value
        await old.complete(1, with: .failure(LookupFailure.example))
        await pending?.value
        #expect(presentation.entry?.translation == "new" && controller.cachedWordCount == 1)
        controller.reset()
        #expect(!controller.isAvailable && !controller.hasSelection && controller.cachedWordCount == 0 && presentation.entry == nil)
    }

    @Test func lookupErrorsAreNotCachedAsMissingWords() async throws {
        let provider = DeferredDictionary(), presentation = LearningPresentation()
        let controller = DictionaryLookupController(presentation: presentation) { _ in provider }
        controller.update(selection: selection("one"), visible: true, path: "dictionary")
        try await waitForRequests(1, from: provider)
        await provider.complete(0, with: .failure(LookupFailure.example))
        await controller.task?.value
        #expect(controller.cachedWordCount == 0 && presentation.status == LookupFailure.example.localizedDescription)
        controller.clearSelection()
        controller.update(selection: selection("one"), visible: true, path: "dictionary")
        try await waitForRequests(2, from: provider)
        await provider.complete(1, with: .success(DictionaryEntry(word: "one")))
        await controller.task?.value
        #expect(presentation.entry?.word == "one")
    }

    @Test func badConfigurationIsAttemptedOnceUntilReset() {
        var creations = 0
        let presentation = LearningPresentation()
        let controller = DictionaryLookupController(presentation: presentation) { _ in creations += 1; throw LookupFailure.example }
        controller.update(selection: selection("one"), visible: true, path: "missing")
        controller.update(selection: selection("two"), visible: true, path: "missing")
        #expect(creations == 1 && !controller.isAvailable && presentation.status == LookupFailure.example.localizedDescription)
        controller.reset()
        controller.update(selection: selection("one"), visible: true, path: "missing")
        #expect(creations == 2)
    }
}

private enum LookupFailure: LocalizedError {
    case example
    var errorDescription: String? { "fixture database read failure" }
}

/// Deliberately ignores task cancellation so completion order is under test control.
private actor DeferredDictionary: LearningContentProvider {
    private(set) var requestCount = 0
    private var pending: [Int: CheckedContinuation<DictionaryEntry?, Error>] = [:]
    func lookup(_ word: String) async throws -> DictionaryEntry? {
        let index = requestCount; requestCount += 1
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func complete(_ index: Int, with result: Result<DictionaryEntry?, Error>) {
        pending.removeValue(forKey: index)?.resume(with: result)
    }
}
