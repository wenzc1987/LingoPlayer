import Foundation

/// A cost bounded LRU. Cost includes decoded pixels, not just compressed JPEGs.
public struct SeekPreviewCache<Value> {
    private var values: [Int: (value: Value, bytes: Int)] = [:]
    private var order: [Int] = []
    public private(set) var bytes = 0
    public var count: Int { values.count }
    public init() {}
    public static func bucket(_ time: Double) -> Int { Int(max(0, time.isFinite ? time : 0) / 2) }
    public mutating func value(for bucket: Int) -> Value? {
        guard let entry = values[bucket] else { return nil }
        order.removeAll { $0 == bucket }; order.append(bucket)
        return entry.value
    }
    public mutating func insert(_ value: Value, bucket: Int, bytes cost: Int) {
        guard cost > 0, cost <= 16 * 1024 * 1024 else { return }
        if let previous = values.removeValue(forKey: bucket) { bytes -= previous.bytes }
        order.removeAll { $0 == bucket }
        while !order.isEmpty && (values.count >= 64 || bytes + cost > 16 * 1024 * 1024) {
            if let old = values.removeValue(forKey: order.removeFirst()) { bytes -= old.bytes }
        }
        values[bucket] = (value, cost); order.append(bucket); bytes += cost
    }
    public mutating func removeAll() { values.removeAll(); order.removeAll(); bytes = 0 }
}

public enum SeekPreviewFrame {
    public static func arguments(media: URL, time: Double) -> [String] {
        ["-nostdin", "-hide_banner", "-loglevel", "error", "-threads", "1",
         "-ss", String(max(0, time)), "-noaccurate_seek", "-skip_frame", "nokey", "-i", media.path,
         "-frames:v", "1", "-an", "-sn", "-dn", "-vf",
         "scale=w='min(240,240*dar)':h='min(240,240/dar)',setsar=1",
         "-filter_threads", "1", "-threads", "1", "-f", "image2pipe", "-vcodec", "mjpeg", "pipe:1"]
    }
}
