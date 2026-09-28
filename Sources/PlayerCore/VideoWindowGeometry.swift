import Foundation
import CoreGraphics

/// Fits the video area, excluding the fixed-width sidebar, without cropping.
public struct VideoWindowGeometry {
    /// Video-stage space needed by the single-row toolbar, title and captions.
    public static let minimumStage = CGSize(width: 680, height: 360)
    public let aspect: Double
    public let sidebar: Double
    public init?(aspect: Double, sidebar: Double = 0) {
        guard aspect.isFinite, aspect > 0, sidebar.isFinite, sidebar >= 0 else { return nil }
        self.aspect = aspect; self.sidebar = sidebar
    }
    public static func displayAspect(width: Double, height: Double, rotation: Double) -> Double? {
        guard width.isFinite, height.isFinite, rotation.isFinite, width > 0, height > 0 else { return nil }
        let radians = rotation.truncatingRemainder(dividingBy: 360) * .pi / 180
        let c = abs(cos(radians)), s = abs(sin(radians))
        return (width * c + height * s) / (width * s + height * c)
    }
    public func maximum(in available: CGSize) -> CGSize {
        let height = max(1, min(available.height, max(1, available.width - sidebar) / aspect))
        return CGSize(width: height * aspect + sidebar, height: height)
    }
    public func minimum(in available: CGSize) -> CGSize {
        let floor = Self.freeMinimum(in: available, sidebar: sidebar)
        let height = min(maximum(in: available).height, max(floor.height, (floor.width - sidebar) / aspect))
        return CGSize(width: max(floor.width, height * aspect + sidebar), height: max(floor.height, height))
    }
    public static func freeMinimum(in available: CGSize, sidebar: Double = 0) -> CGSize {
        CGSize(width: min(available.width, minimumStage.width + sidebar), height: min(available.height, minimumStage.height))
    }
    public static func freeFit(_ proposed: CGSize, in available: CGSize, sidebar: Double = 0) -> CGSize {
        let floor = freeMinimum(in: available, sidebar: sidebar)
        return CGSize(width: min(available.width, max(floor.width, proposed.width)),
                      height: min(available.height, max(floor.height, proposed.height)))
    }
    public func fit(_ proposed: CGSize, in available: CGSize, usingHeight: Bool = false) -> CGSize {
        let desired = usingHeight ? proposed.height : (proposed.width - sidebar) / aspect
        let floor = Self.freeMinimum(in: available, sidebar: sidebar)
        let low = minimum(in: available).height, high = maximum(in: available).height
        let height = min(high, max(low, desired.isFinite ? desired : low))
        // A portrait or very wide video may not fit the toolbar minimum on this
        // screen. Preserve the controls and full video; mpv letterboxes the rest.
        return CGSize(width: max(floor.width, height * aspect + sidebar), height: max(floor.height, height))
    }
}
