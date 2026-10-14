import AppKit
import SwiftUI
import MokuKit

/// Tetsu's break timer (launch QA, lens 4: Moku's paper capsule and Tetsu's were the same pill). The time left lit in
/// dots on a strip of display glass, in its white shell like its label and its bubble; a row of dots under it that go
/// out as the break runs down, a ✕ at the end of the strip, and amber for the last minute. Drawn once a second.
enum LEDBreak {
    static let pitch: CGFloat = 2
    /// The strip's height in points, and how wide the ✕'s end is.
    static let height: CGFloat = 34, crossWidth: CGFloat = 26

    /// The lit dots: the time, the progress row under it (as wide as the time) and the ✕ at the right.
    @MainActor static func dots(text: String, fraction: Double) -> (dots: [DotFont.Dot], timeColumns: Int, columns: Int, rows: Int) {
        let time = DotText(text, width: 80, maxLines: 1)
        var dots = time.dots, columns = time.width
        let top = dots.map(\.y).min() ?? 0, bottom = dots.map(\.y).max() ?? 0
        dots = dots.map { DotFont.Dot(x: $0.x, y: $0.y - top, level: $0.level) }
        let textRows = bottom - top + 1
        // Under it, a dot for each step of the break left: lit ones bright, the rest faint.
        let steps = max(8, columns / 3), lit = Int((max(0, min(1, fraction)) * Double(steps)).rounded(.up))
        let barY = textRows + 2
        for i in 0..<steps {
            let x = Int((Double(i) + 0.5) / Double(steps) * Double(columns)) - 1
            dots.append(DotFont.Dot(x: max(0, x), y: barY, level: i < lit ? 1 : 0.22))
            dots.append(DotFont.Dot(x: max(0, x) + 1, y: barY, level: i < lit ? 1 : 0.22))
        }
        let timeColumns = columns
        // The ✕, a gap after the time: two diagonals five dots across.
        let crossX = columns + 5
        for k in 0..<5 {
            dots.append(DotFont.Dot(x: crossX + k, y: (textRows - 5) / 2 + k, level: 0.55))
            dots.append(DotFont.Dot(x: crossX + 4 - k, y: (textRows - 5) / 2 + k, level: 0.55))
        }
        columns = crossX + 5
        return (dots, timeColumns, columns, barY + 1)
    }

    /// The strip as a picture, `scale` pixels to the point, and its size in points.
    @MainActor static func strip(text: String, fraction: Double, urgent: Bool, dark: Bool, scale: CGFloat) -> (CGSize, CGImage?) {
        let built = dots(text: text, fraction: fraction)
        let margin = DotPainter.glowMargin, color = urgent ? SpeechInk.amber : SpeechInk.cyan
        let shell: CGFloat = 3, padding: CGFloat = 10, card = CGRect(x: 3, y: 4, width: 0, height: height - 8)
        let width = CGFloat(built.columns) * pitch
        let cardWidth = width + 2 * (shell + padding)
        let size = CGSize(width: cardWidth + 2 * card.minX, height: height)
        let lit = DotPainter.image(built.dots, columns: built.columns, rows: built.rows, pitch: pitch, color: color, glow: 1, margin: margin, scale: scale)
        let image = SpeechBubbleView.image(size: size, scale: scale) { _ in
            let strip = CGRect(x: card.minX, y: card.minY, width: cardWidth, height: card.height)
            let shellShape = NSBezierPath(roundedRect: strip, xRadius: strip.height / 2, yRadius: strip.height / 2)
            NSGraphicsContext.saveGraphicsState()
            let drop = NSShadow(); drop.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.45 : 0.2); drop.shadowBlurRadius = 3
            drop.shadowOffset = NSSize(width: 0, height: -1); drop.set()
            (dark ? NSColor(srgbRed: 0.22, green: 0.23, blue: 0.25, alpha: 1) : NSColor(srgbRed: 0.93, green: 0.93, blue: 0.915, alpha: 1)).setFill(); shellShape.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(dark ? 0.5 : 0.16).setStroke(); shellShape.lineWidth = 0.75; shellShape.stroke()
            let glass = strip.insetBy(dx: shell, dy: shell)
            let glassShape = NSBezierPath(roundedRect: glass, xRadius: glass.height / 2, yRadius: glass.height / 2)
            NSGradient(colors: [NSColor(srgbRed: 0.035, green: 0.05, blue: 0.065, alpha: 1), NSColor(srgbRed: 0.008, green: 0.012, blue: 0.018, alpha: 1)])?.draw(in: glassShape, angle: -90)
            guard let context = NSGraphicsContext.current?.cgContext, let lit else { return }
            let height = CGFloat(built.rows) * pitch
            let origin = CGPoint(x: glass.minX + padding, y: (glass.midY - height / 2).rounded())
            context.draw(lit, in: CGRect(x: origin.x - margin, y: origin.y - margin, width: width + 2 * margin, height: height + 2 * margin))
        }
        return (size, image)
    }
}

/// The view in the break panel for a machine: the strip, with the ✕ over its end taking the click (it ends the break).
struct LEDBreakTimerView: View {
    let model: BreakTimerModel
    var onEnd: () -> Void = {}
    var body: some View {
        let strip = LEDBreak.strip(text: model.text, fraction: model.fraction, urgent: model.remaining < 60 && model.remaining > 0, dark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua, scale: 2)
        ZStack(alignment: .trailing) {
            // (On a 1× display the 2× picture is filtered down, not dropped to nearest dots.)
            if let image = strip.1 { Image(decorative: image, scale: 2).interpolation(.high) }
            Button(action: onEnd) { Color.clear.frame(width: LEDBreak.crossWidth + 8, height: strip.0.height) }
                .buttonStyle(.plain).contentShape(Rectangle()).help("End the break").accessibilityLabel("End the break")
        }
        .frame(width: strip.0.width, height: strip.0.height)
        .accessibilityElement(children: .contain).accessibilityLabel("On a break, \(model.text) left")
    }
}
