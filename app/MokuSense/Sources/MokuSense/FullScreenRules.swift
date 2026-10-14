import CoreGraphics
import Foundation

/// Which displays have something full screen on them (a film, a game, a slideshow): Moku steps out of the way there.
///
/// The window server tells it, with no permission and no reading of anything:
/// - the menu bar is a window of its own at layer 24, 33 points tall or so, along the top of each display; it is
///   gone (moved off the screen) when an app goes full screen, and stays gone for apps that hide it themselves;
/// - an app's ordinary windows are at layer 0. One that spans the display, top to bottom, with no menu bar, is full
///   screen. A window as tall as the screen under a menu bar that is there is only a zoomed window.
///
/// A notch takes about 32 points off the top of a full-screen window, so the height is allowed to fall that short.
enum FullScreenRules {
    struct Display: Equatable, Sendable {
        /// The display's `CGDirectDisplayID` (an `NSScreen`'s "NSScreenNumber").
        var id: UInt32
        /// Quartz global coordinates, like the windows'.
        var bounds: CGRect
    }

    /// The most a full-screen window may fall short of the display's height (the notch, and rounding).
    static let notchAllowance: CGFloat = 40
    /// How far a window's edges may be from the display's (a fractional pixel, a hairline border).
    static let edgeTolerance: CGFloat = 2

    static func covered(windows: [WindowEntry], displays: [Display], ownPID: pid_t) -> Set<UInt32> {
        Set(coveringWindows(windows: windows, displays: displays, ownPID: ownPID).keys)
    }

    /// Each covered display's full-screen window: the frontmost one (`windows` are front to back).
    static func coveringWindows(windows: [WindowEntry], displays: [Display], ownPID: pid_t) -> [UInt32: WindowEntry] {
        var covering: [UInt32: WindowEntry] = [:]
        for display in displays {
            if let window = coveringWindow(display, in: windows, ownPID: ownPID) { covering[display.id] = window }
        }
        return covering
    }

    private static func coveringWindow(_ display: Display, in windows: [WindowEntry], ownPID: pid_t) -> WindowEntry? {
        let bounds = display.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        if windows.contains(where: { $0.layer == menuBarLayer && showsMenuBar($0, on: bounds) }) { return nil }
        return windows.first { window in
            window.layer == 0 && window.pid != ownPID && spans(window.bounds, bounds)
        }
    }

    /// The menu bar's layer in `CGWindowListCopyWindowInfo` (`kCGMainMenuWindowLevel`).
    private static let menuBarLayer = 24

    /// A menu bar window sitting along the top of this display (not parked above it).
    private static func showsMenuBar(_ window: WindowEntry, on display: CGRect) -> Bool {
        let box = window.bounds
        return box.midX >= display.minX && box.midX <= display.maxX
            && abs(box.minY - display.minY) <= edgeTolerance && box.height <= 80
    }

    private static func spans(_ window: CGRect, _ display: CGRect) -> Bool {
        window.width >= display.width - edgeTolerance * 2
            && window.height >= display.height - notchAllowance
            && abs(window.minX - display.minX) <= edgeTolerance
            && window.minY >= display.minY - edgeTolerance
            && window.minY <= display.minY + notchAllowance
    }
}

/// Which full-screen displays show media (the friends, 2026-10-14: "in full screen mode for viewing media content moku
/// shouldnt be there"): the covering window's app is playing something (`MediaPlayback`), is an app for watching, or is
/// a browser on a site for watching. Once a window counted it keeps counting while it stays full screen, so pausing a
/// film doesn't bring Moku back over it, unless its browser has moved to a page of work. A full-screen editor never
/// counts.
enum FullScreenMedia {
    static func displays(covering: [UInt32: WindowEntry], playing: Set<pid_t>, isWatchingApp: (pid_t) -> Bool,
                         isOnWorkPage: (pid_t) -> Bool = { _ in false },
                         remembered: Set<CGWindowID>) -> (displays: Set<UInt32>, remembered: Set<CGWindowID>) {
        var media: Set<UInt32> = []
        var keep: Set<CGWindowID> = []
        for (display, window) in covering {
            let stillWatching = remembered.contains(window.id) && !isOnWorkPage(window.pid)
            guard stillWatching || playing.contains(window.pid) || isWatchingApp(window.pid) else { continue }
            media.insert(display)
            keep.insert(window.id)
        }
        return (media, keep)
    }
}
