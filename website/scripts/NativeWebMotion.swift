// Appended to a COPY of RealityCharacter.swift by export-motion.py. This gives
// the exporter access to the production pose driver without editing the app.
extension RealityCharacter {
    func webSample(mood: Mood, motion: String, age: Double) async throws -> CGImage {
        micro = nil; fidgeting = nil; hoverOn = false; hoverStrength = 0; earFlickAt = -100; displayMoment = nil
        let clip = motion == "pat" ? "pat_reaction" : motion == "wave" ? "wave" : nil  // the app's own gesture clips
        _ = try await auditFrame(mood: mood, clip: clip, seconds: age, user: true)
        let now = CACurrentMediaTime()
        switch motion {
        case "blink": blinkStartedAt = now - age  // the app's own blink (BlinkTiming), not a squeezed slow blink
        case "slow-blink": micro = .slowBlink; microStartedAt = now - age
        case "nose": micro = .nose; microStartedAt = now - age
        case "glance": micro = .gazePoint; microStartedAt = now - age
        case "pout": micro = .pout; microStartedAt = now - age
        case "ear-left", "ear-right":
            earFlickAt = now - age; earFlickLeft = motion == "ear-left"; earFlickSide = motion == "ear-left" ? 1 : -1
        case "paw": fidgeting = Fidget(kind: .pawShift, side: 1); fidgetAt = now - age
        case "foot": fidgeting = Fidget(kind: .footWiggle, side: -1); fidgetAt = now - age
        case "head": fidgeting = Fidget(kind: .headTilt, side: -1); fidgetAt = now - age
        case "scan": displayMoment = ("px_scan", now - age, ScanBeam.seconds)  // Tetsu's display while it scans (the beam is the site's, live-demo.css)
        case "hover-in", "hover-out":
            hoverOn = motion == "hover-in"; hoverChangedAt = now - age
            hoverStrength = Float(hoverOn ? 1 - exp(-14 * age) : exp(-14 * age))
        default: break
        }
        // dt=0 preserves the sampled hover envelope. All base face weights are
        // already settled by auditFrame; the production driver adds the motion.
        pose(time: 0, dt: 0)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do { try renderer.updateAndRender(deltaTime: 0, cameraOutput: output, onComplete: { _ in continuation.resume() }) }
            catch { continuation.resume(throwing: error) }
        }
        finishFrame()
        guard let image = lastImage else { throw CocoaError(.fileReadUnknown) }
        return image
    }

    func webTransition(from: Mood, to: Mood, age: Double, duration: Double) async throws -> CGImage {
        _ = try await auditTransition(from: from, to: to, progress: 0)
        moodDuration = duration; moodChangedAt = CACurrentMediaTime() - age
        pose(time: 0, dt: 1)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do { try renderer.updateAndRender(deltaTime: 0, cameraOutput: output, onComplete: { _ in continuation.resume() }) }
            catch { continuation.resume(throwing: error) }
        }
        finishFrame()
        guard let image = lastImage else { throw CocoaError(.fileReadUnknown) }
        return image
    }
}

@MainActor public enum MokuWebMotionExporter {
    public static func export(to directory: URL) async throws {
        guard let character = try await RealityCharacter.load() else { throw CocoaError(.fileReadUnknown) }
        struct Motion { let id: String; let mood: Mood; let action: String; let seconds: Double; let fps: Int }
        let motions: [Motion] = [
            .init(id: "content-idle", mood: .content, action: "idle", seconds: 0, fps: 1),
            .init(id: "content-blink", mood: .content, action: "blink", seconds: BlinkTiming.duration, fps: 60),
            .init(id: "content-slow-blink", mood: .content, action: "slow-blink", seconds: 0.7, fps: 30),
            .init(id: "content-nose", mood: .content, action: "nose", seconds: 0.4, fps: 50),
            .init(id: "content-glance", mood: .content, action: "glance", seconds: 1.2, fps: 30),
            .init(id: "content-ear-left", mood: .content, action: "ear-left", seconds: 1.1, fps: 50),
            .init(id: "content-ear-right", mood: .content, action: "ear-right", seconds: 1.1, fps: 50),
            .init(id: "content-paw", mood: .content, action: "paw", seconds: 2.6, fps: 24),
            .init(id: "content-foot", mood: .content, action: "foot", seconds: 1.8, fps: 30),
            .init(id: "content-head", mood: .content, action: "head", seconds: 3.2, fps: 24),
            .init(id: "content-hover-in", mood: .content, action: "hover-in", seconds: 1.7, fps: 50),
            .init(id: "content-hover-out", mood: .content, action: "hover-out", seconds: 0.45, fps: 50),
            .init(id: "content-pat", mood: .content, action: "pat", seconds: 1.5, fps: 50),
            .init(id: "content-wave", mood: .content, action: "wave", seconds: 53.0 / 24, fps: 24),  // the hello: the clip's own 24 fps, every frame a keyframe (30 fps repeated one frame in five)
            .init(id: "disappointed-idle", mood: .disappointed, action: "idle", seconds: 0, fps: 1),
            .init(id: "disappointed-blink", mood: .disappointed, action: "blink", seconds: BlinkTiming.duration, fps: 60),
            .init(id: "disappointed-slow-blink", mood: .disappointed, action: "slow-blink", seconds: 0.7, fps: 30),
            .init(id: "disappointed-pout", mood: .disappointed, action: "pout", seconds: 1, fps: 30),
            .init(id: "happy-idle", mood: .happy, action: "idle", seconds: 0, fps: 1),
            .init(id: "happy-ear-left", mood: .happy, action: "ear-left", seconds: 1.1, fps: 50),
            .init(id: "happy-paw", mood: .happy, action: "paw", seconds: 2.6, fps: 24),
            .init(id: "happy-head", mood: .happy, action: "head", seconds: 3.2, fps: 24),
        ] + (character.companion.isMachine ? [
            // Tetsu's talent: its display narrows and sweeps while it scans your window (RobotTalents.swift).
            .init(id: "content-scan", mood: .content, action: "scan", seconds: ScanBeam.seconds, fps: 30),
        ] : [])
        var manifest = [String: [String: Any]]()
        func save(_ image: CGImage, folder: URL, index: Int) throws {
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            try data.write(to: folder.appendingPathComponent(String(format: "%04d.png", index)))
        }
        func log(_ message: String) { FileHandle.standardOutput.write(Data((message + "\n").utf8)) }
        for motion in motions {
            let folder = directory.appendingPathComponent(motion.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let count = max(1, Int((motion.seconds * Double(motion.fps)).rounded()))
            for i in 0..<count {
                let age = Double(i) / Double(max(1, count - 1)) * motion.seconds
                try save(await character.webSample(mood: motion.mood, motion: motion.action, age: age), folder: folder, index: i)
            }
            manifest[motion.id] = ["seconds": motion.seconds, "frames": count, "fps": motion.fps]
            log("Captured \(motion.id): \(count) native frames")
        }
        let transitions: [(Mood, Mood, Double)] = [(.content, .disappointed, 3), (.disappointed, .happy, 0.6), (.happy, .content, 1.2), (.content, .happy, 0.8), (.disappointed, .content, 2.4), (.happy, .disappointed, 3)]
        for (from, to, seconds) in transitions {
            let id = "\(from.rawValue)-to-\(to.rawValue)"
            let folder = directory.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let count = Int(seconds * 50)
            for i in 0..<count {
                let age = Double(i) / Double(count - 1) * seconds
                try save(await character.webTransition(from: from, to: to, age: age, duration: seconds), folder: folder, index: i)
            }
            manifest[id] = ["seconds": seconds, "frames": count, "fps": 50]
            log("Captured \(id): \(count) native frames")
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("captures.json"))
    }
}
