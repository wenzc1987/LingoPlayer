import AppKit

/// Capture this process's actual window, including the OpenGL surface and UI.
/// Drawing a video frame over an NSHostingView bitmap would erase floating controls.
@MainActor enum WindowSnapshot {
    @discardableResult static func save(_ window: NSWindow, to url: URL) -> Bool {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url); return true } catch { return false }
    }
}
