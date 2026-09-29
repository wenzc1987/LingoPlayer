import Foundation

public struct ReleaseQuery: Equatable, Sendable {
    public var title: String
    public var year: Int?
    public var season: Int?
    public var episode: Int?
    public init(filename: String) {
        let name = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        func match(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive), let result = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { return nil }
            return (0..<result.numberOfRanges).map { (name as NSString).substring(with: result.range(at: $0)) }
        }
        let episodeMatch = match("S(\\d{1,2})E(\\d{1,3})") ?? match("(\\d{1,2})x(\\d{1,3})")
        season = episodeMatch.flatMap { Int($0[1]) }; episode = episodeMatch.flatMap { Int($0[2]) }
        year = match("(?:^|[ ._(])((?:19|20)\\d{2})(?:[ ._)]|$)").flatMap { Int($0[1]) }
        var titlePart = name
        if let marker = episodeMatch?.first, let range = titlePart.range(of: marker, options: .caseInsensitive) { titlePart = String(titlePart[..<range.lowerBound]) }
        else if let year, let range = titlePart.range(of: String(year)) { titlePart = String(titlePart[..<range.lowerBound]) }
        titlePart = titlePart.replacingOccurrences(of: "[._]", with: " ", options: .regularExpression)
        title = titlePart.replacingOccurrences(of: "(?i)\\b(480p|720p|1080p|2160p|bluray|webrip|web-dl|hdtv|x264|x265|h264|h265)\\b.*$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "-([")))
    }
}

public enum OpenSubtitlesHash {
    public static func compute(url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 131_072 else { return nil }
        var hash = size
        for position in [UInt64(0), size - 65_536] {
            try handle.seek(toOffset: position)
            let data = try handle.read(upToCount: 65_536) ?? Data()
            guard data.count == 65_536 else { return nil }
            for start in stride(from: 0, to: data.count, by: 8) {
                var value: UInt64 = 0
                for byte in 0..<8 { value |= UInt64(data[start + byte]) << (byte * 8) }
                hash = hash &+ value
            }
        }
        return String(format: "%016llx", hash)
    }
}

public struct SubtitleCandidate: Identifiable, Codable, Sendable {
    public var id: Int
    public var filename: String
    public var language: String
    public var release: String
    public var downloads: Int
    public var hashMatched: Bool
    public var hearingImpaired: Bool
}

public enum SubtitleServiceError: LocalizedError {
    case configuration, server(Int, String), invalidResponse
    public var errorDescription: String? {
        switch self {
        case .configuration: return "请先在设置中配置 OpenSubtitles API Key；下载可能还需要账号登录。"
        case .server(let status, let message): return "字幕服务返回 \(status)：\(message)"
        case .invalidResponse: return "字幕服务返回了无法读取的数据。"
        }
    }
}

public final class OpenSubtitlesClient: @unchecked Sendable {
    private let session: URLSession
    private let apiKey: String
    private let token: String
    private let base = URL(string: "https://api.opensubtitles.com/api/v1/")!
    public init(apiKey: String, token: String = "", session: URLSession = .shared) { self.apiKey = apiKey; self.token = token; self.session = session }
    private func request(_ endpoint: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Data {
        guard !apiKey.isEmpty else { throw SubtitleServiceError.configuration }
        var components = URLComponents(url: base.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 25)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("LingoPlayer v\(AppVersion.current ?? "dev")", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SubtitleServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = object?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw SubtitleServiceError.server(http.statusCode, String(message.prefix(300)))
        }
        return data
    }
    public func login(username: String, password: String) async throws -> String {
        let data = try await request("login", method: "POST", body: ["username": username, "password": password])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let value = object["token"] as? String, !value.isEmpty else { throw SubtitleServiceError.invalidResponse }
        return value
    }
    public func search(query: ReleaseQuery, hash: String?, language: SubtitleLanguage) async throws -> [SubtitleCandidate] {
        var items = [URLQueryItem(name: "languages", value: language == .english ? "en" : "zh-cn,zh-tw,zh"), URLQueryItem(name: "order_by", value: "download_count")]
        if !query.title.isEmpty { items.append(URLQueryItem(name: "query", value: query.title)) }
        if let hash { items.append(URLQueryItem(name: "moviehash", value: hash)) }
        if let year = query.year { items.append(URLQueryItem(name: "year", value: String(year))) }
        if let season = query.season { items.append(URLQueryItem(name: "season_number", value: String(season))) }
        if let episode = query.episode { items.append(URLQueryItem(name: "episode_number", value: String(episode))) }
        let data = try await request("subtitles", query: items)
        return try Self.parseCandidates(data)
    }
    public static func parseCandidates(_ data: Data) throws -> [SubtitleCandidate] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = root["data"] as? [[String: Any]] else { throw SubtitleServiceError.invalidResponse }
        var candidates: [SubtitleCandidate] = []
        for row in rows {
            guard let attr = row["attributes"] as? [String: Any], let files = attr["files"] as? [[String: Any]] else { continue }
            for file in files {
                guard let id = file["file_id"] as? Int else { continue }
                candidates.append(SubtitleCandidate(id: id, filename: file["file_name"] as? String ?? "subtitle.srt", language: attr["language"] as? String ?? "", release: attr["release"] as? String ?? "", downloads: attr["download_count"] as? Int ?? 0, hashMatched: attr["moviehash_match"] as? Bool ?? false, hearingImpaired: attr["hearing_impaired"] as? Bool ?? false))
            }
        }
        return candidates.sorted { $0.hashMatched != $1.hashMatched ? $0.hashMatched : $0.downloads > $1.downloads }
    }
    public func download(fileID: Int) async throws -> Data {
        let info = try await request("download", method: "POST", body: ["file_id": fileID, "sub_format": "srt"])
        guard let object = try JSONSerialization.jsonObject(with: info) as? [String: Any], let link = object["link"] as? String, let url = URL(string: link), url.scheme == "https" else { throw SubtitleServiceError.invalidResponse }
        // No API key or bearer token is forwarded to the download host.
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 30))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 10_000_000 else { throw SubtitleServiceError.invalidResponse }
        return data
    }
}
