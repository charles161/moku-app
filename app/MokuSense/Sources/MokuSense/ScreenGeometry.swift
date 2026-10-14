import CoreGraphics

/// Converts between the two global coordinate spaces macOS uses.
/// - Quartz (Accessibility, CGWindowList, ScreenCaptureKit): origin at the top-left of the primary display, y down.
/// - AppKit (NSEvent.mouseLocation, NSWindow, the MokuKit contract): origin at the bottom-left of the primary display, y up.
/// Both spaces share the x axis and are anchored to the primary display, so only its height is needed,
/// whatever the arrangement of the other displays.
enum ScreenGeometry {
    /// The flip is its own inverse, so the same call converts AppKit back to Quartz.
    static func appKitRect(fromQuartz rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Height of the display at Quartz (0, 0), which is the one carrying the menu bar.
    static var primaryDisplayHeight: CGFloat {
        CGDisplayBounds(CGMainDisplayID()).height
    }
}
