import AppKit
import RealityKit
import Metal
import QuartzCore
import MokuKit

private struct MoodFile: Decodable {
    struct Pose: Decodable { let blendShapes: [String: Float]; let jointEulerDegrees: [String: [Float]]; let transitionIn: String?; let transitionOut: String? }
    let moods: [String: Pose]
}

struct Studio: Decodable {
    struct Camera: Decodable { let position: [Float]; let target: [Float]; let fieldOfView: Float; let safeAreaFraction: Float? }
    struct Light: Decodable { let position: [Float]; let color: [Float]; let intensity: Float; let castsShadow: Bool?; let shadowScale: Float? }
    let camera: Camera
    let lights: [Light]
    let environmentCubeSize: Int?
    let environmentColor: [Float]?
    let environmentIntensityExponent: Float?
    /// A studio around Moku for image-based light (moku-look-v2.md), instead of one flat colour.
    let environment: Environment?
    static func vector(_ values: [Float]) -> SIMD3<Float> { SIMD3(values[0], values[1], values[2]) }

    /// Linear RGB, brighter than 1 where it's a light. Directions are toward the light, in the character's space
    /// (+y up, +z toward the camera, +x to Moku's left as we see it).
    struct Environment: Decodable {
        struct Softbox: Decodable { let direction: [Float]; let radius: Float; let color: [Float]; let intensity: Float }
        let zenith: [Float]
        let horizon: [Float]
        let floor: [Float]
        let softboxes: [Softbox]

        /// The studio as an equirectangular HDR image (32-bit float, extended linear sRGB).
        func image(width: Int = 512) -> CGImage {
            let height = width / 2
            let boxes = softboxes.map { box -> (SIMD3<Float>, Float, Float, SIMD3<Float>) in
                let r = box.radius * .pi / 180
                return (simd_normalize(Studio.vector(box.direction)), cos(r), cos(r * 1.6), Studio.vector(box.color) * box.intensity)
            }
            let up = Studio.vector(zenith), side = Studio.vector(horizon), down = Studio.vector(floor)
            var pixels = [Float](repeating: 1, count: width * height * 4)
            for y in 0..<height {
                let theta = (Float(y) + 0.5) / Float(height) * .pi
                for x in 0..<width {
                    let phi = ((Float(x) + 0.5) / Float(width) - 0.5) * 2 * .pi
                    let d = SIMD3<Float>(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi))
                    var c: SIMD3<Float>
                    if d.y >= 0 { let t = pow(d.y, 0.6); c = side + (up - side) * t } else { let t = pow(-d.y, 0.4); c = side + (down - side) * t }
                    for (direction, inner, outer, light) in boxes {
                        let k = simd_dot(d, direction)
                        if k > outer { let t = min(1, (k - outer) / max(0.0001, inner - outer)); c += light * (t * t * (3 - 2 * t)) }
                    }
                    let i = (y * width + x) * 4
                    pixels[i] = c.x; pixels[i+1] = c.y; pixels[i+2] = c.z; pixels[i+3] = 1
                }
            }
            let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
            return CGImage(width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: width * 16,
                           space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                           provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        }
    }
}

/// Explicit RealityRenderer scheduling avoids ARView's continuous, uncontrolled render loop.
/// The shared render target also supplies the exact alpha silhouette for input routing.
@MainActor
final class RealityCharacter {
    let imageLayer = CALayer()
    private let renderer: RealityRenderer
    private var texture: any MTLTexture
    private var output: RealityRenderer.CameraOutput
    /// The render's side in pixels: two per stage point, times Moku's size above 1× (see `setResolution`).
    private(set) var textureSize = StageGeometry.textureSize
    private var pendingTextureSize: Int?
    private let character: Entity
    private let rig: ModelEntity
    private let morphs: FacialMorphs
    /// A face that is a display (Tetsu's LED matrix, PixelFace): drawn from the same face weights; nil for a morph face.
    private let pixelFace: PixelFace?
    /// Which of the model's materials is the display (it shows the pixel face's frame).
    private let displayIndex: Int?
    private let scanBeam = ScanBeam(), hologram = Hologram()
    /// Tetsu's chest LEDs, breathing (a layer inside the image layer); nil for a companion without them.
    private var statusLights: StatusLights?
    /// Where the next drawn frame puts them: shown with that frame's picture.
    private var pendingLights: (visible: Bool, at: CGPoint, across: CGFloat)?
    private var hologramObserver: NSObjectProtocol?
    private let rest: [Transform]
    private let baseMaterials: [any Material]
    private let materialNames: [String]
    private var worldToCamera = matrix_identity_float4x4
    private var projectionScale: Float = 1
    private var headAnchorLocal = SIMD4<Float>(0, 0, 0, 1)
    var projectedHead: CGPoint {
        guard let matrix = PropAttachment.jointMatrix(named: "head", names: rig.jointNames, transforms: rig.jointTransforms) else { return CGPoint(x: StageGeometry.characterFrame.midX, y: 100) }
        let projected = worldToCamera * rig.transformMatrix(relativeTo: nil) * matrix * headAnchorLocal
        let depth = max(0.001, -projected.z)
        let local = CGPoint(x: CGFloat(projected.x * projectionScale / depth + 1) * imageLayer.bounds.width / 2,
                            y: CGFloat(projected.y * projectionScale / depth + 1) * imageLayer.bounds.height / 2)
        return imageLayer.convert(local, to: imageLayer.superlayer)
    }
    func alignGround(at y: CGFloat) {
        let point = worldToCamera * SIMD4<Float>(0, 0, 0, 1)
        let normalizedY = CGFloat(point.y * projectionScale / max(0.001, -point.z) + 1) / 2
        imageLayer.frame.origin.y = y - normalizedY * imageLayer.bounds.height
    }
    private let moodFile: MoodFile?
    private var timer: FrameTicker?
    /// The view Moku is drawn in: while it's on screen, frames follow the display's refresh (no judder).
    weak var hostView: NSView?
    private var busy = false
    /// Recent frames (diagnostics): when each started, and seconds spent posing and flushing.
    private(set) var frameCosts: [(start: Double, pose: Double, flush: Double)] = []
    private(set) var frameDone: [Double] = []
    /// Diagnostics: main-thread seconds per frame, in render() and in finishFrame().
    private(set) var mainCosts: [(render: Double, finish: Double)] = []
    /// The same, every frame since launch (EnergyCheck).
    private(set) var mainCostsTotal = FrameCostLedger()
    /// Diagnostics: seconds per face-morph update.
    var morphCosts: [Double] { morphs.costs }
    var renderPathDescription: String { (morphs.onGPU ? "GPU morphs" : "CPU morphs") + ", getBytes into a CGImage" }
    /// Diagnostics: display ticks skipped because a frame was still being drawn.
    private(set) var busySkips = 0
    private var renderCostPending = 0.0
    private var running = false
    private var lastTime = CACurrentMediaTime()
    private var began = CACurrentMediaTime()
    private var blinkStartedAt = -100.0   // CACurrentMediaTime of the current blink (BlinkTiming)
    private var nextBlink = 2.5
    private var currentWeights: [String: Float] = [:]
    private var mood: Mood = .content
    private var moodChangedAt = -100.0
    private var moodDuration = 2.4
    private var moodFromTransforms: [Transform]?
    /// The pose a clip ended on, eased out of over `clipExitSeconds` so the head never snaps back to the work.
    private var clipExit: (transforms: [Transform], at: Double)?
    static let clipExitSeconds = 1.1
    private var moodFromWeights: [String: Float] = [:]
    private var moodFromAngles: [String: SIMD3<Float>] = [:]
    private var currentMoodAngles: [String: SIMD3<Float>] = [:]
    private let earTransitions: EarTransitions?
    private var earFrom = EarPose()
    private var earCurrent = EarPose()
    private var lastAppliedFace: [String: Float] = [:]
    /// Diagnostics: the face weights on the last frame drawn.
    var shownFace: [String: Float] { lastAppliedFace }
    /// Diagnostics: the face weights as the mesh shows them (FacialMorphs' quantized weights).
    var sentFace: [String: Float] { morphs.lastSent }
    /// Diagnostics: how often the face mesh was rebuilt, and the little life moves played, by kind.
    var faceRebuilds: Int { morphs.rebuilds }
    /// Diagnostics: face changes the CPU path's 30 Hz limit held back for a later frame.
    var faceChangesHeldBack: Int { morphs.heldBack }
    private(set) var lifeEvents: [String: Int] = [:] { didSet { noteLife(lifeEvents, oldValue) } }
    /// Diagnostics: what happened when (blinks, darts, moves, lids, fidgets, flicks), the last 400.
    private(set) var lifeLog: [(t: Double, what: String)] = []
    private func noteLife(_ now: [String: Int], _ before: [String: Int]) {
        for (key, count) in now where count != before[key] { lifeLog.append((CACurrentMediaTime(), key)) }
        if lifeLog.count > 400 { lifeLog.removeFirst(lifeLog.count - 400) }
    }
    private var releaseClipName = "unfold_arms"
    private var nodStartedAt = -100.0
    private var reading = false
    /// When the next line of reading may start (with frames being drawn anyway), and when it starts regardless.
    private var lineDueAt = 0.0, lineLateAt = 0.0
    private(set) var saccadeCount = 0
    private var heldMood: Bool { Self.foldsArms(for: mood) }
    /// A mood held with folded arms. Not the sad face any more: after the sigh it folded its arms and stayed sad, a second
    /// pass Charles didn't want (2026-10-14). Only the old cross face (no longer shown) still does.
    nonisolated static func foldsArms(for mood: Mood) -> Bool { mood == .annoyed }
    private var armClipNames: Set<String> { Set((moodFile?.moods.values.flatMap { [$0.transitionIn, $0.transitionOut].compactMap { $0 } } ?? []) + ["fold_arms", "unfold_arms", "cross_arms", "uncross_arms"]) }
    private var isArmClip: Bool { active != nil && armClipNames.contains(activeClipName ?? "") }
    func setReading(_ on: Bool) {
        if on && !reading { spinPending = true }
        reading = on
        if !on { settleEyes() }
    }
    /// While Moku reads your screen its eyes hop along in small darts (three frames at 30 fps, the eye bones only: no face
    /// rebuild), then sweep back and rest. Not behind closed arcs (proud): frames drawn for darts nobody sees. Returns
    /// how long until the next dart.
    func saccade() -> Double {
        let now = CACurrentMediaTime()
        guard reading, running, !reduced, !drifting, active == nil, now - moodChangedAt >= moodDuration, now - gazeChangedAt >= gazeDuration,
              !expressionBusy, eyesOpen, blinksShow, pixelFace != nil || jointLeaves.isSuperset(of: ["eye_L", "eye_R"]) else { return 1 }
        // Tetsu's eyes wait while its display plays a reading moment.
        if let moment = displayMoment, now - moment.at < moment.seconds + 0.3 { return moment.at + moment.seconds + 0.3 - now }
        if now < displayQuietUntil { return displayQuietUntil - now }
        // A new line starts with frames already being drawn (often a blink, as people blink at the end of a line) once
        // it's due, or on its own once it's late: most of reading then costs no frames of its own.
        if readingEyes.atLineEnd {
            if spinPending, displayMomentStarted() { return 1 }  // Tetsu loads a new window before reading it
            if scanAfterSpin, displayMomentStarted() { return 1 }  // …and scans it as soon as it's loaded
            if now < lineDueAt { return min(1, lineDueAt - now) }
            if timer == nil && now < lineLateAt { return 0.2 }
            if displayMomentStarted() {  // Tetsu: every second line is a scan (at most one every 10 s)
                lineDueAt = now + (displayMoment?.seconds ?? 1) + random.wait(floor: 3, mean: 6, cap: 9); lineLateAt = lineDueAt + 4
                return min(1, lineDueAt - now)
            }
        }
        let rest = readingEyes.dart(now: now, using: &random)
        if readingEyes.atLineEnd { lineDueAt = now + random.wait(floor: 3, mean: 6, cap: 9); lineLateAt = lineDueAt + random.wait(floor: 4, mean: 8, cap: 5) }
        saccadeCount += 1; lifeEvents["dart", default: 0] += 1
        wake(for: readingEyes.seconds + 0.04)
        return rest
    }
    /// The reading darts come home (the gaze moved on, or Moku stopped reading), eased.
    private func settleEyes() {
        let now = CACurrentMediaTime()
        guard readingEyes.offset(at: now) != .zero || readingEyes.target != .zero else { return }
        readingEyes.settle(now: now); wake(for: 0.35)
    }
    private var eyesOpen: Bool {
        max(lastAppliedFace["blink_L"] ?? 0, lastAppliedFace["blink_R"] ?? 0, lastAppliedFace["eyes_happy"] ?? 0, lastAppliedFace["eyes_proud"] ?? 0) < 0.5
    }
    // Tetsu reads like a machine: after it turns to a new window it loads it (a spinner on its matrix) and scans it at
    // once, then scans every second line, at most one scan every 10 s so it stays special (Charles loves the beam). A
    // scan is its signature moment: a beam sweeps across the window and back for 2.2 s while a bright column sweeps its
    // matrix in step (drawn at 15 fps; its 14 column frames are drawn once and kept). The beam is Core Animation in
    // Tetsu's own window. In between, its dot eyes dart along the line with Moku's reading darts.
    private var displayMoment: (channel: String, at: Double, seconds: Double)?
    /// Diagnostics: display channels (and `__gazeX`, `__gazeY`) held over the face, for review stills.
    var displayOverrides: [String: Float] = [:]
    var displayImage: CGImage? { pixelFace?.lastImage }
    /// Diagnostics: seconds per display redraw (a display face).
    var displayCosts: [Double] { pixelFace?.costs ?? [] }
    private var spinPending = false, readingBeats = 0, scanAfterSpin = false, lastScanAt = -100.0
    static let scanGap = 10.0
    /// Diagnostics: the reading moments played (spinner, scan).
    private(set) var displayMoments: [String] = []
    private func displayMomentStarted() -> Bool {
        guard pixelFace != nil else { return false }
        let now = CACurrentMediaTime()
        if let moment = displayMoment, now - moment.at < moment.seconds + 0.3 { return true }
        if now < displayQuietUntil { return true }
        readingBeats += 1
        let channel: String
        if spinPending { channel = "px_spin"; spinPending = false; scanAfterSpin = true }
        else if (scanAfterSpin || readingBeats % 2 == 0) && now - lastScanAt >= Self.scanGap { channel = "px_scan"; scanAfterSpin = false; lastScanAt = now }
        else { scanAfterSpin = false; return false }
        playDisplayMoment(channel)
        return true
    }
    func playDisplayMoment(_ channel: String) {
        guard pixelFace != nil, running else { return }
        let steps = Self.blinkSteps[channel]
        let seconds = steps.map { Double($0.count + 1) / 30 } ?? Self.momentSeconds[channel] ?? ScanBeam.seconds
        displayMoment = (channel, CACurrentMediaTime(), seconds); momentStep = 0; displayMoments.append(channel); lifeEvents[channel, default: 0] += 1
        imageLayer.removeAnimation(forKey: "reading")
        if channel == "px_scan", let parent = imageLayer.superlayer { scanBeam.play(in: parent, from: projectedHead, toward: headLook, reduced: reduced); onTalent?(.scan) }
        // A blink steps through its frames at 30 fps, the scan's column at 15, the rest at 20; never slower than frames
        // already being drawn for something else (a fidget's servo move at 30 slowed to 15 was a held frame and a snap).
        let fps: Double = channel == "px_scan" ? 15 : steps != nil ? 30 : 20
        wake(for: seconds + 0.1); schedule(fps: max(fps, timer != nil ? timerFPS : 0))
    }
    /// A display's blinks, one whole frame per drawn frame, each different from the last, so nothing is held or
    /// repeated: the eyes collapse to a line in three steps and snap back open; now and then twice; or a refresh, dim,
    /// dark, dim, relit. (Weights over the face; `px_refresh` dims or blanks the eyes, PixelFace.)
    private static let blinkSteps: [String: [[String: Float]]] = {
        let half = ["blink_L": Float(0.5), "blink_R": 0.5], narrow = ["blink_L": Float(0.75), "blink_R": 0.75], line = ["blink_L": Float(1), "blink_R": 1]
        return ["px_blink": [half, narrow, line], "px_blink2": [narrow, line, [:], narrow, line], "px_refresh": [["px_refresh": 0.2], ["px_refresh": 0.5], ["px_refresh": 0.2]]]
    }()
    /// The frame of a stepped moment (a blink) to show next.
    private var momentStep = 0
    /// A display moment never starts within this long of the last one's end (a blink straight into a scan read as one
    /// held frame between them), and darts wait for it too.
    private static let displayQuiet = 0.35
    private var displayQuietUntil = -100.0
    /// How long each display moment lasts (the scan: ScanBeam.seconds).
    private static let momentSeconds: [String: Double] = ["px_spin": 1.1, "px_wake": 0.8, "px_lock": 0.6]
    /// A display blinks like a screen (PixelFace): mostly a quick collapse to a line, now and then twice, or a refresh.
    private func displayBlink() {
        let kind = random.chance(0.12) ? "px_blink2" : random.chance(0.1) ? "px_refresh" : "px_blink"
        playDisplayMoment(kind)
    }
    /// Review: the scan held `progress` through its sweep, the beam and the display's column together.
    func reviewScan(at progress: Double) {
        displayOverrides = ["px_scan": Float(max(0.004, progress)), "eyes_narrow": 0.8]
        if let parent = imageLayer.superlayer { scanBeam.play(in: parent, from: projectedHead, toward: headLook, reduced: false, still: progress) }
    }
    /// A house piece landed (`units` built today): Tetsu projects today's rocket, as far as it's built, over its head.
    func showHologram(units: Int) {
        guard companion.isMachine, running, let parent = imageLayer.superlayer, !imageLayer.isHidden,
              let image = Hologram.image(companion: companion, stage: DayHouse.stage(Double(units) * DayHouse.minutesPerPiece) + 1) else { return }
        hologram.show(image, in: parent, above: projectedHead, reduced: reduced)
        onTalent?(.hologram)
    }
    func returnNod() { nodStartedAt = CACurrentMediaTime(); wake(for: 0.95) }
    /// Where the chest LEDs are in the frame being posed (idle only: in a clip, a move or a hold they can turn away).
    private func placeStatusLights() {
        guard let lights = statusLights else { return }
        let visible = active == nil && !moving && !holding && running
        guard visible, let spine = PropAttachment.jointMatrix(named: "spine", names: rig.jointNames, transforms: rig.jointTransforms) else {
            pendingLights = (false, .zero, 0); return
        }
        let centre = rig.transformMatrix(relativeTo: nil) * spine * lights.anchor, half = SIMD4<Float>(lights.span / 2, 0, 0, 0)
        func onLayer(_ p: SIMD4<Float>) -> CGPoint {
            let c = worldToCamera * p, depth = max(0.001, -c.z)
            return CGPoint(x: CGFloat(c.x * projectionScale / depth + 1) * imageLayer.bounds.width / 2, y: CGFloat(c.y * projectionScale / depth + 1) * imageLayer.bounds.height / 2)
        }
        let left = onLayer(centre - half), right = onLayer(centre + half)
        pendingLights = (true, onLayer(centre), hypot(right.x - left.x, right.y - left.y))
    }
    /// Tetsu's comeback: a happy double beep (the antenna LEDs blip twice, the antennae twitch) and a quick servo bob on
    /// the layer, up and settled (the return's "returnHop", so a beat that cuts in eases it home).
    private var beepAt = -100.0
    func machineComeback() {
        guard running, !reduced, !holding else { return }
        let now = CACurrentMediaTime(); beepAt = now; antennaTwitchAt = now + 0.08
        let steps = 24, seconds = 0.7
        let bob = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bob.values = (0...steps).map { NSNumber(value: Double(3 * ServoTiming.envelope(age: seconds * Double($0) / Double(steps), seconds: seconds))) }
        bob.duration = seconds; bob.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        imageLayer.add(bob, forKey: "returnHop")
        smoothFor(0.8)
    }
    /// The comeback bounce (Moku's talent, MokuTalents.swift): on the image layer, seated; the ears follow it in 3D, so
    /// frames are drawn until they've settled.
    private var bounceAt = -100.0
    func happyBounce() {
        guard running, !reduced, !holding else { return }
        imageLayer.add(HappyBounce.animation(feet: feetAboveCentre), forKey: "happyBounce")
        bounceAt = CACurrentMediaTime()
        smoothFor(HappyBounce.seconds + 0.4)
    }
    private var breathingWanted = false
    /// The breath on the layer now (its clock and pace), and how deep it is.
    private var breath = Breath(), breathDepth: Float = 0
    /// The chest and cheeks' share of the breath on the last drawn frame (in depths).
    private var breathShown: Float = 0
    func setBreathing(_ on: Bool) {
        breathingWanted = on
        if on && holding { return }  // held or settling: the hold owns the layer's scale; breathing resumes after
        if on && imageLayer.animation(forKey: "breathing") != nil { return }
        imageLayer.removeAnimation(forKey: "breathing"); imageLayer.removeAnimation(forKey: "breathSwell"); swellUntil = -100
        guard on, running, !companion.isMachine else { return }  // a machine doesn't breathe; its LEDs do
        let now = CACurrentMediaTime(), seconds = Breath.seconds(for: mood), depth = Breath.depth(for: mood) * (reduced ? 0.25 : 1)
        breath = Breath(startedAt: now, seconds: seconds); breathDepth = depth
        imageLayer.add(breathAnimation(depth: depth, seconds: seconds, begin: now, repeats: true), forKey: "breathing")
    }
    /// Taller (the head rises) and a touch wider (the chest fills), about the feet: lifted by what the stretch would
    /// push them down, so they stay planted. The lift is on the position, so a hop's translation can't replace it.
    /// From `begin`, the bottom of a breath; once, or breath after breath.
    private func breathAnimation(depth: Float, seconds: Double, begin: Double, repeats: Bool) -> CAAnimation {
        let rise = 1 + Breath.rise * depth, widen = 1 + Breath.widen * depth
        func part(_ path: String, _ from: CGFloat, _ to: CGFloat) -> CABasicAnimation {
            let a = CABasicAnimation(keyPath: path); a.fromValue = from; a.toValue = to; a.duration = seconds / 2; return a
        }
        let lift = part("position.y", 0, (1 - CGFloat(rise)) * feetAboveCentre); lift.isAdditive = true
        let group = CAAnimationGroup()
        group.animations = [part("transform.scale.y", 1, CGFloat(rise)), part("transform.scale.x", 1, CGFloat(widen)), lift]
        group.beginTime = begin; group.duration = seconds / 2; group.autoreverses = true; group.repeatCount = repeats ? .infinity : 1
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
        return group
    }
    /// Where Moku's feet are on the image layer: points above its centre (negative: below).
    private var feetAboveCentre: CGFloat {
        let point = worldToCamera * SIMD4<Float>(0, 0, 0, 1)
        return (CGFloat(point.y * projectionScale / max(0.001, -point.z) + 1) / 2 - 0.5) * imageLayer.bounds.height
    }
    /// A new mood breathes at its own pace and depth: swapped in at the bottom of a breath, so it never jumps.
    private func refreshBreath(now: Double) {
        let depth = Breath.depth(for: mood) * (reduced ? 0.25 : 1)
        guard breathingWanted, running, !holding, imageLayer.animation(forKey: "breathing") != nil,
              Breath.seconds(for: mood) != breath.seconds || depth != breathDepth, breath.amount(at: now) < 0.01 else { return }
        imageLayer.removeAnimation(forKey: "breathing"); setBreathing(true)
    }
    /// The deeper breath under way (a beat): until when, and how much deeper.
    private var swellUntil = -100.0, swell: Float = 1
    /// A breath `factor` times deeper, from the bottom of this one, then breathing as before from the bottom of that
    /// one: both swaps happen with the layer at rest (within 3% of a breath: a hundredth of a point), so nothing jumps.
    /// False unless the breath is at its bottom (a window of a third of a second, caught by the stage's tick).
    private func swellBreath(now: Double, factor: Float) -> Bool {
        guard breathingWanted, running, !holding, imageLayer.animation(forKey: "breathing") != nil, breath.amount(at: now) < 0.03 else { return false }
        let seconds = breath.seconds
        imageLayer.removeAnimation(forKey: "breathing")
        imageLayer.add(breathAnimation(depth: breathDepth * factor, seconds: seconds, begin: now, repeats: false), forKey: "breathSwell")
        imageLayer.add(breathAnimation(depth: breathDepth, seconds: seconds, begin: now + seconds, repeats: true), forKey: "breathing")
        breath = Breath(startedAt: now, seconds: seconds); swellUntil = now + seconds; swell = factor
        return true
    }
    /// Whether a deeper breath could start within `seconds` (the layer is breathing, and its bottom is that near).
    private func breathBottom(within seconds: Double, now: Double) -> Bool {
        breathingWanted && running && !holding && imageLayer.animation(forKey: "breathing") != nil && now >= swellUntil
            && (breath.amount(at: now) < 0.03 || breath.untilBottom(at: now) <= seconds)
    }
    private var eyeTarget = SIMD2<Float>.zero
    private var eyeLook = SIMD2<Float>.zero
    private var headLook = SIMD2<Float>.zero
    private var gazeChangedAt = -100.0
    private var gazeFromEye = SIMD2<Float>.zero
    private var gazeFromHead = SIMD2<Float>.zero
    private var userAttention: Float = 0
    private var gazeFromUserAttention: Float = 0
    private func beginGaze() { gazeChangedAt = CACurrentMediaTime(); gazeAwaitsFrame = true; gazeFromEye = eyeLook; gazeFromHead = headLook; gazeFromUserAttention = userAttention }
    /// The gaze changed and no frame has been drawn since: the first one starts its ease (GazeTiming.easeStart).
    private var gazeAwaitsFrame = false
    private var drifting = false
    private var driftHeadAnchor = SIMD2<Float>.zero
    // Standing is a pose the app blends toward, not a clip. Blender's grounded pose library (stand_poses:
    // frame k is the standing base at s = k / (n - 1), feet planted) is layered as a delta over the idle pose,
    // so mood, gaze, blush and flush stay live and nothing hands off between animations. Seated only
    // (`Posture.seatedOnly`), the same timeline sits the companion up tall instead: s is how tall.
    private typealias StandDelta = (rotations: [simd_quatf], translations: [SIMD3<Float>], scales: [SIMD3<Float>])
    private var standDeltas: [StandDelta] = []
    private var standLift = SIMD3<Float>(0, 1, 0)
    private var standFrom: Float = 0
    private var standTo: Float = 0
    private var standAt = -100.0
    private var standThumps = false
    /// A full-body clip (a pat, a hop) played over a standing Moku: it stands again when the clip ends.
    private var standAfterClip = false
    var standing: Bool { standTo > 0 }
    private static let riseSeconds = 1.3, sitSeconds = 1.1, thumpSeconds = 0.55
    /// Sitting up tall (seated only): the chest straightens back this far, the head takes half of it back so the gaze
    /// holds, and the body lifts a touch.
    private static let tallChest: Float = 9 * .pi / 180, tallLift: Float = 0.008
    func stand(_ up: Bool) {
        let target: Float = up ? 1 : 0
        if !up { standAfterClip = false }
        guard target != standTo else { return }
        standFrom = standShape(now: CACurrentMediaTime()).s; standTo = target; standAt = CACurrentMediaTime()
        standThumps = up && mood == .annoyed
        settleEyes(); cancelMicro()
        let seconds = (up ? Self.riseSeconds + (standThumps ? Self.thumpSeconds : 0) : Self.sitSeconds) + 0.2
        smoothUntil = CACurrentMediaTime() + seconds
        wake(for: seconds); schedule(fps: 60)
    }
    /// Where the stand is at `now`, and its acting: rising is a small crouch, the push up and a soft overshoot,
    /// with the ears dragging then flopping; sitting lifts a touch before letting down and lands with a squash.
    /// When angry, one hind-foot thump after standing up, like a real annoyed rabbit.
    private struct StandShape { var s: Float = 0; var chest: Float = 0; var lift: Float = 0; var ears: Float = 0; var tap: Float = 0 }
    private func standShape(now: Double) -> StandShape {
        func smooth(_ x: Double) -> Double { let x = min(1, max(0, x)); return x * x * x * (x * (x * 6 - 15) + 10) }
        func pulse(_ x: Double, _ a: Double, _ b: Double, _ c: Double) -> Double { x <= a || x >= c ? 0 : smooth((x - a) / (b - a)) * (1 - smooth((x - b) / (c - b))) }
        let degrees = Float.pi / 180
        var shape = StandShape()
        let up = standTo > standFrom
        let p = (now - standAt) / (up ? Self.riseSeconds : Self.sitSeconds)
        shape.s = standFrom + (standTo - standFrom) * Float(up ? smooth((p - 0.16) / 0.62) : smooth((p - 0.10) / 0.65))
        if companion.isMachine {  // a machine straightens like a servo: quick, a tiny overshoot, settled
            let seconds = up ? Self.riseSeconds : Self.sitSeconds, start = up ? 0.16 : 0.10, span = up ? 0.62 : 0.65
            shape.s = standFrom + (standTo - standFrom) * ServoTiming.progress(age: (p - start) * seconds, duration: span * seconds)
        }
        // Sitting up tall (seated only) is one smooth straightening: no crouch before it, no overshoot after.
        let acted: Float = Posture.seatedOnly ? 0 : 1
        if up {
            shape.chest = acted * Float(7 * pulse(p, 0, 0.10, 0.26) - 3 * pulse(p, 0.70, 0.82, 1)) * degrees
            shape.lift = acted * Float(0.010 * pulse(p, 0.70, 0.80, 1))
            shape.ears = Float(-9 * pulse(p, 0.18, 0.45, 0.70) + 5 * pulse(p, 0.70, 0.84, 1)) * degrees
            if standThumps {
                let q = (p - 1) * Self.riseSeconds / Self.thumpSeconds
                shape.tap = Float(16 * pulse(q, 0, 0.45, 1)) * degrees
                shape.lift += Float(0.004 * pulse(q, 0.55, 0.70, 0.95))
            }
        } else if standFrom > standTo {
            shape.lift = acted * Float(0.008 * pulse(p, 0, 0.12, 0.26))
            shape.chest = acted * Float(4 * pulse(p, 0.72, 0.84, 1)) * degrees
            shape.ears = Float(7 * pulse(p, 0.15, 0.40, 0.65) - 6 * pulse(p, 0.72, 0.86, 1)) * degrees
        }
        return shape
    }
    private func standDelta(at s: Float) -> StandDelta? {
        guard standDeltas.count > 1, s > 0.0001 else { return nil }
        let x = min(1, s) * Float(standDeltas.count - 1), k = min(standDeltas.count - 2, Int(x)), f = x - Float(k)
        let a = standDeltas[k], b = standDeltas[k + 1]
        return (zip(a.rotations, b.rotations).map { simd_slerp($0, $1, f) }, zip(a.translations, b.translations).map { $0 + ($1 - $0) * f },
                zip(a.scales, b.scales).map { $0 + ($1 - $0) * f })
    }
    /// Reads the pose library as deltas from its first (seated) frame, so standing starts exactly at rest.
    /// Every joint's current local transform, by leaf name (diagnostics).
    var jointsForDiagnostics: [(String, Transform)] { zip(rig.jointNames.map { String($0.split(separator: "/").last ?? "") }, rig.jointTransforms).map { ($0, $1) } }
    func loadStandPoses() async {
        guard let url = MokuAssets.file("character/anims/stand_poses.usdz", companion: companion), let imported = try? await Entity(contentsOf: url),
              let donor = Self.descendants(imported).compactMap({ $0 as? ModelEntity }).first(where: { !$0.jointNames.isEmpty }),
              let resource = donor.availableAnimations.first(where: { ($0.name ?? "").contains("/Armature/") }),
              let samples = resource.definition as? SampledAnimation<JointTransforms>, let first = samples.frames.first else { return }
        func leaf(_ name: String) -> String { String(name.split(separator: "/").last ?? "") }
        let source = Dictionary(samples.jointNames.enumerated().map { (leaf($1), $0) }, uniquingKeysWith: { a, _ in a })
        let joints = rig.jointNames.map { source[leaf($0)] }
        standDeltas = samples.frames.map { frame in
            (joints.map { $0.map { first[$0].rotation.inverse * frame[$0].rotation } ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) },
             joints.map { $0.map { frame[$0].translation - first[$0].translation } ?? .zero },
             joints.map { $0.map { frame[$0].scale / first[$0].scale } ?? .one })
        }
        if let root = rig.jointNames.firstIndex(where: { leaf($0) == "root" }), let top = standDeltas.last, simd_length(top.translations[root]) > 0 {
            standLift = simd_normalize(top.translations[root])
        }
    }
    // A little red when Moku has been angry a while: the plush warms toward red. (Only the materials change:
    // a face morph would rebuild the mesh every step and stutter the stand that comes with it.)
    private var flushTarget: Float = 0
    private var flushFrom: Float = 0
    private var flushAt = -100.0
    private var flushApplied: Float = 0
    private var flushAmount: Float { flushFrom + (flushTarget - flushFrom) * MoodTiming.progress(age: CACurrentMediaTime() - flushAt, duration: 2) }
    /// Diagnostics: how red (0…1) and whether standing, as shown now.
    var flushLevel: Float { flushAmount }
    var isStanding: Bool { standTo > 0 }
    func setFlushed(_ on: Bool) {
        let target: Float = on ? 1 : 0
        guard target != flushTarget else { return }
        flushFrom = flushAmount; flushTarget = target; flushAt = CACurrentMediaTime()
        wake(for: 2.15)
    }
    /// What warms with the angry flush: Moku's plush, or the materials a companion's rules mark `flush`.
    private static let flushedMaterials: Set<String> = ["Ivory_woven_plush", "Ivory_face_diffuse_blush", "Warm_milk_plush", "Petal_pink_velour", "Ivory_woven_fuzz", "Ivory_face_fuzz", "Warm_milk_fuzz"]
    private let flushed: Set<String>
    /// Where a companion's flushed materials go instead of warming (Tetsu's cyan LEDs turn amber).
    private let flushColors: [String: [CGFloat]]
    private func applyFlush() {
        let amount = (flushAmount * 24).rounded() / 24
        guard amount != flushApplied, var model = rig.model else { return }
        flushApplied = amount
        model.materials = baseMaterials.enumerated().map { index, material in
            if index == displayIndex, let pixelFace { return pixelFace.material }
            guard index < materialNames.count, flushed.contains(materialNames[index]),
                  var plush = material as? PhysicallyBasedMaterial else { return material }
            if let color = flushColors[materialNames[index]] {
                plush.baseColor.tint = Self.toward(color, from: plush.baseColor.tint, amount)
                plush.emissiveColor.color = Self.toward(color, from: plush.emissiveColor.color, amount)
            } else { plush.baseColor.tint = Self.flushed(plush.baseColor.tint, amount) }
            return plush
        }
        rig.model = model
    }
    /// A colour part of the way to `color` (linear RGB).
    private static func toward(_ color: [CGFloat], from tint: NSColor, _ amount: Float) -> NSColor {
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        guard amount > 0, color.count >= 3, let c = tint.cgColor.converted(to: linear, intent: .defaultIntent, options: nil)?.components, c.count >= 3 else { return tint }
        let a = CGFloat(amount)
        return NSColor(cgColor: CGColor(colorSpace: linear, components: [c[0] + (color[0] - c[0]) * a, c[1] + (color[1] - c[1]) * a, c[2] + (color[2] - c[2]) * a, c.count > 3 ? c[3] : 1])!)!
    }
    /// Green and blue give way in linear light: cream warms to a soft red.
    private static func flushed(_ tint: NSColor, _ amount: Float) -> NSColor {
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        guard amount > 0, let c = tint.cgColor.converted(to: linear, intent: .defaultIntent, options: nil)?.components, c.count >= 3 else { return tint }
        let a = CGFloat(amount)
        return NSColor(cgColor: CGColor(colorSpace: linear, components: [c[0], c[1] * (1 - 0.30 * a), c[2] * (1 - 0.38 * a), c.count > 3 ? c[3] : 1])!)!
    }
    func setDrifting(_ on: Bool) {
        guard drifting != on else { return }
        drifting = on
        if on { driftHeadAnchor = headLook }
        beginGaze(); wake(for: GazeTiming.duration + 0.1)
    }
    private var noticesUser = false
    private var noticedAt = -100.0
    private var hoverOn = false
    private var hoverChangedAt = -100.0
    /// When the pointer last came onto the character (a machine's hover tilt runs its course from here).
    private var hoverBeganAt = -100.0
    /// A machine's antennae twitch from here (the pointer comes on; it locks on to you).
    private var antennaTwitchAt = -100.0
    /// A machine seeing you: when its eyes lock on (after its head has turned).
    private var lockDueAt: Double?
    private var hoverStrength: Float = 0
    /// Where the delight was when the pointer last came or went: it eases from there on the clock (see `pose`).
    private var hoverFrom: Float = 0
    private var micro: MicroExpression?
    private var microStartedAt = -100.0
    private var cachedMicroUntil = -100.0
    private var microFrames: [String: [CGImage]] = [:]
    /// What the micro-expression cache may hold: 24 MB, about 15 frames at the standard size.
    private static let microCacheBytes = 24 << 20
    private var bakingMicroKey: String?
    private var bakingMicroFrames: [CGImage] = []
    private var bakingMicroUntil = -100.0
    private(set) var microCount = 0
    private(set) var microCacheHits = 0
    /// Diagnostics: the frames the micro-expression cache holds.
    var microCacheFrames: Int { microFrames.values.reduce(0) { $0 + $1.count } }
    // Life between the big moments (ExpressionLife.swift): seeded rhythm, lids, little moves, reading darts.
    private var random = LifeRandom(seed: LifeRandom.seed)
    private var rhythm = LifeRhythm(now: CACurrentMediaTime())
    /// How much longer the waits between little face and body moves are (the stage sets it: PowerPolicy).
    var lifeScale = 1.0
    private var lids = LidTension()
    private var lidsSetAt = -100.0
    private var lidChoiceDue = false
    private var lifeMove: LifeMove?
    private var lifeAt = -100.0, lifeMood = Mood.content
    private var lifeFadeAt: Double?
    /// A move set to begin this long after the next warm frame (see `framesSinceWake`).
    private var lifeArmedOffset: Double?
    /// A face move waiting to join the next blink (the face is rebuilt then anyway), or to go on its own at `until`.
    private var pendingLife: (move: LifeMove, until: Double)?
    private var readingEyes = ReadingEyes()
    /// A move on the layer under way (Core Animation, no frames drawn): until when.
    private var layerMoveUntil = -100.0
    /// Since when nothing has moved (no frames drawn, no layer move, nothing on the stage): beats fill the stillness
    /// of moods without blinks.
    private var stillSince = 0.0
    /// The last little move that played (the rhythm's own `last` may be one still waiting).
    private var lastPlayed: LifeMove.Kind?
    /// Diagnostics: a move on the layer is under way.
    var layerMoveUnderWay: Bool { CACurrentMediaTime() < layerMoveUntil }
    /// Whether a pickup, a tilt or a squash is still on the picture (the demo's interaction-spam check).
    var holdingForDiagnostics: Bool { holding }
    /// The joints this character has, by leaf name: life moves use only those (and only morphs that move here).
    private lazy var jointLeaves = Set(rig.jointNames.map { String($0.split(separator: "/").last ?? "") })
    /// Audits: a fixed breath, so their frames stay exact.
    var auditBreath: Float = 0
    private(set) var hoverCount = 0
    var acceptsHover: Bool { running && active == nil && !moving }
    /// The clip playing now, if any.
    var playingClip: String? { active == nil ? nil : activeClipName }
    private var gazeDuration: Double { drifting ? 0.5 : GazeTiming.duration }
    private var transitionSettled: Bool { CACurrentMediaTime() - moodChangedAt >= moodDuration && CACurrentMediaTime() - gazeChangedAt >= gazeDuration && CACurrentMediaTime() >= smoothUntil }
    var acceptsExpression: Bool { running && active == nil && !moving && !hoverOn && transitionSettled }
    var expressionBusy: Bool { hoverOn || CACurrentMediaTime() < cachedMicroUntil || CACurrentMediaTime() - microStartedAt < (micro?.duration ?? 0) || CACurrentMediaTime() - earFlickAt < EarFlick.seconds }
    private var earFlickAt = -100.0, earFlickLeft = true, earFlickSide: Float = 1, earFlickArmed = false
    /// Frames finished since the renderer last woke. The first frame after idle is slow (the GPU wakes up), so the next
    /// is posed a few frames' time later: a quick move whose clock started with the window jumped across that gap (an ear
    /// flick's kick, 7° in one frame). Quick clocks (flicks, darts, little moves) start on the first warm frame instead.
    private var framesSinceWake = 0
    private var fidgeting: Fidget?, fidgetAt = -100.0
    /// A small living movement (Settings › Little movements): a paw, both paws, a foot, the head or the body,
    /// never the same kind twice running. Only while Moku sits quietly; false when it's busy.
    @discardableResult func fidget(_ kind: Fidget.Kind? = nil) -> Bool {
        let now = CACurrentMediaTime()
        guard running, active == nil, !pickedUp, !moving, !reduced, !drifting, !carrying, !arms.folded, !arms.isUnfolding, lifeMove == nil,
              now - fidgetAt > (fidgeting?.seconds ?? 0) else { return false }
        let kinds = Fidget.Kind.allCases.filter { $0 != fidgeting?.kind }
        let pick = Fidget(kind: kind ?? kinds.randomElement()!, side: Bool.random() ? 1 : -1)
        fidgeting = pick; fidgetAt = now; lifeEvents["fidget", default: 0] += 1
        // Slow and small, so 30 fps is plenty (60 would cost twice the CPU for nothing you can see). Not 24: a 60 Hz
        // display can't hold 24 evenly, and the uneven frames read as a wobble.
        wake(for: pick.seconds + 0.1); schedule(fps: 30); return true
    }
    /// Flick an ear (Settings › Ears): which ear and which way are chosen at random. False when busy.
    @discardableResult func flickEar() -> Bool {
        let now = CACurrentMediaTime()
        guard running, active == nil, !pickedUp, !moving, !reduced, lifeMove == nil, now - earFlickAt > EarFlick.seconds else { return false }
        earFlickAt = now + 1; earFlickArmed = true  // running, not yet begun: it begins on the first warm frame
        earFlickLeft = Bool.random(); earFlickSide = Bool.random() ? 1 : -1; lifeEvents["earFlick", default: 0] += 1
        smoothFor(0.8); wake(for: EarFlick.seconds + 0.15); return true
    }
    func setHover(_ on: Bool) {
        guard on != hoverOn else { return }
        hoverFrom = hoverStrength  // a quick in and out never jumps
        hoverOn = on; hoverChangedAt = CACurrentMediaTime(); cancelMicro()
        if on { hoverCount += 1; hoverBeganAt = hoverChangedAt; antennaTwitchAt = hoverChangedAt }
        wake(for: on && !reduced ? 1.7 : 0.45)
    }
    func microExpression(_ expression: MicroExpression) {
        guard acceptsExpression, !expressionBusy, let baseImage = lastImage else { return }
        fadeLife()
        // Cached frames are only good for the same lids, breath and eyes as the frame on screen.
        let key = "\(mood.rawValue)/\(expression.rawValue)/\(noticesUser)/\(eyeTarget)/\(reduced)/\(drifting)/\(headLook)/\(flushTarget)/\(standTo)/\(lids.weights.sorted { $0.key < $1.key })/\((breathShown * 32).rounded())/\(readingEyes.target)/\(lifeMove == nil)"
        microStartedAt = CACurrentMediaTime(); microCount += 1; lifeEvents["micro.\(expression.rawValue)", default: 0] += 1
        if let frames = microFrames[key] {
            microCacheHits += 1
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.values = [baseImage] + frames + [baseImage]
            animation.duration = expression.duration
            imageLayer.add(animation, forKey: "micro")
            cachedMicroUntil = microStartedAt + expression.duration
            return
        }
        micro = expression
        bakingMicroKey = key; bakingMicroFrames = [baseImage]; bakingMicroUntil = microStartedAt + expression.duration
        // Baked at 12 fps, and at 24 with Reduce Motion: there the look-up smile is this (no head turn), so its eyes closed in
        // three steps of 0.3.
        wake(for: expression.duration + 0.06); schedule(fps: reduced ? 24 : 12)
    }
    private func cancelMicro() {
        micro = nil; bakingMicroKey = nil; bakingMicroFrames.removeAll(); cachedMicroUntil = -100
        imageLayer.removeAnimation(forKey: "micro")
        fadeLife()
    }
    // MARK: Life between the big moments

    /// The stage's tick (ten a second): the next little move when one is due, and the breath following the mood.
    /// `occupied`: the stage has Moku busy (a glance, a return, speech, travel, a grab, the pointer on it).
    func live(occupied: Bool) {
        let now = CACurrentMediaTime()
        refreshBreath(now: now); tickCursor(now)
        guard running, !reduced else { return }
        if let move = lifeMove, move.onLayer, now >= layerMoveUntil { lifeMove = nil }
        // Anything moving (frames being drawn, a layer move, the stage busy with Moku) resets the stillness clock.
        if timer != nil || now < layerMoveUntil || occupied { stillSince = now }
        if let pending = pendingLife, pending.move.onLayer {
            // A deeper breath waits for the bottom of this one (at most 1.2 s: it was chosen only that near).
            if lifeMove == nil, !occupied, lifeAllowed(pending.move, now: now), playOnLayer(pending.move, now: now) { pendingLife = nil }
            else if now >= pending.until { pendingLife = nil; rhythm.dropped(pending.move.kind); lifeEvents["dropped." + pending.move.kind.rawValue, default: 0] += 1 }
        } else if let pending = pendingLife, lifeMove == nil {
            // A waiting move joins frames already being drawn (a fidget, a dart, a gaze turn), or goes on its own once
            // it has waited long enough. A face move waits for a blink while blinks show.
            let window = timer != nil && !(pending.move.touchesFace && blinksShow)
            if !occupied && (window || now >= pending.until) && lifeAllowed(pending.move, now: now) { pendingLife = nil; startLife(pending.move, at: now) }
            else if now >= pending.until + 4 { pendingLife = nil; rhythm.dropped(pending.move.kind); lifeEvents["dropped." + pending.move.kind.rawValue, default: 0] += 1 }  // still busy: let it go
        }
        let shapes = morphs.movingShapes, joints = jointLeaves
        if lifeMove == nil, pendingLife == nil, now >= rhythm.nextAt {
            // Busy (the strictest test: a move with ears): it waits a moment rather than being skipped.
            guard !occupied, lifeAllowed(LifeMove(kind: .earPerk, side: 1, strength: 1), now: now) else { rhythm.postpone(until: now + 0.6); return }
            if let move = rhythm.next(mood: mood, now: now, slowedBy: lifeScale, using: &random, playable: { $0.playable(shapes: shapes, joints: joints) }) { pendingLife = (move, now + 6); lifeEvents["waits." + move.kind.rawValue, default: 0] += 1; return }
        }
        // A beat on the layer once Moku has been still a while (happy, proud: no blinks), even while a face move waits
        // for its frames; one move at a time, so never over a fidget or an ear flick either.
        guard lifeMove == nil, pendingLife.map({ !$0.move.onLayer }) ?? true, !occupied, timer == nil,
              fidgeting.map({ now - fidgetAt > $0.seconds }) ?? true, !earFlickArmed, now - earFlickAt > EarFlick.seconds,
              lifeAllowed(LifeMove(kind: .sway, side: 1, strength: 1), now: now) else { return }
        // Never the kind just seen either (a face move picked before it may still be waiting for its frames).
        let swellSoon = pendingLife == nil && breathBottom(within: 1.2, now: now), seen = lastPlayed  // (a swell would wait in a face move's place)
        guard let beat = rhythm.beat(mood: mood, stillFor: now - stillSince, using: &random, playable: { $0 != seen && ($0 != .breathSwell || swellSoon) }) else { return }
        if beat.kind == .breathSwell, !playOnLayer(beat, now: now) { pendingLife = (beat, now + 1.4) }
        else if beat.kind != .breathSwell { _ = playOnLayer(beat, now: now) }
    }
    /// A move on the image layer (Core Animation: no frames drawn). False when it can't start now: a deeper breath
    /// starts only at the bottom of a breath.
    private func playOnLayer(_ move: LifeMove, now: Double) -> Bool {
        guard lifeMove == nil, lifeAllowed(move, now: now) else { return false }
        if move.kind == .breathSwell {
            guard swellBreath(now: now, factor: 1 + 0.7 * move.strength) else { return false }
            layerMoveUntil = now + breath.seconds
        } else {
            lean(move, from: now)
            layerMoveUntil = now + move.seconds
        }
        lifeMove = move; lifeAt = now; lifeArmedOffset = nil; lifeMood = mood; lifeFadeAt = nil; stillSince = now; lastPlayed = move.kind
        lifeEvents[move.kind.rawValue + (move.side > 0 ? ".L" : ".R"), default: 0] += 1
        return true
    }
    /// The layer leans about Moku's feet (a turn, and the shift that keeps the feet where they were), added to whatever
    /// else the layer does (the breath, a hold). Sampled at 30 a second; Core Animation draws the in-betweens.
    private func lean(_ move: LifeMove, from now: Double) {
        let seconds = move.seconds, steps = max(2, Int(seconds * 30))
        var angles = (0...steps).map { LayerLean.angle(move.kind, side: move.side, strength: move.strength, at: seconds * Double($0) / Double(steps)) }
        if companion.isMachine {  // a machine leans like a servo: over quickly, held, back
            let peak = angles.max { abs($0) < abs($1) } ?? 0
            angles = (0...steps).map { peak * ServoTiming.envelope(age: seconds * Double($0) / Double(steps), seconds: seconds) }
        }
        addLean(angles, seconds: seconds, begin: now)
    }
    private func addLean(_ angles: [Float], seconds: Double, begin: Double) {
        let feet = Float(feetAboveCentre), times = angles.indices.map { NSNumber(value: Double($0) / Double(max(1, angles.count - 1))) }
        func track(_ path: String, _ values: [Float]) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: path); a.values = values.map { NSNumber(value: $0) }; a.keyTimes = times
            a.duration = seconds; a.isAdditive = true; return a
        }
        let shift = angles.map { LayerLean.pivot(angle: $0, feet: feet) }
        let group = CAAnimationGroup()
        group.animations = [track("transform.rotation.z", angles), track("position.x", shift.map(\.x)), track("position.y", shift.map(\.y))]
        group.beginTime = begin; group.duration = seconds
        group.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        imageLayer.add(group, forKey: "lifeLean")
    }
    /// Something bigger takes over mid-lean: the lean eases home over 0.3 s from where it is.
    private func easeOutLean(now: Double) {
        guard let move = lifeMove, move.kind == .sway || move.kind == .rock, now < layerMoveUntil else { return }
        let from = LayerLean.angle(move.kind, side: move.side, strength: move.strength, at: now - lifeAt)
        addLean((0...9).map { from * (1 - Float(LifeCurve.smooth(Double($0) / 9))) }, seconds: 0.3, begin: now)
        layerMoveUntil = now + 0.3
    }
    /// Whether nothing else is moving Moku's face or head: no clip (or the ease out of one), travel, hold, hover,
    /// expression, settling mood or gaze, standing up or sitting down, or (for a move with ears) ear flick. Blinks,
    /// darts and fidgets may run alongside: other parts, and drawing them anyway is what makes the move cheap.
    private func lifeAllowed(_ move: LifeMove, now: Double) -> Bool {
        running && !reduced && active == nil && !moving && !pickedUp && !holding && !hoverOn
            && now - moodChangedAt >= moodDuration && now - gazeChangedAt >= gazeDuration && now - standAt > 2.1
            && (clipExit.map { now - $0.at >= Self.clipExitSeconds } ?? true)
            && micro == nil && now >= cachedMicroUntil && (!move.usesEars || now - earFlickAt > EarFlick.seconds)
    }
    /// Blinks show unless the eyes are closed arcs (happy, proud) or shut (a doze).
    private var blinksShow: Bool {
        max(lastAppliedFace["eyes_happy"] ?? 0, lastAppliedFace["eyes_proud"] ?? 0) < 0.3 && min(lastAppliedFace["blink_L"] ?? 0, lastAppliedFace["blink_R"] ?? 0) < 0.85
    }
    private func startLife(_ move: LifeMove, at start: Double) {
        let now = CACurrentMediaTime()
        guard lifeAllowed(move, now: now) else { return }
        lifeMove = move; lifeAt = now + 10; lifeArmedOffset = max(0, start - now); lifeMood = mood; lifeFadeAt = nil; lastPlayed = move.kind
        lifeEvents[move.kind.rawValue + (move.side > 0 ? ".L" : ".R"), default: 0] += 1
        let length = start - now + move.seconds + 0.05
        if move.quick { smoothFor(length) } else { wake(for: length) }
    }
    /// Something bigger takes over: the move eases out over 0.18 s instead of vanishing (a lean on the layer, over 0.3 s;
    /// a deeper breath is a breath, and ends as one).
    private func fadeLife() {
        pendingLife = nil
        if let move = lifeMove, move.onLayer { easeOutLean(now: CACurrentMediaTime()); lifeMove = nil; return }
        guard lifeMove != nil, lifeFadeAt == nil else { return }
        lifeFadeAt = CACurrentMediaTime(); wake(for: 0.2)
    }
    private func resetLife() {
        lifeMove = nil; lifeFadeAt = nil; lifeArmedOffset = nil; pendingLife = nil; readingEyes = ReadingEyes(); lids = LidTension(); lidChoiceDue = false
        earFlickArmed = false; layerMoveUntil = -100; imageLayer.removeAnimation(forKey: "lifeLean")
    }
    /// What the move adds on this frame (eased out if fading); clears it once done. Moves on the layer add nothing here.
    private func lifeSample(now: Double) -> LifeSample {
        guard let move = lifeMove, !move.onLayer else { return LifeSample() }
        var k: Float = 1
        if let fade = lifeFadeAt { k = 1 - MoodTiming.progress(age: now - fade, duration: 0.18) }
        if now - lifeAt >= move.seconds || k <= 0 { lifeMove = nil; lifeFadeAt = nil; return LifeSample() }
        var sample = move.sample(at: now - lifeAt, mood: lifeMood).scaled(k)
        sample.weights = sample.weights.filter { morphs.movingShapes.contains($0.key) }
        sample.angles = sample.angles.filter { jointLeaves.contains($0.key) }
        return sample
    }
    /// A window new to Moku came to the front (Moku's talent, next-wave.md §2): it sniffs it. It may join a gaze turn (the
    /// cursor usually moves with the window), but waits for nothing: when Moku is busy (a clip, a mood changing, the
    /// pointer on it, another little move) it's skipped. A lean on the layer eases out for it.
    func sniff() {
        let now = CACurrentMediaTime(), move = LifeMove(kind: .sniff, side: 1, strength: 1)
        // Organic only: a machine notices a new window its own way (Tetsu loads it on its display).
        guard !companion.isMachine, running, !reduced, !drifting, active == nil, !moving, !pickedUp, !holding, !hoverOn, now - moodChangedAt >= moodDuration,
              micro == nil, now >= cachedMicroUntil, now - earFlickAt > EarFlick.seconds, clipExit.map({ now - $0.at >= Self.clipExitSeconds }) ?? true,
              move.kind.playable(shapes: morphs.movingShapes, joints: jointLeaves), lifeMove.map({ $0.onLayer }) ?? true else { return }
        if lifeMove != nil { fadeLife() }
        pendingLife = nil
        lifeMove = move; lifeAt = now + 10; lifeArmedOffset = 0; lifeMood = mood; lifeFadeAt = nil; lastPlayed = move.kind
        lifeEvents["sniff", default: 0] += 1
        smoothFor(move.seconds + 0.05)
    }
    /// How long until the next blink: uneven, and now and then a quick second one.
    /// `stretch`: after long focus the waits are a little longer (PowerPolicy); a quick second blink stays quick.
    func nextBlinkWait(focused: Bool, stretch: Double = 1) -> Double {
        if random.chance(0.12) { return random.range(0.45...0.6) }
        return stretch * (focused ? random.wait(floor: 2.2, mean: 6.1, cap: 9) : random.wait(floor: 1.8, mean: 4.5, cap: 7))
    }
    func suppressExpressions() {
        cancelMicro()
        if hoverOn { setHover(false) }
    }
    /// Where the frames' bytes come from (FramePool), and the last frame's, for telling whether a point is on Moku.
    private var framePool = FramePool(byteCount: StageGeometry.textureSize * StageGeometry.textureSize * 4)
    private var lastFrame: (buffer: FrameBuffer, side: Int)?
    /// Pixels rendered for each one a Retina display shows (Charles, 2026-10-14: "it should feel premium and pixel dense,
    /// now it feels pixellated kinda some bad edges"). The renderer's own 4× multisampling left the eyes' rings and the
    /// head's outline stepping where the render was shown pixel for pixel; drawn bigger and scaled down by the layer,
    /// they come out smooth. The demo's --sharpness shows each size and its cost (1.75×: about 2.5 ms more a frame).
    static let supersampling: CGFloat = 1.75
    /// The biggest render: the welcome's (2× its size), as before.
    static let largestTexture = 1280
    /// Renders bigger than Moku is shown (`supersampling`), at least the standard 640 px, at most `largestTexture`;
    /// the layer scales it down smoothly. A frame in flight finishes first.
    func setResolution(for scale: CGFloat) {
        let wanted = CGFloat(StageGeometry.textureSize) * max(1, scale * Self.supersampling)
        let size = min(Self.largestTexture, Int((wanted / 16).rounded()) * 16)
        guard size != textureSize || pendingTextureSize != nil else { return }
        if busy { pendingTextureSize = size } else { makeTarget(size: size) }
    }
    private func makeTarget(size: Int) {
        pendingTextureSize = nil
        guard size != textureSize else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: size, height: size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        guard let target = texture.device.makeTexture(descriptor: descriptor), let output = try? RealityRenderer.CameraOutput(.singleProjection(colorTexture: target)) else { return }
        texture = target; self.output = output; textureSize = size
        framePool.retire(); framePool = FramePool(byteCount: size * size * 4); lastFrame = nil
        // Cached frames were drawn at the old resolution.
        cancelMicro(); microFrames.removeAll()
        wake(for: 0.2)
    }
    private var active: AnimationPlaybackController?
    private struct Clip { let joints: AnimationResource; let face: SampledAnimation<BlendShapeWeights>? }
    private var clipCache: [String: Clip] = [:]
    private(set) var clipBindChecks: [String: Float] = [:]
    /// Releases (uncross, unfold) whose first frame is the held pose its mood shows (within 2° a joint): they start with no
    /// blend (see `startClip`). A companion whose clips don't match yet keeps the blend.
    private(set) var releasesOnHold: Set<String> = []
    private var cup: PropAttachment?
    private var carriedLantern: PropAttachment?
    private var carrying = false
    private var lanternBrightness: Float = 0.15
    func setLanternBrightness(_ brightness: Double) {
        lanternBrightness = Float(max(0.15, brightness)); carriedLantern?.setIntensity(lanternBrightness)
        if carrying { wake(for: 0.1) }
    }
    func setCarrying(_ on: Bool) async {
        do {
            if on && carriedLantern == nil { carriedLantern = try await PropAttachment.load(clip: "carry_lantern", rig: rig, companion: companion) }
            guard !Task.isCancelled else { return }
            if carrying != on {
                moodFromWeights = currentWeights; moodFromAngles = currentMoodAngles
                moodChangedAt = CACurrentMediaTime(); moodDuration = 2.4
                wake(for: moodDuration + 0.15)
            }
            carrying = on; carriedLantern?.setIntensity(lanternBrightness); carriedLantern?.update(visible: on, rig: rig); wake(for: 0.4)
        } catch { self.error = "Lantern: \(error.localizedDescription)" }
    }
    private var activeClipName: String?
    /// The Mac is short of memory (a warning or critical pressure event): Moku lets go of everything it can make again,
    /// and its little moves come half as often for two minutes (PowerPolicy). What is on show, and what is playing, stays.
    func relieveMemory() {
        microFrames.removeAll(); if bakingMicroKey == nil { bakingMicroFrames.removeAll() }
        clipCache = clipCache.filter { $0.key == activeClipName }  // a clip loads again when it's next played
        pixelFace?.dropCaches()
        framePool.trim()
        malloc_zone_pressure_relief(nil, 0)
        PowerPolicy.shortOfMemoryUntil = CACurrentMediaTime() + 120
    }
    private var activeFace: SampledAnimation<BlendShapeWeights>?
    private var smileUntil = 0.0
    private var smileStartedAt = -100.0
    /// The soft smile while Moku looks at the user (content only): eases in after it turns, and out as it turns away.
    private var userSmile = Ease()
    private var clipTask: Task<Void, Never>?
    private let arms = ArmUnfoldGate()
    private(set) var clipHistory: [String] = []
    private var activeUntil = 0.0
    private var moving = false
    private var pickedUp = false
    // In your hand. The stage's display-rate loop hands over the swing (`holdAngle`: the pendulum while held,
    // the tumble in a throw) every frame, and it's laid on the layer around the grip, so Moku hangs from where
    // you hold it. `lift` eases the hanging stretch in and out (overshooting into a soft squash when set down),
    // `squish` is the bump against a screen edge. The 3D pose (ears and feet swinging) follows at 30 fps.
    private var lift = Spring(), squish = Spring()
    private var holdAngle = 0.0
    private var grip = CGPoint(x: 0.5, y: 0.7)  // in the image, unit coordinates
    private var holding: Bool { pickedUp || !lift.isSettled(at: 0) || !squish.isSettled(at: 0) || abs(holdAngle) > 0.002 }
    private static let liftSpring = (stiffness: Float(160), damping: Float(17)), squishSpring = (stiffness: Float(260), damping: Float(14))
    /// Picked up at `point` (stage points).
    func beginPickup(at point: CGPoint) {
        faceTravel(0)
        pickedUp = true; clipTask?.cancel(); active?.stop(); active = nil; activeUntil = 0; clipExit = nil; arms.reset(); suppressExpressions()
        imageLayer.removeAnimation(forKey: "breathing"); imageLayer.removeAnimation(forKey: "breathSwell"); imageLayer.removeAnimation(forKey: "happyBounce"); swellUntil = -100; settleEyes()
        let frame = imageLayer.frame
        grip = CGPoint(x: min(1, max(0, (point.x - frame.minX) / frame.width)), y: min(1, max(0, (point.y - frame.minY) / frame.height)))
        wake(for: 0.3); schedule(fps: 30)
    }
    func endPickup(reduced: Bool) {
        guard pickedUp else { return }; pickedUp = false
        if standAfterClip { standAfterClip = false; stand(true) }  // picked up mid-pat or mid-hop while standing
    }
    /// A screen edge stopped a throw at `speed` points per second.
    func bump(speed: Double) { squish.velocity += Float(min(12, speed / 160)) }
    /// One display frame of the hold, from the stage. Returns whether anything is still moving.
    @discardableResult func stepHold(seconds: Double, angle: Double) -> Bool {
        let dt = min(seconds, 1.0 / 30)
        lift.step(toward: pickedUp && !reduced ? 1 : 0, seconds: dt, stiffness: Self.liftSpring.stiffness, damping: Self.liftSpring.damping)
        squish.step(toward: 0, seconds: dt, stiffness: Self.squishSpring.stiffness, damping: Self.squishSpring.damping)
        holdAngle = reduced ? 0 : angle
        let settled = !holding
        if settled { lift = Spring(); squish = Spring(); holdAngle = 0 }
        let bounds = imageLayer.bounds, h = CGFloat(lift.value), q = CGFloat(squish.value)
        // Around the grip: stretch downward from it while held, squash (lift below 0) as it lands, squish on a bump.
        let offset = CGPoint(x: (grip.x - 0.5) * bounds.width, y: (grip.y - 0.5) * bounds.height)
        var t = CATransform3DMakeTranslation(-offset.x, -offset.y, 0)
        if companion.isMachine { t = CATransform3DConcat(t, CATransform3DMakeTranslation(0, -3 * q + 2 * min(0, h), 0)) }  // rigid: a jolt, a clunk down
        else { t = CATransform3DConcat(t, CATransform3DMakeScale(1 - 0.05 * h + 0.10 * q, 1 + 0.04 * h - 0.08 * q, 1)) }
        t = CATransform3DConcat(t, CATransform3DMakeRotation(holdAngle, 0, 0, 1))
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(offset.x, offset.y, 0))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.transform = settled ? CATransform3DIdentity : t
        CATransaction.commit()
        if settled {
            if breathingWanted { setBreathing(true) }
        } else {
            awakeUntil = max(awakeUntil, CACurrentMediaTime() + 0.15); if timer == nil { schedule(fps: 30) }
        }
        return !settled
    }
    private var awakeUntil = 0.0
    private var bakingBlink = false
    private var lastFPSAt = CACurrentMediaTime()
    private var frames = 0
    private(set) var fps = 0.0
    private(set) var renderedFrames = 0
    private(set) var blinkCount = 0
    private(set) var lastImage: CGImage?
    private(set) var error: String?
    var reduced = false
    var diagnostics: String { "weights: \(String(describing: rig.components[BlendShapeWeightsComponent.self]))\nactive: \(active?.time ?? -1) / \(active?.duration ?? -1)\njoints: \(rig.jointTransforms)" }
    var onFrame: (() -> Void)?
    /// Usage (the day's counts): one of the companion's talents played (Tetsu's scan and hologram).
    var onTalent: ((UsageTalent) -> Void)?
    /// Usage: frames missed while a move played (a clip or a move between poses), as they're noticed.
    var onFramesDropped: ((Int) -> Void)?
    /// The last frame was drawn while a move played: the gap to the next one says whether frames were missed.
    private var lastFrameInMove = false

    /// Who this is: every character file it reads is this companion's.
    let companion: Companion
    static func load(companion: Companion = .current) async throws -> RealityCharacter? {
        guard let url = MokuAssets.file("character/moku_bunny.usdz", companion: companion) else { return nil }
        let timing = ProcessInfo.processInfo.environment["MOKU_LOAD_TIMING"] == "1"
        var stepAt = CACurrentMediaTime()
        func step(_ name: String) { if timing { let now = CACurrentMediaTime(); NSLog("load %@ %@: %.0f ms", companion.rawValue, name, (now - stepAt) * 1000); stepAt = now } }
        memoryMark("before USD import")
        let character = try await Entity(contentsOf: url)
        step("usd")
        memoryMark("after USD import")
        guard let rig = descendants(character).compactMap({ $0 as? ModelEntity }).first(where: { !$0.jointNames.isEmpty }) else { return nil }
        // RealityKit drops imported names when a material parameter block changes.
        let materialNames = rig.model?.materials.map { $0.name?.replacingOccurrences(of: " ", with: "_") ?? "" } ?? []
        try await MaterialConfiguration.apply(to: character, companion: companion)
        step("materials")
        memoryMark("after materials")
        let moku = try RealityCharacter(rig: rig, materialNames: materialNames, companion: companion)
        step("init")
        if !Posture.seatedOnly { await moku.loadStandPoses() }
        await moku.preloadEverydayClips()
        step("clips")
        return moku
    }
    /// The tea (every break and water reminder) with its cup, and the nod (every return), loaded before Moku first
    /// shows: loaded on first use, the first tea froze Moku for 0.6 s and then jumped.
    private func preloadEverydayClips() async {
        for name in ["drink_water", "nod"] { _ = try? await loadClip(name) }
        if cup == nil { cup = try? await PropAttachment.load(clip: "drink_water", rig: rig, companion: companion) }
    }
    static func descendants(_ entity: Entity) -> [Entity] { [entity] + entity.children.flatMap { descendants($0) } }
    private init(rig: ModelEntity, materialNames: [String], companion: Companion) throws {
        self.companion = companion
        earTransitions = EarTransitions.load(companion: companion); hopContract = HopTravel.load(companion: companion)
        flushed = MaterialConfiguration.flushedNames(companion: companion) ?? Self.flushedMaterials
        // Detach the renderable from the USD import graph after preserving its
        // authored transform, materials, skeleton and sparse facial deltas.
        // Import metadata can otherwise retain unused source textures/geometry.
        let facialDriver = try FacialMorphs(mesh: rig.model!.mesh, materials: rig.model!.materials, transform: rig.transformMatrix(relativeTo: nil), materialNames: materialNames)
        var materials = rig.model!.materials
        pixelFace = PixelFace.load(companion: companion)
        displayIndex = pixelFace == nil ? nil : materialNames.firstIndex(of: "Tetsu_display")
        if let pixelFace, let displayIndex { materials[displayIndex] = pixelFace.material }
        flushColors = MaterialConfiguration.flushColors(companion: companion)
        let runtimeRig = ModelEntity(mesh: facialDriver.mesh, materials: materials)
        runtimeRig.name = rig.name
        runtimeRig.transform.matrix = rig.transformMatrix(relativeTo: nil)
        runtimeRig.jointTransforms = rig.jointTransforms
        let runtimeRoot = Entity(); runtimeRoot.addChild(runtimeRig)
        self.character = runtimeRoot; self.rig = runtimeRig; rest = runtimeRig.jointTransforms
        baseMaterials = runtimeRig.model?.materials ?? []; self.materialNames = materialNames
        morphs = facialDriver
        if let head = PropAttachment.jointMatrix(named: "head", names: runtimeRig.jointNames, transforms: runtimeRig.jointTransforms) {
            headAnchorLocal = (runtimeRig.transformMatrix(relativeTo: nil) * head).inverse * SIMD4(facialDriver.faceCenter, 1)
        }
        memoryMark("after detached mesh")
        runtimeRig.components.remove(BlendShapeWeightsComponent.self)
        moodFile = MokuAssets.file("character/moods.json", companion: companion).flatMap { try? JSONDecoder().decode(MoodFile.self, from: Data(contentsOf: $0)) }
        renderer = try RealityRenderer()
        memoryMark("after renderer init")
        guard let device = MTLCreateSystemDefaultDevice() else { throw CocoaError(.featureUnsupported) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: StageGeometry.textureSize, height: StageGeometry.textureSize, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw CocoaError(.featureUnsupported) }
        self.texture = texture; output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        renderer.cameraSettings.colorBackground = .color(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        renderer.cameraSettings.isToneMappingEnabled = true
        let fallbackURL = Bundle.module.url(forResource: "studio", withExtension: "json")!
        // A companion's own light first (Moku's is v0's, brighter and even: Charles, 2026-10-05, "the initial version color
        // was accurate"), else the shared studio.
        let studioURL = MokuAssets.file("character/studio.json", companion: companion) ?? MokuAssets.file("runtime/studio.json") ?? fallbackURL
        let studio = try JSONDecoder().decode(Studio.self, from: Data(contentsOf: studioURL))
        // One expanded canvas preserves the approved 160-point projection scale
        // while allowing raised ears and jumps, without reframing individual clips.
        let fov = 2 * atan(tan(studio.camera.fieldOfView * .pi / 360) * Float(StageGeometry.renderPoints / 160) / (studio.camera.safeAreaFraction ?? 1)) * 180 / .pi
        let camera = PerspectiveCamera(); camera.camera.fieldOfViewInDegrees = fov
        camera.look(at: Studio.vector(studio.camera.target), from: Studio.vector(studio.camera.position), relativeTo: nil)
        worldToCamera = camera.transformMatrix(relativeTo: nil).inverse
        projectionScale = 1 / tan(fov * .pi / 360)
        let lights = studio.lights.map { config in
            let light = DirectionalLight()
            light.light.color = NSColor(red: CGFloat(config.color[0]), green: CGFloat(config.color[1]), blue: CGFloat(config.color[2]), alpha: 1)
            light.light.intensity = config.intensity
            // A studio fill/rim does not need its own large cascaded shadow atlas.
            light.shadow = (config.castsShadow ?? true) ? .init(shadowProjection: .fixed(zNear: 0.01, zFar: 12, orthographicScale: config.shadowScale ?? 2), depthBias: 1) : nil
            light.look(at: Studio.vector(studio.camera.target), from: Studio.vector(config.position), relativeTo: nil)
            return light
        }
        let environmentColor = studio.environmentColor ?? [0.85, 0.82, 0.76]
        let environmentImage = studio.environment?.image() ?? Self.environmentImage(color: environmentColor)
        let cubeSize = max(16, min(256, studio.environmentCubeSize ?? 64))
        let cube = try TextureResource(cubeFromEquirectangular: environmentImage, faceSize: cubeSize, options: .init(semantic: .color))
        let environment = try EnvironmentResource(cube: cube, options: .init(specularCubeDimension: cubeSize))
        let lightProbe = Entity()
        lightProbe.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: studio.environmentIntensityExponent ?? 0))
        self.character.components.set(ImageBasedLightReceiverComponent(imageBasedLight: lightProbe))
        renderer.lighting.resource = environment
        renderer.lighting.intensityExponent = studio.environmentIntensityExponent ?? 0
        memoryMark("after environment")
        renderer.entities.append(contentsOf: [self.character, camera, lightProbe] + lights); renderer.activeCamera = camera
        imageLayer.frame = CGRect(x: 0, y: 0, width: StageGeometry.renderPoints, height: StageGeometry.renderPoints); imageLayer.contentsGravity = .resizeAspect
        imageLayer.minificationFilter = .trilinear  // small sizes scale the render down without shimmer
        if companion.isMachine, let spine = PropAttachment.jointMatrix(named: "spine", names: runtimeRig.jointNames, transforms: runtimeRig.jointTransforms),
           let lights = StatusLights(mesh: rig.model!.mesh, transform: rig.transformMatrix(relativeTo: nil), materialNames: materialNames, spine: runtimeRig.transformMatrix(relativeTo: nil) * spine) {
            statusLights = lights; imageLayer.addSublayer(lights.layer)
        }
        if companion.isMachine {
            hologramObserver = NotificationCenter.default.addObserver(forName: .mokuHousePieceLanded, object: nil, queue: .main) { [weak self] note in
                let units = note.userInfo?["units"] as? Int ?? 1
                MainActor.assumeIsolated { self?.showHologram(units: units) }
            }
        }
    }
    static func environmentImage(color: [Float]) -> CGImage {
        let width = 256, height = 128
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let brightness: Float = 0.75 + 0.25 * sin(Float(y) / Float(height) * .pi)
            for x in 0..<width { for channel in 0..<3 { bytes[(y*width+x)*4+channel] = UInt8(clamping: Int(color[channel] * brightness * 255)) } }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
    isolated deinit { timer?.invalidate(); clipTask?.cancel(); if let hologramObserver { NotificationCenter.default.removeObserver(hologramObserver) } }
    func start() {
        guard !running else { return }; running = true; lastTime = CACurrentMediaTime(); awakeUntil = max(lastTime + 0.6, moodChangedAt + moodDuration + 0.15, gazeChangedAt + gazeDuration + 0.1); schedule(fps: 30)
        setBreathing(true)
        if heldMood && !pickedUp && !carrying { foldForMood() }
    }
    func stop() { faceTravel(0); running = false; clipExit = nil; timer?.invalidate(); timer = nil; timerFPS = 0; clipTask?.cancel(); active?.stop(); active = nil; arms.reset(); moving = false; hoverOn = false; hoverStrength = 0; hoverFrom = 0; hoverBeganAt = -100; cancelMicro(); resetLife(); imageLayer.removeAllAnimations(); statusLights?.show(false, at: .zero, across: 0, pace: StatusLights.pace(mood, cross: false), reduced: reduced); pendingLights = nil; fps = 0 }
    private var timerFPS = 0.0
    /// Until then frames stay at 60 fps whatever else asks for, so standing up or sitting down never stutters.
    private var smoothUntil = 0.0
    /// Checks that time the frames have hooked `onFrame` (so a hook is added once).
    var onFrameHooked = false
    /// The most frames a second while something big asks for it (the welcome's life-size companion: 30); nil, none.
    var frameCap: Double? {
        didSet { if running, timer != nil, let frameCap, timerFPS > frameCap { schedule(fps: timerFPS) } }
    }
    private func schedule(fps requested: Double) {
        let fps = min(frameCap ?? .infinity, CACurrentMediaTime() < smoothUntil ? max(60, requested) : requested)
        // A running ticker changes pace in place (recreating it would restart its rhythm, a hitch).
        if let timer, timer.onDisplay == FrameTicker.canUseDisplay(of: hostView) {
            if timerFPS != fps { timer.set(fps: fps); timerFPS = fps }
            return
        }
        timer?.invalidate()
        timer = FrameTicker(fps: fps, host: hostView) { [weak self] in self?.render() }
        timerFPS = fps
    }
    /// A move playing (a clip, or a move between poses) whose frame came late: the frames it should have drawn meanwhile
    /// were missed. Gaps of a second or more are a sleep or a stop, not a stutter.
    private func noteDroppedFrames(gap: Double) {
        let inMove = active != nil || moving
        defer { lastFrameInMove = inMove }
        guard inMove, lastFrameInMove, timerFPS > 0, gap < 1 else { return }
        let missed = Int((gap * timerFPS).rounded()) - 1
        if missed > 0 && gap > 1.5 / timerFPS { onFramesDropped?(missed) }
    }
    /// `delay` holds the old face a moment first (a look-up turns to the user, then its eyes close happily).
    /// When Moku last woke from a doze: what follows (a welcome back, a stretch) waits for its eyes to open.
    private(set) var wokeAt = -100.0
    var justWoke: Bool { CACurrentMediaTime() - wokeAt < 1.5 }
    func setMood(_ mood: Mood, duration: Double = 2.4, delay: Double = 0) {
        guard self.mood != mood else { return }
        if self.mood == .sleepy { wokeAt = CACurrentMediaTime() }
        let waking = self.mood == .sleepy && pixelFace != nil  // Tetsu's display flickers on (below, once the mood is set)
        // Dozing: the gaze comes home and stays, so the head rests in the doze instead of following the screen.
        if mood == .sleepy { beginGaze(); eyeTarget = .zero; noticesUser = false; userSmile.go(to: 0, at: CACurrentMediaTime(), over: 0.6) }
        moodFromWeights = currentWeights; moodFromAngles = currentMoodAngles; earFrom = earCurrent
        lids.scale(lidFade(now: CACurrentMediaTime())); lidsSetAt = -100  // the lids' setting eases out with the old mood
        // Blend from the pose on screen when it isn't the idle pose: a clip, or a blend out of one still under way.
        // (Charles: cancelling a break mid-tea, then the drift's sad look a second later, snapped the tea pose away.)
        let easingOutOfClip = moodFromTransforms != nil && CACurrentMediaTime() - moodChangedAt < moodDuration
        moodFromTransforms = (active != nil || easingOutOfClip) && !moving ? rig.jointTransforms : nil
        moodChangedAt = CACurrentMediaTime() + delay; moodDuration = duration
        self.mood = mood; cancelMicro(); settleEyes()
        bakingBlink = false
        if !moving {
            clipTask?.cancel(); active?.stop(); active = nil; activeFace = nil; activeUntil = 0
            arms.reset()
            if heldMood && !pickedUp && !carrying { foldForMood() }
        }
        // A state change blends the static authored pose. No entry gesture,
        // turn-away or disappointed_hold animation interrupts that transition. A quick one (a happy look-up,
        // coming back) plays at 60 fps.
        smoothFor(delay + duration + 0.15)  // every mood change eases at 60 fps (at 30 a long one looked stepped)
        if waking && !reduced { playDisplayMoment("px_wake") }
    }
    /// The ask (a long drift): Tetsu's display shows a cursor on its bottom line, blinking, waiting for you.
    private var asking = false, cursorShown: Bool?
    func setAsking(_ on: Bool) {
        guard on != asking else { return }
        asking = on; cursorShown = nil; if pixelFace != nil { wake(for: 0.1) }
    }
    /// The cursor's blink: on 0.6 s, off 0.45 s (steady with reduced motion). The stage's tick draws a frame per change.
    private func cursorOn(_ now: Double) -> Bool { reduced || (now - began).truncatingRemainder(dividingBy: 1.05) < 0.6 }
    private func tickCursor(_ now: Double) {
        guard asking, pixelFace != nil, running, cursorShown != cursorOn(now) else { return }
        wake(for: 0.05)
    }
    private func foldForMood() {
        arms.foldedPoseBegan()
        releaseClipName = moodFile?.moods[mood.rawValue]?.transitionOut ?? "unfold_arms"
    }
    /// Keep rendering at 60 fps for a while: head turns and quick expressions stutter at 20 or 30.
    private func smoothFor(_ seconds: Double) { smoothUntil = max(smoothUntil, CACurrentMediaTime() + seconds); wake(for: seconds); schedule(fps: 60) }
    private func wake(for duration: Double) { guard running else { return }; awakeUntil = max(awakeUntil, CACurrentMediaTime() + duration); schedule(fps: 30) }
    func noticeUser() {
        guard !noticesUser else { return }
        cancelMicro(); settleEyes(); noticesUser = true; beginGaze(); eyeTarget = .zero; noticedAt = CACurrentMediaTime()
        // A machine turns (a servo), locks on to you (brackets on its display, its antennae twitch), then smiles ^^.
        if pixelFace != nil && !reduced { lockDueAt = noticedAt + 0.42 }
        if displayMoment?.channel == "px_scan" { displayMoment = nil; scanBeam.stop() }  // it stops reading to look at you
        if pixelFace != nil && !reduced {  // the smile's beat ends after the frames for the turn: draw its end
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.55) { [weak self] in
                guard let self, self.noticesUser else { return }
                self.wake(for: 0.4)
            }
        }
        userSmile.go(to: 1, at: noticedAt, over: 0.6, after: pixelFace != nil && !reduced ? 0.8 : 0.15)
        smoothFor(gazeDuration + 0.15)
    }
    /// Turn to a gaze direction in radians (yaw right, pitch up); zero looks straight at the user.
    func look(_ next: SIMD2<Float>) {
        guard mood != .sleepy else { return }  // a dozing Moku doesn't look around
        let wasUser = noticesUser; noticesUser = false; lockDueAt = nil
        if wasUser { userSmile.go(to: 0, at: CACurrentMediaTime(), over: 0.6) }  // as gently as it came
        guard wasUser || simd_length(next - eyeTarget) > 0.02 else { return }
        beginGaze(); eyeTarget = next; cancelMicro(); settleEyes(); smoothFor(gazeDuration + 0.15)
        spinPending = true
    }
    func blink() {
        guard running, active == nil, transitionSettled, !expressionBusy else { return }
        // Eyes already closed in a happy crescent (a look-up, a smile): a blink would swap the arc for a lid.
        guard max(lastAppliedFace["eyes_happy"] ?? 0, lastAppliedFace["eyes_proud"] ?? 0) < 0.3,
              SmileTiming.amount(age: CACurrentMediaTime() - smileStartedAt) == 0 else { return }
        // Lids already shut (a doze): a blink would draw frames that change nothing. Nor on a display showing dots.
        guard min(lastAppliedFace["blink_L"] ?? 0, lastAppliedFace["blink_R"] ?? 0) < 0.85 else { return }
        guard pixelFace == nil || mood != .sleepy else { return }
        // Rendered frame by frame at 60 fps. It used to crossfade two snapshots: ghosted half-open eyes, and a snap
        // at the end if Moku had moved meanwhile.
        let now = CACurrentMediaTime()
        if pixelFace != nil {  // a display: not lids, but a screen's blink, whole frames
            if let moment = displayMoment, now - moment.at < moment.seconds + Self.displayQuiet { return }
            if now < displayQuietUntil { return }
            blinkCount += 1; lifeEvents["blink", default: 0] += 1; displayBlink(); return
        }
        blinkStartedAt = now; blinkCount += 1; lifeEvents["blink", default: 0] += 1
        lidChoiceDue = random.chance(0.6)  // most blinks open to a slightly different lid
        if let pending = pendingLife, !pending.move.onLayer, lifeMove == nil, lifeAllowed(pending.move, now: now) { pendingLife = nil; startLife(pending.move, at: now + random.range(0...0.1)) }
        smoothFor(BlinkTiming.duration + 0.05)
    }
    /// The lids' setting fades as a new mood comes in (the mood brings its own lids).
    private func lidFade(now: Double) -> Float {
        lidsSetAt >= moodChangedAt ? 1 : 1 - MoodTiming.progress(age: now - moodChangedAt, duration: moodDuration)
    }
    private let hopContract: HopTravel
    private var travelHeading: Float = 0
    private var facingFrom: Float = 0
    private var facingTo: Float = 0
    private var facing: Float = 0
    private var facingAt = -100.0
    private func faceTravel(_ target: Float) { facingFrom = facing; facingTo = target; facingAt = CACurrentMediaTime() }
    var pointsPerWorldUnit: Double {
        let point = worldToCamera * SIMD4<Float>(0,0,0,1)
        return Double(projectionScale/max(0.001,-point.z))*Double(imageLayer.bounds.width)/2
    }
    func beginHopping(direction: Float) async -> Bool {
        clipTask?.cancel(); moving = true; suppressExpressions()
        beginGaze(); eyeTarget = .zero; noticesUser = false; userSmile.go(to: 0, at: CACurrentMediaTime(), over: 0.6)
        await unfoldIfNeeded()
        guard !Task.isCancelled else { return false }
        if travelHeading != 0 && direction != travelHeading {
            let duration = await startClip("hop_turn")
            do { try await Task.sleep(for: .seconds(duration)) } catch { return false }
        }
        travelHeading = direction; faceTravel(direction*0.45)
        let duration = await startClip("hop_start")
        do { try await Task.sleep(for: .seconds(duration)) } catch { return false }
        guard !Task.isCancelled else { return false }
        _ = await startClip("hop_cycle",loop: true); active?.pause()
        return active != nil
    }
    func sampleHop(_ phase: Double) {
        active?.time = phase*hopContract.duration
        wake(for: 0.2)
    }
    func finishHopping() async {
        moving = false; faceTravel(0)
        let duration = await startClip("hop_stop")
        do { try await Task.sleep(for: .seconds(duration)) } catch { return }
        guard !Task.isCancelled else { return }
        active?.stop(); active = nil; activeUntil = 0; wake(for: 0.4)
    }
    func walk(_ moving: Bool) {
        self.moving = moving
        if !moving { faceTravel(0) }
        if moving { play("hop_cycle", loop: true) } else { active?.stop(); active = nil; activeUntil = 0; if running { wake(for: 0.35); if heldMood && !pickedUp && !carrying { foldForMood() } } }
    }
    func perform(_ gesture: MokuKit.Gesture) {
        if gesture == .smile { play("__smile"); return }
        if gesture == .sniff { sniff(); return }
        if gesture == .standUp || gesture == .sitDown { stand(gesture == .standUp); return }
        let clips: [MokuKit.Gesture: String] = [.smile: "cheer", .nod: "nod", .glance: "look_around", .sigh: "sigh", .standUp: "sit_up_tall", .sitDown: "settle_down", .wave: "wave", .cheer: "cheer", .celebrate: "big_celebrate", .stretch: "stretch", .drinkWater: "drink_water", .yawn: "yawn", .patReaction: "pat_reaction"]
        // Tetsu's big celebration is a full spin on its seat, which Reduce Motion shouldn't play, even slowed: its cheer, arms up
        // and its display's ^^, is the calm version.
        if gesture == .celebrate, reduced, companion.isMachine { play("cheer"); return }
        if let clip = clips[gesture] { play(clip) }
    }
    func prepareForMovement() async {
        clipTask?.cancel(); suppressExpressions()
        await unfoldIfNeeded()
    }
    private func unfoldIfNeeded() async {
        await arms.unfold { [weak self] in
            guard let self, running else { return }
            let duration = await startClip(releaseClipName)
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
        }
    }
    private func play(_ name: String, loop: Bool = false) {
        guard running else { return }; clipTask?.cancel(); suppressExpressions()
        clipTask = Task { [weak self] in
            guard let self else { return }
            await unfoldIfNeeded()
            guard !Task.isCancelled, running else { return }
            if name == "__release" { return }
            if name == "__smile" {
                // Turning to the user first: the smile (and the eyes closing into crescents) waits for the head
                // to be most of the way round, instead of happening mid-turn.
                let now = CACurrentMediaTime(), turning = noticesUser ? max(0, 0.45 - (now - noticedAt)) : 0
                smileStartedAt = now + turning; smileUntil = smileStartedAt + SmileTiming.length
                smoothFor(smileUntil - now + 0.1); return
            }
            _ = await startClip(name, loop: loop)
        }
    }
    private func loadClip(_ name: String) async throws -> Clip {
            let key = name + (name == "walk_cycle" && carrying ? "/carrying" : "")
            let clip: Clip
            if let cached = clipCache[key] { clip = cached }
            else {
                guard let url = MokuAssets.file("character/anims/\(name).usdz", companion: companion) else { throw CocoaError(.fileReadUnknown) }
                let imported = try await Entity(contentsOf: url)
                guard let importedRig = Self.descendants(imported).compactMap({ $0 as? ModelEntity }).first(where: { !$0.jointNames.isEmpty }),
                      let resource = importedRig.availableAnimations.first(where: { ($0.name ?? "").contains("/Armature/") }) else { throw CocoaError(.fileReadUnknown) }
                guard importedRig.jointNames == rig.jointNames, importedRig.jointTransforms.count == rest.count else {
                    throw NSError(domain: "MokuVisual", code: 1, userInfo: [NSLocalizedDescriptionKey: "Base/clip joint contract mismatch: \(name)"])
                }
                let importedJoints = importedRig.model?.mesh.contents.skeletons.first?.joints ?? []
                let baseJoints = morphs.mesh.contents.skeletons.first?.joints ?? []
                guard importedJoints.count == baseJoints.count, !baseJoints.isEmpty else { throw NSError(domain: "MokuVisual", code: 3, userInfo: [NSLocalizedDescriptionKey: "Skeletons unavailable \(name): clip \(importedJoints.count), base \(baseJoints.count)"]) }
                var difference: Float = 0
                for (a, b) in zip(importedJoints, baseJoints) {
                    guard a.name == b.name, a.parentIndex == b.parentIndex else { throw NSError(domain: "MokuVisual", code: 4, userInfo: [NSLocalizedDescriptionKey: "Skeleton joint mismatch \(name): \(a.name) / \(b.name)"]) }
                    for (left, right) in [(a.inverseBindPoseMatrix, b.inverseBindPoseMatrix)] {
                        for column in 0..<4 { difference = max(difference, simd_length(left[column] - right[column])) }
                    }
                }
                clipBindChecks[name] = difference
                guard difference < 0.0001 else {
                    throw NSError(domain: "MokuVisual", code: 2, userInfo: [NSLocalizedDescriptionKey: "Base/clip bind mismatch: \(name) delta \(difference)"])
                }
                var definition = resource.definition
                var face = importedRig.availableAnimations.compactMap { $0.definition as? SampledAnimation<BlendShapeWeights> }.first
                if armClipNames.contains(name), var samples = definition as? SampledAnimation<JointTransforms> {
                    let indices = samples.jointNames.indices.filter { let leaf = samples.jointNames[$0].split(separator: "/").last ?? ""; return leaf.hasPrefix("arm_") || leaf.hasPrefix("hand_") }
                    samples.frames = samples.frames.map { frame in JointTransforms(indices.map { frame[$0] }) }
                    samples.jointNames = indices.map { samples.jointNames[$0] }; definition = samples
                    if startsOnHold(samples, release: name) { releasesOnHold.insert(name) }
                    if var values = face {
                        let indices = values.weightNames.indices.filter { ["arms_fold", "paws_lap"].contains(values.weightNames[$0]) }
                        values.frames = values.frames.map { frame in BlendShapeWeights(indices.map { frame[$0] }) }
                        values.weightNames = indices.map { values.weightNames[$0] }; face = values
                    }
                }
                if name == "walk_cycle", carrying, var samples = definition as? SampledAnimation<JointTransforms> {
                    let held = Set(carriedLantern?.holdAngles.keys.map { $0 } ?? [])
                    let indices = samples.jointNames.indices.filter { !held.contains(String(samples.jointNames[$0].split(separator: "/").last ?? "")) }
                    samples.frames = samples.frames.map { frame in JointTransforms(indices.map { frame[$0] }) }
                    samples.jointNames = indices.map { samples.jointNames[$0] }; definition = samples
                }
                clip = Clip(joints: try AnimationResource.generate(with: definition), face: face)
                if clipCache.count >= 64,let key = clipCache.keys.first { clipCache.removeValue(forKey: key) }; clipCache[key] = clip
            }
        return clip
    }
    /// Whether the release `release` starts on the arms its mood holds (rest·Rx·Ry·Rz of the mood's angles, as `pose`).
    private func startsOnHold(_ samples: SampledAnimation<JointTransforms>, release: String) -> Bool {
        guard let first = samples.frames.first, let held = moodFile?.moods.values.first(where: { $0.transitionOut == release }) else { return false }
        let leaves = rig.jointNames.map { String($0.split(separator: "/").last ?? "") }
        for (k, path) in samples.jointNames.enumerated() {
            let leaf = String(path.split(separator: "/").last ?? "")
            guard let i = leaves.firstIndex(of: leaf), k < first.count else { return false }
            let d = (held.jointEulerDegrees[leaf] ?? [0, 0, 0]).map { $0 * .pi / 180 }
            let q = rest[i].rotation * simd_quatf(angle: d[0], axis: [1, 0, 0]) * simd_quatf(angle: d[1], axis: [0, 1, 0]) * simd_quatf(angle: d[2], axis: [0, 0, 1])
            if 2 * acos(min(1, abs(simd_dot(q.vector, first[k].rotation.vector)))) > 2 * .pi / 180 { return false }
        }
        return true
    }
    func prepareReviewClips() async throws {
        for name in ["hop_start","hop_cycle","hop_stop","hop_turn","wave","nod","unfold_arms","uncross_arms"] { _ = try await loadClip(name) }
    }
    /// How long a clip takes to ease in. Clips start facing front, so from a head turned away a quick blend whips it
    /// round: the further it's turned, the slower. Straight out of a doze, slow too (a stretch shouldn't jerk the
    /// sleepy head up).
    private var clipBlendIn: Double {
        if justWoke { return 0.7 }
        return 0.15 + 0.45 * Double(min(1, simd_length(headLook) / 0.5))
    }
    @discardableResult private func startClip(_ name: String, loop: Bool = false) async -> Double {
        do {
            let clip = try await loadClip(name)
            guard !Task.isCancelled, running else { return 0 }
            if name == "drink_water" && cup == nil { cup = try await PropAttachment.load(clip: name, rig: rig, companion: companion) }
            guard !Task.isCancelled, running else { return 0 }
            cancelMicro(); settleEyes(); bakingBlink = false
            if !armClipNames.contains(name) && standing { standFrom = 0; standTo = 0; standAfterClip = true }  // a full-body clip takes over
            activeClipName = name; activeFace = clip.face; active?.stop(); clipExit = nil
            // A release (uncross, unfold) starts exactly on the held arms, so it needs no blend, and must not have one:
            // RealityKit blends the joints an arms-only clip doesn't animate toward no turn at all, which spun the eyes
            // (their rest is a half turn) and pulled the ears and head off the pose for the blend's length.
            let blend = auditSampling || releasesOnHold.contains(name) ? 0 : clipBlendIn
            active = rig.playAnimation(loop ? clip.joints.repeat() : clip.joints, transitionDuration: blend)
            active?.speed = reduced ? 0.65 : 1
            let duration = (active?.duration ?? 2) / Double(active?.speed ?? 1)
            activeUntil = loop ? .infinity : CACurrentMediaTime() + duration
            clipHistory.append(name); if clipHistory.count > 100 { clipHistory.removeFirst() }
            schedule(fps: reduced || armClipNames.contains(name) ? 30 : 60)
            return duration
        } catch is CancellationError { return 0 }
        catch { if !Task.isCancelled { self.error = "Clip \(name): \(error.localizedDescription)"; ErrorReports.report(.assetLoad, error) }; return 0 }
    }
    private func render() {
        guard running else { return }
        if busy { busySkips += 1; return }
        let now = CACurrentMediaTime(); let dt = min(0.1, now - lastTime)
        noteDroppedFrames(gap: now - lastTime); lastTime = now
        defer { renderCostPending = CACurrentMediaTime() - now }
        let t = now - began
        facing = facingFrom+(facingTo-facingFrom)*MoodTiming.progress(age: now-facingAt,duration: 0.45)
        character.orientation = simd_quatf(angle: facing,axis: SIMD3(0,1,0))
        if heldMood && !pickedUp && !carrying && !arms.folded && !arms.isUnfolding && active == nil && !moving && now > smileUntil { foldForMood() }
        if active == nil && now > awakeUntil && !bakingBlink && lastImage != nil { timer?.invalidate(); timer = nil; timerFPS = 0; fps = 0; framesSinceWake = 0; return }
        // A 60 fps burst (a blink, a dart) over a slower move has ended: the rest of it needs no more than 30.
        if timerFPS > 30 && now >= smoothUntil && active == nil { schedule(fps: 30) }
        if now > activeUntil, active != nil {
            let finished = activeClipName
            // Charles: after the drink "it suddenly takes its head to focusing, make it smooth and gradual".
            if !moving && !pickedUp { clipExit = (rig.jointTransforms, now) }
            active?.stop(); active = nil; awakeUntil = now + (finished == "fold_arms" ? 2.5 : 0.4); schedule(fps: 30)
            if clipExit != nil { smoothFor(Self.clipExitSeconds) }
            if standAfterClip && !pickedUp { standAfterClip = false; stand(true) }
            if heldMood && !pickedUp && !carrying && !moving && !arms.folded && !arms.isUnfolding { foldForMood() }
        }
        do {
            let posing = CACurrentMediaTime()
            pose(time: t, dt: dt)
            let flushing = CACurrentMediaTime()
            applyFlush()
            placeStatusLights()
            frameCosts.append((posing, flushing - posing, CACurrentMediaTime() - flushing)); if frameCosts.count > 600 { frameCosts.removeFirst() }
            cup?.update(clip: active == nil ? nil : activeClipName, normalizedTime: (active?.time ?? 0) / max(0.001, active?.duration ?? 1), rig: rig)
            carriedLantern?.update(visible: carrying, rig: rig)
            busy = true
            try renderer.updateAndRender(deltaTime: dt, cameraOutput: output, onComplete: { [weak self] _ in
                Task { @MainActor in self?.finishFrame() }
            })
        } catch { busy = false; self.error = error.localizedDescription; stop() }
    }
    private func pose(time: Double, dt: Double) {
        let pose = moodFile?.moods[mood.rawValue]
        let now = CACurrentMediaTime()
        let hoverAge = now - hoverChangedAt
        // The delight eases in and out on the clock, from where it was when the pointer came or went. It used to take a
        // step of the frame's time (dt × 14, dt capped at 0.1 s), so the first frame after the renderer had slept for
        // the pointer took all of it: the eyes shut into arcs in one frame (docs/specs/launch-qa.md, lens 4).
        hoverStrength = HoverDelight.strength(from: hoverFrom, rising: hoverOn, age: hoverAge)
        let microProgress = (now - microStartedAt) / (micro?.duration ?? 1)
        let sample = MicroSample(micro, progress: microProgress, shapes: morphs.availableShapes, baseline: pose?.blendShapes ?? [:], pleased: mood.isPleased)
        if microProgress >= 1 { micro = nil }
        // Quick clocks begin on a warm frame; whatever is under way keeps frames coming (at its pace) until it lands.
        if framesSinceWake > 0 {
            readingEyes.begin(at: now)
            if let offset = lifeArmedOffset { lifeAt = now - 1.0 / 60 + offset; lifeArmedOffset = nil }
            if earFlickArmed { earFlickAt = now - 1.0 / 60; earFlickArmed = false }
        }
        let life = reduced ? LifeSample() : lifeSample(now: now)
        if readingEyes.moving(at: now) { awakeUntil = max(awakeUntil, readingEyes.at + readingEyes.seconds + 0.04) }
        if let move = lifeMove, !move.onLayer, lifeArmedOffset == nil {
            awakeUntil = max(awakeUntil, lifeAt + move.seconds + 0.04)
            if move.quick { smoothUntil = max(smoothUntil, lifeAt + move.seconds + 0.04) }
        }
        // A flick's kick needs 60 fps; its last half second is a wobble under half a degree a frame at 30.
        if !earFlickArmed && now - earFlickAt < EarFlick.seconds { awakeUntil = max(awakeUntil, earFlickAt + EarFlick.seconds + 0.1); smoothUntil = max(smoothUntil, earFlickAt + 0.7) }
        // The 3D breath follows the layer's only on drawn frames, no faster than Breath.catchUp, so a frame drawn
        // after a pause never jumps; it rests while an arm clip holds the arms.
        let breathing = breathingWanted && imageLayer.animation(forKey: "breathing") != nil && !reduced && !isArmClip
        let deeper: Float = now < swellUntil ? swell : 1  // a deeper breath (a beat) starts and ends at a bottom: no jump
        let breathTarget = breathing ? breath.amount(at: now) * breathDepth * deeper : 0, breathLimit = Breath.catchUp * Float(dt)
        breathShown = auditSampling ? auditBreath : breathShown + max(-breathLimit, min(breathLimit, breathTarget - breathShown))
        // During a clip the renderer is running anyway, so it blinks on its own clock; otherwise blink() starts one.
        if time >= nextBlink { nextBlink = time + Double.random(in: 2.6...6.8); if active != nil { blinkStartedAt = now; blinkCount += 1 } }
        let smiling = SmileTiming.amount(age: now - smileStartedAt), userSmiling = userSmile.value(at: now)
        let blink: Float = bakingBlink ? 1 : BlinkTiming.amount(age: now - blinkStartedAt)
        let names = morphs.availableShapes
        // RealityKit's frames getter materializes every sample. Read it once,
        // not once per control (80 controls in the current rig).
        var clipFace: [String:Float] = [:], clipStart: [String: Float] = [:]
        if let active,let faceClip = activeFace {
            let frames = faceClip.frames
            if !frames.isEmpty {
                // Between the clip's own samples (24 a second), so the face and ears move on every frame drawn: stepping
                // them at 24 inside 60 fps frames made a pat's or a wave's ears judder (a big change, then none).
                let position = min(Double(frames.count - 1), max(0, active.time / max(0.001, active.duration) * Double(frames.count - 1)))
                let frame = min(frames.count - 1, Int(position)), next = min(frames.count - 1, frame + 1), f = Float(position - Double(frame))
                for (index,name) in faceClip.weightNames.enumerated() {
                    clipFace[name] = frames[frame][index] + (frames[next][index] - frames[frame][index]) * f; clipStart[name] = frames[0][index]
                }
            }
        }
        let pleased = mood.isPleased, moodAge = now - moodChangedAt
        // Into or out of closed happy arcs, the smile leads (SmileBridge): no half-shut eyes on the way.
        let bridge = SmileBridge(fromArcs: max(moodFromWeights["eyes_happy"] ?? 0, moodFromWeights["eyes_proud"] ?? 0),
                                 toArcs: max(pose?.blendShapes["eyes_happy"] ?? 0, pose?.blendShapes["eyes_proud"] ?? 0), toPleased: pleased, duration: moodDuration)
        for name in names {
            var target = pose?.blendShapes[name] ?? 0
            if smiling > 0 && (name == "smile" || name == "eyes_happy") { target = max(target, smiling * (name == "smile" ? 1 : 0.8)) }
            if let value = clipFace[name] {
                // Expression channels move from the mood's face as far as the clip moves from its first frame (ClipFace);
                // the others (ears, arms, a display's moments) are the clip's own.
                // A mood still easing in is laid under the clip where it is now, so nothing jumps.
                let moodNow = now - moodChangedAt < moodDuration ? (moodFromWeights[name] ?? 0) + (target - (moodFromWeights[name] ?? 0)) * MoodTiming.progress(age: now - moodChangedAt, duration: moodDuration) : target
                target = ClipFace.relative.contains(name) ? ClipFace.weight(mood: moodNow, clip: value, start: clipStart[name] ?? value, name: name, pleased: pleased) : value
            }
            if name == "arms_fold", active == nil, !arms.folded { target = 0 }
            if mood == .content && userSmiling > 0 {
                // A smile for you on the mouth, with v0's round eyes (Charles, 2026-10-05: raised lower lids made the eyes'
                // bottoms "weirdish", and the blush made Moku pinkish; "the first version was better").
                let smile: [String: Float] = pixelFace != nil ? ["smile": 0.8] : ["smile": 0.8, "blush_more": 0.1]
                target = max(target, (smile[name] ?? 0) * userSmiling)
            }
            // A display's smile for you is a beat: ^^ once its eyes have locked on, then open eyes again, still on you.
            if pixelFace != nil && mood == .content && noticesUser && name == "eyes_happy" {
                let age = now - noticedAt
                target = max(target, Float(LifeCurve.smooth((age - 0.8) / 0.12) * (1 - LifeCurve.smooth((age - 2.6) / 0.12))))
            }
            if active != nil && clipFace[name] != nil {
                // Correctives and bones must sample the same clip time; a face
                // low-pass here used to lag behind the moving ear skeleton.
                currentWeights[name] = target
            } else if (active == nil || isArmClip) && now - moodChangedAt < moodDuration {
                let from = moodFromWeights[name] ?? 0
                // A display swaps its eyes at once (it has no squint frame for the bridge to wait on): a crisp beep.
                let crisp = companion.isMachine && bridge.way != .none && (name == "eyes_happy" || name == "eyes_proud")
                currentWeights[name] = from + (target - from) * (crisp ? Float(LifeCurve.smooth((moodAge - 0.04) / 0.12)) : bridge.progress(name, age: moodAge))
            } else {
                let previous = currentWeights[name] ?? 0
                // A frame late after a pause (the renderer slept) steps no more than a 30 fps frame would: whatever the
                // target does then, the face follows it smoothly, instead of taking all of it at once. (dt ≥ 1 is a
                // review pose: straight there.)
                currentWeights[name] = previous + (target - previous) * Float(dt >= 1 ? 1 : min(dt, 1.0 / 30) * 12)
            }
        }
        var face = currentWeights
        if bridge.way != .none, active == nil || isArmClip, moodAge > 0, moodAge < moodDuration, morphs.movingShapes.contains("lid_smile_lower") {
            face["lid_smile_lower"] = max(face["lid_smile_lower"] ?? 0, bridge.squint(age: moodAge))
        }
        for (name, amount) in sample.weights {
            // A small additive flick also reads on a mood whose shape is already high (but a smile only ever grows).
            let base = face[name] ?? 0, smileGrows = SmileChannels.floor.contains(name) || name == "smile"
            face[name] = min(name.hasPrefix("brow_raise_") ? 0.5 : 1, base + amount * (base > 0.9 && !smileGrows ? -0.7 : 1))
        }
        for (name, amount) in life.weights {
            let cap: Float = name.hasPrefix("brow_raise_") ? 0.5 : name == "nose_twitch" ? 0.85 : 1  // brows: the asset's micro range
            face[name] = max(0, min(cap, (face[name] ?? 0) + amount))
        }
        if hoverStrength > 0 {
            let delight: [String: Float] = ["eyes_happy": 1, "smile": 1, "cheeks_raise": 0.85, "blush_more": 0.85, "cheeks_puff": 0.25]
            for name in morphs.availableShapes where name != "arms_fold" && !name.hasPrefix("ear") {
                face[name] = (face[name] ?? 0) * (1 - hoverStrength) + (delight[name] ?? 0) * hoverStrength
            }
            // A bunny sniffs the pointer that came to rest on it: two quick twitches of the nose as it lights up.
            if hoverOn && !reduced && !companion.isMachine && morphs.movingShapes.contains("nose_twitch") {
                face["nose_twitch"] = min(0.85, (face["nose_twitch"] ?? 0) + 0.7 * LifeCurve.twitch(hoverAge, start: 0.04, length: 0.12) + 0.55 * LifeCurve.twitch(hoverAge, start: 0.21, length: 0.12))
            }
        }
        if companion.isMachine && now - beepAt < 0.6 {  // the comeback's double beep: the antenna LEDs blip twice
            face["nose_twitch"] = min(1, (face["nose_twitch"] ?? 0) + LifeCurve.twitch(now - beepAt, start: 0.04, length: 0.14) + LifeCurve.twitch(now - beepAt, start: 0.26, length: 0.14))
        }
        face["eyes_proud"] = (face["eyes_proud"] ?? 0) * (1 - (face["eyes_happy"] ?? 0))
        face["mouth_open"] = (face["mouth_open"] ?? 0) * (1 - (face["mouth_smile_open"] ?? 0))
        // A transient blink replaces a smiling arc as well as partial lids, so
        // the return's slow blink remains visible even over a happy expression.
        let blinkPulse = max(blink, sample.weights["blink_L"] ?? 0, sample.weights["blink_R"] ?? 0)
        // The lids' setting changes only while a blink has them shut; the blink below then opens onto it.
        if lidChoiceDue && blink >= 0.95 { lids.choose(for: mood, using: &random, shapes: morphs.movingShapes); lidsSetAt = now; lidChoiceDue = false; lifeEvents["lids", default: 0] += 1 }
        if blink == 0 { lidChoiceDue = false }
        let lidAmount = lidFade(now: now)
        for (name, value) in lids.weights where lidAmount > 0 {
            let underBlink: Float = name == "eyes_wide" ? 1 - blinkPulse : 1  // the other lid shapes are eased out under a blink below
            face[name] = max(0, min(1, (face[name] ?? 0) + value * lidAmount * underBlink))
        }
        face["eyes_happy"] = (face["eyes_happy"] ?? 0) * (1 - blinkPulse)
        face["eyes_proud"] = (face["eyes_proud"] ?? 0) * (1 - blinkPulse)
        let closedArc = max(face["eyes_happy"] ?? 0, face["eyes_proud"] ?? 0)
        face["blink_L"] = (1 - closedArc) * max(face["blink_L"] ?? 0, blink)
        face["blink_R"] = (1 - closedArc) * max(face["blink_R"] ?? 0, blink)
        for name in ["eyes_narrow", "lid_flat", "lid_sad", "lid_smile_lower"] { face[name] = (face[name] ?? 0) * (1 - blinkPulse) }
        // Eyes closing into arcs take the smiling lower lid with them: both raise the eye's bottom, and together they'd
        // push it past the arc.
        face["lid_smile_lower"] = (face["lid_smile_lower"] ?? 0) * (1 - closedArc)
        var resolvedEars: EarPose?
        if (active == nil || isArmClip), let route = earTransitions, route.requiredShapes.isSubset(of: morphs.availableShapes) {
            var targetWeights = (pose?.blendShapes ?? [:]).filter { route.clearControls.contains($0.key) }
            for (key,value) in sample.weights where route.clearControls.contains(key) { targetWeights[key] = max(targetWeights[key] ?? 0,value) }
            let targetAngles = (pose?.jointEulerDegrees ?? [:]).filter { $0.key.hasPrefix("ear_") }.mapValues { SIMD3($0[0],$0[1],$0[2]) * (.pi/180) }
            let targetEar = EarPose(weights: targetWeights,angles: targetAngles)
            if route.usesPath(from: earFrom,to: targetEar) {
                earCurrent = route.interpolate(from: earFrom,to: targetEar,progress: Float((now-moodChangedAt)/route.duration(from: earFrom,to: targetEar)))
            } else { earCurrent = .blend(earFrom,targetEar,MoodTiming.progress(age: now-moodChangedAt,duration: moodDuration)) }
            let resolved = route.resolve(earCurrent); resolvedEars = resolved
            for key in route.clearControls { face[key] = 0 }
            for (key,value) in resolved.weights { face[key] = value }
            // A machine sitting up tall: its antennae telescope up, at attention (over the mood's own ear angles).
            if companion.isMachine, Posture.seatedOnly, case let tall = standShape(now: now).s, tall > 0.001 {
                for (key, value) in route.resolve(EarPose(weights: ["ears_lift": min(1, 0.8 * tall)])).weights where value > 0 { face[key] = max(face[key] ?? 0, value) }
            }
        }
        lastAppliedFace = face
        if gazeAwaitsFrame { gazeAwaitsFrame = false; gazeChangedAt = GazeTiming.easeStart(changedAt: gazeChangedAt, firstFrame: now) }
        let gazeAge = now - gazeChangedAt
        // A display's eyes jump ahead of the head in dot steps (a quick servo); a morph face's ease.
        eyeLook = gazeFromEye + (eyeTarget - gazeFromEye) * (pixelFace != nil ? ServoTiming.progress(age: gazeAge, duration: 0.32) : GazeTiming.eyes(gazeAge))
        userAttention = gazeFromUserAttention + ((noticesUser ? 1 : 0) - gazeFromUserAttention) * GazeTiming.eyes(gazeAge)
        // During a drift the head holds still (no head shaking), except to turn and face the user. Held or not, it
        // turns there with the same ease (switching straight to the hold snapped the head back in one frame).
        let headTarget = drifting && !noticesUser ? driftHeadAnchor : eyeTarget
        headLook = gazeFromHead + (headTarget - gazeFromHead) * (companion.isMachine ? ServoTiming.head(gazeAge) : GazeTiming.head(gazeAge, reduced: reduced))
        do { try morphs.apply(face, gaze: drifting ? .zero : sample.gaze, userAttention: userAttention, to: rig, limitingRate: dt < 1) } catch { self.error = "Face morphs: \(error.localizedDescription)" }
        if morphs.changeWaiting { awakeUntil = max(awakeUntil, now + 0.08) }  // the face the CPU path held back shows on a coming frame
        // The reading darts are eye turns of a few hundredths of a radian; tripled, each moves Tetsu's dot eyes about one dot.
        if let pixelFace {
            var shown = displayOverrides.isEmpty ? face : face.merging(displayOverrides.filter { !$0.key.hasPrefix("__") }) { $1 }
            if let moment = displayMoment, Self.blinkSteps[moment.channel] == nil, now - moment.at < moment.seconds {
                shown[moment.channel] = Float(max(0.004, (now - moment.at) / moment.seconds))
                // Scanning, the eyes narrow and hold still (no blink, no dart), so its frames are the same every scan.
                if moment.channel == "px_scan" { shown["eyes_narrow"] = 0.8; shown["blink_L"] = 0; shown["blink_R"] = 0 }
            }
            if asking { let on = cursorOn(now); shown["px_cursor"] = on ? 1 : 0.25; cursorShown = on }
            // Lids on a display are whole frames: a closing beyond the mood's own (a slow or double blink) is a line at
            // once, then open again, never the steps of a lid.
            for side in ["blink_L", "blink_R"] {
                let rest = pose?.blendShapes[side] ?? 0
                shown[side] = (shown[side] ?? 0) > rest + 0.3 ? 1 : min(shown[side] ?? 0, rest)
            }
            // Seeing you: once the head has turned, its eyes lock on (brackets) and its antennae twitch.
            if let due = lockDueAt, now >= due { lockDueAt = nil; if noticesUser { playDisplayMoment("px_lock"); antennaTwitchAt = now } }
            // Dots and a "z" only while dozing: awake, the display shows the new mood's eyes at once (the body still eases).
            if mood != .sleepy { shown["eyes_dot"] = 0; shown["sleep_z"] = 0 }
            let lookOverride = SIMD2(displayOverrides["__gazeX"] ?? 0, displayOverrides["__gazeY"] ?? 0)
            let scanning = displayMoment.map { $0.channel == "px_scan" && now - $0.at < $0.seconds } ?? false
            let displayGaze = scanning ? .zero : eyeLook + lookOverride + (drifting ? .zero : sample.gaze) + (reduced ? .zero : readingEyes.offset(at: now) * 3)
            // A blink's next frame (over the lids above: its own steps, not a line at once). A step that would look the
            // same as the frame on show (in some moods two lid steps draw alike) is passed over: no frame is ever held.
            if let moment = displayMoment, let steps = Self.blinkSteps[moment.channel] {
                var next: [String: Float]?
                while momentStep < steps.count {
                    var candidate = shown; for (name, value) in steps[momentStep] { candidate[name] = value }; momentStep += 1
                    if PixelFace.frame(for: candidate, gaze: displayGaze, cross: flushAmount > 0.5) != pixelFace.frame { next = candidate; break }
                }
                if let next { shown = next } else { displayMoment = nil; displayQuietUntil = now + Self.displayQuiet }
            }
            if pixelFace.show(shown, gaze: displayGaze, cross: flushAmount > 0.5),
               let displayIndex, var model = rig.model, displayIndex < model.materials.count {
                model.materials[displayIndex] = pixelFace.material; rig.model = model
            }
        }
        // Imported clips own the skeleton while playing; idle articulation starts at rest every frame.
        if active == nil || isArmClip || (carrying && activeClipName == "walk_cycle") {
            var transforms = active != nil ? rig.jointTransforms : rest
            let body = GazeSplit(headLook)
            let shape = standShape(now: now), stand = standDelta(at: shape.s), tall = Posture.seatedOnly ? shape.s : 0
            for (i, name) in rig.jointNames.enumerated() {
                let leaf = String(name.split(separator: "/").last ?? "")
                let carried = carrying ? carriedLantern?.holdAngles[leaf] : nil
                if active != nil && !isArmClip && carried == nil { continue }
                // moods.json angles are joint-local degrees applied as rest·Rx·Ry·Rz (below), which is Blender's 'ZYX' Euler,
                // not its to_euler('XYZ') (Rz·Ry·Rx): a Blender script writing or reading them must convert (assets/README.md).
                let degrees = carried ?? pose?.jointEulerDegrees[leaf] ?? [0, 0, 0]
                if isArmClip && (leaf.hasPrefix("arm_") || leaf.hasPrefix("hand_")) { continue }
                // Partial clips own arms only. Reset every other joint completely,
                // including translations/scales left by a previous full-body clip.
                transforms[i] = rest[i]
                var goal = SIMD3<Float>(degrees[0], degrees[1], degrees[2]) * (.pi / 180)
                if leaf == "head" && mood == .annoyed { goal.y = 0; goal.z = 0 }
                let from = moodFromAngles[leaf] ?? .zero
                let amount = companion.isMachine ? ServoTiming.progress(age: now - moodChangedAt, duration: moodDuration) : MoodTiming.progress(age: now - moodChangedAt, duration: moodDuration)
                var angles = from + (goal - from) * amount
                if let ear = resolvedEars?.angles[leaf] { angles = ear }
                currentMoodAngles[leaf] = angles
                if carried == nil && (leaf.hasPrefix("arm_") || leaf.hasPrefix("hand_")) && heldMood && !arms.folded { angles = .zero }
                if leaf == "head" { angles.x -= body.headPitch; angles.y += body.headYaw
                    angles += sample.head * (reduced || drifting ? 0 : 1)
                    let nodAge = now - nodStartedAt
                    if nodAge >= 0 && nodAge < 0.9 { angles.x += Float(pow(sin(nodAge / 0.9 * .pi), 2)) * (reduced ? 0.01 : 0.035) }
                    if hoverOn && !reduced && !drifting && !companion.isMachine {
                        let envelope = Float(max(0, 1 - hoverAge / 1.5))
                        angles.y += Float(sin(hoverAge / 1.5 * .pi * 5)) * 0.095 * envelope
                    }
                    // A machine tilts its head, quick and curious, and back; it finishes even if the pointer leaves.
                    if companion.isMachine && !reduced && !drifting { angles.z += 0.11 * ServoTiming.acknowledge(now - hoverBeganAt) }
                }
                if leaf == "chest" { angles.y += body.chestYaw; angles.x += (drifting ? 0 : sample.chest) + shape.chest - tall * Self.tallChest }
                if leaf == "head" { angles.x += tall * Self.tallChest / 2 }
                if leaf == "ear_L_02" || leaf == "ear_R_02" { angles.x += shape.ears + HappyBounce.earLag(at: now - bounceAt) * (reduced ? 0 : 1) }
                if leaf == "ear_L_01" || leaf == "ear_R_01" {
                    angles.x += 0.4 * HappyBounce.earLag(at: now - bounceAt - 0.03) * (reduced ? 0 : 1)
                    // Ear language: turning to you (not in a drift), the ears perk up a little and settle back.
                    if !reduced && !drifting && mood != .sleepy && !companion.isMachine { angles.x -= (leaf == "ear_L_01" ? 0.06 : 0.045) * LifeCurve.bump(now - noticedAt - (leaf == "ear_L_01" ? 0.1 : 0.16), rise: 0.25, hold: 0.3, fall: 0.45) }
                }
                if leaf == "foot_R" { angles.x += shape.tap }
                if leaf == "ear_L_01" { angles.z += reduced ? 0 : sample.ear }
                if let fidgeting, !reduced, active == nil {
                    angles += companion.isMachine ? fidgeting.angles(for: leaf, envelope: ServoTiming.envelope(age: now - fidgetAt, seconds: fidgeting.seconds), wag: 0)
                                                  : fidgeting.angles(for: leaf, at: now - fidgetAt)
                }
                if let move = life.angles[leaf] { angles += move }
                // Breathing in 3D: the chest lifts a touch and swells (its own felt only: the neck and arms take
                // the swell back out), and the head stays where it was looking.
                if leaf == "chest" { angles.x -= 0.008 * breathShown }
                if leaf == "neck" { angles.x += 0.008 * breathShown }
                if !reduced, now - earFlickAt < EarFlick.seconds + 0.1, leaf.hasPrefix(earFlickLeft ? "ear_L_" : "ear_R_") {
                    let machine = companion.isMachine
                    func flick(_ age: Double) -> Float { machine ? ServoTiming.twitch(age: age) : EarFlick.angle(age: age) }
                    if leaf.hasSuffix("_01") { let base = flick(now - earFlickAt); angles.z += base * earFlickSide; angles.x += abs(base) * 0.3 }
                    if leaf.hasSuffix("_02") { angles.z += flick(now - earFlickAt - 0.06) * earFlickSide * 0.8 }
                }
                if leaf == "ear_R_01" && resolvedEars == nil { angles.x += abs(headLook.x) * 0.17 }
                if leaf.hasPrefix("ear_") && hoverOn && !reduced && !companion.isMachine {
                    angles.z += Float(sin(max(0, hoverAge - 0.10) / 1.5 * .pi * 5)) * 0.07 * Float(max(0, 1 - hoverAge / 1.65))
                }
                if leaf.hasPrefix("ear_") && companion.isMachine && !reduced {  // the antennae twitch, the tips a beat behind
                    angles.z += (leaf.hasPrefix("ear_L") ? 1 : -1) * ServoTiming.twitch(age: now - antennaTwitchAt - (leaf.hasSuffix("_02") ? 0.12 : 0.06))
                }
                if holding && !reduced {
                    let h = lift.value, s = Float(max(-1, min(1, -holdAngle / 0.5)))  // the ears and feet trail the swing
                    if leaf.hasPrefix("ear_") { angles.z -= s * 0.22; angles.x += 0.16 * h }
                    if leaf.hasPrefix("foot_") { angles.z -= s * 0.18; angles.x += 0.25 * h }
                    if leaf == "head" { angles.z += s * 0.08 }
                }
                // The whole eyeball turns (in head space), so the dark pupil stays centred in its rim. It also
                // takes up the mood's head tilt, so a sad lowered head still looks up at the user.
                var eyePitch = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
                if leaf.hasPrefix("eye_") && pixelFace == nil {  // a display's eyes are drawn (PixelFace): its eye joints only carry hidden anchors
                    let head = currentMoodAngles["head"] ?? .zero, chest = currentMoodAngles["chest"] ?? .zero
                    let eyeTurn = body.eyes(toward: eyeLook, moodTurn: SIMD2(head.y + chest.y, -(head.x + chest.x))) + (reduced ? .zero : readingEyes.offset(at: now))
                    eyePitch = simd_quatf(angle: eyeTurn.x, axis: SIMD3<Float>(0, 1, 0)) * simd_quatf(angle: -eyeTurn.y, axis: SIMD3<Float>(1, 0, 0))
                }
                let targetRotation = eyePitch * rest[i].rotation * simd_quatf(angle: angles.x, axis: [1, 0, 0]) * simd_quatf(angle: angles.y, axis: [0, 1, 0]) * simd_quatf(angle: angles.z, axis: [0, 0, 1])
                transforms[i].rotation = targetRotation
                if breathShown != 0 {
                    let swell = 1 + 0.02 * breathShown
                    if leaf == "chest" { transforms[i].scale *= swell }
                    if leaf == "neck" || leaf.hasPrefix("arm_") { transforms[i].scale /= swell }
                    if leaf == "head" { transforms[i].scale *= SIMD3(1 + 0.008 * breathShown, 1, 1 + 0.005 * breathShown) }  // the cheeks fill
                }
                if let prior = moodFromTransforms, now - moodChangedAt < moodDuration {
                    transforms[i].rotation = simd_slerp(prior[i].rotation, targetRotation, amount)
                    transforms[i].translation = prior[i].translation + (transforms[i].translation - prior[i].translation) * amount
                    transforms[i].scale = prior[i].scale + (transforms[i].scale - prior[i].scale) * amount
                }
                if active == nil, let exit = clipExit, now - exit.at < Self.clipExitSeconds, exit.transforms.count == transforms.count {
                    let k = MoodTiming.progress(age: now - exit.at, duration: Self.clipExitSeconds)
                    transforms[i].rotation = simd_slerp(exit.transforms[i].rotation, transforms[i].rotation, k)
                    transforms[i].translation = exit.transforms[i].translation + (transforms[i].translation - exit.transforms[i].translation) * k
                    transforms[i].scale = exit.transforms[i].scale + (transforms[i].scale - exit.transforms[i].scale) * k
                }
                if let stand {
                    transforms[i].rotation = transforms[i].rotation * stand.rotations[i]
                    transforms[i].translation += stand.translations[i]
                    transforms[i].scale *= stand.scales[i]
                }
                if leaf == "root" { transforms[i].translation += standLift * (shape.lift + tall * Self.tallLift) }
            }
            rig.jointTransforms = transforms
        }

    }
    private(set) var displayedMood: Mood = .content
    private(set) var displayedAnnoyedStrength: Float = 0
    private(set) var displayedMoodProgress: Float = 1
    private(set) var displayedEyeLook = SIMD2<Float>.zero
    private(set) var displayedAttentionToUser = false
    private(set) var displayedLooksAtUser = false
    private(set) var displayedHeadRotation = SIMD4<Float>(0,0,0,1)
    private func finishFrame() {
        let finishing = CACurrentMediaTime()
        defer {
            mainCosts.append((renderCostPending, CACurrentMediaTime() - finishing)); if mainCosts.count > 600 { mainCosts.removeFirst() }
            mainCostsTotal.append(render: renderCostPending, finish: CACurrentMediaTime() - finishing)
        }
        busy = false; guard running else { return }
        framesSinceWake += 1
        let side = textureSize
        let buffer = framePool.take()
        texture.getBytes(buffer.bytes, bytesPerRow: side * 4, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        SoftEdges.correct(buffer.bytes, pixelCount: side * side)  // soft pixels premultiplied in sRGB, as Core Animation reads them
        if let size = pendingTextureSize { makeTarget(size: size) }  // this frame shows; the next is at the new size
        guard let image = buffer.image(side: side) else { return }
        lastFrame = (buffer, side)
        if let head = rig.jointNames.firstIndex(where: { $0.split(separator: "/").last == "head" }) { displayedHeadRotation = rig.jointTransforms[head].rotation.vector }
        displayedMood = mood
        displayedMoodProgress = MoodTiming.progress(age: CACurrentMediaTime() - moodChangedAt, duration: moodDuration)
        displayedEyeLook = eyeLook; displayedAttentionToUser = noticesUser
        displayedAnnoyedStrength = currentWeights["brows_angry"] ?? 0
        displayedLooksAtUser = noticesUser && simd_length(eyeLook) < 0.15
        frames += 1; renderedFrames += 1
        frameDone.append(CACurrentMediaTime()); if frameDone.count > 600 { frameDone.removeFirst() }
        if renderedFrames == 1 { memoryMark("first completed frame") }
        if let key = bakingMicroKey {
            if CACurrentMediaTime() < bakingMicroUntil { bakingMicroFrames.append(image) }
            else {
                // The cache keeps whole frames (1.6 MB each at the standard size): a few expressions, never more than a
                // fixed amount of memory.
                let limit = Self.microCacheBytes / (side * side * 4)  // (a bigger render, as in the welcome, caches fewer: none above about 2.5x)
                if microFrames.count >= 4 || microCacheFrames + bakingMicroFrames.count > limit { microFrames.removeAll() }
                if bakingMicroFrames.count <= limit { microFrames[key] = bakingMicroFrames }
                bakingMicroKey = nil; bakingMicroFrames.removeAll()
            }
        }
        lastImage = image
        CATransaction.begin(); CATransaction.setDisableActions(true); imageLayer.contents = image
        if let lights = pendingLights { statusLights?.show(lights.visible, at: lights.at, across: lights.across, pace: StatusLights.pace(mood, cross: flushAmount > 0.5), reduced: reduced) }
        CATransaction.commit()
        let now = CACurrentMediaTime()
        if now - lastFPSAt >= 1 { fps = Double(frames) / (now - lastFPSAt); frames = 0; lastFPSAt = now }
        onFrame?()
    }
    // Deterministic offscreen acceptance uses the same mesh, camera, material and
    // pose composition as production, with paused native clips at exact times.
    private var auditPair = ""
    private var auditSampling = false
    /// Renders at a larger size for look development (`MokuVisualDiagnostics.lookCheck`).
    func setAuditResolution(_ scale: CGFloat) { setResolution(for: scale) }
    func auditFrame(mood: Mood, clip: String?, seconds: Double, gaze: SIMD2<Float> = .zero, user: Bool = false) async throws -> (CGImage, Double) {
        timer?.invalidate(); timer = nil; timerFPS = 0; running = true; auditSampling = true
        let pair = mood.rawValue + "/" + (clip ?? "idle") + "/\(gaze)/\(user)"
        if pair != auditPair {
            active?.stop(); active = nil; activeClipName = nil; activeFace = nil
            clipTask?.cancel(); cancelMicro(); resetLife(); displayMoment = nil
            self.mood = mood; moodChangedAt = -100; noticesUser = user; noticedAt = -100
            userSmile = Ease(); userSmile.go(to: user ? 1 : 0, at: -100, over: 0.6)
            hoverOn = false; hoverStrength = 0; hoverFrom = 0; hoverBeganAt = -100; smileUntil = 0; smileStartedAt = -100
            drifting = false; moodFromTransforms = nil; lidsSetAt = -100
            earFrom = EarPose(); earCurrent = EarPose()
            currentWeights = [:]; moodFromAngles = [:]; currentMoodAngles = [:]
            eyeTarget = gaze; eyeLook = gaze; headLook = gaze; gazeFromEye = gaze; gazeFromHead = gaze
            userAttention = user ? 1 : 0; gazeFromUserAttention = userAttention
            gazeChangedAt = -100; arms.reset(); if heldMood { arms.foldedPoseBegan() }
            rig.jointTransforms = rest
            if let clip {
                guard await startClip(clip) > 0 else { throw NSError(domain: "MokuVisual", code: 5, userInfo: [NSLocalizedDescriptionKey: error ?? "Missing clip: \(clip)"]) }
                active?.pause()
            }
            timer?.invalidate(); timer = nil; timerFPS = 0; auditPair = pair
        }
        let duration = active?.duration ?? 1.25
        active?.time = min(seconds, max(0, duration - 0.0001))
        blinkStartedAt = -100; nextBlink = .infinity; bakingBlink = false
        pose(time: 0, dt: 1); placeStatusLights()
        cup?.update(clip: clip, normalizedTime: seconds / max(0.001,duration), rig: rig)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do { try renderer.updateAndRender(deltaTime: 0, cameraOutput: output, onComplete: { _ in continuation.resume() }) }
            catch { continuation.resume(throwing: error) }
        }
        finishFrame()
        guard let image = lastImage else { throw CocoaError(.fileReadUnknown) }
        return (image, duration)
    }
    /// Look development for the life between the big moments: the mood's pose `age` seconds into `move`, with a fixed
    /// breath (in depths), lid setting and reading offset, through the same pose and renderer as the app.
    func auditLife(mood: Mood, move: LifeMove?, age: Double, breath: Float = 0, lids lidWeights: [String: Float] = [:], eyes: SIMD2<Float> = .zero, gaze: SIMD2<Float> = .zero) async throws -> CGImage {
        _ = try await auditFrame(mood: mood, clip: nil, seconds: 0, gaze: gaze)
        auditBreath = breath; lids = LidTension(weights: lidWeights); lidsSetAt = CACurrentMediaTime()
        readingEyes = .fixed(eyes); lifeMove = move; lifeMood = mood; lifeFadeAt = nil; lifeArmedOffset = nil; lifeAt = CACurrentMediaTime() - age
        pose(time: 0, dt: 1)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do { try renderer.updateAndRender(deltaTime: 0, cameraOutput: output, onComplete: { _ in continuation.resume() }) }
            catch { continuation.resume(throwing: error) }
        }
        finishFrame()
        auditBreath = 0; resetLife(); auditPair = ""
        guard let image = lastImage else { throw CocoaError(.fileReadUnknown) }
        return image
    }
    /// Look development for the micro-expressions: the mood's pose `progress` (0…1) into `expression`, through the same
    /// pose and renderer as the app (the smile survey).
    func auditMicro(mood: Mood, expression: MicroExpression, progress: Double, gaze: SIMD2<Float> = .zero, user: Bool = false) async throws -> CGImage {
        _ = try await auditFrame(mood: mood, clip: nil, seconds: 0, gaze: gaze, user: user)
        micro = expression; microStartedAt = CACurrentMediaTime() - progress * expression.duration
        pose(time: 0, dt: 1)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do { try renderer.updateAndRender(deltaTime: 0, cameraOutput: output, onComplete: { _ in continuation.resume() }) }
            catch { continuation.resume(throwing: error) }
        }
        finishFrame()
        micro = nil; microStartedAt = -100; auditPair = ""
        guard let image = lastImage else { throw CocoaError(.fileReadUnknown) }
        return image
    }
    func auditBlink() async throws -> (CGImage,[Float]) {
        auditPair = ""; _ = try await auditFrame(mood: .content,clip: nil,seconds: 0,user: true)
        bakingBlink = true; pose(time: 0,dt: 1)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            do { try renderer.updateAndRender(deltaTime: 0,cameraOutput: output,onComplete: { _ in continuation.resume() }) } catch { continuation.resume(throwing: error) }
        }
        finishFrame(); bakingBlink = false
        guard let closed = lastImage else { throw CocoaError(.fileReadUnknown) }
        return (closed,pixelFace?.closure(lastAppliedFace) ?? morphs.closureThickness(lastAppliedFace))
    }
    private var transitionPair = ""
    func auditTransition(from: Mood, to: Mood, progress: Double) async throws -> (CGImage, [[Float]]) {
        let key = from.rawValue + "/" + to.rawValue
        if transitionPair != key {
            auditPair = ""
            _ = try await auditFrame(mood: from, clip: nil, seconds: 0, user: true)
            _ = try await auditFrame(mood: from, clip: nil, seconds: 0, user: true)
            setMood(to, duration: 3); timer?.invalidate(); timer = nil; timerFPS = 0
            transitionPair = key
        }
        moodChangedAt = CACurrentMediaTime() - progress*3
        pose(time: 0, dt: 1)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do { try renderer.updateAndRender(deltaTime: 0, cameraOutput: output, onComplete: { _ in continuation.resume() }) }
            catch { continuation.resume(throwing: error) }
        }
        finishFrame()
        guard let image = lastImage else { throw CocoaError(.fileReadUnknown) }
        return (image, morphs.earSpans(lastAppliedFace))
    }
    func contains(_ point: CGPoint) -> Bool {
        let rendered = imageLayer.presentation() ?? imageLayer
        let local = rendered.convert(point, from: imageLayer.superlayer?.presentation() ?? imageLayer.superlayer)
        let perPoint = CGFloat(textureSize) / StageGeometry.renderPoints
        let x = Int(local.x * perPoint), y = Int((StageGeometry.renderPoints - local.y) * perPoint)
        guard x >= 0, x < textureSize, y >= 0, y < textureSize else { return false }
        guard let frame = lastFrame, frame.side == textureSize else { return false }
        return frame.buffer.alpha(x: x, y: y, side: frame.side) > 32
    }
}

/// Moku's frame clock. On screen it's the display's own refresh (a CADisplayLink at the asked rate: 60 for motion, 30
/// for small things), so every frame lands on a refresh and nothing judders. Off screen (renders, tests, the panel
/// before it shows) a timer.
@MainActor final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private var timer: Timer?
    private let tick: @MainActor () -> Void
    var onDisplay: Bool { link != nil }

    init(fps: Double, host: NSView?, tick: @escaping @MainActor () -> Void) {
        self.tick = tick
        super.init()
        if let host, Self.canUseDisplay(of: host) {
            let link = host.displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            self.link = link
            set(fps: fps)
        } else {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            timer?.tolerance = 0.002
        }
    }

    /// Only once the window is on screen: a display link on a window that isn't (Moku's panel waits for its first
    /// frame before it shows) may never fire, and Moku would never appear. Until then a timer, swapped on the next pace.
    static func canUseDisplay(of host: NSView?) -> Bool { host?.window?.isVisible == true }

    func set(fps: Double) {
        if let link {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(fps), maximum: Float(fps), preferred: Float(fps))
        } else if let timer, abs(timer.timeInterval - 1 / fps) > 0.0001 {
            timer.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            self.timer?.tolerance = 0.002
        }
    }

    @objc private func step(_ link: CADisplayLink) { tick() }

    func invalidate() {
        link?.invalidate(); link = nil
        timer?.invalidate(); timer = nil
    }
}
