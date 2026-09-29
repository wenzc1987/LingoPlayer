import AppKit
import SwiftUI

/// Keep one native selectable field per paragraph. SwiftUI's selectable Text
/// layout repeatedly bridges and measures the changing dictionary paragraphs.
struct LearningText: NSViewRepresentable, Equatable {
    enum Style: Equatable {
        case word, phonetic, translation, definition, sentence, chinese
        var size: CGFloat {
            switch self {
            case .word: return 30
            case .phonetic: return 14
            case .translation: return 15
            case .sentence: return 16
            case .definition, .chinese: return 13
            }
        }
        var spacing: CGFloat {
            switch self {
            case .translation, .sentence: return 4
            case .definition, .chinese: return 3
            default: return 0
            }
        }
        var color: NSColor {
            switch self {
            case .word: return NSColor(srgbRed: 0.73, green: 0.89, blue: 0.43, alpha: 1)
            case .phonetic: return NSColor(srgbRed: 0.53, green: 0.58, blue: 0.63, alpha: 1)
            case .definition, .chinese: return .secondaryLabelColor
            default: return .labelColor
            }
        }
    }
    let text: String
    let style: Style
    func makeNSView(context: Context) -> LearningTextField { LearningTextField(wrappingLabelWithString: "") }
    func updateNSView(_ field: LearningTextField, context: Context) { field.configure(text: text, style: style) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LearningTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return nsView.fittingSize(width: width)
    }
}

final class LearningTextField: NSTextField {
    private var content: String?
    private var style: LearningText.Style?
    private var measuredWidth: CGFloat?
    private var measuredSize = CGSize.zero
    func configure(text: String, style: LearningText.Style) {
        guard content != text || self.style != style else { return }
        content = text; self.style = style; measuredWidth = nil
        isSelectable = true; isEditable = false; drawsBackground = false; isBordered = false
        maximumNumberOfLines = 0; lineBreakMode = .byWordWrapping
        let weight: NSFont.Weight = style == .word ? .semibold : style == .sentence ? .medium : .regular
        var font = NSFont.systemFont(ofSize: style.size, weight: weight)
        if style == .word, let descriptor = font.fontDescriptor.withDesign(.rounded), let rounded = NSFont(descriptor: descriptor, size: style.size) { font = rounded }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = style.spacing
        attributedStringValue = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: style.color, .paragraphStyle: paragraph])
        invalidateIntrinsicContentSize()
    }
    func fittingSize(width: CGFloat) -> CGSize {
        let width = max(0, width)
        if measuredWidth == width { return measuredSize }
        let size = cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: max(1, width), height: .greatestFiniteMagnitude)) ?? .zero
        measuredWidth = width; measuredSize = CGSize(width: width, height: ceil(size.height))
        return measuredSize
    }
}
