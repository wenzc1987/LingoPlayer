import AppKit
import Testing
@testable import LingoPlayer

@MainActor struct LearningTextTests {
    @Test func paragraphsWrapWithoutClippingAndRemainSelectable() {
        let field = LearningTextField(wrappingLabelWithString: "")
        field.configure(text: "A long dictionary definition with several words that must wrap when the learning sidebar is narrow.", style: .definition)
        let wide = field.fittingSize(width: 290), narrow = field.fittingSize(width: 140)
        #expect(wide.height > 0 && narrow.height > wide.height)
        #expect(field.isSelectable && !field.isEditable && field.maximumNumberOfLines == 0)
        #expect(field.fittingSize(width: 290) == wide)
        field.configure(text: "word", style: .definition)
        #expect(field.fittingSize(width: 290).height < wide.height)
    }

    @Test func newParagraphAndFontInvalidateMeasurements() {
        let field = LearningTextField(wrappingLabelWithString: "")
        field.configure(text: "word", style: .definition)
        let small = field.fittingSize(width: 290)
        field.configure(text: "word", style: .word)
        #expect(field.fittingSize(width: 290).height > small.height)
        field.configure(text: "first line\nsecond line\nthird line", style: .chinese)
        #expect(field.fittingSize(width: 290).height >= small.height * 3)
        #expect(field.attributedStringValue.string == "first line\nsecond line\nthird line")
    }
}
