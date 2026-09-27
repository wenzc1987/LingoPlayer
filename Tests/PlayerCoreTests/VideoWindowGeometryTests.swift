import Foundation
import Testing
@testable import PlayerCore

struct VideoWindowGeometryTests {
    @Test func widescreenAndSidebarUseVideoArea() throws {
        for sidebar in [0.0, 333.0] {
            let geometry = try #require(VideoWindowGeometry(aspect: 16.0 / 9, sidebar: sidebar))
            let fitted = geometry.fit(CGSize(width: 1280 + sidebar, height: 800), in: CGSize(width: 2000, height: 1000))
            #expect(abs(fitted.width - sidebar - fitted.height * 16 / 9) < 0.0001)
            #expect(abs(fitted.height - 720) < 0.0001)
            let vertical = geometry.fit(CGSize(width: 1280, height: 810), in: CGSize(width: 2000, height: 1000), usingHeight: true)
            #expect(vertical.height == 810)
        }
    }
    @Test func portraitAndCinemaStayOnSmallScreens() throws {
        for aspect in [9.0 / 16, 4.0 / 3, 16.0 / 9, 2.39, 5.0] {
            for sidebar in [0.0, 333.0] {
                let geometry = try #require(VideoWindowGeometry(aspect: aspect, sidebar: sidebar))
                let screen = CGSize(width: 1024, height: 700)
                for proposal in [CGSize(width: 50, height: 20), CGSize(width: 3000, height: 2000)] {
                    let fitted = geometry.fit(proposal, in: screen)
                    #expect(fitted.width <= screen.width + 0.001 && fitted.height <= screen.height)
                    #expect(abs((fitted.width - sidebar) / fitted.height - aspect) < 0.0001)
                    #expect(fitted.height >= geometry.minimum(in: screen).height)
                }
            }
        }
    }
    @Test func displayAspectIncludesRotationAndRejectsMissingVideo() throws {
        #expect(VideoWindowGeometry.displayAspect(width: 1920, height: 1080, rotation: 0) == 16.0 / 9)
        let rotated = try #require(VideoWindowGeometry.displayAspect(width: 1920, height: 1080, rotation: 90))
        #expect(abs(rotated - 9.0 / 16) < 0.0001)
        #expect(VideoWindowGeometry.displayAspect(width: 0, height: 1080, rotation: 0) == nil)
        #expect(VideoWindowGeometry.displayAspect(width: .infinity, height: 1080, rotation: 0) == nil)
        #expect(VideoWindowGeometry(aspect: .nan) == nil)
        #expect(VideoWindowGeometry(aspect: -1) == nil)
    }
}
