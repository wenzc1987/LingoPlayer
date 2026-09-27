import Foundation
import Security

struct RuntimeSettings: Codable {
    var libmpv = ""
    var ffmpeg = ""
    var ffprobe = ""
    var python = ""
    var mfa = ""
    var dictionary = ""
    var acousticModel = "english_mfa"
    var pronunciationDictionary = "english_us_mfa"
    var autoSearch = true

    static var supportDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["LINGOPLAYER_DATA_DIR"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LingoPlayer", isDirectory: true)
    }
    static var runtimeRoots: [URL] {
        var roots: [URL] = []
        if let path = ProcessInfo.processInfo.environment["LINGOPLAYER_RUNTIME"] { roots.append(URL(fileURLWithPath: path)) }
        if let path = Bundle.main.object(forInfoDictionaryKey: "LingoPlayerRuntime") as? String { roots.append(URL(fileURLWithPath: path)) }
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".runtime"))
        return roots
    }
    static func load() -> RuntimeSettings {
        var settings = (try? Data(contentsOf: supportDirectory.appendingPathComponent("settings.json"))).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
        func locate(_ current: String, _ candidates: [String]) -> String {
            if !current.isEmpty { return current }
            return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? ""
        }
        let roots = runtimeRoots.map(\.path)
        settings.python = locate(settings.python, roots.map { $0 + "/aligner/bin/python" } + ["/usr/bin/python3"])
        settings.libmpv = locate(settings.libmpv, [Bundle.main.bundlePath + "/Contents/Frameworks/libmpv.2.dylib"] + roots.map { $0 + "/lib/libmpv.2.dylib" } + ["/opt/homebrew/lib/libmpv.dylib", "/usr/local/lib/libmpv.dylib"])
        settings.ffmpeg = locate(settings.ffmpeg, roots.map { $0 + "/aligner/bin/ffmpeg" } + ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])
        settings.ffprobe = locate(settings.ffprobe, roots.map { $0 + "/aligner/bin/ffprobe" } + ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"])
        settings.mfa = locate(settings.mfa, roots.map { $0 + "/aligner/bin/mfa" })
        settings.dictionary = locate(settings.dictionary, [supportDirectory.appendingPathComponent("ecdict.sqlite").path] + roots.map { $0 + "/ecdict.sqlite" })
        return settings
    }
    func save() throws {
        try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.supportDirectory.appendingPathComponent("settings.json"), options: .atomic)
    }
}

enum SecretStore {
    static func read(_ name: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "LingoPlayer.OpenSubtitles", kSecAttrAccount as String: name, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func write(_ value: String, name: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "LingoPlayer.OpenSubtitles", kSecAttrAccount as String: name]
        if value.isEmpty { SecItemDelete(query as CFDictionary); return }
        let attrs = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil) }
        if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
