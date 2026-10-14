import AppKit
import QuartzCore
import MokuKit

@MainActor final class LanternLayer {
    private struct Manifest: Decodable {
        struct State: Decodable {
            struct Files: Decodable { let body: String; let flame: String }
            let name: String; let intensity: Double; let files: [String: Files]
        }
        let displaySizePoints: [Double]
        let anchorsNormalizedTopLeft: [String: [Double]]
        let states: [State]
    }
    let root = CALayer()
    private let sprite = CALayer()
    private var bodies: [CALayer] = []
    private var flames: [CALayer] = []
    private var intensities: [Double] = []
    private var nextGutter = 0.0
    var preferences: UserDefaults?
    private var firstFocusDay: Date?
    private var burstTask: Task<Void, Never>?
    private var state: WorkState = .idle
    private(set) var phase = LanternPhase.forState(.idle)
    private(set) var isCarried = false
    private(set) var gutterCount = 0
    private var isHidden = false
    private var reduced = false
    private var flamePoint = CGPoint(x: 54, y: 30)
    private var sparkImage: CGImage?
    init() {
        root.name = "lantern"; root.frame = CGRect(origin: .zero, size: StageGeometry.size)
        root.addSublayer(sprite)
        loadSprites()
        apply(.idle, reduced: false, instant: true)
    }
    private func loadSprites() {
        guard let url = MokuAssets.file("lantern/manifest.json"), let data = try? Data(contentsOf: url), let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return }
        let size = CGSize(width: manifest.displaySizePoints[0], height: manifest.displaySizePoints[1])
        sprite.frame = CGRect(x: StageGeometry.characterFrame.midX - 88, y: 12, width: size.width, height: size.height)
        if let anchor = manifest.anchorsNormalizedTopLeft["flame"], anchor.count == 2 {
            flamePoint = CGPoint(x: sprite.frame.minX + anchor[0] * size.width, y: sprite.frame.minY + (1-anchor[1]) * size.height)
        }
        for item in manifest.states.sorted(by: { $0.intensity < $1.intensity }) {
            guard let files = item.files["3x"] ?? item.files["2x"] else { continue }
            let body = CALayer(), flame = CALayer()
            for (layer, name) in [(body, files.body), (flame, files.flame)] {
                layer.frame = CGRect(origin: .zero, size: size); layer.contents = Self.image("lantern/\(name)")
                layer.contentsScale = 3; layer.contentsGravity = .resizeAspect; layer.opacity = 0; sprite.addSublayer(layer)
            }
            bodies.append(body); flames.append(flame); intensities.append(item.intensity)
        }
        sparkImage = Self.image("lantern/spark@3x.png")
    }
    static func image(_ path: String) -> CGImage? {
        guard let url = MokuAssets.file(path), let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    func apply(_ state: WorkState, reduced: Bool, instant: Bool = false, returning: Bool = false) {
        // Grace preserves the in-flight flame curve rather than jumping to lit.
        if state == .grace && !instant && self.reduced == reduced { self.state = state; return }
        self.state = state; self.reduced = reduced; if state != .grace { phase = .forState(state) }
        let today = Calendar.current.startOfDay(for: .now)
        let recorded = preferences?.object(forKey: "MokuVisual.firstFocusDay") as? Date
        let lighting = state == .focused && (firstFocusDay ?? recorded) != today && !returning
        if state == .focused { firstFocusDay = today; preferences?.set(today, forKey: "MokuVisual.firstFocusDay") }
        let duration = instant ? 0 : reduced ? 1 : lighting ? 90 : state == .noticing ? 20 : returning ? 1.5 : 1.2
        let brightness = max(0.15, phase.brightness)
        var weights = [Double](repeating: 0, count: intensities.count)
        if let low = intensities.indices.last(where: { intensities[$0] <= brightness }) {
            if low + 1 < intensities.count {
                let high = low + 1, fraction = (brightness - intensities[low]) / (intensities[high] - intensities[low])
                weights[low] = 1 - fraction; weights[high] = fraction
            } else { weights[low] = 1 }
        } else if !weights.isEmpty { weights[0] = 1 }
        for index in bodies.indices {
            animate(bodies[index], key: "opacity", to: Float(weights[index]), duration: duration)
            animate(flames[index], key: "opacity", to: Float(weights[index]), duration: duration)
        }
        nextGutter = CACurrentMediaTime() + Double.random(in: 7...11)
    }
    private func animate(_ layer: CALayer, key: String, to value: Any, duration: Double) {
        let from = (layer.presentation() ?? layer).value(forKeyPath: key)
        CATransaction.begin(); CATransaction.setDisableActions(true); layer.setValue(value, forKeyPath: key); CATransaction.commit()
        layer.removeAnimation(forKey: key)
        guard duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: key); animation.fromValue = from; animation.toValue = value; animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
        layer.add(animation, forKey: key)
    }
    func tick(now: Double) {
        guard phase.gutter, !reduced, !isHidden, !isCarried, now >= nextGutter else { return }
        nextGutter = now + Double.random(in: 7...11); gutterCount += 1
        // Multiplicative dip retains a visible ember in every state.
        let flicker = CAKeyframeAnimation(keyPath: "opacity"); flicker.values = [1, 0.6, 1]; flicker.keyTimes = [0, 0.4, 1]; flicker.duration = 0.7
        sprite.add(flicker, forKey: "gutter")
    }
    func setCarried(_ carried: Bool) { isCarried = carried; sprite.isHidden = carried }
    func setHidden(_ hidden: Bool) {
        isHidden = hidden; root.isHidden = hidden
        if hidden { burstTask?.cancel(); root.sublayers?.filter { $0 is CAEmitterLayer }.forEach { $0.removeFromSuperlayer() } }
    }
    func celebrate(_ size: ReturnSize, reduced: Bool) {
        apply(.focused, reduced: reduced, returning: true)
        guard !isHidden else { return }
        if reduced { return }
        for flame in flames {
            let flare = CAKeyframeAnimation(keyPath: "transform.scale")
            flare.values = [1, 1.4, 1]; flare.keyTimes = [0, 0.25, 1]; flare.duration = 0.25
            flare.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            flame.add(flare, forKey: "returnFlare")
        }
        guard let sparkImage else { return }
        burstTask?.cancel()
        let emitter = CAEmitterLayer(); emitter.frame = root.bounds; emitter.emitterPosition = flamePoint; emitter.emitterShape = .point; emitter.renderMode = .additive
        let cell = CAEmitterCell(); cell.contents = sparkImage; cell.birthRate = size == .full ? 50 : 38; cell.lifetime = 1.2
        cell.velocity = 28; cell.velocityRange = 8; cell.emissionLongitude = .pi / 2; cell.emissionRange = .pi / 4
        cell.scale = 0.22; cell.scaleRange = 0.06; cell.alphaSpeed = -0.83; emitter.emitterCells = [cell]; root.addSublayer(emitter)
        burstTask = Task { [weak emitter] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { emitter?.removeFromSuperlayer(); return }
            emitter?.birthRate = 0
            do { try await Task.sleep(for: .seconds(1.3)) } catch { emitter?.removeFromSuperlayer(); return }
            emitter?.removeFromSuperlayer()
        }
    }
    isolated deinit { burstTask?.cancel() }
}
