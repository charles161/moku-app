import AppKit
import AVFoundation
import MokuKit

/// Review-only encoding of actual app frames. Never used by the production idle loop.
@MainActor final class ReviewMovie {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let folder: URL
    let width: Int, height: Int, fps: Int32
    private var index: Int64 = 0
    init(url: URL, width: Int, height: Int, fps: Int32 = 24) throws {
        folder = url.deletingPathExtension(); self.width = width; self.height = height; self.fps = fps
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in (try? FileManager.default.contentsOfDirectory(at: folder,includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "png" { try FileManager.default.removeItem(at: file) }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 5_000_000]])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
    }
    func append(_ image: CGImage, at seconds: Double? = nil) async throws {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            try await Task.sleep(for: .milliseconds(2))
        }
        var pixel: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(pixel, []); defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(NSColor(calibratedRed: 0.965, green: 0.95, blue: 0.92, alpha: 1).cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard adaptor.append(pixel, withPresentationTime: seconds.map { CMTime(seconds: $0, preferredTimescale: 60000) } ?? CMTime(value: index, timescale: fps)) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        if index % 6 == 0 { try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(String(format: "%05lld.png", index))) }
        index += 1
    }
    func finish() async throws {
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}

extension MokuVisualDiagnostics {
    public static func quickFixMovie(stage: MokuCharacterStage, directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.setHidden(false); stage.setMood(.content); stage.setAttention(.user)
        let deadline = CACurrentMediaTime()+90
        while stage.totalRenderedFrames == 0 && stage.rendererError == nil && CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard stage.totalRenderedFrames > 0,stage.rendererError == nil else { throw CocoaError(.fileReadUnknown) }
        try await Task.sleep(for: .seconds(3))
        let movie = try ReviewMovie(url: directory.appendingPathComponent("ear-blink.mp4"), width: 640, height: 680)
        let start = CACurrentMediaTime()
        var lifted = false, lowered = false, blinked = false
        while CACurrentMediaTime() - start < 11 {
            let elapsed = CACurrentMediaTime() - start
            if elapsed >= 1 && !lifted { lifted = true; stage.setMood(.happy) }
            if elapsed >= 4.5 && !lowered { lowered = true; stage.setMood(.content) }
            if elapsed >= 8 && !blinked { blinked = true; stage.view.real?.microExpression(.slowBlink) }
            try await movie.append(stageImage(stage: stage), at: elapsed)
            try await Task.sleep(for: .seconds(1.0 / 24))
        }
        try await movie.finish(); stage.setHidden(true)
    }
}
