import AppKit
import MokuKit

/// Launch QA, lens 4 (docs/specs/launch-qa.md): a companion's moves traced frame by frame through the app's own stage,
/// then judged. Three kinds of evidence, all taken while the stage runs on the clock the way the app runs it:
/// - **the pose**, every frame the renderer draws: how far every joint turned since the frame before, and every face weight;
/// - **the picture**, every frame: how much of it changed, how much of the frame the character covers, and its bounds;
/// - **the layers and windows**, about 120 times a second: the opacity of every visible layer in the stage and of the
///   companion's windows (the bubble, the label, the break timer), and where the image layer sits.
/// `QAJudge` turns that into stutters (a held frame between moving ones), snaps (one frame far above its neighbours),
/// staircases (a weight or a joint that moves in steps), and pops (a layer or a picture that appears or goes at once).
@MainActor final class QATrace {
    struct Frame {
        var t: Double, gap: Double
        var turns: [Float]            // degrees each joint turned since the previous frame
        var face: [String: Float]     // the face weights as shown
        var motion = 0.0, coverage = 0.0, box = CGRect.zero
        var beat = ""
    }
    struct Sample {
        var t: Double
        var panel: Double, speech: Double, label: Double, breakTimer: Double   // window alphas (0 while ordered out)
        var origin: CGPoint
        var layerShift: CGPoint, layerScale: Double, layerTilt: Double, layerOpacity: Double
        /// The companion can't be seen: its window is faded out, or the scan line has erased it.
        var hidden = false
    }
    struct LayerEvent { var t: Double; var what: String }
    /// What the companion's own life did and when (the renderer's life log: blinks, darts, ear flicks, display moments).
    private(set) var events: [LayerEvent] = []
    private var lastEvent = -Double.infinity

    let began: Double
    let folder: URL?
    private(set) var jointNames: [String] = []
    private(set) var frames: [Frame] = []
    private(set) var samples: [Sample] = []
    private(set) var layerEvents: [LayerEvent] = []
    /// The opacity each watched kind of layer is seen at, per sample: the chest LEDs, a manga mark and the one leaving.
    private(set) var watched: [(t: Double, lights: Float, mark: Float, leaving: Float)] = []
    var beat = ""
    private var lastQuats: [SIMD4<Float>]?
    private var lastT: Double?
    /// (The layer itself is held, so a layer that goes can't hand its identity to the next one made.)
    private var lastLayers: [ObjectIdentifier: (name: String, opacity: Float, layer: CALayer)] = [:]
    private var born: [ObjectIdentifier: Double] = [:]
    private let stats = QAStats()
    private let queue = DispatchQueue(label: "moku.qa.writer")

    init(folder: URL?) {
        began = CACurrentMediaTime(); self.folder = folder
        if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    }

    /// A frame the renderer drew (call from its `onFrame`).
    func frame(_ real: RealityCharacter) {
        let t = (real.frameCosts.last?.start ?? CACurrentMediaTime()) - began
        let named = real.jointsForDiagnostics
        if jointNames.isEmpty { jointNames = named.map(\.0) }
        let quats = named.map { $0.1.rotation.vector }
        func degrees(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float { 2 * acos(min(1, abs((a * b).sum()))) * 180 / .pi }
        let turns = lastQuats.map { last in zip(last, quats).map { degrees($0, $1) } } ?? [Float](repeating: 0, count: quats.count)
        add(Frame(t: t, gap: lastT.map { t - $0 } ?? 0, turns: turns, face: real.shownFace, beat: beat))
        lastQuats = quats; lastT = t
        guard let image = real.lastImage else { return }
        let index = frames.count - 1, meter = stats, folder = folder
        queue.async {
            let small = LifeRecorder.scaled(image, side: 320)
            meter.add(index: index, image: small)
            if let folder, let small { try? NSBitmapImageRep(cgImage: small).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(String(format: "r-%05d.png", index))) }
        }
    }

    /// A frame to judge (the tests build traces by hand).
    func add(_ frame: Frame) { frames.append(frame) }
    /// A window/layer sample, for the tests.
    func add(_ sample: Sample) { samples.append(sample) }
    /// A joint's name, for the tests' hand-built traces.
    func name(joints: [String]) { jointNames = joints }
    /// What the companion's life did, for the tests.
    func note(_ what: String, at t: Double) { events.append(LayerEvent(t: t, what: what)) }

    /// The layers and windows now (call about every 8 ms).
    func sample(stage: MokuCharacterStage) {
        let now = CACurrentMediaTime() - began
        if let real = stage.view.real {
            for entry in real.lifeLog where entry.t - began > lastEvent { events.append(LayerEvent(t: entry.t - began, what: entry.what)); lastEvent = entry.t - began }
        }
        func alpha(_ window: NSWindow) -> Double { window.isVisible || stage.rendersOffscreen ? Double(window.alphaValue) : 0 }
        let layer = stage.view.real?.imageLayer
        let shown = layer.map { $0.presentation() ?? $0 }
        let m = shown?.transform ?? CATransform3DIdentity
        samples.append(Sample(t: now, panel: alpha(stage.panel), speech: stage.speechPanel.isVisible || stage.rendersOffscreen ? Double(stage.speechPanel.alphaValue) : 0,
                              label: stage.captionShowing ? Double(stage.labelPanel.alphaValue) : 0, breakTimer: stage.breakTimer.until != nil || stage.breakTimer.endedWith != nil ? Double(stage.breakPanel.alphaValue) : 0,
                              origin: stage.panel.frame.origin,
                              layerShift: CGPoint(x: m.m41, y: m.m42), layerScale: hypot(Double(m.m11), Double(m.m12)), layerTilt: atan2(Double(m.m12), Double(m.m11)) * 180 / .pi,
                              layerOpacity: Double(shown?.opacity ?? 1),
                              hidden: stage.panel.alphaValue < 0.05 || ((stage.view.stage.mask?.presentation() ?? stage.view.stage.mask).map { $0.bounds.height <= StageBeam.bottom + 2 } ?? false)))
        // Every layer that draws something, with the opacity it's really seen at (its own times its parents').
        var seen: [ObjectIdentifier: (name: String, opacity: Float, layer: CALayer)] = [:]
        func walk(_ layer: CALayer, path: String, inherited: Float) {
            let p = layer.presentation() ?? layer
            let effective = inherited * (layer.isHidden ? 0 : p.opacity)
            let draws = layer.contents != nil || layer.backgroundColor != nil || layer is CAShapeLayer || layer is CATextLayer || layer is CAGradientLayer
            let name = path + "/" + (layer.name ?? String(describing: type(of: layer)))
                + String(format: " %.0f×%.0f", layer.bounds.width, layer.bounds.height)
            if draws { seen[ObjectIdentifier(layer)] = (name, effective, layer) }
            for (i, child) in (layer.sublayers ?? []).enumerated() { walk(child, path: path + "/" + String(i), inherited: effective) }
        }
        walk(stage.view.layer!, path: "", inherited: 1)
        // A mark that hands over to its own fading copy (ManpuLayer.retire) hasn't popped: skip the pair.
        let handover = seen.values.contains { $0.name.contains("(leaving)") }
        // A layer added with a fade-in shows its model value for the first sample or two, before its animation takes
        // over: judge a new layer only once it's 60 ms old.
        let first = lastLayers.isEmpty
        for (id, now0) in seen {
            // A fading copy's own rise is the hand-over; the mark it replaces is skipped too in the sample it goes.
            if now0.name.contains("(leaving)") || (handover && now0.name.contains("manpu mark")) { continue }
            if lastLayers[id] == nil, !first { born[id] = now }
            if let at = born[id] {
                if now - at < 0.06 { continue }
                born[id] = nil
                // (A mark's pop, a light's quick rise and a flicker's first beat are meant: judge only what shows at once, whole.)
                let meant = now0.name.contains("manpu mark") || now0.name.contains("stageBeam") || now0.name.contains("hologram")
                if now0.opacity > 0.7, !meant { layerEvents.append(LayerEvent(t: at, what: String(format: "%@ appears at %.2f", now0.name, now0.opacity))) }
                continue
            }
            if let before = lastLayers[id], abs(now0.opacity - before.opacity) > 0.4 {
                layerEvents.append(LayerEvent(t: now, what: String(format: "%@ opacity %.2f → %.2f", now0.name, before.opacity, now0.opacity)))
            }
        }
        for (id, before) in lastLayers where seen[id] == nil && before.opacity > 0.4 && born[id] == nil && !(handover && before.name.contains("manpu mark")) {
            layerEvents.append(LayerEvent(t: now, what: String(format: "%@ goes at %.2f", before.name, before.opacity)))
        }
        for id in born.keys where seen[id] == nil { born[id] = nil }
        func strongest(_ part: String, leaving: Bool = false) -> Float { seen.values.filter { $0.name.contains(part) && $0.name.contains("(leaving)") == leaving }.map(\.opacity).max() ?? 0 }
        watched.append((now, strongest("statusLights"), strongest("manpu mark"), strongest("manpu mark", leaving: true)))
        lastLayers = seen
    }

    /// Waits for the picture work, then fills in each frame's image numbers.
    func finish() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
        let rows = stats.rows
        for i in frames.indices { if let r = rows[i] { frames[i].motion = r.motion; frames[i].coverage = r.coverage; frames[i].box = r.box } }
    }
}

/// The picture numbers of one frame, worked out off the main thread: the mean change from the frame before (as
/// `MotionMeter`), the share of the frame the character covers, and the box around it (0–1, y down).
final class QAStats: @unchecked Sendable {
    private var previous: [UInt8]?
    private(set) var rows: [Int: (motion: Double, coverage: Double, box: CGRect)] = [:]
    func add(index: Int, image: CGImage?) {
        guard let image else { return }
        let side = 160
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &rgba, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var gray = [UInt8](repeating: 0, count: side * side)
        var covered = 0, minX = side, maxX = -1, minY = side, maxY = -1
        for i in 0..<(side * side) {
            gray[i] = UInt8((Int(rgba[i * 4]) + Int(rgba[i * 4 + 1]) * 2 + Int(rgba[i * 4 + 2])) / 4)
            if rgba[i * 4 + 3] > 24 { covered += 1; let x = i % side, y = i / side; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        }
        var motion = 0.0
        if let before = previous {
            var total = 0
            for i in 0..<gray.count { total += abs(Int(gray[i]) - Int(before[i])) }
            motion = Double(total) / Double(gray.count)
        }
        let fside = Double(side)
        var box = CGRect.zero
        if maxX >= 0 { box = CGRect(x: Double(minX) / fside, y: Double(minY) / fside, width: Double(maxX - minX + 1) / fside, height: Double(maxY - minY + 1) / fside) }
        rows[index] = (motion, Double(covered) / (fside * fside), box)
        previous = gray
    }
}
