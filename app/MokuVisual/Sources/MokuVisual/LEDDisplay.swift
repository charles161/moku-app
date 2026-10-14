import AppKit

/// Text laid out in Tetsu's dots (DotFont): glyphs in reading order, wrapped into lines `width` dots wide. Spaces are
/// glyphs too, so typing pauses on them the way a terminal's does.
struct DotText {
    struct Placed { var glyph: DotFont.Glyph; var x: Int; var line: Int; var isSpace = false }
    private(set) var glyphs: [Placed] = []
    private(set) var lineWidths: [Int] = [0]
    var width: Int { lineWidths.max() ?? 0 }
    var lines: Int { lineWidths.count }
    /// The rows the block takes, from a capital's accent on the first line to the last line's descender.
    var rows: Int { (lines - 1) * DotFont.lineRows + 9 - DotFont.topRow }

    /// Words wrap at `width`; a word longer than a line breaks. Past `maxLines` the last line ends in "…".
    @MainActor init(_ text: String, width maxWidth: Int, maxLines: Int = 8) {
        var x = 0
        for (index, paragraph) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { newLine(&x) }
            for word in paragraph.split(separator: " ") {
                let shapes = word.map { DotFont.glyph($0) ?? DotFont.drawn($0) }
                let wordWidth = shapes.reduce(0) { $0 + $1.width } + shapes.count - 1
                if x > 0 && x + DotFont.Glyph.space.width + 1 + wordWidth > maxWidth { newLine(&x) }
                else if x > 0 { place(.space, at: &x, isSpace: true) }
                for shape in shapes {
                    if x > 0 && x + shape.width > maxWidth { newLine(&x) }
                    place(shape, at: &x)
                }
            }
        }
        guard lines > maxLines, let ellipsis = DotFont.glyph("…") else { return }
        glyphs.removeAll { $0.line >= maxLines }
        lineWidths.removeLast(lines - maxLines)
        while let last = glyphs.last, last.line == maxLines - 1, last.isSpace || last.x + last.glyph.width + 1 + ellipsis.width > maxWidth {
            glyphs.removeLast()
        }
        x = glyphs.last.map { $0.line == maxLines - 1 ? $0.x + $0.glyph.width + 1 : 0 } ?? 0
        place(ellipsis, at: &x)
    }
    /// The ask's last line: Tetsu's prompt, waiting for you (">", then the cursor).
    @MainActor mutating func appendPrompt() {
        var x = 0
        newLine(&x)
        if let prompt = DotFont.glyph(">") { place(prompt, at: &x) }
    }
    private mutating func newLine(_ x: inout Int) { lineWidths.append(0); x = 0 }
    private mutating func place(_ glyph: DotFont.Glyph, at x: inout Int, isSpace: Bool = false) {
        glyphs.append(Placed(glyph: glyph, x: x, line: lines - 1, isSpace: isSpace))
        if !isSpace { lineWidths[lines - 1] = x + glyph.width }
        x += glyph.width + 1
    }
    /// Every lit dot, in rows from the block's top (a capital's accent on the first line is row 0).
    var dots: [DotFont.Dot] {
        glyphs.flatMap { placed in
            placed.glyph.dots.map { DotFont.Dot(x: placed.x + $0.x, y: placed.line * DotFont.lineRows + $0.y - DotFont.topRow, level: $0.level) }
        }
    }
    /// The lit dots of the first `count` glyphs only: the line typed that far.
    func dots(typed count: Int) -> [DotFont.Dot] {
        glyphs.prefix(max(0, count)).flatMap { placed in
            placed.glyph.dots.map { DotFont.Dot(x: placed.x + $0.x, y: placed.line * DotFont.lineRows + $0.y - DotFont.topRow, level: $0.level) }
        }
    }
    /// Where the cursor stands once `typed` glyphs are out: the column after the last one, on its line.
    func cursor(after typed: Int) -> (x: Int, line: Int) {
        guard typed > 0 else { return (0, 0) }
        let last = glyphs[min(typed, glyphs.count) - 1]
        return (last.x + last.glyph.width + 1, last.line)
    }
}

/// Draws lit dots the way Tetsu's face does (PixelFace): square dots a little narrower than their cell, corners
/// softened, the last row of each dot dimmer so the rows read as scanlines, and a soft glow bleeding into the gaps.
/// Everything is drawn once into a static image; nothing is redrawn per frame.
enum DotPainter {
    /// The glow's reach, in points, around lit dots.
    static let glowMargin: CGFloat = 6

    /// An image of `dots` in a grid `columns` × `rows` of `pitch`-point cells, with `margin` points of room around it
    /// for the glow, at `scale` pixels per point. `glow` 0 draws the dots alone.
    static func image(_ dots: [DotFont.Dot], columns: Int, rows: Int, pitch: CGFloat, color: NSColor, glow: CGFloat,
                      margin: CGFloat, scale: CGFloat) -> CGImage? {
        let cell = max(1, Int((pitch * scale).rounded())), pad = Int((margin * scale).rounded())
        let width = columns * cell + 2 * pad, height = rows * cell + 2 * pad
        guard width > 0, height > 0, let plain = pixels(dots, width: width, height: height, cell: cell, pad: pad, color: color) else { return nil }
        guard glow > 0 else { return plain }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return plain }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        // Blur is in pixels here (the context isn't scaled), so it's the same size in points on any display.
        context.setShadow(offset: .zero, blur: 3.2 * scale, color: color.withAlphaComponent(0.95 * glow).cgColor)
        context.draw(plain, in: rect)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.draw(plain, in: rect)
        return context.makeImage()
    }

    /// The dots alone, pixel by pixel: no blending or antialiasing, so each dot is crisp at 1× and 2×.
    private static func pixels(_ dots: [DotFont.Dot], width: Int, height: Int, cell: Int, pad: Int, color: NSColor) -> CGImage? {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = Float(rgb.redComponent), g = Float(rgb.greenComponent), b = Float(rgb.blueComponent), a = Float(rgb.alphaComponent)
        // A dot three quarters of its cell where there's room (2×: 3 of 4 pixels); a whole cell below that (1×), so it
        // stays bright, its last row still dimmer.
        let size = cell >= 4 ? cell * 3 / 4 : cell
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for dot in dots {
            let left = pad + dot.x * cell, top = pad + dot.y * cell
            for j in 0..<size { for i in 0..<size {
                let x = left + i, y = top + j
                guard x >= 0, x < width, y >= 0, y < height else { continue }
                var level = dot.level * a
                if size >= 3 && (i == 0 || i == size - 1) && (j == 0 || j == size - 1) { level *= 0.45 }
                if size >= 2 && j == size - 1 { level *= 0.62 }
                let k = (y * width + x) * 4
                let alpha = max(Float(bytes[k + 3]) / 255, level)
                bytes[k] = UInt8(min(255, r * alpha * 255)); bytes[k + 1] = UInt8(min(255, g * alpha * 255))
                bytes[k + 2] = UInt8(min(255, b * alpha * 255)); bytes[k + 3] = UInt8(min(255, alpha * 255))
            }}
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
