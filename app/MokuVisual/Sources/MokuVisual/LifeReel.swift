import AppKit
import MokuKit

/// Moku's idle life, recorded the way the app drives it (the stage's own tick: blinks, ear flicks, fidgets, reading,
/// drift glances) through the app's renderer, offscreen. For checking micro-expressions frame by frame
/// (moku-look-v2.md, step 6) and what they cost.
extension MokuVisualDiagnostics {
    /// The moods a reel covers, and how the app is placed in each.
    static let lifeMoods: [Mood] = [.content, .happy, .disappointed, .sleepy]

    @MainActor static func placeForLife(_ stage: MokuCharacterStage, mood: Mood) {
        let screen = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let work = CGPoint(x: screen.midX - 120, y: screen.midY + 60)
        switch mood {
        case .disappointed:  // a drift: sad, looking at you
            stage.setWorkState(.noticing); stage.setMood(.disappointed); stage.setAttention(.user)
        case .sleepy:        // dozing through a break
            stage.setWorkState(.onBreak); stage.setMood(.sleepy); stage.setAttention(.wander)
        default:             // working: Moku reads the screen with you
            stage.setWorkState(.focused); stage.setMood(mood); stage.setAttention(.point(work))
        }
    }

    /// `--life-reel <dir>`: 30 s per mood (MOKU_LIFE_SECONDS to change it). Writes, per mood:
    /// - life-<mood>.mp4, the stage as composited (the layer's breath and cached replays included), 30 fps;
    /// - life-<mood>-rendered/r-<n>.png, every frame the renderer drew (full size); life-<mood>/, every sixth reel frame;
    /// - life-<mood>-events.csv, what happened when (blinks, darts, little moves, lids, fidgets, ear flicks);
/// - life-<mood>-frames.csv, one row per rendered frame: time, gap, largest joint turn (°), largest face-weight
    ///   step, image motion (mean 0–255 change vs the previous frame, as record-moku-window.swift), face rebuilt;
    /// and life.json: per mood, frames, face rebuilds, events, the stutters (a still frame between moving ones, or a
    /// dropped frame mid-move) and snaps (a frame far above its neighbours) found, and longestStillSeconds (nothing
    /// moving but the breath: no drawn frame that changed the picture, no move on the layer).
    public static func lifeReel(stage: MokuCharacterStage, directory: URL) async throws {
        try await runLife(stage: stage, directory: directory, record: true)
    }

    /// `--life-cpu <dir>`: the same states, 60 s each (MOKU_LIFE_SECONDS), recording nothing but cost: process CPU,
    /// frames drawn, face rebuilds and main-thread time per frame. life-cpu.json.
    public static func lifeCPU(stage: MokuCharacterStage, directory: URL) async throws {
        try await runLife(stage: stage, directory: directory, record: false)
    }

    @MainActor private static func runLife(stage: MokuCharacterStage, directory: URL, record: Bool) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let real = stage.view.real else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let seconds = Double(ProcessInfo.processInfo.environment["MOKU_LIFE_SECONDS"] ?? "") ?? (record ? 30 : 60)
        let moods = (ProcessInfo.processInfo.environment["MOKU_LIFE_MOODS"]?.split(separator: ",").compactMap { Mood(rawValue: String($0)) }) ?? lifeMoods
        stage.setHidden(false)
        try await Task.sleep(for: .seconds(3))
        var summary: [String: Any] = ["seconds": seconds, "date": ISO8601DateFormatter().string(from: .now)]
        for mood in moods {
            placeForLife(stage, mood: mood)
            try await Task.sleep(for: .seconds(6))  // the mood and gaze settle, reading starts
            let recorder = LifeRecorder(folder: record ? directory.appendingPathComponent("life-\(mood.rawValue)-rendered") : nil)
            let previous = real.onFrame
            real.onFrame = { previous?(); recorder.frame(real) }
            let counts = (blinks: real.blinkCount, micros: real.microCount, saccades: real.saccadeCount, rebuilds: real.faceRebuilds, held: real.faceChangesHeldBack, frames: real.renderedFrames, events: real.lifeEvents)
            let cpu0 = processCPUSeconds(), work0 = processWork(), began = CACurrentMediaTime()
            recorder.began = began
            while CACurrentMediaTime() - began < seconds {
                if record { recorder.sample(real.imageLayer, rendered: real.lastImage, layerMove: real.layerMoveUnderWay) }
                try await Task.sleep(for: .milliseconds(record ? 16 : 250))
            }
            let elapsed = CACurrentMediaTime() - began, cpu = (processCPUSeconds() - cpu0) / elapsed * 100
            // Work done (instructions retired by the whole process), steadier than CPU time on a busy Mac.
            let work = processWork(), instructions = Double(work.instructions &- work0.instructions) / 1e9
            real.onFrame = previous
            let costs = real.mainCosts.suffix(min(real.mainCosts.count, real.renderedFrames - counts.frames))
            var row: [String: Any] = [
                "cpuPercent": cpu, "seconds": elapsed, "instructionsBillions": instructions,
                "instructionsBillionsPerMinute": instructions / elapsed * 60,
                "renderedFrames": real.renderedFrames - counts.frames, "faceRebuilds": real.faceRebuilds - counts.rebuilds, "faceChangesHeldBack": real.faceChangesHeldBack - counts.held,
                "blinks": real.blinkCount - counts.blinks, "micros": real.microCount - counts.micros, "saccades": real.saccadeCount - counts.saccades,
                "lifeEvents": real.lifeEvents.merging(counts.events) { $0 - $1 },
                "mainMsPerFrame": costs.isEmpty ? 0 : costs.map { ($0.render + $0.finish) * 1000 }.reduce(0, +) / Double(costs.count),
                "error": real.error ?? "none"]
            if record {
                await recorder.finish()
                try recorder.writeCSV(to: directory.appendingPathComponent("life-\(mood.rawValue)-frames.csv"))
                let events = real.lifeLog.filter { $0.t >= began - 8 && $0.t <= began + elapsed }.map { String(format: "%.4f,%@", $0.t - began, $0.what) }
                try (["t,event"] + events).joined(separator: "\n").write(to: directory.appendingPathComponent("life-\(mood.rawValue)-events.csv"), atomically: true, encoding: .utf8)
                row.merge(recorder.verdict()) { a, _ in a }
                try await recorder.writeMovie(to: directory.appendingPathComponent("life-\(mood.rawValue).mp4"), seconds: elapsed)
                row["longestStillSeconds"] = recorder.longestStill(seconds: elapsed)
            }
            summary[mood.rawValue] = row
            NSLog("Life %@ %@: %@", record ? "reel" : "cpu", mood.rawValue, "\(row.filter { $0.key != "lifeEvents" })")
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent(record ? "life.json" : "life-cpu.json"))
        }
        stage.setHidden(true)
    }

    // processCPUSeconds() is shared with EnergyCheck.swift.
}

/// Collects a reel: every rendered frame (written to disk off the main thread, so recording can't stall the frames
/// being recorded) and the image layer as shown, 60 times a second.
@MainActor final class LifeRecorder {
    struct Frame { var t: Double; var gap: Double; var joints: Double; var face: Double; var motion: Double = 0; var rebuilt: Bool; var joint = "" }
    let folder: URL?
    var began = 0.0
    private(set) var frames: [Frame] = []
    private var lastJoints: [SIMD4<Float>]?
    private var lastFace: [String: Float] = [:]
    private var lastRebuilds = 0
    private var lastT: Double?
    /// The layer as shown: time, transform, its shift (the breath's lift, a lean's pivot), (for cached replays) which
    /// image, and whether a move on the layer was under way.
    private var samples: [(t: Double, transform: CATransform3D, shift: CGPoint, replay: ObjectIdentifier?, layerMove: Bool)] = []
    private var replays: [ObjectIdentifier: CGImage] = [:]
    private let queue = DispatchQueue(label: "moku.life.writer")
    private let motion = MotionMeter()
    init(folder: URL?) {
        self.folder = folder
        if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    }
    func frame(_ real: RealityCharacter) {
        // When the frame was posed (what it shows), not when the GPU finished it.
        let t = (real.frameCosts.last?.start ?? CACurrentMediaTime()) - began
        let named = real.jointsForDiagnostics, joints = named.map { $0.1.rotation.vector }
        func degrees(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Double { Double(2 * acos(min(1, abs((a * b).sum())))) * 180 / .pi }
        let turns = lastJoints.map { zip($0, joints).map { degrees($0, $1) } } ?? []
        let turn = turns.max() ?? 0, which = turns.firstIndex(of: turn).map { named[$0].0 } ?? ""
        let face = real.shownFace
        let step = Set(face.keys).union(lastFace.keys).map { Double(abs((face[$0] ?? 0) - (lastFace[$0] ?? 0))) }.max() ?? 0
        let rebuilt = real.faceRebuilds != lastRebuilds
        frames.append(Frame(t: t, gap: lastT.map { t - $0 } ?? 0, joints: turn, face: frames.isEmpty ? 0 : step, rebuilt: frames.isEmpty ? false : rebuilt, joint: which))
        lastJoints = joints; lastFace = face; lastRebuilds = real.faceRebuilds; lastT = t
        guard let folder, let image = real.lastImage else { return }
        let index = frames.count - 1
        let meter = motion
        queue.async {
            meter.add(index: index, image: LifeRecorder.scaled(image, side: 320))
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(String(format: "r-%05d.png", index)))
        }
    }
    /// `rendered`: the frame the renderer last drew; anything else on the layer is a cached replay.
    func sample(_ layer: CALayer, rendered: CGImage?, layerMove: Bool) {
        let shown = layer.presentation() ?? layer
        var replay: ObjectIdentifier?
        if let contents = shown.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID {
            let image = contents as! CGImage
            if image !== rendered { let id = ObjectIdentifier(image); replays[id] = image; replay = id }
        }
        let shift = CGPoint(x: shown.position.x - layer.position.x, y: shown.position.y - layer.position.y)
        samples.append((CACurrentMediaTime() - began, shown.transform, shift, replay, layerMove))
    }
    /// The longest stretch (s) in which nothing moved but the breath: no drawn frame that changed the picture at all
    /// (a paw shift is about 0.01, a blink 0.1) and no move on the layer.
    func longestStill(seconds: Double) -> Double {
        let moving = (frames.filter { $0.motion > 0.005 }.map(\.t) + samples.filter(\.layerMove).map(\.t)).filter { $0 >= 0 && $0 <= seconds }.sorted()
        return zip([0] + moving, moving + [seconds]).map { $1 - $0 }.max() ?? seconds
    }
    func finish() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
        let values = motion.values
        for i in frames.indices { frames[i].motion = values[i] ?? 0 }
    }
    func writeCSV(to url: URL) throws {
        let rows = frames.enumerated().map { String(format: "%d,%.4f,%.1f,%.3f,%.4f,%.3f,%d,%@", $0, $1.t, $1.gap * 1000, $1.joints, $1.face, $1.motion, $1.rebuilt ? 1 : 0, $1.joint) }
        try (["frame,t,gap_ms,joint_deg,face_step,motion,rebuilt,joint"] + rows).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    /// Stutters and snaps among the rendered frames, measured on what you see (image motion).
    func verdict() -> [String: Any] {
        var stutters: [String] = [], snaps: [String] = []
        let gaps = frames.dropFirst().map(\.gap).filter { $0 < 0.1 }.sorted()
        let nominal = gaps.isEmpty ? 1.0 / 30 : gaps[gaps.count / 2]
        for i in frames.indices.dropFirst().dropLast() {
            let a = frames[i - 1], f = frames[i], b = frames[i + 1]
            // A still frame between two moving ones, inside one burst of frames.
            if f.motion < 0.02, a.motion > 0.15, b.motion > 0.15, f.gap < 0.1, b.gap < 0.1 { stutters.append(String(format: "%.2fs still", f.t)) }
            // A frame that arrives late while Moku is moving: the one before it was held on screen.
            if f.gap > 2.5 * nominal, f.gap < 0.25, a.motion > 0.15, f.motion > 0.15 { stutters.append(String(format: "%.2fs held %.0f ms", f.t, f.gap * 1000)) }
            let around = frames[max(0, i - 3)..<min(frames.count, i + 4)].enumerated().filter { $0.offset != min(3, i) }.map(\.element.motion).sorted()
            let typical = around.isEmpty ? 0 : around[around.count / 2]
            if f.motion > 0.6, f.motion > 3 * max(typical, 0.2) { snaps.append(String(format: "%.2fs %.2f (around it %.2f)", f.t, f.motion, typical)) }
        }
        let moving = frames.filter { $0.motion > 0.05 }.count
        return ["stutters": stutters, "snaps": snaps, "framesThatMove": moving, "largestMotion": frames.map(\.motion).max() ?? 0,
                "largestJointTurnDeg": frames.map(\.joints).max() ?? 0, "nominalGapMs": nominal * 1000]
    }
    /// The reel as shown, at `fps`: the latest rendered frame (or a cached replay) under the layer's transform.
    /// `overlay(context, t, behind)` draws what else is in Moku's window (in the layer's points, 2 px each), behind it
    /// and then in front of it; `frames` collects every frame written (for review strips).
    func writeMovie(to url: URL, seconds: Double, fps: Double = 30, overlay: ((CGContext, Double, Bool) -> Void)? = nil, frames shown: ((Double, CGImage) -> Void)? = nil) async throws {
        guard let folder else { return }
        let side = 640
        let movie = try ReviewMovie(url: url, width: side, height: side, fps: Int32(fps))
        var cache: (Int, CGImage)?
        var frameIndex = 0, sampleIndex = 0
        for n in 0..<Int(seconds * fps) {
            let t = Double(n) / fps
            while frameIndex + 1 < frames.count && frames[frameIndex + 1].t <= t { frameIndex += 1 }
            while sampleIndex + 1 < samples.count && samples[sampleIndex + 1].t <= t { sampleIndex += 1 }
            let sample = samples.isEmpty ? nil : samples[sampleIndex]
            var image: CGImage?
            if let id = sample?.replay { image = replays[id] }
            if image == nil, !frames.isEmpty {
                if cache?.0 != frameIndex, let loaded = NSImage(contentsOf: folder.appendingPathComponent(String(format: "r-%05d.png", frameIndex)))?.cgImage(forProposedRect: nil, context: nil, hints: nil) { cache = (frameIndex, loaded) }
                image = cache?.1
            }
            guard let image else { continue }
            let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor(calibratedRed: 0.965, green: 0.95, blue: 0.92, alpha: 1).cgColor); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            if let overlay { context.saveGState(); overlay(context, t, true); context.restoreGState() }
            context.saveGState()
            // The layer's transform is about its centre, in points; the reel is 2 px per point of a 320-point layer.
            if let m = sample?.transform, let shift = sample?.shift {
                let unit = CGFloat(side) / 320
                context.translateBy(x: CGFloat(side) / 2 + shift.x * unit, y: CGFloat(side) / 2 + shift.y * unit)
                context.concatenate(CGAffineTransform(a: m.m11, b: m.m12, c: m.m21, d: m.m22, tx: m.m41 * unit, ty: m.m42 * unit))
                context.translateBy(x: -CGFloat(side) / 2, y: -CGFloat(side) / 2)
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            context.restoreGState()
            if let overlay { context.saveGState(); overlay(context, t, false); context.restoreGState() }
            let frame = context.makeImage()!
            shown?(t, frame)
            try await movie.append(frame, at: t)
        }
        try await movie.finish()
    }
    nonisolated static func scaled(_ image: CGImage, side: Int) -> CGImage? {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.interpolationQuality = .high
        context?.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context?.makeImage()
    }
}

/// Image motion between consecutive rendered frames, the way record-moku-window.swift measures it: the mean change of a
/// half-size grey image (alpha-weighted), 0–255. Runs on the recorder's queue.
final class MotionMeter: @unchecked Sendable {
    private var previous: [UInt8]?
    private(set) var values: [Int: Double] = [:]
    func add(index: Int, image: CGImage?) {
        guard let image else { return }
        let side = 160
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &rgba, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var gray = [UInt8](repeating: 0, count: side * side)
        for i in 0..<(side * side) { gray[i] = UInt8((Int(rgba[i * 4]) + Int(rgba[i * 4 + 1]) * 2 + Int(rgba[i * 4 + 2])) / 4) }
        if let previous { values[index] = zip(gray, previous).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(gray.count) }
        else { values[index] = 0 }
        previous = gray
    }
}

extension MokuVisualDiagnostics {
    /// `--life-moves <dir>`: every little move of each mood, frame by frame at 30 fps through the app's pose and
    /// renderer (deterministic, no clock): move-<mood>-<kind>.png (a strip of the face, every other frame) and .mp4
    /// (full frames), plus breath-<mood>.png (out, in, and the difference), lids-<mood>.png (each lid setting) and
    /// reading.png (the darts' span), and moves.json (each frame's image change, to find snaps).
    public static func lifeMoves(stage: MokuCharacterStage, directory: URL) async throws {
        stage.setHidden(true)
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let real = stage.view.real else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let face = CGRect(x: 150, y: 110, width: 340, height: 300)  // in the 640 px render, y down
        let gaze = SIMD2<Float>(-0.35, 0.12)  // watching the screen, as when working
        var report: [String: Any] = [:]
        func crop(_ image: CGImage) -> CGImage { image.cropping(to: face) ?? image }
        func strip(_ images: [CGImage], to url: URL) throws {
            guard let first = images.first else { return }
            let w = first.width, h = first.height
            let context = CGContext(data: nil, width: w * images.count, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor(calibratedRed: 0.965, green: 0.95, blue: 0.92, alpha: 1).cgColor); context.fill(CGRect(x: 0, y: 0, width: w * images.count, height: h))
            for (i, image) in images.enumerated() { context.draw(image, in: CGRect(x: i * w, y: 0, width: w, height: h)) }
            try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
        }
        let meter = MotionMeter()
        for mood in lifeMoods {
            let look = mood == .disappointed || mood == .sleepy ? SIMD2<Float>.zero : gaze
            for (kind, _) in LifeRhythm.vocabulary(for: mood) {
                let move = LifeMove(kind: kind, side: 1, strength: 1)
                let movie = try ReviewMovie(url: directory.appendingPathComponent("move-\(mood.rawValue)-\(kind.rawValue).mp4"), width: 640, height: 640, fps: 30)
                var faces: [CGImage] = [], motion: [Double] = []
                let frames = Int((move.seconds + 0.1) * 30)
                for n in 0...frames {
                    let image = try await real.auditLife(mood: mood, move: move, age: Double(n) / 30, gaze: look)
                    try await movie.append(image)
                    if n % 2 == 0 { faces.append(crop(image)) }
                    meter.add(index: n, image: LifeRecorder.scaled(image, side: 320)); motion.append(meter.values[n] ?? 0)
                }
                try await movie.finish()
                try strip(faces, to: directory.appendingPathComponent("move-\(mood.rawValue)-\(kind.rawValue).png"))
                report["\(mood.rawValue)/\(kind.rawValue)"] = motion
            }
            let out = try await real.auditLife(mood: mood, move: nil, age: 0, breath: 0, gaze: look)
            let full = try await real.auditLife(mood: mood, move: nil, age: 0, breath: Breath.depth(for: mood), gaze: look)
            try strip([out, full, difference(out, full)], to: directory.appendingPathComponent("breath-\(mood.rawValue).png"))
            var lidImages: [CGImage] = []
            for setting in LidTension.choices(for: mood) { lidImages.append(crop(try await real.auditLife(mood: mood, move: nil, age: 0, lids: setting, gaze: look))) }
            if !lidImages.isEmpty { try strip(lidImages, to: directory.appendingPathComponent("lids-\(mood.rawValue).png")) }
        }
        var reading: [CGImage] = []
        for x in [-0.09, 0, 0.09] as [Float] { reading.append(crop(try await real.auditLife(mood: .content, move: nil, age: 0, eyes: SIMD2(x, 0), gaze: gaze))) }
        try strip(reading, to: directory.appendingPathComponent("reading.png"))
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("moves.json"))
    }

    /// Where two renders differ, brightened (black: the same).
    static func difference(_ a: CGImage, _ b: CGImage) -> CGImage {
        let w = a.width, h = a.height
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return data
        }
        let x = pixels(a), y = pixels(b)
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for i in stride(from: 0, to: x.count, by: 4) {
            let d = (0..<3).map { abs(Int(x[i + $0]) - Int(y[i + $0])) }.max()!
            let v = UInt8(min(255, d * 6)); out[i] = v; out[i + 1] = v; out[i + 2] = v
        }
        let context = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}
