import Foundation
import Testing
@testable import PlayerCore

struct SeekPreviewTests {
    @Test func cacheIsLRUAndBoundedByBothCountAndDecodedBytes() {
        var cache = SeekPreviewCache<String>()
        for index in 0..<64 { cache.insert(String(index), bucket: index, bytes: 100) }
        #expect(cache.count == 64 && cache.bytes == 6400)
        #expect(cache.value(for: 0) == "0")
        cache.insert("64", bucket: 64, bytes: 100)
        #expect(cache.value(for: 1) == nil && cache.value(for: 0) == "0")
        cache.insert("large", bucket: 65, bytes: 16 * 1024 * 1024)
        #expect(cache.count == 1 && cache.bytes == 16 * 1024 * 1024)
        cache.insert("too large", bucket: 66, bytes: 16 * 1024 * 1024 + 1)
        #expect(cache.count == 1)
        cache.insert("small", bucket: 65, bytes: 20)
        #expect(cache.count == 1 && cache.bytes == 20)
        cache.removeAll(); #expect(cache.count == 0 && cache.bytes == 0)
    }
    @Test func bucketsAndDecodeCommandDoNotScaleWithMovieDuration() {
        #expect(SeekPreviewCache<Int>.bucket(1.99) == 0)
        #expect(SeekPreviewCache<Int>.bucket(2) == 1)
        #expect(SeekPreviewCache<Int>.bucket(36000) == 18000)
        #expect(SeekPreviewCache<Int>.bucket(-1) == 0)
        let args = SeekPreviewFrame.arguments(media: URL(fileURLWithPath: "/movie.mkv"), time: 36000)
        #expect(args.contains("nokey") && args.contains("-noaccurate_seek"))
        #expect(args.last == "pipe:1")
        #expect(args.filter { $0 == "-threads" }.count == 2)
    }
}
