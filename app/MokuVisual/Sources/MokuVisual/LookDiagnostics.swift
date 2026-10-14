import AppKit
import RealityKit
import MokuKit

extension MokuVisualDiagnostics {
    /// Look development (moku-look-v2.md): Moku front and three-quarter, in a few moods, through the app's own renderer
    /// at 2× (1280 px), as `front-<mood>.png` and `three-quarter-<mood>.png`. Three-quarter turns the whole character
    /// under the same studio, as it turns when it travels, with its face toward the left of the image like the concept
    /// sheet. Run with MOKU_ASSETS_DIR=<assets> to see edited assets before they're bundled.
    public static func lookPairs(stage: MokuCharacterStage, directory: URL) async throws {
        stage.setHidden(true)
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let renderer = stage.view.real else { throw CocoaError(.fileReadUnknown) }
        // The character entity is private to the renderer; a diagnostic only turns it and turns it back.
        guard let character = Mirror(reflecting: renderer).children.first(where: { $0.label == "character" })?.value as? Entity else { throw CocoaError(.fileReadUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        renderer.setAuditResolution(2)
        _ = try await renderer.auditFrame(mood: .content, clip: nil, seconds: 0, user: true)
        for (view, yaw) in [("front", Float(0)), ("three-quarter", Float(-0.55))] {
            character.orientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
            for mood in [Mood.content, .happy, .curious, .sleepy] {
                let (image, _) = try await renderer.auditFrame(mood: mood, clip: nil, seconds: 0, user: true)
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(view)-\(mood.rawValue).png"))
            }
        }
        character.orientation = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
        renderer.setAuditResolution(1)
    }
    /// The cost of a look change: 160 frames at the live size (640 px), alternating two moods so the face is re-uploaded
    /// every frame, timed from pose to the GPU's completion. The median resists other work on the Mac (look-cost.json).
    public static func lookCost(stage: MokuCharacterStage, directory: URL) async throws {
        stage.setHidden(true)
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let renderer = stage.view.real else { throw CocoaError(.fileReadUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        renderer.setAuditResolution(1)
        for _ in 0..<10 { _ = try await renderer.auditFrame(mood: .content, clip: nil, seconds: 0, user: true) }
        var times = [Double]()
        for i in 0..<160 {
            let started = CACurrentMediaTime()
            _ = try await renderer.auditFrame(mood: i.isMultiple(of: 2) ? .content : .happy, clip: nil, seconds: 0, user: true)
            times.append((CACurrentMediaTime() - started) * 1000)
        }
        let sorted = times.sorted()
        let report: [String: Any] = ["medianMs": sorted[sorted.count / 2], "p25Ms": sorted[sorted.count / 4], "meanMs": times.reduce(0, +) / Double(times.count)]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("look-cost.json"))
    }
}
