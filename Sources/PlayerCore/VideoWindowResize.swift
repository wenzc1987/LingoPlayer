import Foundation
import CoreGraphics

/// Keep one driving axis throughout a drag. Comparing each proposal with the
/// last aspect-corrected frame mistakes our own correction for pointer motion.
public struct VideoWindowResize {
    private var initialSize: CGSize?
    private var heightDriven: Bool?
    public var isActive: Bool { initialSize != nil }
    public init() {}
    public mutating func begin(at size: CGSize) { initialSize = size; heightDriven = nil }
    public mutating func end() { initialSize = nil; heightDriven = nil }
    public mutating func usingHeight(for proposed: CGSize, current: CGSize, aspect: Double) -> Bool {
        if let heightDriven { return heightDriven }
        let reference = initialSize ?? current
        let widthChange = abs(proposed.width - reference.width)
        let heightChange = abs(proposed.height - reference.height) * aspect
        let result = heightChange > widthChange
        if isActive && max(widthChange, heightChange) > 1 { heightDriven = result }
        return result
    }
}
