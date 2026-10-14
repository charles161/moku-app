import CoreGraphics
import Foundation
import Testing
@testable import MokuSense

@Suite struct OCRPipelineTests {
    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).map(String.init)
    }

    /// Share of the true tokens found in the OCR output, each found token used once.
    static func recall(truth: String, recognized: String) -> Double {
        var found: [String: Int] = [:]
        for token in tokens(recognized) { found[token, default: 0] += 1 }
        let wanted = tokens(truth)
        var hits = 0
        for token in wanted where (found[token] ?? 0) > 0 {
            found[token]! -= 1
            hits += 1
        }
        return Double(hits) / Double(wanted.count)
    }

    @Test func recognizesCodeOnARetinaWindow() throws {
        let window = TestImages.window(showing: TestImages.code)
        #expect(window.width == 2880 && window.height == 1800)
        let started = Date()
        let lines = try TextRecognizer.recognizeLines(in: window)
        let elapsed = Date().timeIntervalSince(started)
        let recall = Self.recall(truth: TestImages.code, recognized: lines.joined(separator: "\n"))
        #expect(recall >= 0.90, "token recall \(recall)")
        // Reading order: the first line of the file comes first, the last comes last.
        #expect(lines.first?.contains("import") == true)
        #expect(lines.last?.contains("ActivitySample") == true)
        print(String(format: "OCR: %d lines, token recall %.1f%%, %.0f ms (first run includes model load)",
                     lines.count, recall * 100, elapsed * 1000))
    }

    @Test func readingOrderIsRowsTopToBottomThenLeftToRight() {
        // Vision boxes: origin bottom-left, y up.
        let lines: [ReadingOrder.Line] = [
            .init(box: CGRect(x: 0.5, y: 0.80, width: 0.3, height: 0.02), text: "top right"),
            .init(box: CGRect(x: 0.1, y: 0.10, width: 0.3, height: 0.02), text: "bottom"),
            .init(box: CGRect(x: 0.1, y: 0.805, width: 0.3, height: 0.02), text: "top left"),
            .init(box: CGRect(x: 0.1, y: 0.50, width: 0.3, height: 0.02), text: "middle"),
        ]
        #expect(ReadingOrder.sorted(lines) == ["top left", "top right", "middle", "bottom"])
    }
}
