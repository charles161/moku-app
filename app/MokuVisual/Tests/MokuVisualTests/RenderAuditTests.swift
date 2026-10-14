import AppKit
import Testing
@testable import MokuVisual

@Test func silhouetteGateRejectsClippingAndEvenOneDetachedPixel() {
    func image(_ boxes: [CGRect]) -> CGImage {
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        boxes.forEach { context.fill($0) }
        return context.makeImage()!
    }
    let body = CGRect(x: 8, y: 8, width: 16, height: 16)
    #expect(SilhouetteResult.analyze(image([body])).passes)
    #expect(!SilhouetteResult.analyze(image([body, CGRect(x: 2, y: 2, width: 1, height: 1)])).passes)
    #expect(!SilhouetteResult.analyze(image([CGRect(x: 0, y: 8, width: 20, height: 16)])).passes)
    #expect(!SilhouetteResult.analyze(image([])).passes)
}
