import Foundation
import CoreGraphics
import Testing
@testable import PlayerCore

struct VideoWindowResizeTests {
    @Test func horizontalDragDoesNotBounceBackToInitialHeight() throws {
        let geometry = try #require(VideoWindowGeometry(aspect: 16.0 / 9))
        let initial = CGSize(width: 1280, height: 720)
        var drag = VideoWindowResize(), current = initial
        drag.begin(at: initial)
        // AppKit keeps the non-dragged edge at the original mouse-down size.
        // With per-frame axis detection, the second proposal jumps back to 1280.
        for width in stride(from: 1270.0, through: 1000, by: -10) {
            let proposal = CGSize(width: width, height: initial.height)
            let fitted = geometry.fit(proposal, in: CGSize(width: 2000, height: 1200),
                                      usingHeight: drag.usingHeight(for: proposal, current: current, aspect: geometry.aspect))
            #expect(abs(fitted.width - width) < 0.0001)
            #expect(fitted.width < current.width)
            current = fitted
        }
    }
    @Test func verticalDragAndDirectionReversalUseSameAxis() throws {
        let geometry = try #require(VideoWindowGeometry(aspect: 16.0 / 9, sidebar: 333))
        let initial = CGSize(width: 1280 + 333, height: 720)
        var drag = VideoWindowResize(), current = initial
        drag.begin(at: initial)
        for height in [710.0, 700, 600, 650, 700, 730] {
            let proposal = CGSize(width: initial.width, height: height)
            current = geometry.fit(proposal, in: CGSize(width: 2400, height: 1400),
                                   usingHeight: drag.usingHeight(for: proposal, current: current, aspect: geometry.aspect))
            #expect(abs(current.height - height) < 0.0001)
        }
        drag.end()
        #expect(!drag.isActive)
        drag.begin(at: current)
        let horizontal = drag.usingHeight(for: CGSize(width: current.width - 10, height: current.height), current: current, aspect: geometry.aspect)
        #expect(!horizontal)
    }
    @Test func noMotionDoesNotLatchAxisAndProgrammaticResizeRemainsFlexible() {
        let current = CGSize(width: 1280, height: 720)
        var drag = VideoWindowResize()
        drag.begin(at: current)
        let unchanged = drag.usingHeight(for: current, current: current, aspect: 16.0 / 9)
        let vertical = drag.usingHeight(for: CGSize(width: 1280, height: 710), current: current, aspect: 16.0 / 9)
        #expect(!unchanged)
        #expect(vertical)
        drag.end()
        let horizontalProposal = drag.usingHeight(for: CGSize(width: 1260, height: 720), current: current, aspect: 16.0 / 9)
        let verticalProposal = drag.usingHeight(for: CGSize(width: 1280, height: 700), current: current, aspect: 16.0 / 9)
        #expect(!horizontalProposal)
        #expect(verticalProposal)
    }
}
