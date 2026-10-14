import AppKit
import MokuKit

extension MokuVisualDiagnostics {
    /// Stills for the welcome concepts' storyboards (assets/previews/welcome-wow): the current companion (MOKU_COMPANION),
    /// through the app's own renderer at twice the size, in the poses the concepts need. It looks at you, at the pointer,
    /// down at a window beside it and up at the menu bar; it waves, cheers, hops, sleeps, yawns and stretches; and Tetsu's
    /// display boots, scans and shows a heart, with its scan beam and hologram as Core Animation lays them. Transparent
    /// PNGs, so the storyboards can stand them on any desk. Concept tooling: nothing in the app calls it.
    public static func welcomeWowFrames(stage: MokuCharacterStage, directory: URL) async throws {
        stage.setHidden(true)
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let renderer = stage.view.real else { throw CocoaError(.fileReadUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        renderer.setAuditResolution(2)
        func save(_ image: CGImage, _ name: String) throws {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
        }
        let held: [(String, Mood, SIMD2<Float>, Bool)] = [
            ("you", .content, .zero, true), ("happy", .happy, .zero, true), ("curious", .curious, .zero, true),
            ("proud", .proud, .zero, true), ("sleepy", .sleepy, .zero, false), ("disappointed", .disappointed, .zero, true),
            ("look-left", .content, SIMD2(-0.55, 0), false), ("look-right", .content, SIMD2(0.55, 0), false),
            ("look-down-left", .content, SIMD2(-0.5, -0.35), false), ("look-down-right", .content, SIMD2(0.5, -0.35), false),
            ("look-up-right", .content, SIMD2(0.45, 0.6), false), ("look-up-left", .content, SIMD2(-0.45, 0.6), false),
            ("curious-left", .curious, SIMD2(-0.5, -0.2), false), ("happy-up-right", .happy, SIMD2(0.45, 0.6), false),
        ]
        for (name, mood, gaze, user) in held {
            try save(try await renderer.auditFrame(mood: mood, clip: nil, seconds: 0, gaze: gaze, user: user).0, name)
        }
        let clips: [(String, Mood, [Double])] = [
            ("hello_wave", .content, [0.2, 0.35, 0.5, 0.65]), ("cheer", .happy, [0.3, 0.5]), ("big_celebrate", .happy, [0.35, 0.55]),
            ("hop", .content, [0.2, 0.4, 0.6]), ("sleep_loop", .sleepy, [0.0, 0.5]), ("yawn", .sleepy, [0.4, 0.6]),
            ("stretch", .content, [0.45, 0.6]), ("nod", .happy, [0.4]), ("look_around", .curious, [0.3, 0.7]), ("pat_reaction", .happy, [0.5]),
        ]
        for (clip, mood, fractions) in clips {
            guard let (_, duration) = try? await renderer.auditFrame(mood: mood, clip: clip, seconds: 0, user: true) else { continue }
            for fraction in fractions {
                try save(try await renderer.auditFrame(mood: mood, clip: clip, seconds: duration * fraction, user: true).0, "\(clip)-\(Int(fraction * 100))")
            }
        }
        if stage.companion?.isMachine == true {
            let moments: [(String, [String: Float], SIMD2<Float>, Bool)] = [
                ("off", ["px_boot": 0.01], .zero, true), ("boot-1", ["px_boot": 0.2], .zero, true), ("boot-2", ["px_boot": 0.42], .zero, true),
                ("boot-3", ["px_boot": 0.66], .zero, true), ("boot-4", ["px_boot": 0.82], .zero, true),
                ("scan-left-1", ["px_scan": 0.3, "eyes_narrow": 0.8], SIMD2(-0.5, -0.2), false), ("scan-left-2", ["px_scan": 0.62, "eyes_narrow": 0.8], SIMD2(-0.5, -0.2), false),
                ("heart", ["px_heart": 1], .zero, true), ("thinking", ["px_spin": 0.3], .zero, true),
            ]
            for (name, values, gaze, user) in moments {
                renderer.displayOverrides = values
                try save(try await renderer.auditFrame(mood: .content, clip: nil, seconds: 0, gaze: gaze, user: user).0, name)
            }
            renderer.displayOverrides = [:]
            if let parent = renderer.imageLayer.superlayer {
                func layers(_ name: String) throws {
                    let scale: CGFloat = 2, size = parent.bounds.size
                    let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.scaleBy(x: scale, y: scale); parent.render(in: context)
                    try save(context.makeImage()!, name)
                }
                renderer.setAuditResolution(1)
                _ = try await renderer.auditFrame(mood: .content, clip: nil, seconds: 0, gaze: SIMD2(-0.5, 0.2))
                renderer.playDisplayMoment("px_scan")
                try layers("talent-scan")
                _ = try await renderer.auditFrame(mood: .happy, clip: nil, seconds: 0, user: true)
                renderer.showHologram(units: 16)
                try layers("talent-hologram")
            }
        }
        renderer.setAuditResolution(1)
        renderer.stop()
    }
}
