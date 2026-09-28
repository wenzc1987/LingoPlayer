/// Bounded, in-memory results for one dictionary instance. Keys are normalized
/// words; a stored miss is distinct from a word that has not been queried.
public struct DictionaryLookupCache {
    public struct Hit {
        public let entry: DictionaryEntry?
    }
    private let capacity: Int
    private var entries: [String: Hit] = [:]
    private var order: [String] = []
    private var nextEviction = 0

    public init(capacity: Int = 256) { self.capacity = max(0, capacity) }
    public var count: Int { entries.count }
    public func value(for word: String) -> Hit? { entries[word] }

    public mutating func insert(_ entry: DictionaryEntry?, for word: String) {
        guard capacity > 0 else { return }
        if entries[word] == nil {
            if order.count < capacity { order.append(word) }
            else {
                entries.removeValue(forKey: order[nextEviction])
                order[nextEviction] = word
                nextEviction = (nextEviction + 1) % capacity
            }
        }
        entries[word] = Hit(entry: entry)
    }

    public mutating func removeAll() {
        entries.removeAll(); order.removeAll(); nextEviction = 0
    }
}
