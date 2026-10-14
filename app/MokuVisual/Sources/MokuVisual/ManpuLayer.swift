import AppKit
import QuartzCore
import MokuKit

@MainActor final class ManpuLayer {
    private struct Manifest: Decodable {
        struct Sprite: Decodable {
            struct Density: Decodable { let sheet: String; let still: String; let frameSizePixels: [Int] }
            let name: String; let frameCount: Int; let frameDurationSeconds: Double
            let offsetFromHeadInCanvasNormalized: [Double]; let displaySizePoints: Double
            let densities: [String: Density]
        }
        let sprites: [Sprite]
    }
    let root = CALayer()
    private let glyph = CALayer()
    private let manifest: Manifest?
    private var task: Task<Void, Never>?
    private var head = CGPoint(x: 130, y: 95)
    private var current: Manifest.Sprite?
    private var cachedFrames: [String: [CGImage]] = [:]
    private(set) var symbol: String?
    /// Marks the companion on stage draws itself (Tetsu's visor shows its own "z" when it dozes).
    var ownMarks: Set<String> = []
    private var suppressed = false
    init() {
        root.name = "manpu"; glyph.name = "manpu mark"
        manifest = MokuAssets.file("symbols/manifest.json").flatMap { try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: $0)) }
        root.frame = CGRect(origin: .zero, size: StageGeometry.size); root.addSublayer(glyph); glyph.opacity = 0
    }
    func anchor(at point: CGPoint) {
        head = point
        guard let current else { return }
        let offset = current.offsetFromHeadInCanvasNormalized
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // The manifest's offsets are from the head; our anchor is the face centre (between the pupils), so
        // unnudged a mark lands on the right eye. Out past the head's edge, like a manga mark.
        let side: CGFloat = offset[0] < 0 ? -1 : 1  // outward, on whichever side the mark sits
        glyph.position = CGPoint(x: head.x + offset[0] * 120 + side * Self.besideTheHead.x, y: head.y - offset[1] * 120 + Self.besideTheHead.y)
        CATransaction.commit()
    }
    static let besideTheHead = CGPoint(x: 16, y: 12)
    func setSuppressed(_ on: Bool) { suppressed = on; root.isHidden = on }
    func clear() { task?.cancel(); task = nil; retire(); symbol = nil; glyph.removeAllAnimations(); glyph.opacity = 0 }
    /// A mark still on show (a held vein or drop of sweat, a repeating "z") goes with a short fade, where it is, instead of
    /// vanishing the moment the mood changes (launch QA, lens 4: the angry vein popped out at 0.8 opacity on the return).
    private func retire() {
        guard symbol != nil, !root.isHidden, let shown = glyph.presentation(), shown.opacity > 0.08, let picture = shown.contents else { return }
        let ghost = CALayer()
        ghost.name = "manpu mark (leaving)"; ghost.bounds = glyph.bounds; ghost.position = shown.position; ghost.transform = shown.transform
        ghost.contents = picture; ghost.contentsScale = glyph.contentsScale; ghost.opacity = 0
        root.addSublayer(ghost)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = shown.opacity; fade.toValue = 0; fade.duration = 0.2; fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
        ghost.add(fade, forKey: "leave")
        CATransaction.commit()
    }
    func mood(_ mood: Mood, reduced: Bool) {
        clear()
        task = Task { [weak self] in
            guard let self else { return }
            switch mood {
            case .content: return
            case .happy:
                show("bounce", duration: 1.2, reduced: reduced)
                do { try await Task.sleep(for: .seconds(1.2)) } catch { return }
                show("sparkles", duration: 0.8, reduced: reduced)
            case .proud:
                show("hmph", duration: 0.6, reduced: reduced)
                do { try await Task.sleep(for: .seconds(0.6)) } catch { return }
                show("sparkles", duration: 4, repeats: true, reduced: reduced)
            case .curious:
                show("exclamation", duration: 0.4, reduced: reduced)
                do { try await Task.sleep(for: .seconds(0.4)) } catch { return }
                show("question", duration: 6, reduced: reduced)
            case .concerned: show("sweat", duration: 1.2, holds: true, reduced: reduced)
            case .disappointed: show("sigh", duration: 1.5, reduced: reduced)
            case .annoyed: show("pop_vein", duration: 1.2, holds: true, reduced: reduced)
            case .sleepy: show("zzz", duration: 4, repeats: true, reduced: reduced)
            }
        }
    }
    func pat(reduced: Bool) { clear(); show("heart", duration: 0.8, reduced: reduced) }
    private func frames(for sprite: Manifest.Sprite) -> [CGImage] {
        if let cached = cachedFrames[sprite.name] { return cached }
        guard let density = sprite.densities["3x"] ?? sprite.densities["2x"],
              let image = LanternLayer.image("symbols/\(density.sheet)") else { return [] }
        let size = density.frameSizePixels
        let frames = (0..<sprite.frameCount).compactMap { image.cropping(to: CGRect(x: $0 * size[0], y: 0, width: size[0], height: size[1])) }
        cachedFrames[sprite.name] = frames; return frames
    }
    private func show(_ name: String, duration: Double, repeats: Bool = false, holds: Bool = false, reduced: Bool) {
        guard !ownMarks.contains(name) else { return }  // the companion draws this one itself
        guard let sprite = manifest?.sprites.first(where: { $0.name == name }) else { return }
        let frames = frames(for: sprite); guard !frames.isEmpty else { return }
        current = sprite; symbol = name; glyph.removeAllAnimations(); glyph.opacity = holds ? 0.8 : 0
        glyph.bounds = CGRect(x: 0, y: 0, width: sprite.displaySizePoints, height: sprite.displaySizePoints)
        glyph.contents = frames[min(2, frames.count - 1)]; glyph.contentsScale = 3; anchor(at: head)
        let group = CAAnimationGroup(); group.duration = reduced ? min(1, duration) : duration
        group.repeatCount = repeats && !reduced ? .infinity : 0
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = holds ? [0, 1, 0.8] : [0, 1, 1, 0]
        opacity.keyTimes = holds ? [0, 0.2, 1] : [0, 0.08, repeats ? 0.55 : 0.7, repeats ? 0.75 : 1]
        var animations: [CAAnimation] = [opacity]
        if !reduced {
            let contents = CAKeyframeAnimation(keyPath: "contents"); contents.values = frames
            contents.calculationMode = .discrete; contents.duration = min(duration, Double(frames.count) * sprite.frameDurationSeconds)
            animations.append(contents)
            if name == "question" {
                let bob = CAKeyframeAnimation(keyPath: "transform.translation.y"); bob.values = [0, 1, 0, -1, 0]; bob.duration = 1.4; bob.repeatCount = .infinity; animations.append(bob)
            } else if name == "pop_vein" {
                let pulse = CAKeyframeAnimation(keyPath: "transform.scale"); pulse.values = [1, 1.25, 1, 1.25, 1]; pulse.duration = 1.2; animations.append(pulse)
            } else if name == "sweat" || name == "zzz" || name == "sigh" {
                let rise = CABasicAnimation(keyPath: "transform.translation.y"); rise.fromValue = 0; rise.toValue = name == "sweat" ? -3 : 12; rise.duration = min(duration, 3); animations.append(rise)
            }
        }
        group.animations = animations; group.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
        glyph.add(group, forKey: "manpu"); root.isHidden = suppressed
    }
    func capture(in context: CGContext) {
        guard !suppressed else { return }
        let previous = glyph.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glyph.opacity = symbol == nil ? 0 : 0.9; root.render(in: context); glyph.opacity = previous
        CATransaction.commit()
    }
    isolated deinit { task?.cancel() }
}
