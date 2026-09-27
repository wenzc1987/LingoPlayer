import Combine

@MainActor final class PlayerWindowPresentation: ObservableObject {
    @Published var isFullScreen = false
    @Published var isTransitioning = false
    var fullScreenHelp: String {
        if isTransitioning { return isFullScreen ? "正在恢复窗口…" : "正在进入全屏…" }
        return isFullScreen ? "退出全屏，恢复窗口" : "进入全屏"
    }
}
