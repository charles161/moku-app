import AppKit
import RealityKit
import MokuKit

extension MokuVisualDiagnostics {
    /// "It feels pixellated kinda some bad edges" (Charles, 2026-10-14). The same frame (content, eyes on the user) through
    /// the app's renderer at 1×, 1.25×, 1.5× and 2× of the live 640 px (`render-<factor>.png`), and what each frame costs
    /// from pose to the GPU's completion, the median of 40 (sharpness.json). The renderer's own 4× multisampling is on at
    /// every size; a bigger render, scaled down on screen, smooths the eyes' and the mouth's edges further.
    public static func sharpness(stage: MokuCharacterStage, directory: URL) async throws {
        stage.setHidden(true)
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let renderer = stage.view.real else { throw CocoaError(.fileReadUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report: [String: Any] = [:]
        for factor in [1.0, 1.25, 1.5, 2.0] as [CGFloat] {
            renderer.setAuditResolution(factor)
            for _ in 0..<5 { _ = try await renderer.auditFrame(mood: .content, clip: nil, seconds: 0, user: true) }
            var times = [Double]()
            var last: CGImage?
            for i in 0..<40 {
                let started = CACurrentMediaTime()
                let (image, _) = try await renderer.auditFrame(mood: i.isMultiple(of: 2) ? .content : .happy, clip: nil, seconds: 0, user: true)
                times.append((CACurrentMediaTime() - started) * 1000)
                if !i.isMultiple(of: 2) { continue }
                last = image
            }
            let name = String(format: "%.2f", Double(factor))
            if let last { try NSBitmapImageRep(cgImage: last).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("render-\(name).png")) }
            let sorted = times.sorted()
            report[name] = ["pixels": renderer.textureSize, "medianMs": sorted[sorted.count / 2], "p90Ms": sorted[sorted.count * 9 / 10]]
        }
        renderer.setAuditResolution(1)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("sharpness.json"))
    }
}
