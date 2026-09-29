import Foundation

public enum PlayerAction: String, Codable, CaseIterable, Identifiable {
    case playPause, replaySentence, resumeLearning, backward, forward, previousSentence, nextSentence
    case volumeDown, volumeUp, slower, faster, previousVideo, nextVideo, toggleSidebar
    case toggleSentenceLoop, cycleSubtitleDisplay
    case toggleSidebarVisibility
    case toggleFullScreen, toggleFitVideoWindow, screenshot
    case previousWord, nextWord
    public var id: String { rawValue }
    public var requiresLearning: Bool { [.replaySentence, .resumeLearning, .previousSentence, .nextSentence, .toggleSentenceLoop, .previousWord, .nextWord].contains(self) }
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
        case .toggleSidebar: return "切换学习／字幕／播放列表"
        case .toggleSentenceLoop: return "开启／关闭单句循环"
        case .cycleSubtitleDisplay: return "切换视频字幕显示"
        case .toggleSidebarVisibility: return "展开／折叠侧栏"
        case .toggleFullScreen: return "全屏／恢复窗口"
        case .toggleFitVideoWindow: return "开启／关闭无黑边"
        case .screenshot: return "截图"
        case .previousWord: return "上一个单词"
        case .nextWord: return "下一个单词"
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
        case .toggleSentenceLoop: return .init(15, "r", [.command, .shift])
        case .cycleSubtitleDisplay: return .init(11, "b", .command)
        case .toggleSidebarVisibility: return .init(37, "l", [.command, .option])
        case .toggleFullScreen: return .init(3, "f", [.command, .control])
        case .toggleFitVideoWindow: return .init(11, "b", [.command, .option])
        case .screenshot: return .init(35, "p", [.command, .option])
        case .previousWord: return .init(123, "←", .command)
        case .nextWord: return .init(124, "→", .command)
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
        // The player owns the standard fullscreen chord; plain Cmd-F remains
        // reserved for native text/search behavior.
        if keyCode == 3 && key.lowercased() == "f" && modifiers == [.command, .control] { return false }
        // Leave application, file, editing and system window shortcuts to AppKit.
        if modifiers.contains(.command) && ["o", "i", ",", "q", "w", "h", "m", "a", "c", "v", "x", "z", "s", "f", "g", "t", "n", "`", "\t", " "].contains(key.lowercased()) { return true }
        if modifiers.contains(.control) && !modifiers.contains(.command) { return true } // IME / native navigation
        return [48, 53, 51, 117].contains(keyCode) || key.isEmpty // Tab, Escape, Delete
    }
}

public struct InteractionPreferences: Codable, Equatable {
    public var autoplay = true
    public var subtitleDisplay: SubtitleDisplayMode = .bilingual
    public var sidebarCollapsed = true
    public var cardHidden = false
    public private(set) var conflictNotices: [String] = []
    /// Explicit nil bindings are stored as disabled action names, so missing fields retain defaults.
    private var bindings: [String: Shortcut] = [:]
    private var disabled: Set<String> = []
    public init() {}
    enum CodingKeys: String, CodingKey { case autoplay, bindings, disabled, subtitleDisplay, conflictNotices, sidebarCollapsed, cardHidden }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoplay = try c.decodeIfPresent(Bool.self, forKey: .autoplay) ?? true
        subtitleDisplay = try c.decodeIfPresent(SubtitleDisplayMode.self, forKey: .subtitleDisplay) ?? .bilingual
        sidebarCollapsed = try c.decodeIfPresent(Bool.self, forKey: .sidebarCollapsed) ?? true
        cardHidden = try c.decodeIfPresent(Bool.self, forKey: .cardHidden) ?? false
        conflictNotices = try c.decodeIfPresent([String].self, forKey: .conflictNotices) ?? []
        let incoming = try c.decodeIfPresent([String: Shortcut].self, forKey: .bindings) ?? [:]
        disabled = try c.decodeIfPresent(Set<String>.self, forKey: .disabled) ?? []
        // Reconcile a partial file deterministically; never install duplicate or reserved bindings.
        for action in PlayerAction.allCases {
            if let value = incoming[action.rawValue], !value.isReserved { bindings[action.rawValue] = value }
        }
        var used: [Shortcut] = []
        for action in PlayerAction.allCases {
            if let shortcut = shortcut(for: action) {
                if used.contains(where: { $0.matches(shortcut) }) {
                    disabled.insert(action.rawValue)
                    if !conflictNotices.contains(action.rawValue) { conflictNotices.append(action.rawValue) }
                }
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
        conflictNotices.removeAll { $0 == action.rawValue }
        return nil
    }
    public mutating func resetAll() { bindings = [:]; disabled = []; conflictNotices = [] }
}
