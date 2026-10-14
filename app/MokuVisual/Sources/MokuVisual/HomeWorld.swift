import AppKit
import SwiftUI
import RealityKit
import Metal
import MokuKit
import Observation

// Moku's home (docs/specs/home.md): the burrow or the treehouse, built room by room with one item per 10 focused
// minutes. The layout comes from assets/src/home_kit.py (world/home/layout.json), in RealityKit space.

public enum HomeKind: String, CaseIterable, Sendable {
    case burrow, treehouse
    public var title: String { self == .burrow ? "Burrow" : "Treehouse" }
    static let key = "MokuVisual.homeKind"
    static var saved: HomeKind { HomeKind(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .burrow }
}

struct HomeLayout: Decodable {
    struct Slot: Decodable {
        let asset: String, t: [Float], q: [Float], s: [Float], home: String?
        /// A lantern's room: it's lit only once that stage's room exists.
        var stage: Int? = nil
        var transform: Transform { Transform(scale: SIMD3(s[0], s[1], s[2]), rotation: simd_quatf(ix: q[0], iy: q[1], iz: q[2], r: q[3]), translation: SIMD3(t[0], t[1], t[2])) }
        /// Today's tree, today's house and each companion's home keep their pieces in their own folder under world/.
        var file: String { home.map { $0 == "daytree" || $0 == "dayhouse" || Companion(rawValue: $0) != nil ? "world/\($0)/\(asset).usdz" : "world/home/\($0)/\(asset).usdz" } ?? "world/home/kit/\(asset).usdz" }
    }
    struct Stage: Decodable { let threshold: Double; let room: String; let structure: [Slot]; let items: [Slot]; let outline: [Slot]?; let light: [Float]? }
    struct Camera: Decodable { let threshold: Double; let target: [Float]; let from: [Float] }
    /// `starScale`: how big each star is drawn (today's tree is seen from farther away than the home).
    /// A companion's home names itself and its pieces (the cottage's are DayHouse.cottage). Stages are names, or
    /// `{name, first}` records; anything unreadable is left out rather than failing the home.
    struct Names: Decodable {
        let home: String?, stages: [String], pieces: [String], finished: String?
        private struct Stage: Decodable { let name: String }
        private enum Keys: String, CodingKey { case home, stages, pieces, finished }
        init(from decoder: any Decoder) throws {
            let names = try decoder.container(keyedBy: Keys.self)
            home = try? names.decode(String.self, forKey: .home)
            stages = (try? names.decode([String].self, forKey: .stages)) ?? (try? names.decode([Stage].self, forKey: .stages))?.map(\.name) ?? []
            pieces = (try? names.decode([String].self, forKey: .pieces)) ?? []
            finished = try? names.decode(String.self, forKey: .finished)
        }
    }
    struct Home: Decodable { let base: [Slot]; let terrain: [Slot]?; let stages: [Stage]; let bulbs: [Slot]; let stars: [[Float]]; let starScale: Float?; let cameras: [Camera]; var names: Names? = nil }
    let thresholds: [Double]
    let pointsPerItem: Double
    let homes: [String: Home]
    /// The home's layout, or today's tree's (`world/daytree/layout.json`, assets/src/tree_kit.py).
    static func load(_ path: String = "world/home/layout.json") throws -> HomeLayout {
        guard let url = MokuAssets.file(path) else { throw CocoaError(.fileNoSuchFile) }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

extension DayHouse {
    /// Names the day's home after the companion's: its own home's names once that's bundled, the cottage's otherwise.
    /// MokuMind's lines ("four minutes until the nose cone") read them through DayHouse.
    static func useNames(of companion: Companion) {
        let home = companion.homeKey
        guard home != "dayhouse", let layout = try? HomeLayout.load(companion.homeLayoutPath), let names = layout.homes[home]?.names else { use(cottage); return }
        use(Names(home: names.home ?? cottage.home, stages: names.stages, pieces: names.pieces, finished: names.finished))
    }
}

/// What's on show after `points` focused minutes and `returns` returns.
struct HomeProgress: Equatable {
    let points: Double, returns: Int
    /// Items shown in a stage: all of a finished stage's, a share of the current one's, none of later ones.
    func items(in stage: HomeLayout.Stage, next: Double?, perItem: Double) -> Int {
        guard points >= stage.threshold else { return 0 }
        if let next, points >= next { return stage.items.count }
        return min(stage.items.count, Int((points - stage.threshold) / perItem))
    }
    /// Rooms dug or built so far (the burrow swaps in the hill with that many rooms carved).
    func roomsOpen(_ thresholds: [Double]) -> Int { thresholds.dropFirst().prefix(5).filter { points >= $0 }.count }
    /// After the observatory opens, a new star every 10 focused minutes.
    func stars(_ thresholds: [Double], perItem: Double) -> Int { max(0, Int((points - (thresholds.last ?? .infinity)) / perItem)) }
}

@MainActor final class HomeWorldRenderer {
    static let pixels = (width: 800, height: 760)
    let kind: HomeKind
    let layout: HomeLayout
    /// Which of the layout's homes to draw: the kind's, "daytree" for today's tree, "dayhouse" for today's house.
    let homeKey: String
    var home: HomeLayout.Home { layout.homes[homeKey]! }
    let renderer: RealityRenderer
    let camera = PerspectiveCamera()
    let root = Entity()
    /// Two pictures, drawn in turn: the screen copies the last one while the next is drawn into the other.
    private let textures: [any MTLTexture]
    private let outputs: [RealityRenderer.CameraOutput]
    private var current = 0
    /// The last picture drawn.
    var texture: any MTLTexture { textures[current] }
    private var prototypes: [String: Entity] = [:]
    private let built = Entity()
    private var shown: [String: Entity] = [:]
    /// The shown parts in build order, and which of them land and leave (the pieces) rather than just appear.
    private var order: [String] = []
    private var pieces: Set<String> = []
    private var signature = ""
    private var lights: [Int: PointLight] = [:]
    /// Pieces landing: each drops in from above and settles with a squash and a little bounce.
    private var popping: [(entity: Entity, transform: Transform, start: Double)] = []
    /// Pieces leaving (a day with less built): each shrinks and sinks away, the newest first.
    private var leaving: [String: (entity: Entity, transform: Transform, start: Double)] = [:]
    static let dropSeconds = 0.34, settleSeconds = 0.32, dropHeight: Float = 1.3, leaveSeconds = 0.22
    private var rendering = false
    private var lastFrame = 0.0
    private var view: (target: SIMD3<Float>, from: SIMD3<Float>)?
    /// The camera is still easing to the framing for what's built.
    private var cameraMoving = false

    init(kind: HomeKind, layout: HomeLayout, homeKey: String? = nil) async throws {
        self.kind = kind; self.layout = layout; self.homeKey = homeKey ?? kind.rawValue
        renderer = try RealityRenderer()
        guard let device = MTLCreateSystemDefaultDevice() else { throw CocoaError(.featureUnsupported) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: Self.pixels.width, height: Self.pixels.height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
        let textures = (0..<2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        guard textures.count == 2 else { throw CocoaError(.featureUnsupported) }
        self.textures = textures
        outputs = try textures.map { try RealityRenderer.CameraOutput(.singleProjection(colorTexture: $0)) }
        renderer.cameraSettings.colorBackground = .color(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        renderer.cameraSettings.isToneMappingEnabled = true
        // A 30° horizontal field of view, as in the Blender previews.
        camera.camera.fieldOfViewInDegrees = Float(2 * atan(tan(15 * Double.pi / 180) * Double(Self.pixels.height) / Double(Self.pixels.width)) * 180 / .pi)
        // Dusk: a warm low sun from the front left, a cool sky fill, and a warm rim from behind.
        let sun: [Entity] = [(SIMD3<Float>(-4, 6, 5), SIMD3<Float>(1, 0.86, 0.7), Float(1900), true), (SIMD3<Float>(5, 3, 3), SIMD3<Float>(0.7, 0.78, 1), 650, false), (SIMD3<Float>(-1, 4, -5), SIMD3<Float>(1, 0.8, 0.6), 900, false)].map { position, colour, intensity, shadows in
            let light = DirectionalLight(); light.light.intensity = intensity
            light.light.color = NSColor(red: CGFloat(colour.x), green: CGFloat(colour.y), blue: CGFloat(colour.z), alpha: 1)
            light.look(at: .zero, from: position, relativeTo: nil)
            light.shadow = shadows ? .init(shadowProjection: .fixed(zNear: 0.1, zFar: 60, orthographicScale: 16), depthBias: 1) : nil
            return light
        }
        let cube = try await TextureResource(cubeFromEquirectangular: RealityCharacter.environmentImage(color: [0.72, 0.72, 0.86]), faceSize: 32, options: .init(semantic: .color))
        renderer.lighting.resource = try await EnvironmentResource(cube: cube, options: .init(specularCubeDimension: 32))
        renderer.lighting.intensityExponent = 0.2
        renderer.entities.append(contentsOf: [root, camera] + sun); renderer.activeCamera = camera
        root.addChild(built)
        // Every part up front, all at once: loading one mid-animation would stall the pieces landing.
        let home = layout.homes[self.homeKey]!
        let slots = home.base + (home.terrain ?? []) + home.bulbs + home.stages.flatMap { $0.structure + $0.items + ($0.outline ?? []) }
        try await load(Set(slots.map(\.file) + (home.stars.isEmpty ? [] : [HomeLayout.Slot(asset: "star", t: [0, 0, 0], q: [0, 0, 0, 1], s: [1, 1, 1], home: nil).file])))
    }

    /// Loads the parts not loaded yet, side by side.
    private func load(_ files: Set<String>) async throws {
        let loads = files.subtracting(prototypes.keys).map { file in
            Task { @MainActor [weak self] in
                guard let url = MokuAssets.file(file) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: file]) }
                let entity = try await Entity(contentsOf: url); try await MaterialConfiguration.apply(to: entity); self?.prototypes[file] = entity
            }
        }
        for load in loads { try await load.value }
    }

    private func prototype(_ slot: HomeLayout.Slot) async throws -> Entity {
        try await load([slot.file])
        return prototypes[slot.file]!
    }

    /// Adds and removes only what changed, so a new piece costs one clone. When `animated`, new pieces land and
    /// pieces no longer wanted leave; otherwise everything just appears or goes.
    private func sync(_ progress: HomeProgress, animated: Bool, now: Double) async throws {
        let perItem = layout.pointsPerItem, stages = home.stages
        let counts = stages.indices.map { progress.items(in: stages[$0], next: $0 + 1 < stages.count ? stages[$0 + 1].threshold : nil, perItem: perItem) }
        let stars = min(home.stars.count, progress.stars(layout.thresholds, perItem: perItem))
        let lastOpen = stages.lastIndex { progress.points >= $0.threshold } ?? 0
        let lanterns = home.bulbs.filter { ($0.stage ?? 0) <= lastOpen }, returns = min(lanterns.count, progress.returns)
        let key = "\(counts)/\(returns)/\(stars)"
        guard key != signature else { return }
        signature = key
        var wanted: [(String, HomeLayout.Slot, Bool)] = home.base.enumerated().map { ("b\($0)", $1, false) }
        let open = progress.roomsOpen(layout.thresholds)
        if let terrain = home.terrain, !terrain.isEmpty { wanted.append(("t\(open)", terrain[min(open, terrain.count - 1)], false)) }
        let upcoming = stages.firstIndex { progress.points < $0.threshold }
        var lit: [Int: SIMD3<Float>] = [:]
        for (i, stage) in stages.enumerated() {
            if progress.points < stage.threshold {
                if i == upcoming { wanted += (stage.outline ?? []).enumerated().map { ("o\(i).\($0)", $1, false) } }
                continue
            }
            wanted += stage.structure.enumerated().map { ("s\(i).\($0)", $1, false) }
            wanted += stage.items.prefix(counts[i]).enumerated().map { ("i\(i).\($0)", $1, true) }
            if let light = stage.light { lit[i] = SIMD3(light[0], light[1], light[2]) }
        }
        wanted += lanterns.prefix(returns).enumerated().map { ("l\($0)", $1, true) }
        let starSize = home.starScale ?? 1
        wanted += home.stars.prefix(stars).enumerated().map { ("*\($0)", HomeLayout.Slot(asset: "star", t: $1, q: [0, 0, 0, 1], s: [starSize, starSize, starSize], home: nil), true) }
        let keys = Set(wanted.map(\.0)), first = shown.isEmpty  // the first build just appears
        try await load(Set(wanted.map(\.1.file)))  // (all loaded up front; this is only a safety net)
        // What's no longer wanted goes: pieces leave one after another, the newest first; the rest just goes.
        let going = order.filter { !keys.contains($0) }.reversed()
        for (n, k) in going.enumerated() {
            guard let entity = shown.removeValue(forKey: k) else { continue }
            popping.removeAll { $0.entity === entity }
            if animated && pieces.contains(k) { leaving[k] = (entity, entity.transform, now + Double(n) * 0.03) } else { entity.removeFromParent() }
        }
        for (k, slot, piece) in wanted where shown[k] == nil {
            if let back = leaving.removeValue(forKey: k) {  // wanted again before it had gone: it just comes back
                back.entity.transform = slot.transform; shown[k] = back.entity; continue
            }
            let entity = try await prototype(slot).clone(recursive: true); entity.transform = slot.transform; built.addChild(entity); shown[k] = entity
            if animated && piece && !first { popping.append((entity, slot.transform, now + Double(popping.count) * 0.04)); entity.scale = .zero }
        }
        order = wanted.map(\.0); pieces = Set(wanted.filter(\.2).map(\.0))
        for (i, light) in lights where lit[i] == nil { light.removeFromParent(); lights[i] = nil }
        for (i, position) in lit where lights[i] == nil {
            let light = PointLight(); light.light.color = NSColor(red: 1, green: 0.78, blue: 0.52, alpha: 1)
            light.light.intensity = 3600; light.light.attenuationRadius = 3.0; light.position = position; root.addChild(light); lights[i] = light
        }
    }

    /// Draws what's built after `points` focused minutes into `texture`. `animated`: pieces land and leave, and the
    /// camera eases to its new framing (a still, or reduced motion, shows the end state at once).
    func render(points: Double, returns: Int = 0, animated: Bool = false) async throws {
        while rendering { try await Task.sleep(for: .milliseconds(3)) }; rendering = true; defer { rendering = false }
        let now = CACurrentMediaTime(), delta = lastFrame == 0 ? 1.0 / 60 : min(0.1, now - lastFrame); lastFrame = now
        try await sync(HomeProgress(points: points, returns: returns), animated: animated, now: now)
        popping = popping.filter { item in
            let elapsed = now - item.start
            guard elapsed >= 0 else { item.entity.scale = .zero; return true }
            var t = item.transform
            if elapsed < Self.dropSeconds {
                // Falling: from above, gathering speed, a touch small.
                let u = Float(elapsed / Self.dropSeconds), fall = u * u
                t.translation.y += Self.dropHeight * (1 - fall)
                t.scale *= 0.55 + 0.45 * u
            } else {
                // Landed: squashed, then springing back past its size and settling.
                let u = Float(min(1, (elapsed - Self.dropSeconds) / Self.settleSeconds))
                let wobble = sin(u * .pi * 2.2) * (1 - u) * 0.18
                t.scale *= SIMD3(1 + wobble * 0.6, 1 - wobble, 1 + wobble * 0.6)
            }
            item.entity.transform = t
            if elapsed >= Self.dropSeconds + Self.settleSeconds { item.entity.transform = item.transform; return false }
            return true
        }
        leaving = leaving.filter { _, item in
            let u = Float(max(0, now - item.start) / Self.leaveSeconds)
            guard u < 1 else { item.entity.removeFromParent(); return false }
            // A little lift, then shrinking as it sinks.
            var t = item.transform, ease = u * u
            t.translation.y += 0.12 * sin(u * .pi) - 0.35 * ease
            t.scale *= max(0.001, 1 - ease)
            item.entity.transform = t
            return true
        }
        // The camera eases to the framing for what's built.
        let goal = home.cameras.last { $0.threshold <= points } ?? home.cameras[0]
        let target = SIMD3(goal.target[0], goal.target[1], goal.target[2]), from = SIMD3(goal.from[0], goal.from[1], goal.from[2])
        if let current = view, animated {
            let k = Float(1 - exp(-delta * 2.6))
            let next = (target: current.target + (target - current.target) * k, from: current.from + (from - current.from) * k)
            cameraMoving = simd_distance(next.target, target) + simd_distance(next.from, from) > 0.003
            view = cameraMoving ? next : (target, from)
        } else { view = (target, from); cameraMoving = false }
        camera.look(at: view!.target, from: view!.from, relativeTo: nil)
        let next = 1 - current
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do { try renderer.updateAndRender(deltaTime: delta, cameraOutput: outputs[next], onComplete: { _ in continuation.resume() }) } catch { continuation.resume(throwing: error) }
        }
        current = next
    }
    /// Draws every stage once (each ground, every piece), so the first time a part shows on screen costs nothing:
    /// a part's first draw uploads it to the GPU, which would stall an animation for a moment.
    func warmUp() async throws {
        for points in layout.thresholds { try await render(points: points) }
    }

    /// Something is still moving: a piece landing or leaving, or the camera easing.
    var animating: Bool { !popping.isEmpty || !leaving.isEmpty || cameraMoving }

    /// The last picture drawn, as an image (for a still, or to show while the renderer loads again).
    func image() -> CGImage? {
        let (w, h) = Self.pixels
        var bytes = Data(count: w * h * 4)
        bytes.withUnsafeMutableBytes { buffer in texture.getBytes(buffer.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The popover's (and the Today window's) view of a day's house: what's built after `points` focused minutes. New
/// pieces since you last looked land one after another when it opens. On screen, a HouseCanvas draws it at the
/// display's pace, only while something moves; with no canvas on screen (a look check, a capture) it draws stills.
@MainActor @Observable final class HomeScene {
    /// The last still: drawn when no canvas is on screen, and kept on close so reopening shows the house at once.
    var image: CGImage?
    var error: String?
    /// Focused minutes to show the house at: today's, or the day picked in the Today window.
    private(set) var points = 0.0
    /// What's on show while new pieces land.
    private(set) var displayedPoints = 0.0
    private(set) var delivering = false
    /// "Look what we built, together." for a few seconds after a milestone.
    private(set) var celebrating = false
    /// A canvas is showing live frames (the still underneath is hidden).
    private(set) var live = false
    var loading: Bool { image == nil && error == nil && !live }
    /// Set once the first picture's in (and stays).
    private(set) var hasFrame = false
    @ObservationIgnored private(set) var frames = 0
    /// Seconds between two pieces landing (the Today window changes days faster).
    @ObservationIgnored var step = 0.32
    @ObservationIgnored private var renderer: HomeWorldRenderer?
    @ObservationIgnored private var layout: HomeLayout?
    /// The companion whose home is loaded: another one's means loading again.
    @ObservationIgnored private var loadedFor: Companion?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var release: Task<Void, Never>?
    @ObservationIgnored private var celebration: Task<Void, Never>?
    @ObservationIgnored private var landing = (from: 0.0, started: 0.0, delay: 0.0)
    /// Something changed since the last frame (new points, just opened).
    @ObservationIgnored private var dirty = true
    @ObservationIgnored private var drawing = false
    /// The view drawing live frames while it's on screen.
    @ObservationIgnored weak var canvas: HouseCanvasView?
    /// The renderer is kept this long after closing, so reopening soon is instant; then it's let go.
    @ObservationIgnored var keepRendererSeconds = 90.0
    @ObservationIgnored private var companionObserver: NSObjectProtocol?

    init() {
        companionObserver = NotificationCenter.default.addObserver(forName: .mokuCompanionChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.companionChanged() }
        }
    }
    /// Another companion: an open scene shows its home at once, with the same progress (nothing lands again); a closed
    /// one lets the old home go and loads the new one when it next opens.
    func companionChanged() {
        guard loadedFor != nil, loadedFor != Companion.current else { return }
        if task != nil { open(points: points, from: points); return }
        release?.cancel(); release = nil; renderer = nil; layout = nil; image = nil; loadedFor = nil
    }

    /// Shows the house at `points` focused minutes; the pieces after `from` land one by one (all of them on a new day).
    func open(points value: Double, from previous: Double? = nil) {
        stop(); release?.cancel(); release = nil; error = nil; let token = generation
        points = value
        land(from: min(previous ?? value, value), delay: 0.5)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let companion = Companion.current
                if loadedFor != companion { layout = nil; renderer = nil; image = nil; hasFrame = false; loadedFor = companion }
                if layout == nil { layout = try HomeLayout.load(companion.homeLayoutPath) }
                if renderer == nil {
                    let loaded = try await HomeWorldRenderer(kind: .treehouse, layout: layout!, homeKey: companion.homeKey); try await loaded.warmUp()
                    guard !Task.isCancelled, token == generation else { return }; renderer = loaded
                }
                // Where the landing starts, as it is: a kept renderer still shows the last house, the warmed one the whole.
                try await renderer?.render(points: displayedPoints); guard !Task.isCancelled, token == generation else { return }
                canvas?.wake()
                while !Task.isCancelled, token == generation {
                    // No canvas on screen: draw stills here, steadily (look checks and captures wait on them).
                    if canvas?.onScreen != true {
                        try await draw(); guard !Task.isCancelled, token == generation else { return }
                        image = renderer?.image(); frames += 1; if !hasFrame { hasFrame = true }
                    }
                    try await Task.sleep(for: .milliseconds(canvas?.onScreen == true ? 250 : 33))
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription; ErrorReports.report(.assetLoad, error) }
        }
    }

    /// New focused minutes: the next pieces land, or (a day with less built) the extra ones leave.
    func setPoints(_ value: Double) {
        guard value != points else { return }
        if value > points, task != nil { land(from: displayedPoints, delay: 0) }
        points = value
        if value < displayedPoints { set(\.displayedPoints, value); set(\.delivering, false) }
        dirty = true; canvas?.wake()
    }

    func skipDelivery() { set(\.delivering, false); set(\.displayedPoints, points); dirty = true; canvas?.wake() }

    /// "Look what we built, together." over the house for a few seconds.
    func celebrate(for seconds: Double) {
        celebration?.cancel(); celebrating = true
        celebration = Task { [weak self] in try? await Task.sleep(for: .seconds(seconds)); if !Task.isCancelled { self?.celebrating = false } }
    }

    func postcardFrame() async throws -> CGImage? {
        guard let renderer else { return image }
        try await renderer.render(points: points)
        return renderer.image()
    }

    func close() {
        let wasOpen = task != nil
        stop()
        if wasOpen, live, let renderer { image = renderer.image() }  // the last picture, for an instant reopen
        set(\.live, false)
        release?.cancel()
        release = Task { [weak self, keep = keepRendererSeconds] in
            try? await Task.sleep(for: .seconds(keep))
            guard !Task.isCancelled, let self, self.task == nil else { return }
            self.renderer = nil
        }
    }
    var holdsRenderer: Bool { renderer != nil }
    /// Something is changing on screen (a piece landing or leaving, the camera easing, a change not drawn yet).
    var moving: Bool { dirty || delivering || (renderer?.animating ?? false) }

    /// The canvas's display link: the next frame when something moves; otherwise the link rests.
    func tick(_ canvas: HouseCanvasView) {
        guard task != nil else { canvas.rest(); return }
        guard let renderer, !drawing else { return }  // still loading, or the last frame isn't done
        guard moving else { canvas.rest(); return }
        drawing = true
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            defer { drawing = false }
            guard (try? await draw()) != nil, token == generation, task != nil else { return }
            canvas.present(renderer.texture)
            frames += 1
            // The landing's clock starts with the first frame on screen, so nothing lands unseen while it loaded.
            if !live { live = true; hasFrame = true; landing.started = CACurrentMediaTime() }
        }
    }

    private func draw() async throws {
        guard let renderer else { return }
        let reduced = MotionPreference.reduced
        if delivering && !reduced {
            let raw = (CACurrentMediaTime() - landing.started - landing.delay) / step, landed = raw < 0 ? 0 : Int(raw) + 1
            let shown = min(points, landed == 0 ? landing.from : (landing.from / 10).rounded(.down) * 10 + Double(landed) * 10)
            set(\.displayedPoints, shown)
            if shown >= points { set(\.delivering, false) }
        }
        if !delivering || reduced { set(\.delivering, false); set(\.displayedPoints, points) }
        dirty = false
        try await renderer.render(points: displayedPoints, animated: !reduced)
    }

    /// Replays the house from `from` up to `points`, one piece every `step` seconds after `delay`.
    private func land(from start: Double, delay: Double) {
        landing = (max(0, start), CACurrentMediaTime(), delay)
        set(\.displayedPoints, landing.from); set(\.delivering, landing.from < points)
        dirty = true
    }

    private func stop() { generation += 1; task?.cancel(); task = nil; set(\.delivering, false) }

    /// Assigns only real changes: views read these, and a frame sets them 60 times a second.
    private func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<HomeScene, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
    isolated deinit {
        task?.cancel(); release?.cancel(); celebration?.cancel()
        if let companionObserver { NotificationCenter.default.removeObserver(companionObserver) }
    }
}

/// Draws a HomeScene's live frames straight to the screen: a Metal layer, fed at the display's pace and only while
/// something moves, so pieces land smoothly without copying every frame through the CPU.
final class HouseCanvasView: NSView {
    private let metal = CAMetalLayer()
    private let queue: (any MTLCommandQueue)?
    private var link: CADisplayLink?
    weak var scene: HomeScene?
    var onScreen: Bool { window != nil && link != nil }

    init(scene: HomeScene) {
        let device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        self.scene = scene
        super.init(frame: .zero)
        metal.device = device
        metal.pixelFormat = .bgra8Unorm_srgb
        metal.framebufferOnly = false
        metal.isOpaque = false
        metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metal.drawableSize = CGSize(width: HomeWorldRenderer.pixels.width, height: HomeWorldRenderer.pixels.height)
        metal.contentsGravity = .resizeAspectFill
        metal.masksToBounds = true
        layer = metal; wantsLayer = true  // layer-hosting: the view shows exactly this layer
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate(); link = nil
        if window != nil {
            let link = displayLink(target: self, selector: #selector(step))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            self.link = link
            scene?.canvas = self
        } else if scene?.canvas === self { scene?.canvas = nil }
    }
    @objc private func step(_ link: CADisplayLink) { scene?.tick(self) }
    func wake() { link?.isPaused = false }
    func rest() { link?.isPaused = true }
    func present(_ texture: any MTLTexture) {
        guard let drawable = metal.nextDrawable(), let buffer = queue?.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: texture, to: drawable.texture); blit.endEncoding()
        buffer.present(drawable); buffer.commit()
    }
}

struct HouseCanvas: NSViewRepresentable {
    let scene: HomeScene
    func makeNSView(context: Context) -> HouseCanvasView { HouseCanvasView(scene: scene) }
    func updateNSView(_ view: HouseCanvasView, context: Context) { if view.scene !== scene { view.scene = scene } }
}

/// The home at dusk: the sky and moon, the house (live, or its last still while it loads), the celebration and Skip.
struct HomeSceneView: View {
    let scene: HomeScene
    var body: some View {
        ZStack {
            HomeSky()
            if !scene.live, let image = scene.image { Image(decorative: image, scale: 2).resizable().scaledToFill().frame(maxWidth: .infinity, maxHeight: .infinity).clipped() }
            HouseCanvas(scene: scene).allowsHitTesting(false)
            if let error = scene.error { Text("Moku’s home is resting.\n\(error)").font(.caption).foregroundStyle(.white.opacity(0.85)).padding(24) }
            else if scene.loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            if scene.celebrating {
                Text("Look what we built, together.").font(.system(size: 12, design: .serif)).padding(10).background(paper, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(.top, 92).padding(.trailing, 12)
                    .transition(.opacity)
            }
            if scene.delivering {
                Button("Skip") { scene.skipDelivery() }.font(.caption).buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule()).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(12)
            }
        }
        .animation(.easeOut(duration: 0.25), value: scene.celebrating)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(DayHouse.names.home): \(DayHouse.percent(scene.displayedPoints)) percent built")
    }
}

/// Dusk behind the home: indigo to rose to warm sand, a few stars, and the moon.
struct HomeSky: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(stops: [.init(color: Color(red: 0.15, green: 0.18, blue: 0.32), location: 0), .init(color: Color(red: 0.40, green: 0.36, blue: 0.50), location: 0.42),
                                   .init(color: Color(red: 0.80, green: 0.64, blue: 0.58), location: 0.72), .init(color: Color(red: 0.93, green: 0.84, blue: 0.72), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                for (x, y, r) in [(0.12, 0.06, 1.1), (0.3, 0.14, 0.8), (0.46, 0.05, 0.9), (0.62, 0.2, 0.7), (0.22, 0.26, 0.8), (0.55, 0.32, 0.6), (0.08, 0.34, 0.7)] as [(Double, Double, Double)] {
                    context.fill(Path(ellipseIn: CGRect(x: x * size.width, y: y * size.height, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.7)))
                }
            }
            Circle().fill(RadialGradient(colors: [Color(red: 1, green: 0.98, blue: 0.9), Color(red: 0.98, green: 0.91, blue: 0.74)], center: .init(x: 0.4, y: 0.38), startRadius: 1, endRadius: 28))
                .frame(width: 44, height: 44).shadow(color: Color(red: 1, green: 0.92, blue: 0.72).opacity(0.75), radius: 20)
                .padding(.trailing, 30).padding(.top, 26).accessibilityHidden(true)
        }
    }
}

extension MokuVisualDiagnostics {
    /// Look-dev stills: each home at day 1 (3 h), week 1 (20 h) and month 3 (200 h), over the dusk sky:
    /// home-<kind>-<age>.png, and a contact sheet, home-look.png.
    public static func homeLookCheck(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let layout = try HomeLayout.load()
        var sheet: [CGImage] = []
        for kind in HomeKind.allCases {
            let renderer = try await HomeWorldRenderer(kind: kind, layout: layout)
            for (points, returns, age) in [(180.0, 6, "day1"), (1200.0, 40, "week1"), (12000.0, 200, "month3")] {
                var image: CGImage?
                try await renderer.render(points: points, returns: returns); image = renderer.image()
                guard let image, let composed = overSky(image) else { continue }
                try NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("home-\(kind.rawValue)-\(age).png"))
                sheet.append(composed)
            }
        }
        if let contact = contactSheet(sheet, columns: 3) { try NSBitmapImageRep(cgImage: contact).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("home-look.png")) }
    }

    /// Look development for today's tree (assets/src/tree_kit.py), drawn by the app's own renderer: the day at
    /// several focused-minute marks, with a lantern for every ~40 minutes. treeday-<minutes>.png and
    /// a contact sheet, daytree-look.png.
    public static func dayTreeLookCheck(directory: URL, minutes: [Double] = [15, 45, 75, 105, 150, 200, 240, 300, 360, 420, 480, 560]) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let layout = try HomeLayout.load("world/daytree/layout.json")
        let renderer = try await HomeWorldRenderer(kind: .treehouse, layout: layout, homeKey: "daytree")
        var sheet: [CGImage] = []
        for points in minutes {
            var image: CGImage?
            try await renderer.render(points: points, returns: min(10, Int(points / 40))); image = renderer.image()
            guard let image, let composed = overSky(image) else { continue }
            try NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(String(format: "treeday-%03d.png", Int(points))))
            sheet.append(composed)
        }
        if let contact = contactSheet(sheet, columns: 4) { try NSBitmapImageRep(cgImage: contact).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("daytree-look.png")) }
    }

    /// Look development for today's house (assets/src/house_kit.py), drawn by the app's own renderer: the day at
    /// several focused-minute marks. houseday-<minutes>.png and a contact sheet, dayhouse-look.png.
    public static func dayHouseLookCheck(directory: URL, minutes: [Double] = [10, 40, 80, 110, 140, 180, 210, 240]) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let layout = try HomeLayout.load("world/dayhouse/layout.json")
        let renderer = try await HomeWorldRenderer(kind: .treehouse, layout: layout, homeKey: "dayhouse")
        var sheet: [CGImage] = []
        for points in minutes {
            var image: CGImage?
            try await renderer.render(points: points); image = renderer.image()
            guard let image, let composed = overSky(image) else { continue }
            try NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(String(format: "houseday-%03d.png", Int(points))))
            sheet.append(composed)
        }
        if let contact = contactSheet(sheet, columns: 4) { try NSBitmapImageRep(cgImage: contact).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("dayhouse-look.png")) }
    }

    /// The house in a real window, so its canvas draws live frames at the display's pace: today's house lands from the
    /// empty plot (150 min), then the day changes to one with less built (60 min) and one with more (220 min).
    /// live-house.json holds each change's frames, seconds and fps; live-house-window.txt the window's number (for
    /// `screencapture -l`), written as soon as it's on screen.
    public static func liveHouseCheck(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scene = HomeScene(); scene.step = 0.07
        let window = NSWindow(contentRect: CGRect(x: 80, y: 160, width: 500, height: 475), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Moku house check"
        window.contentView = NSHostingView(rootView: HomeSceneView(scene: scene)); window.orderFrontRegardless()
        try "\(window.windowNumber)".write(to: directory.appendingPathComponent("live-house-window.txt"), atomically: true, encoding: .utf8)
        var report: [[String: Any]] = []
        for (label, minutes) in [("open 150", 150.0), ("down to 60", 60), ("up to 220", 220), ("reopen 240 from 180", 240)] {
            let frames = scene.frames, start = CACurrentMediaTime()
            if label.hasPrefix("open") { scene.open(points: minutes, from: 0) }
            else if label.hasPrefix("reopen") { scene.close(); try await Task.sleep(for: .seconds(1)); scene.open(points: minutes, from: 180) }
            else { scene.setPoints(minutes) }
            try await Task.sleep(for: .milliseconds(150))
            while scene.moving || !scene.live || scene.frames == frames { try await Task.sleep(for: .milliseconds(20)); if CACurrentMediaTime() - start > 20 { break } }
            let seconds = CACurrentMediaTime() - start, drawn = scene.frames - frames
            report.append(["change": label, "frames": drawn, "seconds": (seconds * 100).rounded() / 100, "fps": (Double(drawn) / seconds).rounded()])
            try await Task.sleep(for: .seconds(1.5))  // time for a screenshot of the settled house
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]).write(to: directory.appendingPathComponent("live-house.json"))
        window.close(); scene.close()
    }

    /// The popover's dusk sky behind a render: indigo to rose to sand, and a soft moon.
    static func overSky(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colours = [CGColor(srgbRed: 0.93, green: 0.84, blue: 0.72, alpha: 1), CGColor(srgbRed: 0.80, green: 0.64, blue: 0.58, alpha: 1), CGColor(srgbRed: 0.40, green: 0.36, blue: 0.50, alpha: 1), CGColor(srgbRed: 0.15, green: 0.18, blue: 0.32, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours as CFArray, locations: [0, 0.28, 0.58, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        context.setShadow(offset: .zero, blur: 40, color: CGColor(srgbRed: 1, green: 0.92, blue: 0.72, alpha: 0.8))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.97, blue: 0.88, alpha: 1)); context.fillEllipse(in: CGRect(x: Double(w) * 0.78, y: Double(h) * 0.8, width: 64, height: 64))
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    static func contactSheet(_ images: [CGImage], columns: Int) -> CGImage? {
        guard let first = images.first else { return nil }
        let w = first.width / 2, h = first.height / 2, rows = (images.count + columns - 1) / columns
        guard let context = CGContext(data: nil, width: w * columns, height: h * rows, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for (i, image) in images.enumerated() { context.draw(image, in: CGRect(x: (i % columns) * w, y: (rows - 1 - i / columns) * h, width: w, height: h)) }
        return context.makeImage()
    }
}
