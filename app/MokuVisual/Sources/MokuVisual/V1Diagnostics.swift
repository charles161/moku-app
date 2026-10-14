import AppKit
import MokuKit

extension MokuVisualDiagnostics {
    public static func state(stage: MokuCharacterStage) -> [String: Any] {
        ["workState": stage.workState.rawValue, "glances": stage.totalDriftGlances,
         "displayedMood": stage.view.real?.displayedMood.rawValue ?? "none",
         "moodProgress": stage.view.real?.displayedMoodProgress ?? 1,
         "eyes": stage.view.real.map { [$0.displayedEyeLook.x, $0.displayedEyeLook.y] } ?? [],
         "attentionToUser": stage.view.real?.displayedAttentionToUser ?? false,
         "clips": stage.view.real?.clipHistory ?? [],
         "annoyedStrength": stage.view.real?.displayedAnnoyedStrength ?? 0,
         "looksAtUser": stage.view.real?.displayedLooksAtUser ?? false,
         "headRotation": stage.view.real.map { [$0.displayedHeadRotation.x, $0.displayedHeadRotation.y, $0.displayedHeadRotation.z, $0.displayedHeadRotation.w] } ?? [],
         "gazeHeldPoint": stage.workDirection.workPoint.map { [$0.x, $0.y] } ?? [],
         "carrying": stage.view.lantern.isCarried, "lanternBrightness": stage.view.lantern.phase.brightness,
         "saccades": stage.totalReadingSaccades, "microExpressions": stage.totalMicroExpressions,
         "symbol": stage.view.manpu.symbol ?? "none", "firstVisibleSource": stage.firstVisibleSource ?? "none",
         "error": stage.rendererError ?? "none"]
    }
    public static func silhouette(stage: MokuCharacterStage) -> Bool {
        guard let image = stage.view.real?.lastImage else { return false }
        return SilhouetteResult.analyze(image).passes
    }
    public static func settledLantern(stage: MokuCharacterStage) {
        stage.view.lantern.apply(stage.workState, reduced: stage.reduced, instant: true)
    }
    /// Composites the actual cached rig with the standing CA layers, offscreen.
    /// The sheet shows a representative manpu frame; timing is exercised separately.
    public static func captureStage(stage: MokuCharacterStage, to url: URL) throws {
        let image = try stageImage(stage: stage)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
    }
    public static func stageImage(stage: MokuCharacterStage) throws -> CGImage {
        let size = StageGeometry.size
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 3), pixelsHigh: Int(size.height * 3), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.scaleBy(x: 3, y: 3)
        let shadow = stage.view.puppet.shadow
        let origin = stage.view.puppet.root.frame.origin
        context.saveGState()
        context.translateBy(x: origin.x + shadow.frame.minX, y: origin.y + shadow.frame.minY)
        shadow.render(in: context)
        context.restoreGState()
        if let real = stage.view.real, let image = real.lastImage {
            let root = CALayer(), copy = CALayer(); root.frame = CGRect(origin: .zero, size: size)
            copy.bounds = real.imageLayer.bounds; copy.position = real.imageLayer.position
            copy.transform = (real.imageLayer.presentation() ?? real.imageLayer).transform; copy.contents = image
            root.addSublayer(copy); root.render(in: context)
        }

        stage.view.manpu.capture(in: context)
        guard let image = bitmap.cgImage else { throw CocoaError(.fileWriteUnknown) }; return image
    }
}

extension MokuVisualDiagnostics {
    public static func exerciseGrab(stage: MokuCharacterStage, directory: URL) async -> [String: Any] {
        let original = stage.panel.frame.origin
        let press = CGPoint(x: original.x + 130, y: original.y + 80)
        stage.beginGrab(at: press, press: press)
        for i in 1...12 {
            stage.dragGrab(to: CGPoint(x: press.x - CGFloat(i) * 8, y: press.y + CGFloat(i) * 5))
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? captureStage(stage: stage, to: directory.appendingPathComponent("picked-up.png"))
        let drop = stage.panel.frame.origin
        try? await Task.sleep(for: .milliseconds(160)); stage.releaseGrab()
        try? await Task.sleep(for: .milliseconds(700))
        let saved = stage.homeScreen().map { stage.homeOrigin(on: $0) } ?? .zero
        await stage.move(to: .near(CGPoint(x: press.x - 350, y: press.y + 120)))
        await stage.move(to: .home)
        let returned = stage.panel.frame.origin
        let cursor = CGPoint(x: returned.x + 130, y: returned.y + 80)
        stage.beginGrab(at: cursor, press: cursor)
        for i in 1...6 {
            stage.dragGrab(to: CGPoint(x: cursor.x - CGFloat(i) * 25, y: cursor.y + CGFloat(i) * 3))
            try? await Task.sleep(for: .milliseconds(16))
        }
        stage.releaseGrab(); try? await Task.sleep(for: .milliseconds(250))
        try? captureStage(stage: stage, to: directory.appendingPathComponent("dropped.png"))
        try? await Task.sleep(for: .seconds(3))
        try? captureStage(stage: stage, to: directory.appendingPathComponent("landed.png"))
        let result: [String: Any] = ["drop": [drop.x, drop.y], "savedHome": [saved.x, saved.y], "returnedHome": [returned.x, returned.y], "landed": [stage.panel.frame.minX, stage.panel.frame.minY], "error": stage.rendererError ?? "none"]
        stage.resetHome(); try? await Task.sleep(for: .seconds(8))
        return result
    }
}


extension MokuVisualDiagnostics {
    /// Look development (moku-look-v2.md): Moku in six moods, looking at you, rendered at 2× (look-<mood>.png), and
    /// the time per frame over 30 renders (look.json), to compare a change's look and cost.
    public static func lookCheck(stage: MokuCharacterStage, directory: URL) async throws {
        stage.setHidden(true)
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let renderer = stage.view.real else { throw CocoaError(.fileReadUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        renderer.setAuditResolution(2)
        _ = try await renderer.auditFrame(mood: .content, clip: nil, seconds: 0, user: true)
        for mood in [Mood.content, .happy, .curious, .disappointed, .annoyed, .sleepy] {
            let (image, _) = try await renderer.auditFrame(mood: mood, clip: nil, seconds: 0, user: true)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("look-\(mood.rawValue).png"))
        }
        renderer.setAuditResolution(1)
        _ = try await renderer.auditFrame(mood: .happy, clip: nil, seconds: 0, user: true)
        let started = CACurrentMediaTime()
        for i in 0..<30 { _ = try await renderer.auditFrame(mood: i.isMultiple(of: 2) ? .content : .happy, clip: nil, seconds: 0, user: true) }
        let report: [String: Any] = ["msPerFrame": (CACurrentMediaTime() - started) / 30 * 1000]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]).write(to: directory.appendingPathComponent("look.json"))
    }
    public static func auditFrames(stage: MokuCharacterStage, directory: URL) async throws {
        stage.setHidden(true)
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let renderer = stage.view.real, let root = MokuAssets.root else { throw CocoaError(.fileReadUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let clips = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("character/anims"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "usdz" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
        var report = [[String: Any]]()
        let quick = ProcessInfo.processInfo.environment["MOKU_AUDIT_QUICK"] == "1"
        for mood in Mood.allCases {
            for clip in ["idle"] + (quick ? ["big_celebrate"] : clips) {
                let folder = directory.appendingPathComponent(mood.rawValue + "-" + clip)
                let (_, duration) = try await renderer.auditFrame(mood: mood, clip: clip == "idle" ? nil : clip, seconds: 0)
                let count = clip == "idle" ? 1 : Int(ceil(duration * 12)) + 1
                var failures = [[String: Any]]()
                for index in 0..<count {
                    let time = min(duration, Double(index) / 12)
                    let (image, _) = try await renderer.auditFrame(mood: mood, clip: clip == "idle" ? nil : clip, seconds: time)
                    let result = SilhouetteResult.analyze(image)
                    if !result.passes {
                        failures.append(["frame": index,"seconds": time,"bounds": result.bounds,"components": result.components,"edgeClear": result.edgeClear])
                    }
                    if !result.passes || index == count / 2 || index == 0 {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(String(format:"%04d.png",index)))
                    }
                }
                report.append(["mood":mood.rawValue,"clip":clip,"frames":count,"duration":duration,"bindDelta":renderer.clipBindChecks[clip] ?? 0,"pass":failures.isEmpty,"failures":failures])
                let data = try JSONSerialization.data(withJSONObject:report, options:[.prettyPrinted,.sortedKeys])
                try data.write(to:directory.appendingPathComponent("clipping.json"))
            }
        }
        renderer.stop()
        if report.contains(where: { ($0["pass"] as? Bool) != true }) { throw CocoaError(.validationMissingMandatoryProperty) }
    }
}


extension MokuVisualDiagnostics {
    public static func feedback3(stage: MokuCharacterStage, directory: URL) async throws {
        stage.setHidden(true)
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let renderer = stage.view.real else { throw CocoaError(.fileReadUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, mood, gaze, user, clip, time) in [
            // The home corner of a 1470 x 956 display looking at its centre (radians).
            ("idle-focus", Mood.content, SIMD2<Float>(-0.83,0.42), false, Optional<String>.none, 0.0),
            ("looking-at-you", .content, .zero, true, nil, 0.0),
            ("drift", .disappointed, SIMD2<Float>(-0.83,0.42), false, nil, 0.0),
            ("gesture", .content, .zero, false, "big_celebrate", 0.75)
        ] {
            // Flush the previous native animation's stop/reset before capturing
            // the new idle articulation (the audit loop also has this warmup).
            _ = try await renderer.auditFrame(mood: mood, clip: clip, seconds: time, gaze: gaze, user: user)
            let (image, _) = try await renderer.auditFrame(mood: mood, clip: clip, seconds: time, gaze: gaze, user: user)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + "-rig.png"))
            stage.view.lantern.setHidden(false)
            stage.view.lantern.apply(name == "drift" ? .drifting : .focused, reduced: true, instant: true)
            try captureStage(stage: stage, to: directory.appendingPathComponent(name + ".png"))
        }
        renderer.stop()
    }
}

// Kept with diagnostics so a source-only integration cannot omit the audit type.

struct SilhouetteResult: Codable {
    let bounds: [Int]
    let components: [Int]
    let edgeClear: Bool
    var passes: Bool { edgeClear && components.count == 1 }
    static func analyze(_ image: CGImage) -> Self {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w*h*4)
        let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var mask = (0..<w*h).map { pixels[$0*4+3] > 0 }
        var sizes = [Int](), lowX = w, lowY = h, highX = -1, highY = -1
        for seed in mask.indices where mask[seed] {
            var queue = [seed], cursor = 0; mask[seed] = false
            while cursor < queue.count {
                let index = queue[cursor], x = index % w, y = index / w; cursor += 1
                lowX = min(lowX,x); lowY = min(lowY,y); highX = max(highX,x); highY = max(highY,y)
                for dy in -1...1 { for dx in -1...1 {
                    let nx = x+dx, ny = y+dy
                    guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                    let next = ny*w+nx
                    if mask[next] { mask[next] = false; queue.append(next) }
                } }
            }
            sizes.append(queue.count)
        }
        return .init(bounds: [lowX,lowY,highX+1,highY+1], components: sizes.sorted(by: >), edgeClear: lowX > 0 && lowY > 0 && highX < w-1 && highY < h-1)
    }
}
