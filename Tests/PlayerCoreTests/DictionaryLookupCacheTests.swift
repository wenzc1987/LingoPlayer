import Testing
@testable import PlayerCore

struct DictionaryLookupCacheTests {
    @Test func distinguishesUnqueriedWordsFromCachedMisses() throws {
        var cache = DictionaryLookupCache()
        #expect(cache.value(for: "unknown") == nil)
        cache.insert(nil, for: "unknown")
        let hit = try #require(cache.value(for: "unknown"))
        #expect(hit.entry == nil)
        #expect(cache.count == 1)
    }

    @Test func retainsTheCompleteDictionaryEntry() throws {
        let entry = DictionaryEntry(word: "went", phonetic: "went", definition: "past of go", translation: "去", exchange: "0:go")
        var cache = DictionaryLookupCache()
        cache.insert(entry, for: "went")
        #expect(try #require(cache.value(for: "went")).entry == entry)
    }

    @Test func boundsResultsAndEvictsOldestInsertionsIncludingMisses() {
        var cache = DictionaryLookupCache(capacity: 2)
        cache.insert(nil, for: "missing")
        cache.insert(DictionaryEntry(word: "one"), for: "one")
        cache.insert(DictionaryEntry(word: "two"), for: "two")
        #expect(cache.value(for: "missing") == nil)
        #expect(cache.value(for: "one")?.entry?.word == "one")
        cache.insert(nil, for: "three")
        #expect(cache.value(for: "one") == nil)
        #expect(cache.value(for: "two")?.entry?.word == "two")
        #expect(cache.value(for: "three") != nil)
        #expect(cache.count == 2)
    }

    @Test func replacingAResultDoesNotConsumeAnotherSlot() {
        var cache = DictionaryLookupCache(capacity: 2)
        cache.insert(nil, for: "one")
        cache.insert(DictionaryEntry(word: "one"), for: "one")
        cache.insert(nil, for: "two")
        #expect(cache.count == 2)
        #expect(cache.value(for: "one")?.entry?.word == "one")
        #expect(cache.value(for: "two") != nil)
    }

    @Test func dictionaryReplacementClearsPositiveAndNegativeResults() {
        var cache = DictionaryLookupCache(capacity: 1)
        cache.insert(nil, for: "old")
        cache.insert(DictionaryEntry(word: "recent"), for: "recent")
        cache.removeAll()
        #expect(cache.count == 0)
        #expect(cache.value(for: "recent") == nil)
        cache.insert(nil, for: "new")
        #expect(cache.value(for: "new") != nil)
        #expect(cache.count == 1)
    }

    @Test func disabledCacheDoesNotAccumulateResults() {
        for capacity in [0, -1] {
            var cache = DictionaryLookupCache(capacity: capacity)
            cache.insert(nil, for: "missing")
            #expect(cache.count == 0 && cache.value(for: "missing") == nil)
        }
    }
}
