// Records only Moku's character window (never the rest of the screen) at up to 120 fps, for checking animation
// smoothness without capturing whatever else is open on the Mac.
//   swift scripts/record-moku-window.swift <seconds> <out-dir>
// Writes <out-dir>/frames.csv (frame, time, motion vs the previous frame, 0–255 mean) and every frame as a PNG.
// A held frame between two moving ones (motion near 0) is a stutter; one frame far above its neighbours is a snap.
// Needs Screen Recording permission for the terminal running it, and Moku running.
import ScreenCaptureKit
import CoreImage
import AppKit

let seconds = Double(CommandLine.arguments[1]) ?? 8
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

final class Sink: NSObject, SCStreamOutput {
    var rows: [String] = []
    var previous: [UInt8]?
    var start: Double?
    var index = 0
    let context = CIContext()
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        if start == nil { start = t }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels), stride = CVPixelBufferGetBytesPerRow(pixels)
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        var gray = [UInt8](repeating: 0, count: (w / 2) * (h / 2))
        for y in 0..<(h / 2) { for x in 0..<(w / 2) {
            let p = base + (y * 2) * stride + (x * 2) * 4
            gray[y * (w / 2) + x] = UInt8((Int(p[0]) + Int(p[1]) * 2 + Int(p[2])) / 4 * Int(p[3]) / 255)
        } }
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        var diff = 0.0
        if let previous { diff = zip(gray, previous).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(gray.count) }
        previous = gray
        rows.append(String(format: "%d,%.4f,%.3f", index, t - start!, diff))
        let image = CIImage(cvPixelBuffer: pixels).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        try? context.writePNGRepresentation(of: image, to: outDir.appendingPathComponent(String(format: "f%04d.png", index)), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        index += 1
    }
}

let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
guard let window = content.windows.first(where: { $0.owningApplication?.applicationName == "Moku" && $0.frame.width == 320 }) else {
    print("no Moku window"); exit(1)
}
let config = SCStreamConfiguration()
config.width = 640; config.height = 680
config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
config.showsCursor = false
config.pixelFormat = kCVPixelFormatType_32BGRA
let sink = Sink()
let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: nil)
try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "frames"))
try await stream.startCapture()
print("recording"); fflush(stdout)
try await Task.sleep(for: .seconds(seconds))
try await stream.stopCapture()
try (["frame,t,motion"] + sink.rows).joined(separator: "\n").write(to: outDir.appendingPathComponent("frames.csv"), atomically: true, encoding: .utf8)
print("frames", sink.rows.count)
