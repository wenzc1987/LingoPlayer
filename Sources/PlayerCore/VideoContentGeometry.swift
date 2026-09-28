import Foundation
import CoreGraphics

/// The centered, uncropped image inside a video surface, excluding letterboxing.
public struct VideoContentGeometry {
    public let bounds: CGRect
    public let image: CGRect

    public init(size: CGSize, aspect: Double?) {
        bounds = CGRect(origin: .zero, size: size)
        guard let aspect, aspect.isFinite, aspect > 0, size.width > 0, size.height > 0 else {
            image = bounds; return
        }
        let height = min(size.height, size.width / aspect)
        let width = min(size.width, height * aspect)
        image = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    public var subtitleWidth: CGFloat { image.width * 0.92 }

    /// Keep the caption inside the image when a small surface cannot fit the
    /// requested distance. UI overlays and exported screenshots share this rule.
    public func subtitleBottomInset(_ requested: Double, captionHeight: CGFloat) -> CGFloat {
        bounds.maxY - image.maxY + min(max(0, requested), max(0, image.height - captionHeight))
    }

    /// Prefer space above the captions, then below raised captions. If neither
    /// fits, keep the controls on screen beneath the title even if they overlap
    /// the captions temporarily. Caption geometry stays identical to exports.
    public func controlsBottomInset(captionBottom: CGFloat, captionHeight: CGFloat, controlsHeight: CGFloat) -> CGFloat {
        let gap: CGFloat = 18
        let maximum = max(0, bounds.height - 80 - controlsHeight)
        let above = captionBottom + max(76, captionHeight) + gap
        if above <= maximum { return above }
        let below = captionBottom - controlsHeight - gap
        if below >= 16 { return min(below, maximum) }
        return maximum
    }
}
