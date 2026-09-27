import Foundation

/// Fits the video area, excluding the fixed-width sidebar, without cropping.
public struct VideoWindowGeometry {
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
        // Leave room for the title, wrapped captions and the expanded toolbar.
        let height = min(maximum(in: available).height, max(360, min(480, 480 / aspect)))
        return CGSize(width: height * aspect + sidebar, height: height)
    }
    public func fit(_ proposed: CGSize, in available: CGSize, usingHeight: Bool = false) -> CGSize {
        let desired = usingHeight ? proposed.height : (proposed.width - sidebar) / aspect
        let low = minimum(in: available).height, high = maximum(in: available).height
        let height = min(high, max(low, desired.isFinite ? desired : low))
        return CGSize(width: height * aspect + sidebar, height: height)
    }
}
