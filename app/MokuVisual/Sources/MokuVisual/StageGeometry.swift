import Foundation
import CoreGraphics

public enum StageGeometry {
    // Expand the canvas without changing projected pixels per world unit. One camera for all clips.
    static let renderPoints: CGFloat = 320
    static let textureSize = 640
    public static let size = CGSize(width: 320, height: 340)
    public static let characterFrame = CGRect(x: 0, y: 5, width: renderPoints, height: renderPoints)
    // Logical resting-body center is independent of transparent render padding.
    static let restingCenter = CGPoint(x: characterFrame.midX, y: 85)
    // The resting bunny spans this far either side of its panel's centre (measured from the render;
    // the right is wider for the hanging lop ear). The transparent rest of the panel may hang past
    // the screen's side, so the bunny itself sits `edgePadding` from it.
    static let bodyLeft: CGFloat = 48, bodyRight: CGFloat = 60
    static let edgePadding: CGFloat = 10
    /// Moku's size (Settings › Size): the standard is 1, from a quarter of it up to 1.25 times.
    /// Everything inside the panel (the render, the eye line, the head's top, the body's extent) is
    /// laid out in stage points, as at size 1, and the panel scales it as one.
    public static let scales: ClosedRange<CGFloat> = 0.25...1.25
    static func panelSize(scale: CGFloat) -> CGSize { CGSize(width: size.width * scale, height: size.height * scale) }
    /// The scale a panel was sized for.
    static func scale(of panel: CGRect) -> CGFloat { panel.height / size.height }
    /// Where Moku's feet meet the ground, in stage points: what stays put when it is resized.
    static let feet = CGPoint(x: characterFrame.midX, y: 18)
    /// Panel x origins that keep the bunny's body inside the visible frame, `edgePadding` from its sides.
    static func originsX(in visible: CGRect, scale: CGFloat) -> ClosedRange<CGFloat> {
        let low = visible.minX + edgePadding - (characterFrame.midX - bodyLeft) * scale
        return low...max(low, visible.maxX - edgePadding - (characterFrame.midX + bodyRight) * scale)
    }
    public static func home(in visible: CGRect, scale: CGFloat) -> CGPoint {
        CGPoint(x: originsX(in: visible, scale: scale).upperBound, y: visible.minY + 6)
    }
    /// A Dock that hides itself takes only a sliver (a few points) out of the visible frame, then slides out over that
    /// edge when the pointer reaches it, over Moku at home. Moku keeps clear of the Dock as shown: its icons (`dockTile`)
    /// and their margins, 21 pt (a 52 pt Dock reserves 73). A Dock that stays shown is already out of the visible frame.
    static func clearOfHiddenDock(visible: CGRect, screen: CGRect, dockTile: @autoclosure () -> CGFloat) -> CGRect {
        let sliver: ClosedRange<CGFloat> = 0.5...10
        var clear = visible
        if sliver.contains(visible.minY - screen.minY) {
            clear.origin.y = screen.minY + dockTile() + 21; clear.size.height = visible.maxY - clear.minY
        } else if sliver.contains(visible.minX - screen.minX) {
            clear.origin.x = screen.minX + dockTile() + 21; clear.size.width = visible.maxX - clear.minX
        } else if sliver.contains(screen.maxX - visible.maxX) {
            clear.size.width = screen.maxX - dockTile() - 21 - visible.minX
        }
        return clear
    }
    /// How far to scoot sideways (right is positive) so a wave reaching `reach` either side of the centre stays
    /// `edgePadding` inside the visible frame; zero when it already does.
    static func roomToWave(panel: CGRect, visible: CGRect, reach: (left: CGFloat, right: CGFloat)) -> CGFloat {
        let scale = scale(of: panel), centre = panel.minX + characterFrame.midX * scale
        return max(0, visible.minX + edgePadding - (centre - reach.left * scale)) - max(0, centre + reach.right * scale + edgePadding - visible.maxX)
    }
    /// Dropped within this of an edge, Moku glides the rest of the way to it: the screen's edges are magnetic,
    /// so "at the side" or "in the top corner" is exact.
    static let snapDistance: CGFloat = 48
    /// Panel y origins that keep Moku on screen: from the bottom up to its head `edgePadding` under the top.
    /// (The transparent panel above the head may run past the screen's top, into the menu bar.)
    static func originsY(in visible: CGRect, scale: CGFloat) -> ClosedRange<CGFloat> {
        let low = visible.minY
        return low...max(low, visible.maxY - edgePadding - headTop * scale)
    }
    /// Where a throw from `origin` lands: the point where the line it was thrown along leaves `xs` × `ys` (the panel
    /// origins on its display), so the edge it was thrown toward, at the height or place that line reaches it. With no
    /// direction it stays where it is, on screen.
    static func edge(from origin: CGPoint, toward direction: CGPoint, xs: ClosedRange<CGFloat>, ys: ClosedRange<CGFloat>) -> CGPoint {
        let start = CGPoint(x: min(xs.upperBound, max(xs.lowerBound, origin.x)), y: min(ys.upperBound, max(ys.lowerBound, origin.y)))
        var reach = CGFloat.infinity
        if direction.x > 0 { reach = min(reach, (xs.upperBound - start.x) / direction.x) }
        if direction.x < 0 { reach = min(reach, (xs.lowerBound - start.x) / direction.x) }
        if direction.y > 0 { reach = min(reach, (ys.upperBound - start.y) / direction.y) }
        if direction.y < 0 { reach = min(reach, (ys.lowerBound - start.y) / direction.y) }
        guard reach.isFinite else { return start }
        return CGPoint(x: min(xs.upperBound, max(xs.lowerBound, start.x + direction.x * reach)),
                       y: min(ys.upperBound, max(ys.lowerBound, start.y + direction.y * reach)))
    }
    /// Where a dropped Moku settles: on screen, and flush with any edge it was dropped near.
    static func settled(_ origin: CGPoint, in visible: CGRect, scale: CGFloat) -> CGPoint {
        let xs = originsX(in: visible, scale: scale), ys = originsY(in: visible, scale: scale)
        var settled = clamped(origin, to: visible, scale: scale)
        if settled.x > xs.upperBound - snapDistance { settled.x = xs.upperBound } else if settled.x < xs.lowerBound + snapDistance { settled.x = xs.lowerBound }
        let floor = home(in: visible, scale: scale).y
        if settled.y > ys.upperBound - snapDistance { settled.y = ys.upperBound } else if settled.y < floor + snapDistance { settled.y = floor }
        return settled
    }
    public static func clamped(_ origin: CGPoint, to visible: CGRect, scale: CGFloat) -> CGPoint {
        let xs = originsX(in: visible, scale: scale), ys = originsY(in: visible, scale: scale)
        return CGPoint(x: min(max(origin.x, xs.lowerBound), xs.upperBound), y: min(max(origin.y, ys.lowerBound), ys.upperBound))
    }
    public static func gaze(at point: CGPoint, from origin: CGPoint, in visible: CGRect) -> CGPoint {
        // Screen-relative targeting preserves differences between distant windows.
        CGPoint(x: min(1, max(-1, (point.x - origin.x) / max(1, visible.width * 0.65))),
                y: min(1, max(-1, (point.y - origin.y) / max(1, visible.height * 0.65))))
    }
    /// Where Moku's eyes sit in its panel at rest (measured from the render), in stage points.
    static let eyeLine = CGPoint(x: characterFrame.midX, y: 92)
    /// Moku's eyes on screen, for a panel at any size.
    static func eyes(panel: CGRect) -> CGPoint {
        let scale = scale(of: panel)
        return CGPoint(x: panel.minX + eyeLine.x * scale, y: panel.minY + eyeLine.y * scale)
    }
    /// The top of Moku's head and looped ear at rest, above the panel's bottom (measured from the
    /// render across moods; only "sit up tall" reaches higher). Captions sit above it.
    static let headTop: CGFloat = 160
    /// The caption sits `gap` above Moku's head, centred on it, and stays on screen. The gap is in
    /// screen points, the same at any size.
    static func captionOrigin(panel: CGRect, caption: CGSize, visible: CGRect, gap: CGFloat) -> CGPoint {
        CGPoint(x: min(max(panel.midX - caption.width / 2, visible.minX + 8), visible.maxX - caption.width - 8),
                y: min(visible.maxY - caption.height, panel.minY + headTop * scale(of: panel) + gap))
    }
    /// The speech bubble's clear margin (room for its shadow) around the drawn bubble.
    static let speechInset: CGFloat = 12
    /// The speech bubble's drawn edge sits `gap` above Moku's head, and above the caption when one is
    /// showing beneath it. With no room above (Moku near the top of the screen) it hangs below Moku.
    /// The share of a bubble's width to the left of the companion's centre: it leans left, away from the screen's
    /// edge at home, and keeps that lean whatever its width (Moku's paper, Tetsu's wider display, a small thinking one).
    static let speechLean: CGFloat = 200 / 282
    static func speechOrigin(panel: CGRect, bubble: CGSize, visible: CGRect, gap: CGFloat, caption: CGRect?) -> CGPoint {
        let x = min(max((panel.midX - bubble.width * speechLean).rounded(), visible.minX + 8), visible.maxX - bubble.width - 8)
        var y = panel.minY + headTop * scale(of: panel) + gap - speechInset
        if let caption, caption.maxX > x, caption.minX < x + bubble.width { y = max(y, caption.maxY + 2 - speechInset) }
        if y + bubble.height > visible.maxY { y = panel.minY - bubble.height + speechInset }
        return CGPoint(x: x, y: max(visible.minY, y))
    }
    /// The direction from Moku's eyes to the centre of its display, in radians: yaw is positive
    /// to the right, pitch positive upward. The centre lies on the glass beside Moku, where a
    /// literal look would be a profile, so the target sits in front of the glass by a depth that
    /// scales with the display: a corner-to-centre look turns about 50° on any screen. The line
    /// of sight still passes exactly through the centre as seen by the user.
    static func centerGaze(eyes: CGPoint, screen: CGRect) -> SIMD2<Float> { gaze(eyes: eyes, at: CGPoint(x: screen.midX, y: screen.midY), screen: screen) }
    /// The eyes' turn toward a point on screen, for someone sitting about a third of the screen's width away.
    static func gaze(eyes: CGPoint, at point: CGPoint, screen: CGRect) -> SIMD2<Float> {
        let dx = point.x - eyes.x, dy = point.y - eyes.y, depth = screen.width * 0.35
        return SIMD2(Float(atan2(dx, depth)), Float(atan2(dy, hypot(dx, depth))))
    }
    public static func path(from: CGPoint, to: CGPoint, progress: Double) -> CGPoint {
        let t = min(1, max(0, progress)); let ease = t * t * (3 - 2 * t)
        return CGPoint(x: from.x + (to.x - from.x) * ease, y: from.y + (to.y - from.y) * ease)
    }
    public static func contains(_ point: CGPoint, ellipse: CGRect) -> Bool {
        guard ellipse.width > 0, ellipse.height > 0 else { return false }
        let x = (point.x - ellipse.midX) / (ellipse.width / 2)
        let y = (point.y - ellipse.midY) / (ellipse.height / 2)
        return x * x + y * y <= 1
    }
}
