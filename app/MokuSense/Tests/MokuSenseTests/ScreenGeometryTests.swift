import CoreGraphics
import Testing
@testable import MokuSense

/// Two displays: a 1470×956 pt primary (the MacBook) and a 1920×1080 external placed above it and to the left.
/// Quartz frames: primary (0, 0, 1470, 956), external (-1200, -1080, 1920, 1080).
/// AppKit frames:  primary (0, 0, 1470, 956), external (-1200, 956, 1920, 1080).
@Suite struct ScreenGeometryTests {
    let primaryHeight: CGFloat = 956

    @Test func displaysMapToTheirAppKitFrames() {
        #expect(ScreenGeometry.appKitRect(fromQuartz: CGRect(x: 0, y: 0, width: 1470, height: 956), primaryDisplayHeight: primaryHeight)
                == CGRect(x: 0, y: 0, width: 1470, height: 956))
        #expect(ScreenGeometry.appKitRect(fromQuartz: CGRect(x: -1200, y: -1080, width: 1920, height: 1080), primaryDisplayHeight: primaryHeight)
                == CGRect(x: -1200, y: 956, width: 1920, height: 1080))
    }

    @Test func windowOnThePrimaryDisplay() {
        // A window just below the menu bar, 800×600, at the top-left of the primary display.
        let quartz = CGRect(x: 0, y: 33, width: 800, height: 600)
        #expect(ScreenGeometry.appKitRect(fromQuartz: quartz, primaryDisplayHeight: primaryHeight)
                == CGRect(x: 0, y: 323, width: 800, height: 600))
    }

    @Test func windowOnTheExternalDisplay() {
        let quartz = CGRect(x: -1100, y: -1000, width: 1000, height: 700)
        let appKit = ScreenGeometry.appKitRect(fromQuartz: quartz, primaryDisplayHeight: primaryHeight)
        #expect(appKit == CGRect(x: -1100, y: 1256, width: 1000, height: 700))
        let external = CGRect(x: -1200, y: 956, width: 1920, height: 1080)
        #expect(external.contains(appKit))
    }

    @Test func windowSpanningBothDisplaysRoundTrips() {
        let quartz = CGRect(x: -300, y: -200, width: 900, height: 500)
        let appKit = ScreenGeometry.appKitRect(fromQuartz: quartz, primaryDisplayHeight: primaryHeight)
        #expect(appKit == CGRect(x: -300, y: 656, width: 900, height: 500))
        #expect(ScreenGeometry.appKitRect(fromQuartz: appKit, primaryDisplayHeight: primaryHeight) == quartz)
    }
}
