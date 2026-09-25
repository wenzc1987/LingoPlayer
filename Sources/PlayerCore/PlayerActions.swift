import Foundation

public enum PlayerAction: String, Codable, CaseIterable, Identifiable {
    case playPause, replaySentence, resumeLearning, backward, forward, previousSentence, nextSentence
    case volumeDown, volumeUp, slower, faster, previousVideo, nextVideo, toggleSidebar
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .playPause: return "播放／暂停"
        case .replaySentence: return "回放本句"
        case .resumeLearning: return "继续学习"
        case .backward: return "后退 5 秒"
        case .forward: return "前进 5 秒"
        case .previousSentence: return "上一句"
        case .nextSentence: return "下一句"
        case .volumeDown: return "降低音量"
        case .volumeUp: return "提高音量"
        case .slower: return "降低倍速"
        case .faster: return "提高倍速"
        case .previousVideo: return "上一部视频"
        case .nextVideo: return "下一部视频"
        case .toggleSidebar: return "切换学习／播放列表"
        }
    }
    public var defaultShortcut: Shortcut {
        switch self {
        case .playPause: return .init(35, "p", .command)
        case .replaySentence: return .init(15, "r", .command)
        case .resumeLearning: return .init(36, "\r", .command)
        case .backward: return .init(123, "←")
        case .forward: return .init(124, "→")
        case .previousSentence: return .init(123, "←", .option)
        case .nextSentence: return .init(124, "→", .option)
        case .volumeDown: return .init(125, "↓")
        case .volumeUp: return .init(126, "↑")
        case .slower: return .init(33, "[")
        case .faster: return .init(30, "]")
        case .previousVideo: return .init(123, "←", [.command, .shift])
        case .nextVideo: return .init(124, "→", [.command, .shift])
        case .toggleSidebar: return .init(37, "l", .command)
        }
    }
}

public struct KeyModifiers: OptionSet, Codable, Hashable {
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1)
    public static let option = Self(rawValue: 2)
    public static let control = Self(rawValue: 4)
    public static let shift = Self(rawValue: 8)
}

public struct Shortcut: Codable, Hashable {
    public let keyCode: UInt16
    public let key: String
    public let modifiers: KeyModifiers
    public init(_ keyCode: UInt16, _ key: String, _ modifiers: KeyModifiers = []) {
        self.keyCode = keyCode; self.key = key; self.modifiers = modifiers
    }
    public func matches(_ other: Shortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }
    public var label: String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "") +
        (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") +
        (key == "\r" ? "Return" : key == " " ? "Space" : key.uppercased())
    }
    public var isReserved: Bool {
        // Leave application, file, editing and system window shortcuts to AppKit.
        if modifiers.contains(.command) && ["o", "i", ",", "q", "w", "h", "m", "a", "c", "v", "x", "z", "s", "f", "g", "t", "n", "`", "\t", " "].contains(key.lowercased()) { return true }
        if modifiers.contains(.control) && !modifiers.contains(.command) { return true } // IME / native navigation
        return [48, 53, 51, 117].contains(keyCode) || key.isEmpty // Tab, Escape, Delete
    }
}

public struct InteractionPreferences: Codable, Equatable {
    public var autoplay = true
    /// Explicit nil bindings are stored as disabled action names, so missing fields retain defaults.
    private var bindings: [String: Shortcut] = [:]
    private var disabled: Set<String> = []
    public init() {}
    enum CodingKeys: String, CodingKey { case autoplay, bindings, disabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoplay = try c.decodeIfPresent(Bool.self, forKey: .autoplay) ?? true
        let incoming = try c.decodeIfPresent([String: Shortcut].self, forKey: .bindings) ?? [:]
        disabled = try c.decodeIfPresent(Set<String>.self, forKey: .disabled) ?? []
        // Reconcile a partial file deterministically; never install duplicate or reserved bindings.
        for action in PlayerAction.allCases {
            if let value = incoming[action.rawValue], !value.isReserved { bindings[action.rawValue] = value }
        }
        var used: [Shortcut] = []
        for action in PlayerAction.allCases {
            if let shortcut = shortcut(for: action) {
                if used.contains(where: { $0.matches(shortcut) }) { disabled.insert(action.rawValue) }
                else { used.append(shortcut) }
            }
        }
    }
    public func shortcut(for action: PlayerAction) -> Shortcut? {
        disabled.contains(action.rawValue) ? nil : bindings[action.rawValue] ?? action.defaultShortcut
    }
    public func conflict(_ shortcut: Shortcut, excluding action: PlayerAction) -> PlayerAction? {
        PlayerAction.allCases.first { $0 != action && self.shortcut(for: $0)?.matches(shortcut) == true }
    }
    public mutating func assign(_ shortcut: Shortcut?, to action: PlayerAction) -> String? {
        if let shortcut {
            if shortcut.isReserved { return "此按键保留给系统、文本编辑或原生菜单。" }
            if let other = conflict(shortcut, excluding: action) { return "与“\(other.title)”冲突，请先清除该操作的绑定。" }
            bindings[action.rawValue] = shortcut; disabled.remove(action.rawValue)
        } else { bindings.removeValue(forKey: action.rawValue); disabled.insert(action.rawValue) }
        return nil
    }
    public mutating func resetAll() { bindings = [:]; disabled = [] }
}
