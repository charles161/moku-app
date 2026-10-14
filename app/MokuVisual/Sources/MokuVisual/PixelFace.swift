import AppKit
import RealityKit

/// A face that is a display (next-wave.md §7): Tetsu's LED matrix behind the dark glass of its visor. The art is
/// `character/<id>/pixel_face.json` (assets/src/tetsu_pixels.py): the matrix, the palette and every eye frame as
/// pixel art. The face weights every companion shares (the moods, blinks, clips and micro-expressions) pick a frame
/// here, so the expression code stays shared and Moku's morph face is untouched; a change is always a
/// whole frame, with no in-between. Each frame is drawn once into its own small static texture (dots, glow and
/// scanlines) and kept; a change only swaps which one the display material shows.
@MainActor
final class PixelFace {
    struct Spec: Decodable {
        struct Spinner: Decodable { let centre: [Float]; let radius: Float; let dots: Int; let tail: Int }
        struct Display: Decodable { let cellPixels: Int; let dotSize: [Int]; let offLevel: Float; let glow: Float; let scanline: Float }
        /// The texture covers the whole visor, a cell per dot pitch; the matrix sits at `matrixOrigin` in it.
        struct Texture: Decodable { let columns: Int; let rows: Int; let matrixOrigin: [Int] }
        let columns: Int
        let rows: Int
        let eyes: [[Float]]
        let mouth: [Float]
        let zed: [Float]
        /// Where the ask's ">" sits and its cursor blinks (nil in older art).
        let prompt: [Float]?
        let cursor: [Float]?
        let frames: [String: [String]]
        let anchors: [String: String]
        let glyphs: [String: [String]]
        let palette: [String: [Float]]
        let spinner: Spinner
        let display: Display
        let texture: Texture
    }

    /// What the display shows: everything that decides its pixels, so equal frames draw nothing new.
    struct Frame: Hashable {
        var eyes = ["open", "open"]   // viewer's left, viewer's right
        var offset = SIMD2<Int>.zero  // the eyes' shift in dots (the gaze), +x right, +y down
        var mouth: String?
        var zed: String?
        var spinner: Int?
        var scan: Int?               // the scan's column step, 0…scanSteps (once across)
        var boot: Int?               // 0…63: the boot-up's step
        var dim = false              // a refresh blink: the eyes at a third of their brightness
        var lock: Int?               // seeing you: 0 brackets acquiring, wide round the eyes; 1 locked, tight
        var asking = false           // the ask: a ">" on the bottom line…
        var cursor = false           // …and the cursor after it, on or off
        var palette = "content"
    }

    let spec: Spec
    private(set) var frame = Frame()
    /// The display's material for the frame on show.
    private(set) var material: UnlitMaterial
    /// Frames already drawn, each a static texture made once (a blink's steps, the moods, the gaze positions), most
    /// recent last. At most `kept` (each is about 290 KB on the GPU).
    private var drawn: [Frame: UnlitMaterial] = [:]
    private var recent: [Frame] = []
    /// A scan's frames (its column steps, there and back), kept for good: every scan shows the same ones.
    private var scanFrames: [Frame: UnlitMaterial] = [:]
    private let kept = 16
    /// Diagnostics: the frames shown since launch, and seconds spent drawing them.
    private(set) var changes = 0
    private(set) var costs: [Double] = []
    /// Diagnostics: the display as last newly drawn.
    private(set) var lastImage: CGImage?

    static func load(companion: Companion) -> PixelFace? {
        guard companion != .moku, let url = MokuAssets.file("character/\(companion.rawValue)/pixel_face.json", companion: .moku),
              let data = try? Data(contentsOf: url), let spec = try? JSONDecoder().decode(Spec.self, from: data) else { return nil }
        return try? PixelFace(spec: spec)
    }

    init(spec: Spec) throws {
        self.spec = spec
        material = UnlitMaterial(color: .black)
        material = try picture(of: Frame())
    }

    /// The display's material for a frame: the matrix as an unlit picture of dark glass and lit dots (a screen lights
    /// itself; the glint on the glass above it keeps it glassy). An emissive texture on a lit material didn't follow
    /// the UVs in RealityRenderer. Drawn once per frame and kept.
    private func picture(of frame: Frame) throws -> UnlitMaterial {
        if let kept = drawn[frame] { recent.removeAll { $0 == frame }; recent.append(frame); return kept }
        if let kept = scanFrames[frame] { return kept }
        let color = (spec.palette[frame.palette] ?? [1, 1, 1]).map { $0 * (frame.dim ? 0.3 : 1) }
        let image = Self.draw(Self.levels(frame, spec), color: color, spec: spec)
        let texture = try TextureResource(image: image, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
        var material = UnlitMaterial(color: .white)
        material.color = .init(tint: .white, texture: .init(texture))
        lastImage = image
        if frame.scan != nil && scanFrames.count < 64 { scanFrames[frame] = material; return material }  // a scan's: kept
        drawn[frame] = material; recent.append(frame)
        if recent.count > kept { drawn[recent.removeFirst()] = nil }
        return material
    }

    /// The Mac is short of memory: the frames drawn so far go (the one on show stays; the others draw again when they're due).
    func dropCaches() { drawn = [:]; recent = []; scanFrames = [:] }

    /// Shows the frame for these face weights and this gaze (radians: yaw right, pitch up). `cross` turns it amber.
    /// Returns whether the display changed.
    @discardableResult func show(_ face: [String: Float], gaze: SIMD2<Float>, cross: Bool) -> Bool {
        let next = Self.frame(for: face, gaze: gaze, cross: cross)
        guard next != frame else { return false }
        let started = CACurrentMediaTime()
        do { material = try picture(of: next) } catch { NSLog("Pixel face: %@", "\(error)"); return false }
        frame = next; changes += 1
        if costs.count < 100_000 { costs.append(CACurrentMediaTime() - started) }
        return true
    }

    /// The blink gate for a display: how tall the lit eye is closed, against open (the iris height for a morph face).
    func closure(_ face: [String: Float]) -> [Float] {
        var open = face; open["blink_L"] = 0; open["blink_R"] = 0
        let shut = Self.levels(Self.frame(for: face, gaze: .zero, cross: false), spec), wide = Self.levels(Self.frame(for: open, gaze: .zero, cross: false), spec)
        return [0, 1].map { side in
            let half = side == 0 ? 0..<(spec.columns / 2) : (spec.columns / 2)..<spec.columns
            func height(_ levels: [Float]) -> Float { Float((0..<spec.rows).filter { r in half.contains { levels[r * spec.columns + $0] > 0.3 } }.count) }
            return height(shut) / max(1, height(wide))
        }
    }

    // MARK: - From weights to a frame

    static func frame(for face: [String: Float], gaze: SIMD2<Float>, cross: Bool) -> Frame {
        func w(_ name: String) -> Float { face[name] ?? 0 }
        var frame = Frame()
        let boot = w("px_boot")
        if boot > 0.003 { frame.boot = min(63, Int(boot * 64)); frame.eyes = ["off", "off"]; return frame }
        let spin = w("px_spin")
        if spin > 0.003 { frame.spinner = Int(spin * 48); frame.eyes = ["off", "off"]; return frame }
        if w("brows_angry") > 0.45 || cross { frame.palette = "cross" }
        // Waking from a doze: the dots go dark, the eyes flicker on as a line, catch, half open, then the mood's own.
        let wake = w("px_wake")
        if wake > 0.003 && wake < 0.7 {
            frame.eyes = Array(repeating: ["off", "line", "off", "line", "line", "half", "half"][min(6, Int(wake * 10))], count: 2)
            return frame
        }
        // A refresh blink (RealityCharacter steps it): the eyes dim (below 0.38), or go dark.
        let refresh = w("px_refresh")
        if refresh > 0.003 && refresh < 0.62 {
            if refresh < 0.38 { frame.dim = true } else { frame.eyes = ["off", "off"]; return frame }
        }
        // Seeing you: brackets close in round the eyes (acquiring), then hold tight (locked).
        let lock = w("px_lock")
        if lock > 0.003 && lock < 0.75 { frame.lock = lock < 0.3 ? 0 : 1 }
        // Each side's closure: a blink, narrowed or flat lids. blink_L is the character's left: the viewer's right.
        let lids = max(w("eyes_narrow") * 0.75, w("lid_flat"))
        let closure = [max(w("blink_R"), lids), max(w("blink_L"), lids)]
        for side in 0...1 {
            let c = closure[side]
            let eye: String
            if w("px_heart") > 0.5 { eye = "heart"; frame.palette = "heart" }
            else if w("eyes_dot") > 0.5 { eye = "dot" }
            else if w("eyes_happy") > 0.5 { eye = c > 0.9 ? "line" : "happy" }
            else if w("brows_angry") > 0.45 { eye = c < 0.38 ? "angry" : c < 0.75 ? "angry_half" : "line" }
            else if w("lid_sad") > 0.4 { eye = c < 0.45 ? "sad" : c < 0.8 ? "sad_half" : "line" }
            else if w("brows_concern") > 0.35 { eye = c < 0.3 ? "concerned" : c < 0.62 ? "half" : c < 0.88 ? "narrow" : "line" }
            else {
                let open = w("eyes_proud") > 0.4 ? "proud" : w("eyes_wide") > 0.45 ? "wide" : "open"
                eye = c < 0.3 ? open : c < 0.62 ? "half" : c < 0.88 ? "narrow" : "line"
            }
            frame.eyes[side] = eye
        }
        if frame.eyes == ["dot", "dot"] { frame.zed = w("sleep_z") > 0.75 ? "z" : w("sleep_z") > 0.3 ? "z_small" : nil }
        if w("mouth_smile_open") > 0.4 { frame.mouth = "mouth_smile" } else if w("mouth_open") > 0.35 { frame.mouth = "mouth_o" }
        else if w("cheeks_puff") > 0.35 { frame.mouth = "mouth_huff" }                              // cross: a huff
        else if max(w("pout"), w("lips_press")) > 0.35 { frame.mouth = "mouth_flat" }             // a pout, pressed lips
        else if w("frown") > 0.6 && !["happy", "heart", "dot"].contains(frame.eyes[0]) { frame.mouth = "mouth_frown" }  // let down
        // The ask: px_cursor is 1 while the cursor shows and 0.25 between blinks; the prompt line keeps no mouth.
        if w("px_cursor") > 0.1 { frame.mouth = nil; frame.asking = true; frame.cursor = w("px_cursor") > 0.5 }
        let scan = w("px_scan")
        if scan > 0.003 { frame.scan = scanStep(scan) }
        // The gaze moves the eyes by whole dots: a robot's saccade.
        frame.offset = SIMD2(Int((max(-1, min(1, gaze.x / 0.45)) * 3).rounded()),
                             Int((max(-1, min(1, -gaze.y / 0.4)) * 2).rounded()) + (w("eyes_look_down") > 0.5 ? 2 : 0))
        return frame
    }

    /// The scan's column, crossing the display once as the beam sweeps down the window (ScanBeam's curve, ease in and
    /// out), in `scanSteps` steps: an LED scanner, and few enough frames that each is drawn once and kept.
    static let scanSteps = 14
    static func scanStep(_ progress: Float) -> Int {
        Int((Float(ScanBeam.sweep(Double(progress))) * Float(scanSteps)).rounded())
    }

    // MARK: - Drawing

    /// Brightness (0…1) per dot, row-major from the top-left.
    static func levels(_ frame: Frame, _ spec: Spec) -> [Float] {
        let cols = spec.columns, rows = spec.rows
        var dots = [Float](repeating: 0, count: cols * rows)
        func set(_ c: Int, _ r: Int, _ v: Float) { if c >= 0, c < cols, r >= 0, r < rows { dots[r * cols + c] = max(dots[r * cols + c], v) } }
        func level(_ ch: Character) -> Float { ch == "#" ? 1 : ch == "+" ? 0.5 : ch == "-" ? 0.25 : 0 }
        func stamp(_ art: [String], centre: SIMD2<Float>, mirrored: Bool, rowTop: Int? = nil) {
            guard let width = art.first?.count else { return }
            let left = Int((centre.x - Float(width - 1) / 2).rounded(.down)), top = rowTop ?? Int((centre.y - Float(art.count - 1) / 2).rounded(.down))
            for (r, line) in art.enumerated() {
                for (c, ch) in (mirrored ? String(line.reversed()) : line).enumerated() where level(ch) > 0 { set(left + c, top + r, level(ch)) }
            }
        }
        if let boot = frame.boot {
            // Powered down, then the rows light one by one from the top, a full flash, dark, and the eyes switch on.
            let p = Float(boot) / 64
            if p >= 0.06 && p < 0.62 {
                let lit = min(rows, Int(((p - 0.06) / 0.56 * Float(rows)).rounded(.up)))
                for r in 0..<lit { for c in 0..<cols { set(c, r, r == lit - 1 ? 1 : 0.32) } }
            } else if p >= 0.62 && p < 0.72 {
                for r in 0..<rows { for c in 0..<cols { set(c, r, 0.55) } }
            } else if p >= 0.78 {
                for (side, eye) in spec.eyes.enumerated() { stamp(spec.frames[p < 0.88 ? "line" : "half"] ?? [], centre: SIMD2(eye[0], eye[1]), mirrored: side == 1) }
            }
            return dots
        }
        if let spinner = frame.spinner {
            let s = spec.spinner
            for k in 0..<s.dots {
                let behind = (spinner - k + s.dots * 64) % s.dots
                let v: Float = behind == 0 ? 1 : behind < s.tail ? 0.9 - 0.5 * Float(behind) / Float(s.tail) : 0.25  // bold enough at 100 px
                let a = Float(k) / Float(s.dots) * 2 * .pi - .pi / 2
                // Each step of the ring is a 2×2 block, so it reads as boldly as the eyes.
                let x = Int((s.centre[0] - 0.5 + s.radius * cos(a)).rounded()), y = Int((s.centre[1] - 0.5 + s.radius * sin(a)).rounded())
                for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] { set(x + dx, y + dy, v) }
            }
            return dots
        }
        for (side, name) in frame.eyes.enumerated() where name != "off" {
            guard let art = spec.frames[name], side < spec.eyes.count else { continue }
            let eye = spec.eyes[side], open = spec.frames["open"] ?? art
            let centre = SIMD2(eye[0] + Float(frame.offset.x), eye[1] + Float(frame.offset.y))
            let openTop = Int((centre.y - Float(open.count - 1) / 2).rounded(.down))
            let top: Int? = switch spec.anchors[name] {
            case "bottom": openTop + open.count - art.count
            case "low": openTop + open.count - art.count - 1
            default: nil
            }
            stamp(art, centre: centre, mirrored: side == 1, rowTop: top)
        }
        // The mouth follows the eyes across, and down when they look down, so they never overlap.
        if let mouth = frame.mouth, let art = spec.glyphs[mouth] {
            stamp(art, centre: SIMD2(spec.mouth[0] + Float(frame.offset.x), min(Float(rows) - Float(art.count) / 2, spec.mouth[1] + Float(max(0, frame.offset.y)))), mirrored: false)
        }
        if let lock = frame.lock {
            // Corner brackets round each eye's open frame: wide while acquiring, tight once locked.
            let open = spec.frames["open"] ?? [], h = Float(open.count), wEye = Float(open.first?.count ?? 6), gap: Float = lock == 0 ? 3 : 1
            for eye in spec.eyes {
                let cx = eye[0] + Float(frame.offset.x), cy = eye[1] + Float(frame.offset.y)
                let left = Int((cx - wEye / 2 - gap).rounded(.down)), right = Int((cx + wEye / 2 + gap).rounded(.up)) - 1
                let top = Int((cy - h / 2 - gap).rounded(.down)), bottom = Int((cy + h / 2 + gap).rounded(.up)) - 1
                for (x, y, dx, dy) in [(left, top, 1, 1), (right, top, -1, 1), (left, bottom, 1, -1), (right, bottom, -1, -1)] {
                    set(x, y, 1); set(x + dx, y, 1); set(x, y + dy, 1)
                }
            }
        }
        if frame.asking, let at = spec.prompt, let art = spec.glyphs["prompt"] { stamp(art, centre: SIMD2(at[0], at[1]), mirrored: false) }
        if frame.cursor, let at = spec.cursor, let art = spec.glyphs["cursor"] { stamp(art, centre: SIMD2(at[0], at[1]), mirrored: false) }
        if let zed = frame.zed, let art = spec.glyphs[zed] {
            stamp(art, centre: SIMD2(spec.zed[0] - (zed == "z" ? 0 : 1), spec.zed[1] + (zed == "z" ? 0 : 1)), mirrored: false)
        }
        if let scan = frame.scan {
            // A bright column sweeping across and back, glowing to both sides; the eyes stay lit under it.
            let x = -2 + Int((Float(scan) / Float(Self.scanSteps) * Float(spec.columns + 3)).rounded())
            for r in 0..<rows { for (k, v) in [Float(1), 0.45, 0.18].enumerated() { set(x - k, r, v); set(x + k, r, v) } }
        }
        return dots
    }

    /// The display as an image: round-cornered dots with dark gaps (wider between rows, so it reads as scanlines),
    /// the unlit dots faintly visible, and a soft glow from the lit ones bleeding into the gaps.
    static func draw(_ matrix: [Float], color: [Float], spec: Spec) -> CGImage {
        // The texture's grid: the matrix inside a margin of plain glass, so the whole visor maps into it.
        let cols = spec.texture.columns, rows = spec.texture.rows, cell = spec.display.cellPixels
        let ox = spec.texture.matrixOrigin[0], oy = spec.texture.matrixOrigin[1]
        var dots = [Float](repeating: -1, count: cols * rows)   // -1: no LED there
        for r in 0..<spec.rows { for c in 0..<spec.columns { dots[(r + oy) * cols + c + ox] = matrix[r * spec.columns + c] } }
        let width = cols * cell, height = rows * cell
        let dw = spec.display.dotSize[0], dh = spec.display.dotSize[1]
        let x0 = (cell - dw) / 2, y0 = (cell - dh) / 2
        // The glow: the lit dots blurred over a dot or so (two weighted 3×3 passes on the grid).
        var glow = dots.map { max(0, $0) }
        for _ in 0..<2 {
            var next = glow
            for r in 0..<rows { for c in 0..<cols {
                var sum: Float = 0, n: Float = 0
                for dr in -1...1 { for dc in -1...1 {
                    let rr = r + dr, cc = c + dc
                    if rr >= 0, rr < rows, cc >= 0, cc < cols { let k: Float = dr == 0 && dc == 0 ? 2 : 1; sum += glow[rr * cols + cc] * k; n += k }
                } }
                next[r * cols + c] = sum / n
            } }
            glow = next
        }
        let off = spec.display.offLevel, glowStrength = spec.display.glow, scan = spec.display.scanline
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let tint = SIMD3<Float>(color[0], color[1], color[2]), dim = SIMD3<Float>(0.55, 0.75, 0.80), glass = SIMD3<Float>(0.012, 0.016, 0.02)
        for y in 0..<height {
            let r = y / cell, ly = y % cell
            // Glow sampled between cell centres, so it spreads smoothly instead of in blocks.
            let gy = (Float(y) + 0.5) / Float(cell) - 0.5, r0 = max(0, min(rows - 1, Int(gy.rounded(.down)))), r1 = min(rows - 1, r0 + 1), fy = max(0, min(1, gy - Float(r0)))
            for x in 0..<width {
                let c = x / cell, lx = x % cell
                let gx = (Float(x) + 0.5) / Float(cell) - 0.5, c0 = max(0, min(cols - 1, Int(gx.rounded(.down)))), c1 = min(cols - 1, c0 + 1), fx = max(0, min(1, gx - Float(c0)))
                let g = (glow[r0 * cols + c0] * (1 - fx) + glow[r0 * cols + c1] * fx) * (1 - fy) + (glow[r1 * cols + c0] * (1 - fx) + glow[r1 * cols + c1] * fx) * fy
                var value = glass + tint * (g * glowStrength)
                let lit = dots[r * cols + c]
                if lit >= 0, lx >= x0, lx < x0 + dw, ly >= y0, ly < y0 + dh {
                    let corner = (lx == x0 || lx == x0 + dw - 1) && (ly == y0 || ly == y0 + dh - 1)
                    var dot = lit > 0 ? tint * lit : dim * off
                    if ly == y0 + dh - 1 { dot *= scan }       // each dot's last line is a scanline
                    if corner { dot *= 0.45 }
                    value += dot
                }
                let i = (y * width + x) * 4
                bytes[i] = UInt8(min(255, value.x * 255)); bytes[i + 1] = UInt8(min(255, value.y * 255)); bytes[i + 2] = UInt8(min(255, value.z * 255)); bytes[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}
