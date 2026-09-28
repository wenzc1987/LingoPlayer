import SwiftUI

struct SeekPreviewOverlay: View {
    @ObservedObject var preview: SeekPreviewController
    let duration: Double
    var body: some View {
        GeometryReader { geometry in
            if preview.visible {
                let width = min(180.0, geometry.size.width)
                let x = min(geometry.size.width - width / 2, max(width / 2, geometry.size.width * preview.target / max(1, duration)))
                let height: CGFloat = preview.image == nil ? 30 : 136
                let y = max(-height / 2 - 12, height / 2 - geometry.frame(in: .named("player-stage")).minY + 8)
                VStack(spacing: 5) {
                    if let image = preview.image {
                        Image(nsImage: image).resizable().scaledToFit().frame(height: 100)
                    }
                    Text(clock(preview.target)).font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .padding(6).frame(width: width)
                .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.2)) }
                .position(x: x, y: y)
                .accessibilityIdentifier("seek-preview")
            }
        }.allowsHitTesting(false)
    }
}
