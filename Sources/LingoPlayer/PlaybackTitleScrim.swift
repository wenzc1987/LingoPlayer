import AppKit
import SwiftUI

/// Core Animation resizes this gradient without repainting a wide bitmap on
/// the main thread for every window-size change.
struct PlaybackTitleScrim: NSViewRepresentable {
    final class ScrimView: NSView {
        override func makeBackingLayer() -> CALayer {
            let gradient = CAGradientLayer()
            gradient.colors = [NSColor.black.withAlphaComponent(0.6).cgColor, NSColor.clear.cgColor]
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            return gradient
        }
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {}
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> ScrimView {
        let view = ScrimView(); view.wantsLayer = true
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ nsView: ScrimView, context: Context) {}
}
