import CoreGraphics
import Testing
@testable import MokuSense

/// "Hide Moku when media is full screen" (Charles, 2026-10-08). The numbers are a real Mac's: a 1470 x 956 display with
/// a notch, the menu bar a layer-24 window 33 points tall, the Dock a layer-20 window the size of the display, Moku's
/// own panel at layer 25 and ordinary windows at layer 0.
@Suite struct FullScreenRulesTests {
    static let display = FullScreenRules.Display(id: 1, bounds: CGRect(x: 0, y: 0, width: 1470, height: 956))
    static let own: pid_t = 100

    static func window(_ id: CGWindowID, pid: pid_t = 200, layer: Int = 0, _ bounds: CGRect) -> WindowEntry {
        WindowEntry(id: id, pid: pid, layer: layer, bounds: bounds, title: "")
    }
    static let menuBar = window(1, pid: 50, layer: 24, CGRect(x: 0, y: 0, width: 1470, height: 33))
    static let dock = window(2, pid: 60, layer: 20, CGRect(x: 0, y: 0, width: 1470, height: 956))
    static let mokuPanel = window(3, pid: own, layer: 25, CGRect(x: 1200, y: 700, width: 200, height: 200))

    static func covered(_ windows: [WindowEntry], displays: [FullScreenRules.Display] = [display]) -> Set<UInt32> {
        FullScreenRules.covered(windows: windows, displays: displays, ownPID: own)
    }

    @Test func aNormalDayCoversNothing() {
        let editor = Self.window(10, CGRect(x: 0, y: 33, width: 1470, height: 845))  // zoomed, the Dock showing
        #expect(Self.covered([Self.mokuPanel, Self.menuBar, editor, Self.dock]).isEmpty)
    }

    @Test func aWindowAsTallAsTheScreenUnderTheMenuBarIsNotFullScreen() {
        // The Dock hidden: a zoomed window reaches the bottom, but the menu bar is still there.
        let editor = Self.window(10, CGRect(x: 0, y: 33, width: 1470, height: 923))
        #expect(Self.covered([Self.mokuPanel, Self.menuBar, editor, Self.dock]).isEmpty)
    }

    @Test func nativeFullScreenWithoutMenuBarCoversTheDisplay() {
        // Below the notch, the menu bar gone.
        let video = Self.window(10, CGRect(x: 0, y: 32, width: 1470, height: 924))
        #expect(Self.covered([Self.mokuPanel, video, Self.dock]) == [1])
    }

    @Test func aFullScreenWindowFromTopToBottomCoversTheDisplay() {
        let game = Self.window(10, CGRect(x: 0, y: 0, width: 1470, height: 956))
        #expect(Self.covered([Self.mokuPanel, game]) == [1])
    }

    @Test func theMenuBarSlidDownForAMomentCountsAsShown() {
        // The pointer at the top edge brings the menu bar over a full-screen window: Moku stays out of its way, not in it.
        let video = Self.window(10, CGRect(x: 0, y: 32, width: 1470, height: 924))
        #expect(Self.covered([Self.mokuPanel, Self.menuBar, video]).isEmpty)
    }

    @Test func aMenuBarParkedAboveTheScreenIsNotShown() {
        let parked = Self.window(1, pid: 50, layer: 24, CGRect(x: 0, y: -33, width: 1470, height: 33))
        let video = Self.window(10, CGRect(x: 0, y: 32, width: 1470, height: 924))
        #expect(Self.covered([parked, video]) == [1])
    }

    @Test func theDockAloneIsNotAFullScreenWindow() {
        // The Dock's window is the size of the display, but at layer 20.
        #expect(Self.covered([Self.dock]).isEmpty)
    }

    @Test func mokuOwnWindowsNeverCount() {
        let own = Self.window(11, pid: Self.own, CGRect(x: 0, y: 0, width: 1470, height: 956))  // the welcome, Settings…
        #expect(Self.covered([own]).isEmpty)
    }

    @Test func aSmallWindowOverTheVideoDoesNotHideTheCover() {
        let palette = Self.window(12, CGRect(x: 600, y: 300, width: 300, height: 200))
        let video = Self.window(10, CGRect(x: 0, y: 32, width: 1470, height: 924))
        #expect(Self.covered([palette, video]) == [1])
    }

    @Test func aWideWindowThatIsNotTallEnoughIsNotFullScreen() {
        let banner = Self.window(10, CGRect(x: 0, y: 0, width: 1470, height: 700))
        #expect(Self.covered([banner]).isEmpty)
    }

    @Test func eachDisplayIsJudgedOnItsOwn() {
        let second = FullScreenRules.Display(id: 2, bounds: CGRect(x: 1470, y: -124, width: 1920, height: 1080))
        let secondBar = Self.window(4, pid: 50, layer: 24, CGRect(x: 1470, y: -124, width: 1920, height: 24))
        let video = Self.window(10, CGRect(x: 1470, y: -124, width: 1920, height: 1080))
        let editor = Self.window(11, CGRect(x: 0, y: 33, width: 1470, height: 845))
        // The video fills the second display with its menu bar gone; the first display is working as usual.
        #expect(Self.covered([Self.mokuPanel, Self.menuBar, video, editor], displays: [Self.display, second]) == [2])
        // The same video with that display's menu bar showing: nothing is full screen.
        #expect(Self.covered([Self.mokuPanel, Self.menuBar, secondBar, video, editor], displays: [Self.display, second]).isEmpty)
    }

    @Test func noWindowsNoDisplaysNothing() {
        #expect(Self.covered([]).isEmpty)
        #expect(Self.covered([Self.window(10, CGRect(x: 0, y: 0, width: 1470, height: 956))], displays: []).isEmpty)
    }
}
