import CoreGraphics
import Vision

/// On-device OCR with Apple Vision in accurate mode: about 225–245 ms for a full 2940×1912 screen on an M4,
/// against 130–170 ms in fast mode, which garbles small grey text (sidebars, captions, timestamps) that Jev
/// relies on in apps without accessibility text. OCR runs at most every 9 s and only when the window changed,
/// so the difference is about 1% of one core. Synchronous; call it off the main thread.
enum TextRecognizer {
    static func recognizeLines(in image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> ReadingOrder.Line? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return ReadingOrder.Line(box: observation.boundingBox, text: text)
        }
        return ReadingOrder.sorted(lines)
    }
}

/// Puts recognized lines in reading order: rows top to bottom, and left to right within a row.
enum ReadingOrder {
    /// `box` is in Vision's normalized space: origin at the bottom-left, y up.
    struct Line: Sendable, Equatable {
        var box: CGRect
        var text: String
    }

    static func sorted(_ lines: [Line]) -> [String] {
        let topDown = lines.sorted { $0.box.midY > $1.box.midY }
        var rows: [[Line]] = []
        for line in topDown {
            // Same row when the vertical centers are within half a line height of the row's first line.
            if let first = rows.last?.first, abs(first.box.midY - line.box.midY) < max(first.box.height, line.box.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { row in row.sorted { $0.box.minX < $1.box.minX }.map(\.text) }
    }
}
