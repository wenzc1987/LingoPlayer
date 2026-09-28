import Foundation
import CoreGraphics
import Testing
@testable import PlayerCore

struct VideoContentGeometryTests {
    @Test func fullScreenLetterboxUsesImageBottom() {
        let geometry = VideoContentGeometry(size: CGSize(width: 1920, height: 1200), aspect: 16.0 / 9)
        #expect(geometry.image == CGRect(x: 0, y: 60, width: 1920, height: 1080))
        for inset in [8.0, 40, 160] {
            #expect(abs(geometry.subtitleBottomInset(inset, captionHeight: 80) - 60 - inset) < 0.0001)
        }
    }
    @Test func portraitPillarboxLimitsCaptionWidth() {
        let geometry = VideoContentGeometry(size: CGSize(width: 1280, height: 720), aspect: 9.0 / 16)
        #expect(geometry.image == CGRect(x: 437.5, y: 0, width: 405, height: 720))
        #expect(geometry.subtitleWidth == 405 * 0.92)
        #expect(geometry.subtitleBottomInset(8, captionHeight: 80) == 8)
    }
    @Test func resizingAndSidebarKeepCaptionInsideImage() {
        for aspect in [9.0 / 16, 4.0 / 3, 16.0 / 9, 2.39, 32.0 / 9] {
            for sidebar in [0.0, 333] {
                for width in stride(from: 1024.0, through: 1600, by: 16) {
                    let geometry = VideoContentGeometry(size: CGSize(width: width - sidebar, height: 800), aspect: aspect)
                    let bottom = geometry.subtitleBottomInset(8, captionHeight: 80)
                    #expect(abs(bottom - geometry.image.minY - 8) < 0.0001)
                    #expect(bottom + 80 <= geometry.image.maxY)
                }
            }
        }
    }
    @Test func smallImageClampsOnlyWhenCaptionWouldLeaveImage() {
        let geometry = VideoContentGeometry(size: CGSize(width: 680, height: 360), aspect: 4)
        #expect(geometry.image.height == 170)
        #expect(geometry.subtitleBottomInset(160, captionHeight: 80) == 185)
        #expect(geometry.subtitleBottomInset(8, captionHeight: 80) == 103)
    }
    @Test func missingAspectUsesAvailableSurface() {
        for aspect: Double? in [nil, 0, -.infinity, .nan] {
            let geometry = VideoContentGeometry(size: CGSize(width: 680, height: 360), aspect: aspect)
            #expect(geometry.image == geometry.bounds)
            #expect(geometry.subtitleBottomInset(8, captionHeight: 80) == 8)
        }
    }
    @Test func raisedCaptionsLeaveControlsBelowWhenTheyCannotFitAbove() {
        let geometry = VideoContentGeometry(size: CGSize(width: 680, height: 360), aspect: 16.0 / 9)
        let captionBottom = geometry.subtitleBottomInset(160, captionHeight: 229)
        let controlsBottom = geometry.controlsBottomInset(captionBottom: captionBottom, captionHeight: 229, controlsHeight: 96)
        #expect(captionBottom == 131)
        #expect(controlsBottom >= 16)
        #expect(controlsBottom + 96 + 18 <= captionBottom)
    }
    @Test func controlsStayInsideTheStageBelowTheTitleWithTallCaptions() {
        for size in [CGSize(width: 680, height: 360), CGSize(width: 1024, height: 700)] {
            for aspect in [9.0 / 16, 16.0 / 9, 32.0 / 9] {
                let geometry = VideoContentGeometry(size: size, aspect: aspect)
                for height in [0.0, 80, 229, 450] {
                    for requested in [8.0, 160] {
                        let captionBottom = geometry.subtitleBottomInset(requested, captionHeight: height)
                        let bottom = geometry.controlsBottomInset(captionBottom: captionBottom, captionHeight: height, controlsHeight: 100)
                        #expect(bottom >= 0)
                        #expect(bottom + 100 <= size.height - 80)
                    }
                }
            }
        }
    }
    @Test func roomyStageKeepsControlsAboveCaptions() {
        let geometry = VideoContentGeometry(size: CGSize(width: 1280, height: 720), aspect: 16.0 / 9)
        let bottom = geometry.controlsBottomInset(captionBottom: 24, captionHeight: 80, controlsHeight: 100)
        #expect(bottom == 122)
    }
}
