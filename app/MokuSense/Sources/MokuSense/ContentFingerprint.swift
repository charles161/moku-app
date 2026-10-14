import CoreGraphics

/// A cheap perceptual hash of a window: its brightness on a coarse grid. Two captures of the
/// same content (a blinking caret, a clock ticking, compression noise) come out "similar";
/// a scroll, a new line of text or a different page do not. Decides whether OCR must run again.
struct ContentFingerprint: Sendable, Equatable {
    static let columns = 64
    static let rows = 40
    /// A cell counts as changed when its mean brightness moves by more than this (0–255).
    static let cellThreshold = 12
    /// Content counts as changed when at least this many cells changed (~0.25% of the grid).
    static let changedCellsThreshold = 6

    let cells: [UInt8]

    /// Nil only if the image cannot be drawn.
    init?(image: CGImage) {
        var cells = [UInt8](repeating: 0, count: Self.columns * Self.rows)
        let drawn = cells.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: Self.columns, height: Self.rows,
                                          bitsPerComponent: 8, bytesPerRow: Self.columns,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: Self.columns, height: Self.rows))
            return true
        }
        guard drawn else { return nil }
        self.cells = cells
    }

    /// Number of grid cells whose brightness changed noticeably.
    func changedCells(comparedTo other: ContentFingerprint) -> Int {
        zip(cells, other.cells).reduce(0) { count, pair in
            abs(Int(pair.0) - Int(pair.1)) > Self.cellThreshold ? count + 1 : count
        }
    }

    func isSimilar(to other: ContentFingerprint) -> Bool {
        changedCells(comparedTo: other) < Self.changedCellsThreshold
    }
}
