import AppKit
import MokuKit

/// The menu bar's house: filled from the bottom with as much of its own shape as today's house is built, the popover's
/// percent. The line is set by the symbol's ink, not its height: the roof's tip holds little of it. Before (a friend's
/// screenshot, 2026-10-06), the fill went up in eighths of the 18 pt square, rounded up, and at 69% showed 93% of the
/// house.
@MainActor
enum MenuBarHouse {
    static let size = CGSize(width: 18, height: 18)
    static let symbol = NSImage(systemSymbolName: "house.fill", accessibilityDescription: "Today’s house")
    /// The symbol's ink in each pixel row, bottom row first, measured once at 4x.
    static let ink: [Double] = measureInk()

    /// The height (points from the icon's bottom) the fill reaches at `fraction` of today's house.
    static func fillLine(_ fraction: Double, ink: [Double] = ink, height: CGFloat = size.height) -> CGFloat {
        let total = ink.reduce(0, +)
        guard fraction > 0 else { return 0 }
        guard fraction < 1 else { return height }
        guard total > 0 else { return height * CGFloat(fraction) }  // the symbol couldn't be measured: by height, never empty
        let goal = total * fraction
        var below = 0.0
        for (row, amount) in ink.enumerated() {
            if below + amount >= goal {
                let within = amount > 0 ? (goal - below) / amount : 0
                return (CGFloat(row) + CGFloat(within)) * height / CGFloat(ink.count)
            }
            below += amount
        }
        return height
    }

    /// How much of the house's ink lies below `line`.
    static func inkFraction(below line: CGFloat, ink: [Double] = ink, height: CGFloat = size.height) -> Double {
        let total = ink.reduce(0, +)
        guard total > 0 else { return 0 }
        let rows = Double(line / height) * Double(ink.count)
        let whole = max(0, min(ink.count, Int(rows)))
        var below = ink[..<whole].reduce(0, +)
        if whole < ink.count { below += ink[whole] * (rows - Double(whole)) }
        return below / total
    }

    /// The symbol drawn at the icon's size, `scale` pixels a point, and its ink (alpha) summed per row.
    static func measureInk(scale: Int = 4) -> [Double] {
        let width = Int(size.width) * scale, height = Int(size.height) * scale
        guard let symbol, let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                         bytesPerRow: 0, bitsPerPixel: 0) else { return [] }
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        symbol.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        // The bitmap's row 0 is the top.
        return (0..<height).map { row in
            let y = height - 1 - row
            return (0..<width).reduce(0) { $0 + Double(bitmap.colorAt(x: $1, y: y)?.alphaComponent ?? 0) }
        }
    }
}
