import CoreGraphics
import Testing
@testable import MokuSense

@Suite struct ContentFingerprintTests {
    let base = TestImages.window(showing: TestImages.code)

    @Test func sameContentIsSimilar() throws {
        let first = try #require(ContentFingerprint(image: base))
        let again = try #require(ContentFingerprint(image: TestImages.window(showing: TestImages.code)))
        #expect(first.changedCells(comparedTo: again) == 0)
        #expect(first.isSimilar(to: again))
    }

    @Test func blinkingCaretIsSimilar() throws {
        let caret = TestImages.window(showing: TestImages.code) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 400, y: 300, width: 1, height: 17))
        }
        let before = try #require(ContentFingerprint(image: base))
        let after = try #require(ContentFingerprint(image: caret))
        #expect(before.isSimilar(to: after))
    }

    @Test func oneTypedCharacterIsSimilar() throws {
        let typed = TestImages.window(showing: TestImages.code + "x")
        let before = try #require(ContentFingerprint(image: base))
        #expect(before.isSimilar(to: try #require(ContentFingerprint(image: typed))))
    }

    @Test func aNewLineOfTextIsAChange() throws {
        let typed = TestImages.window(showing: TestImages.code + "\nexport const Feedback = z.object({ kind: FeedbackKind });")
        let before = try #require(ContentFingerprint(image: base))
        #expect(!before.isSimilar(to: try #require(ContentFingerprint(image: typed))))
    }

    @Test func scrollingIsAChange() throws {
        let scrolled = TestImages.window(showing: TestImages.code.split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst(3).joined(separator: "\n"))
        let before = try #require(ContentFingerprint(image: base))
        #expect(!before.isSimilar(to: try #require(ContentFingerprint(image: scrolled))))
    }

    @Test func aDifferentScreenIsAChange() throws {
        let other = TestImages.window(showing: TestImages.otherCode)
        let before = try #require(ContentFingerprint(image: base))
        let after = try #require(ContentFingerprint(image: other))
        #expect(before.changedCells(comparedTo: after) > 100)
        #expect(!before.isSimilar(to: after))
    }

    /// In the app the fingerprint comes from a small ScreenCaptureKit capture, not the full window.
    /// Even a crude nearest-neighbour downscale to that size must keep a new line visible.
    @Test func changesSurviveTheThumbnailCapture() throws {
        func thumbnail(_ image: CGImage) -> CGImage {
            let width = Int(ScreenTextReader.thumbnailSize), height = width * image.height / image.width
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()!
        }
        let before = try #require(ContentFingerprint(image: thumbnail(base)))
        let sameAgain = try #require(ContentFingerprint(image: thumbnail(TestImages.window(showing: TestImages.code))))
        let newLine = try #require(ContentFingerprint(image: thumbnail(TestImages.window(
            showing: TestImages.code + "\nexport const Feedback = z.object({ kind: FeedbackKind });"))))
        #expect(before.isSimilar(to: sameAgain))
        #expect(!before.isSimilar(to: newLine))
    }
}
