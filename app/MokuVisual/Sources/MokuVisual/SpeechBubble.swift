import AppKit
import QuartzCore
import MokuKit

/// How a companion talks over its head (Charles, 2026-10-04: "symbolic of whether its moku or tetsu ... a dot matrix
/// led style when he talks and thinks"): Moku in a soft paper bubble with stitched edges, Tetsu on a little LED display
/// in a white shell like its visor, its words typing on in cyan dots (amber when it's cross).
enum SpeechStyle: Equatable {
    case paper, led
    init(_ companion: Companion) { self = companion == .tetsu ? .led : .paper }
}

/// What a bubble shows: a line, or that one is being written (while Luna writes a celebration).
enum SpeechContent: Equatable {
    case line(SpeechLine)
    case thinking
}

/// A view drawn in layers, captured by checks with this instead of `cacheDisplay` (which misses layer contents).
@MainActor protocol LayerSnapshot: NSView {
    func snapshot(scale: CGFloat) -> CGImage?
}

/// The colours, light and dark.
enum SpeechInk {
    static let cyan = NSColor(srgbRed: 0.30, green: 0.92, blue: 1.0, alpha: 1)    // Tetsu's face, content (pixel_face.json)
    static let amber = NSColor(srgbRed: 1.0, green: 0.58, blue: 0.10, alpha: 1)   // and cross
    static func led(_ tone: SpeechLine.Tone) -> NSColor { tone == .calling || tone == .firm ? amber : cyan }
    static func paper(_ tone: SpeechLine.Tone, dark: Bool) -> NSColor {
        let (r, g, b): (CGFloat, CGFloat, CGFloat) = switch tone {
        case .gentle: (0.52, 0.59, 0.48)
        case .warm: (0.67, 0.48, 0.35)
        case .firm: (0.39, 0.45, 0.39)
        case .calling: (0.62, 0.40, 0.34)
        case .cheerful: (0.45, 0.59, 0.29)
        }
        // On dark paper the accents lift, so they keep their contrast.
        let accent = dark ? NSColor(srgbRed: r + (1 - r) * 0.35, green: g + (1 - g) * 0.35, blue: b + (1 - b) * 0.35, alpha: 1) : NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        // Increase Contrast: the small name above a line is the ink's own shade more than the tone (3.1:1 to 3.6:1 on the paper
        // for three of the five tones becomes at least 5.6:1).
        return ContrastPreference.increased ? accent.blended(withFraction: 0.55, of: paperText(dark: dark)) ?? accent : accent
    }
    /// How strong the stitched edge and the label's outline are drawn (Increase Contrast makes them plain).
    static func stitchAlpha(dark: Bool) -> CGFloat { ContrastPreference.increased ? 0.8 : dark ? 0.34 : 0.36 }
    static func paperFill(dark: Bool) -> NSColor { dark ? NSColor(srgbRed: 0.205, green: 0.192, blue: 0.172, alpha: 1) : NSColor(srgbRed: 1, green: 0.987, blue: 0.956, alpha: 1) }
    static func paperText(dark: Bool) -> NSColor { dark ? NSColor(srgbRed: 0.94, green: 0.91, blue: 0.85, alpha: 1) : NSColor(srgbRed: 0.24, green: 0.27, blue: 0.23, alpha: 1) }
    static let sage = NSColor(srgbRed: 0.54, green: 0.62, blue: 0.47, alpha: 1)
}

/// The speech bubble over a companion's head. Every picture in it is drawn once when it's made (the paper, the LED
/// display, the lit dots, the cursor); typing on, the blinking cursor, the thinking dots and the entrance are Core
/// Animation, so the window server plays them with no work per frame here. With Reduce Motion it just fades in:
/// no type-on, no pop, a steady cursor, and the thinking dots only glow.
@MainActor final class SpeechBubbleView: NSView, LayerSnapshot {
    let style: SpeechStyle
    let content: SpeechContent
    let dark: Bool
    let reduced: Bool
    /// The drawn bubble in the view; the margin around it (`StageGeometry.speechInset`) is room for the shadow.
    let card: CGRect
    /// How long typing on takes (0 when the line just appears).
    private(set) var typingSeconds: Double = 0
    /// "Where was I?" with somewhere to go: the bubble shows "Take me there", and a click anywhere on it calls `onActivate`.
    /// "What's new" is a link the same way, with an ✕ (WhatsNewBubble.swift).
    let offersAction: Bool
    /// Set by the stage when `offersAction`: the click.
    var onActivate: (() -> Void)?
    /// "What's new" after an update: the version its bubble links to.
    let whatsNew: String?
    /// Set by the stage on a "What's new" bubble: its ✕.
    var onClose: (() -> Void)?
    private(set) var hovered = false
    private(set) var closeHovered = false
    /// The pointer is over the card (the hand cursor is pushed). A bubble you can click stays while it is (StageMovement).
    private(set) var pointerInside = false
    private var pressed = false
    private var pressedClose = false
    /// The longest a thinking bubble stays up: the engine says its line within `voiceWaitSec` (5 s) and replaces it.
    static let thinkingTimeout: TimeInterval = 9

    private let cardLayer = CALayer()
    private var parts: Parts
    private let scale: CGFloat

    /// Everything drawn, in the card's coordinates (points, origin bottom-left).
    private struct Parts {
        var chrome: CGImage?
        var ink: CGImage?
        var inkFrame = CGRect.zero
        /// Per line, bottom to top in the ink's coordinates: its band, and its right edge after each glyph typed.
        var lines: [(band: CGRect, edges: [CGFloat], rightToLeft: Bool)] = []
        var cursor: CGImage?
        var cursorFrames: [CGRect] = []
        /// The thinking dots: one picture, at each place.
        var dot: CGImage?
        var dotFrames: [CGRect] = []
        /// "What's new"'s underline, and where it sits.
        var action: (frame: CGRect, button: BubbleButton)?
        /// "What's new"'s ✕, and where it sits.
        var close: (frame: CGRect, button: BubbleButton)?
    }

    init(content: SpeechContent, style: SpeechStyle, name: String, dark: Bool, scale: CGFloat, reduced: Bool) {
        self.content = content; self.style = style; self.dark = dark; self.reduced = reduced; self.scale = scale
        let line: SpeechLine? = if case .line(let line) = content { line } else { nil }
        whatsNew = line?.whatsNew
        let action = line?.whatsNew != nil
        offersAction = action
        let inset = StageGeometry.speechInset
        let built: (size: CGSize, parts: Parts) = switch (style, content) {
        case (.paper, .line(let line)): Self.paperLine(line, name: name, dark: dark, scale: scale, action: action)
        case (.paper, .thinking): Self.paperThinking(dark: dark, scale: scale)
        case (.led, .line(let line)): Self.ledLine(line, name: name, dark: dark, scale: scale, action: action)
        case (.led, .thinking): Self.ledThinking(name: name, dark: dark, scale: scale)
        }
        card = CGRect(x: inset, y: inset, width: built.size.width, height: built.size.height)
        parts = built.parts
        super.init(frame: CGRect(x: 0, y: 0, width: built.size.width + 2 * inset, height: built.size.height + 2 * inset))
        layer = CALayer(); wantsLayer = true   // layer-hosting: the layers below are ours
        layer?.masksToBounds = false
        build()
        setAccessibilityElement(true); setAccessibilityRole(action ? .button : .staticText)
        switch content {
        case .line(let line): setAccessibilityLabel("\(name) says: \(line.text)")
        case .thinking: setAccessibilityLabel("\(name) is thinking")
        }
        if whatsNew != nil {
            setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Close") { [weak self] in
                guard let onClose = self?.onClose else { return false }
                onClose(); return true
            }])
        }
    }
    required init?(coder: NSCoder) { nil }

    // MARK: Layers

    private func build() {
        guard let root = layer else { return }
        cardLayer.frame = card
        // Grows from the bottom edge, nearest the companion's head.
        cardLayer.anchorPoint = CGPoint(x: 0.5, y: 0); cardLayer.position = CGPoint(x: card.midX, y: card.minY)
        root.addSublayer(cardLayer)
        let chrome = CALayer(); chrome.frame = CGRect(x: -StageGeometry.speechInset, y: -StageGeometry.speechInset,
                                                     width: bounds.width, height: bounds.height)
        configure(chrome, parts.chrome); cardLayer.addSublayer(chrome)
        if let ink = parts.ink {
            let inkLayer = CALayer(); inkLayer.frame = parts.inkFrame; configure(inkLayer, ink)
            cardLayer.addSublayer(inkLayer)
            inkLayer.name = "ink"
        }
        if let cursor = parts.cursor, let last = parts.cursorFrames.last {
            let cursorLayer = CALayer(); cursorLayer.frame = last; configure(cursorLayer, cursor); cursorLayer.name = "cursor"
            cardLayer.addSublayer(cursorLayer)
        }
        for (index, frame) in parts.dotFrames.enumerated() {
            let dot = CALayer(); dot.frame = frame; configure(dot, parts.dot); dot.name = "dot-\(index)"
            cardLayer.addSublayer(dot)
        }
        if let action = parts.action {
            let button = CALayer(); button.frame = action.frame; configure(button, action.button.resting); button.name = "action"
            cardLayer.addSublayer(button)
        }
        if let close = parts.close {
            let button = CALayer(); button.frame = close.frame; configure(button, close.button.resting); button.name = "close"
            cardLayer.addSublayer(button)
        }
    }
    private func configure(_ layer: CALayer, _ image: CGImage?) {
        layer.contents = image; layer.contentsScale = scale; layer.contentsGravity = .resize
        layer.magnificationFilter = style == .led ? .nearest : .linear
        layer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
    }
    private func sublayer(_ name: String) -> CALayer? { cardLayer.sublayers?.first { $0.name == name } }

    /// Plays the entrance (and for a line on the LED, typing on). Call once the window is up.
    func play(entrance: Bool = true) {
        let now = cardLayer.convertTime(CACurrentMediaTime(), from: nil)
        if entrance && !reduced { playEntrance(at: now) }
        switch (style, content) {
        case (.led, .line(let line)):
            let start = now + (entrance && !reduced ? 0.12 : 0.05)
            if !reduced { typeOn(from: start) }
            blinkCursor(from: start + typingSeconds, ask: line.tone == .calling)
            // The key lights once the words are out.
            if !reduced, let key = sublayer("action") {
                let light = CABasicAnimation(keyPath: "opacity"); light.fromValue = 0; light.toValue = 1
                light.duration = 0.2; light.beginTime = start + typingSeconds; light.fillMode = .backwards
                key.add(light, forKey: "light")
            }
        case (.led, .thinking): spin(from: now)
        case (.paper, .thinking): breathe(from: now)
        case (.paper, .line): break
        }
    }

    private func playEntrance(at now: CFTimeInterval) {
        switch style {
        case .paper:
            // A soft pop up from the head, settling with a little give, like a plush.
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.86; pop.toValue = 1; pop.mass = 1; pop.stiffness = 260; pop.damping = 17; pop.initialVelocity = 0
            pop.duration = pop.settlingDuration; pop.beginTime = now; pop.fillMode = .backwards
            cardLayer.add(pop, forKey: "pop")
        case .led:
            // The display switching on: a bright line that opens to the full panel, like an old tube.
            let open = CABasicAnimation(keyPath: "transform.scale.y")
            open.fromValue = 0.06; open.toValue = 1; open.duration = 0.16; open.beginTime = now; open.fillMode = .backwards
            open.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            cardLayer.add(open, forKey: "open")
        }
    }

    /// The line types on glyph by glyph: each line's mask widens a glyph at a time (discrete steps), and the cursor
    /// jumps along with it, never blinking while it types.
    private func typeOn(from start: CFTimeInterval) {
        guard let ink = sublayer("ink") else { return }
        let steps = parts.lines.reduce(0) { $0 + $1.edges.count }
        guard steps > 0 else { return }
        let interval = min(0.034, 1.6 / Double(steps))
        typingSeconds = interval * Double(steps)
        let mask = CALayer(); mask.frame = ink.bounds
        var elapsed = 0.0
        for line in parts.lines {
            let band = CALayer(); band.backgroundColor = NSColor.black.cgColor
            band.anchorPoint = CGPoint(x: line.rightToLeft ? 1 : 0, y: 0)
            band.bounds = CGRect(x: 0, y: 0, width: ink.bounds.width, height: line.band.height)
            band.position = CGPoint(x: line.rightToLeft ? ink.bounds.width : 0, y: line.band.minY)
            let widths = [0] + line.edges.map { line.rightToLeft ? ink.bounds.width - $0 : $0 } + [ink.bounds.width]
            let grow = CAKeyframeAnimation(keyPath: "bounds.size.width")
            grow.values = widths; grow.calculationMode = .discrete
            grow.keyTimes = (0...widths.count).map { NSNumber(value: Double($0) / Double(widths.count)) }
            grow.duration = interval * Double(widths.count); grow.beginTime = start + elapsed; grow.fillMode = .backwards
            band.add(grow, forKey: "type")
            mask.addSublayer(band)
            elapsed += interval * Double(line.edges.count)
        }
        ink.mask = mask
        if let cursor = sublayer("cursor"), parts.cursorFrames.count > 1 {
            let move = CAKeyframeAnimation(keyPath: "position")
            let points = parts.cursorFrames.map { NSValue(point: CGPoint(x: $0.midX, y: $0.midY)) }
            move.values = points; move.calculationMode = .discrete
            move.keyTimes = (0...points.count).map { NSNumber(value: Double($0) / Double(points.count)) }
            move.duration = interval * Double(points.count); move.beginTime = start; move.fillMode = .backwards
            cursor.add(move, forKey: "type")
        }
    }

    /// Done typing, the cursor blinks (a block; the ask's is an underscore after its ">" prompt) for a while, then holds.
    private func blinkCursor(from start: CFTimeInterval, ask: Bool) {
        guard !reduced, let cursor = sublayer("cursor") else { return }
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 0]; blink.keyTimes = [0, 0.5, 1]; blink.calculationMode = .discrete
        blink.duration = 1.06; blink.beginTime = start; blink.repeatDuration = ask ? 120 : 30
        cursor.add(blink, forKey: "blink")
    }

    /// Tetsu thinks like its face does: a ring of dots with a bright head and a fading tail, a step at a time.
    private func spin(from now: CFTimeInterval) {
        let count = parts.dotFrames.count
        for index in 0..<count {
            guard let dot = sublayer("dot-\(index)") else { continue }
            if reduced {
                let glow = CABasicAnimation(keyPath: "opacity"); glow.fromValue = 0.35; glow.toValue = 1
                glow.duration = 1.2; glow.autoreverses = true; glow.repeatCount = .infinity; glow.beginTime = now
                glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                dot.add(glow, forKey: "glow"); continue
            }
            let step = CAKeyframeAnimation(keyPath: "opacity")
            step.values = (0..<count).map { tick in
                let behind = (tick - index + count) % count
                return behind == 0 ? 1 : behind < 4 ? 0.85 - 0.6 * Double(behind) / 4 : 0.16
            }
            step.keyTimes = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
            step.calculationMode = .discrete; step.duration = 0.8; step.repeatCount = .infinity; step.beginTime = now
            dot.add(step, forKey: "spin")
        }
    }

    /// Moku thinks softly: three dots that breathe in turn.
    private func breathe(from now: CFTimeInterval) {
        for index in 0..<parts.dotFrames.count {
            guard let dot = sublayer("dot-\(index)") else { continue }
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.32; fade.toValue = 1
            var animations: [CAAnimation] = [fade]
            if !reduced { let swell = CABasicAnimation(keyPath: "transform.scale"); swell.fromValue = 0.72; swell.toValue = 1; animations.append(swell) }
            let group = CAAnimationGroup(); group.animations = animations
            group.duration = 0.62; group.autoreverses = true; group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            group.beginTime = now + 0.2 * Double(index); group.fillMode = .backwards
            dot.add(group, forKey: "breathe")
        }
    }

    // MARK: Take me there

    /// The whole card takes the click when there's somewhere to go; otherwise clicks pass through, as they always have.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onActivate != nil else { return nil }
        return card.contains(convert(point, from: superview)) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressed = card.contains(point); pressedClose = onClose(at: point)
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false; pressedClose = false }
        let point = convert(event.locationInWindow, from: nil)
        guard pressed, card.contains(point) else { return }
        // The ✕ closes (pressed and let go on it); the rest of the bubble is the link.
        if pressedClose { if onClose(at: point) { onClose?() } } else { onActivate?() }
    }
    /// Whether `point` (in the view) is on the ✕, give or take a little.
    private func onClose(at point: CGPoint) -> Bool {
        guard onClose != nil, let close = parts.close else { return false }
        return close.frame.offsetBy(dx: card.minX, dy: card.minY).insetBy(dx: -WhatsNewLook.closeReach, dy: -WhatsNewLook.closeReach).contains(point)
    }
    override func accessibilityPerformPress() -> Bool {
        guard let onActivate else { return false }
        onActivate(); return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard offersAction else { return }
        addTrackingArea(NSTrackingArea(rect: card, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
        if let close = parts.close {
            let reach = close.frame.offsetBy(dx: card.minX, dy: card.minY).insetBy(dx: -WhatsNewLook.closeReach, dy: -WhatsNewLook.closeReach)
            addTrackingArea(NSTrackingArea(rect: reach, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: ["part": "close"]))
        }
    }
    override func mouseEntered(with event: NSEvent) {
        if Self.isClose(event) { lightClose(true); light(false) } else { setHovered(true) }
    }
    override func mouseExited(with event: NSEvent) {
        if Self.isClose(event) { lightClose(false); if pointerInside { light(true) } } else { setHovered(false); lightClose(false) }
    }
    private static func isClose(_ event: NSEvent) -> Bool { event.trackingArea?.userInfo?["part"] as? String == "close" }

    /// The bubble is going (clicked, dismissed, or replaced): the pointer is given back. Its window goes from under the
    /// pointer, so the pointer never "leaves" it, and the pointing hand stayed pushed after the bubble had gone.
    func releasePointer() {
        setHovered(false)
        lightClose(false)
    }

    /// The button lights under the pointer, and the pointer becomes a hand.
    func setHovered(_ on: Bool) {
        guard offersAction, on != pointerInside else { return }
        pointerInside = on
        light(on)
        if on { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    }

    /// The ✕ lit or resting, with the same short crossfade.
    func lightClose(_ on: Bool) {
        guard let button = sublayer("close"), let close = parts.close, on != closeHovered else { return }
        closeHovered = on
        let fade = CATransition(); fade.type = .fade; fade.duration = 0.12
        button.add(fade, forKey: "hover")
        button.contents = on ? close.button.hovered : close.button.resting
    }

    /// The button lit or resting, with a short crossfade (checks call it to see the lit one).
    func light(_ on: Bool) {
        guard let button = sublayer("action"), let action = parts.action else { return }
        hovered = on
        let fade = CATransition(); fade.type = .fade; fade.duration = 0.12
        button.add(fade, forKey: "hover")
        button.contents = on ? action.button.hovered : action.button.resting
    }

    // MARK: Snapshot (checks)

    /// The bubble as drawn, settled; `typed` glyphs only (with the cursor after them) shows typing part way.
    func snapshot(scale: CGFloat) -> CGImage? { snapshot(scale: scale, typed: nil) }
    func snapshot(scale: CGFloat, typed: Int?) -> CGImage? {
        let width = Int((bounds.width * scale).rounded()), height = Int((bounds.height * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale); context.interpolationQuality = style == .led ? .none : .high
        if let chrome = parts.chrome { context.draw(chrome, in: bounds) }
        context.translateBy(x: card.minX, y: card.minY)
        if let ink = parts.ink, typed != 0 {
            context.saveGState()
            if let typed {
                context.translateBy(x: parts.inkFrame.minX, y: parts.inkFrame.minY)
                var left = typed
                for line in parts.lines {
                    let shown = min(left, line.edges.count); left -= shown
                    guard shown > 0 else { continue }
                    let edge = line.edges[shown - 1]
                    context.addRect(line.rightToLeft ? CGRect(x: edge, y: line.band.minY, width: parts.inkFrame.width - edge, height: line.band.height)
                                                     : CGRect(x: 0, y: line.band.minY, width: edge, height: line.band.height))
                }
                context.translateBy(x: -parts.inkFrame.minX, y: -parts.inkFrame.minY)
                if typed < parts.lines.reduce(0, { $0 + $1.edges.count }) { context.clip() } else { context.beginPath() }
            }
            context.draw(ink, in: parts.inkFrame)
            context.restoreGState()
        }
        if let cursor = parts.cursor, !parts.cursorFrames.isEmpty {
            let frame = parts.cursorFrames[min(typed ?? parts.cursorFrames.count - 1, parts.cursorFrames.count - 1)]
            context.draw(cursor, in: frame)
        }
        // Tetsu's key (or link) lights once the words are out, as it does live.
        let typedOut = typed.map { $0 >= parts.lines.reduce(0) { $0 + $1.edges.count } } ?? true
        if let action = parts.action, typedOut || style != .led, let image = hovered ? action.button.hovered : action.button.resting {
            context.draw(image, in: action.frame)
        }
        if let close = parts.close, let image = closeHovered ? close.button.hovered : close.button.resting {
            context.draw(image, in: close.frame)
        }
        if let dot = parts.dot {
            for (index, frame) in parts.dotFrames.enumerated() {
                context.saveGState()
                // The spinner's head at the top with its tail behind; Moku's three dots at rest.
                context.setAlpha(style == .led ? (index == 0 ? 1 : index >= parts.dotFrames.count - 3 ? 0.85 - 0.2 * CGFloat(parts.dotFrames.count - index) : 0.16) : 0.35 + 0.3 * CGFloat(index))
                context.draw(dot, in: frame)
                context.restoreGState()
            }
        }
        return context.makeImage()
    }

    // MARK: Moku's paper

    private nonisolated static let paperPadding: CGFloat = 17, paperRadius: CGFloat = 22

    private static func paperLine(_ line: SpeechLine, name: String, dark: Bool, scale: CGFloat, action: Bool) -> (CGSize, Parts) {
        let accent = SpeechInk.paper(line.tone, dark: dark)
        let header = NSAttributedString(string: name.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold).rounded, .kern: 2, .foregroundColor: accent])
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .natural; paragraph.baseWritingDirection = .natural
        paragraph.lineSpacing = 1.5; paragraph.lineBreakMode = .byWordWrapping
        let size: CGFloat = line.tone == .calling ? 20 : 15.5
        let text = line.text.replacingOccurrences(of: "'", with: "’")
        let body = NSMutableAttributedString(string: text, attributes: [
            .font: paperFont(size: size), .foregroundColor: SpeechInk.paperText(dark: dark), .paragraphStyle: paragraph])
        // "What's new": its link, bolder and inked.
        let news = line.whatsNew != nil
        let emphasis = news ? WhatsNewLook.link : nil
        var link: NSRange?
        if let bold = emphasis?.replacingOccurrences(of: "'", with: "’"), let range = text.range(of: bold) {
            body.addAttribute(.font, value: paperFont(size: size, weight: .semibold), range: NSRange(range, in: text))
            if news {
                link = NSRange(range, in: text)
                body.addAttribute(.foregroundColor, value: WhatsNewLook.paperLinkInk(accent: accent, dark: dark), range: NSRange(range, in: text))
            }
        }
        // At most 260 points tall with its margin, like the panel always was; longer lines end in "…".
        let maxText: CGFloat = 222, maxBody: CGFloat = 180
        let measured = body.boundingRect(with: CGSize(width: maxText, height: 4000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let bodySize = CGSize(width: min(maxText, ceil(measured.width)), height: min(maxBody, ceil(measured.height)))
        let headerSize = header.size()
        let close = news ? WhatsNewLook.paperClose(accent: accent, dark: dark, scale: scale) : nil
        let width = max(bodySize.width, headerSize.width + (close.map { $0.size.width + 6 } ?? 0)) + 2 * paperPadding
        let height = paperPadding + ceil(headerSize.height) + 6 + bodySize.height + paperPadding - 1
        let card = CGSize(width: max(width, 92), height: height)
        let rightToLeft = DotFont.readsRightToLeft(line.text)
        let chrome = drawn(card: card, scale: scale) { rect in
            paper(rect, accent: accent, dark: dark)
            let textLeft = rightToLeft ? rect.maxX - paperPadding - bodySize.width : rect.minX + paperPadding
            let headerX = rightToLeft ? rect.maxX - paperPadding - headerSize.width : rect.minX + paperPadding
            header.draw(at: CGPoint(x: headerX, y: rect.maxY - paperPadding - headerSize.height + 2))
            body.draw(with: CGRect(x: textLeft, y: rect.minY + paperPadding - 2, width: bodySize.width + 1, height: bodySize.height),
                      options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        }
        var parts = Parts(chrome: chrome)
        if let close {
            // In the header's row, at the far end from the name, inside the stitching.
            let inset = StageGeometry.speechInset
            let middle = card.height - paperPadding - headerSize.height / 2 + 2
            let x = rightToLeft ? paperPadding - 4 : card.width - paperPadding - close.size.width + 4
            parts.close = (CGRect(x: x, y: (middle - close.size.height / 2).rounded(), width: close.size.width, height: close.size.height), close)
            if let link {
                let textLeft = rightToLeft ? card.width - paperPadding - bodySize.width : paperPadding
                let textRect = CGRect(x: inset + textLeft, y: inset + paperPadding - 2, width: bodySize.width + 1, height: bodySize.height)
                let whole = CGSize(width: card.width + 2 * inset, height: card.height + 2 * inset)
                let underline = WhatsNewLook.paperUnderline(body, link: link, in: textRect, size: whole, ink: WhatsNewLook.paperLinkInk(accent: accent, dark: dark), scale: scale)
                parts.action = (CGRect(x: -inset, y: -inset, width: whole.width, height: whole.height), underline)
            }
        }
        return (card, parts)
    }

    private static func paperThinking(dark: Bool, scale: CGFloat) -> (CGSize, Parts) {
        let card = CGSize(width: 70, height: 38)
        let chrome = drawn(card: card, scale: scale) { rect in paper(rect, accent: SpeechInk.sage, dark: dark, radius: 19) }
        let diameter: CGFloat = 8, gap: CGFloat = 6.5
        let dot = image(size: CGSize(width: diameter, height: diameter), scale: scale) { rect in
            NSColor(srgbRed: 0.43, green: 0.53, blue: 0.37, alpha: 1).blended(withFraction: dark ? 0.35 : 0, of: .white)?.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
        let left = (card.width - 3 * diameter - 2 * gap) / 2
        let frames = (0..<3).map { CGRect(x: left + CGFloat($0) * (diameter + gap), y: (card.height - diameter) / 2, width: diameter, height: diameter) }
        return (card, Parts(chrome: chrome, dot: dot, dotFrames: frames))
    }

    /// Moku's body text: New York, the serif the website's headings echo, soft and easy to read at a glance.
    static func paperFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    /// The paper: warm, with a soft shadow and a stitched edge, like a felt patch sewn on a plush.
    private static func paper(_ rect: CGRect, accent: NSColor, dark: Bool, radius: CGFloat = paperRadius) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.42 : 0.15); shadow.shadowBlurRadius = 9
        shadow.shadowOffset = NSSize(width: 0, height: -3); shadow.set()
        SpeechInk.paperFill(dark: dark).setFill(); shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        // A soft light along the top, the way light sits on a cushion.
        NSGraphicsContext.saveGraphicsState(); shape.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(dark ? 0.05 : 0.55), NSColor.white.withAlphaComponent(0)])?
            .draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        accent.withAlphaComponent(dark ? 0.30 : 0.24).setStroke(); shape.lineWidth = 1; shape.stroke()
        let stitch = NSBezierPath(roundedRect: rect.insetBy(dx: 5, dy: 5), xRadius: radius - 5, yRadius: radius - 5)
        stitch.lineWidth = 1.1; stitch.lineCapStyle = .round; stitch.setLineDash([2.4, 3.4], count: 2, phase: 0)
        accent.withAlphaComponent(SpeechInk.stitchAlpha(dark: dark)).setStroke(); stitch.stroke()
    }

    // MARK: Tetsu's LED display

    /// Dots are `pitch` points apart; text wraps at `columns` dots.
    private static let pitch: CGFloat = 2, columns = 124
    /// The shell around the glass, and the glass's padding around the text.
    private static let shell: CGFloat = 5, glassPadding: CGFloat = 12, headerTop: CGFloat = 8, headerGap: CGFloat = 7, glassBottom: CGFloat = 10

    private static func ledLine(_ line: SpeechLine, name: String, dark: Bool, scale: CGFloat, action: Bool) -> (CGSize, Parts) {
        let color = SpeechInk.led(line.tone), ask = line.tone == .calling
        // "What's new" is laid out the display's way ("> updated: …"), not as Moku's sentence.
        let news = line.whatsNew != nil
        let shown = news ? WhatsNewLook.ledText : line.text
        guard DotFont.spells(shown) else { return ledTypeset(line, text: shown, name: name, color: color, dark: dark, scale: scale) }
        var text = DotText(shown, width: columns)
        if ask { text.appendPrompt() }
        let cursorWidth = 5, lastLine = text.lineWidths.last ?? 0
        let header = headerDots(name)
        // Wide enough for the text, the cursor after the last line, and the name with its status light (in 1-point dots).
        let textColumns = max(text.width, lastLine + 1 + cursorWidth, (header.width + 10 + 1) / 2)
        let textSize = CGSize(width: CGFloat(textColumns) * pitch, height: CGFloat(text.rows) * pitch)
        let card = CGSize(width: textSize.width + 2 * (shell + glassPadding),
                          height: shell + headerTop + 7 + headerGap + textSize.height + glassBottom + shell)
        let textOrigin = CGPoint(x: shell + glassPadding, y: shell + glassBottom)
        let margin = DotPainter.glowMargin
        var parts = Parts()
        parts.chrome = ledChrome(card: card, dark: dark, scale: scale, color: color, header: header,
                                 grid: (CGRect(origin: textOrigin, size: textSize), textColumns, text.rows), statusLight: !news)
        parts.ink = DotPainter.image(text.dots, columns: textColumns, rows: text.rows, pitch: pitch, color: color, glow: 1, margin: margin, scale: scale)
        parts.inkFrame = CGRect(x: textOrigin.x - margin, y: textOrigin.y - margin, width: textSize.width + 2 * margin, height: textSize.height + 2 * margin)
        if news {
            // The link's dots under its words, and the ✕ where the status light sits, in the header's row.
            parts.action = WhatsNewLook.ledUnderline(text, linkFrom: WhatsNewLook.ledLinkFirstGlyph, columns: textColumns, color: color, scale: scale)
                .map { (parts.inkFrame, $0) }
            let close = WhatsNewLook.ledClose(color: color, scale: scale)
            let middle = CGPoint(x: card.width - shell - glassPadding - 2.5, y: card.height - shell - headerTop - 3.5)
            parts.close = (CGRect(x: middle.x - close.size.width / 2, y: middle.y - close.size.height / 2, width: close.size.width, height: close.size.height), close)
        }
        // Each line's band (its rows, accents to descender; the row two lines share goes to the upper one's
        // descender) and where it ends after each glyph, in the ink's points.
        func top(ofRow row: Int) -> CGFloat { parts.inkFrame.height - margin - CGFloat(row) * pitch }
        parts.lines = (0..<text.lines).map { index in
            let first = index * DotFont.lineRows + (index == 0 ? 0 : 1), last = (index + 1) * DotFont.lineRows
            let upper = top(ofRow: first) + (index == 0 ? margin : 0), lower = top(ofRow: last + 1) - (index == text.lines - 1 ? margin : 0)
            let edges = text.glyphs.filter { $0.line == index }.map { margin + CGFloat($0.x + $0.glyph.width) * pitch }
            return (CGRect(x: 0, y: lower, width: parts.inkFrame.width, height: upper - lower), edges, false)
        }
        // The cursor: a block of dots (the ask's is an underscore), after each glyph in turn.
        let cursorDots = (ask ? [6] : Array(0...6)).flatMap { row in (0..<cursorWidth).map { DotFont.Dot(x: $0, y: row) } }
        parts.cursor = DotPainter.image(cursorDots, columns: cursorWidth, rows: 7, pitch: pitch, color: color, glow: 1, margin: margin, scale: scale)
        let cursorSize = CGSize(width: CGFloat(cursorWidth) * pitch + 2 * margin, height: 7 * pitch + 2 * margin)
        parts.cursorFrames = (0...text.glyphs.count).map { typed in
            let spot = text.cursor(after: typed)
            let x = textOrigin.x + CGFloat(spot.x) * pitch - margin
            let capTop = textOrigin.y + textSize.height - CGFloat(spot.line * DotFont.lineRows - DotFont.topRow) * pitch
            return CGRect(origin: CGPoint(x: x, y: capTop - 7 * pitch - margin), size: cursorSize)
        }
        return (card, parts)
    }

    /// Text the dots can't spell (right to left, CJK and other scripts) is set in type, still lit in the display's
    /// colour with its glow, typing on a line at a time from where the line starts.
    private static func ledTypeset(_ line: SpeechLine, text shown: String, name: String, color: NSColor, dark: Bool,
                                   scale: CGFloat) -> (CGSize, Parts) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .natural; paragraph.baseWritingDirection = .natural; paragraph.lineSpacing = 2
        let text = NSAttributedString(string: shown, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                                                .foregroundColor: color, .paragraphStyle: paragraph])
        let maxWidth = CGFloat(columns) * pitch
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, CGSize(width: maxWidth, height: 220), nil)
        let header = headerDots(name)
        let textSize = CGSize(width: max(ceil(fit.width), CGFloat(header.width + 10)), height: ceil(fit.height))
        let card = CGSize(width: textSize.width + 2 * (shell + glassPadding),
                          height: shell + headerTop + 7 + headerGap + textSize.height + glassBottom + shell)
        let textOrigin = CGPoint(x: shell + glassPadding, y: shell + glassBottom)
        let margin = DotPainter.glowMargin, rightToLeft = DotFont.readsRightToLeft(shown)
        var parts = Parts()
        parts.chrome = ledChrome(card: card, dark: dark, scale: scale, color: color, header: header, grid: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: CGRect(origin: .zero, size: textSize), transform: nil), nil)
        let inkSize = CGSize(width: textSize.width + 2 * margin, height: textSize.height + 2 * margin)
        parts.inkFrame = CGRect(origin: CGPoint(x: textOrigin.x - margin, y: textOrigin.y - margin), size: inkSize)
        parts.ink = image(size: inkSize, scale: scale) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.translateBy(x: margin, y: margin)
            context.setShadow(offset: .zero, blur: 3.2 * scale, color: color.withAlphaComponent(0.9).cgColor)
            CTFrameDraw(frame, context)
        }
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(), &origins)
        parts.lines = zip(lines, origins).map { ctLine, origin in
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))
            let start = origin.x + margin, steps = max(1, CTLineGetStringRange(ctLine).length)
            let band = CGRect(x: 0, y: origin.y + margin - descent - 2, width: inkSize.width, height: ascent + descent + 4)
            let edges = (1...steps).map { step in
                let reach = width * CGFloat(step) / CGFloat(steps)
                return rightToLeft ? start + width - reach : start + reach
            }
            return (band, edges, rightToLeft)
        }
        return (card, parts)
    }

    private static func ledThinking(name: String, dark: Bool, scale: CGFloat) -> (CGSize, Parts) {
        let color = SpeechInk.cyan, header = headerDots(name)
        let ring: CGFloat = 26, radius: CGFloat = 9
        let glassWidth = max(CGFloat(header.width) + 3 + 2 * glassPadding + 10, ring + 2 * glassPadding + 16)
        let card = CGSize(width: glassWidth + 2 * shell, height: shell + headerTop + 7 + headerGap + ring + glassBottom + shell)
        var parts = Parts()
        parts.chrome = ledChrome(card: card, dark: dark, scale: scale, color: color, header: header, grid: nil)
        let margin = DotPainter.glowMargin
        let block = (0..<2).flatMap { y in (0..<2).map { DotFont.Dot(x: $0, y: y) } }
        parts.dot = DotPainter.image(block, columns: 2, rows: 2, pitch: pitch, color: color, glow: 1, margin: margin, scale: scale)
        // Eight 2×2 blocks on a ring, the first at the top, going clockwise (the face's spinner, px_spin), on whole points.
        let centre = CGPoint(x: (card.width / 2).rounded(), y: (shell + glassBottom + ring / 2).rounded())
        parts.dotFrames = (0..<8).map { k in
            let angle = CGFloat(k) / 8 * 2 * .pi
            let x = (centre.x + radius * sin(angle) - pitch).rounded(), y = (centre.y + radius * cos(angle) - pitch).rounded()
            return CGRect(x: x - margin, y: y - margin, width: 2 * pitch + 2 * margin, height: 2 * pitch + 2 * margin)
        }
        return (card, parts)
    }

    /// The name over the text in small dots (a dot a point), like a status line.
    private static func headerDots(_ name: String) -> (dots: [DotFont.Dot], width: Int) {
        var x = 0, dots: [DotFont.Dot] = []
        for character in name.uppercased() {
            guard let glyph = DotFont.glyph(character) else { continue }
            dots += glyph.dots.map { DotFont.Dot(x: x + $0.x, y: $0.y) }
            x += glyph.width + 1
        }
        return (dots, max(0, x - 1))
    }

    /// The display: a soft shadow, a shell like Tetsu's (white plastic, graphite in dark mode), the dark glass with a
    /// faint reflection, the name in small dim dots with a status light, and the unlit dots of the matrix.
    private static func ledChrome(card: CGSize, dark: Bool, scale: CGFloat, color: NSColor, header: (dots: [DotFont.Dot], width: Int),
                                  grid: (rect: CGRect, columns: Int, rows: Int)?, statusLight: Bool = true) -> CGImage? {
        drawn(card: card, scale: scale) { rect in
            let shellShape = NSBezierPath(roundedRect: rect, xRadius: 15, yRadius: 15)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.5 : 0.24); shadow.shadowBlurRadius = 9
            shadow.shadowOffset = NSSize(width: 0, height: -3); shadow.set()
            (dark ? NSColor(srgbRed: 0.19, green: 0.20, blue: 0.22, alpha: 1) : NSColor(srgbRed: 0.90, green: 0.90, blue: 0.88, alpha: 1)).setFill()
            shellShape.fill()
            NSGraphicsContext.restoreGraphicsState()
            let shellColors = dark ? [NSColor(srgbRed: 0.27, green: 0.28, blue: 0.31, alpha: 1), NSColor(srgbRed: 0.17, green: 0.18, blue: 0.20, alpha: 1)]
                                   : [NSColor(srgbRed: 0.97, green: 0.97, blue: 0.955, alpha: 1), NSColor(srgbRed: 0.84, green: 0.84, blue: 0.82, alpha: 1)]
            NSGradient(colors: shellColors)?.draw(in: shellShape, angle: -90)
            NSColor.white.withAlphaComponent(dark ? 0.10 : 0.7).setStroke()
            let rim = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 14.25, yRadius: 14.25); rim.lineWidth = 0.75; rim.stroke()
            NSColor.black.withAlphaComponent(dark ? 0.5 : 0.16).setStroke(); shellShape.lineWidth = 0.75; shellShape.stroke()

            let glass = rect.insetBy(dx: shell, dy: shell)
            let glassShape = NSBezierPath(roundedRect: glass, xRadius: 10, yRadius: 10)
            NSGradient(colors: [NSColor(srgbRed: 0.035, green: 0.05, blue: 0.065, alpha: 1), NSColor(srgbRed: 0.008, green: 0.012, blue: 0.018, alpha: 1)])?
                .draw(in: glassShape, angle: -90)
            NSGraphicsContext.saveGraphicsState(); glassShape.addClip()
            // The glass's reflection: a faint sheen across its top.
            NSGradient(colors: [NSColor.white.withAlphaComponent(0.07), NSColor.white.withAlphaComponent(0)])?
                .draw(in: CGRect(x: glass.minX, y: glass.maxY - glass.height * 0.42, width: glass.width, height: glass.height * 0.42), angle: -90)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.75).setStroke(); glassShape.lineWidth = 1; glassShape.stroke()

            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let dim = color.withAlphaComponent(0.6)
            let headerOrigin = CGPoint(x: glass.minX + glassPadding, y: glass.maxY - headerTop - 7)
            if let name = DotPainter.image(header.dots, columns: max(1, header.width), rows: 7, pitch: 1, color: dim, glow: 0, margin: 0, scale: scale) {
                context.draw(name, in: CGRect(x: headerOrigin.x, y: headerOrigin.y, width: CGFloat(max(1, header.width)), height: 7))
            }
            let light = (0..<3).flatMap { y in (0..<3).map { DotFont.Dot(x: $0, y: y) } }
            let margin = DotPainter.glowMargin
            if statusLight, let status = DotPainter.image(light, columns: 3, rows: 3, pitch: 1, color: color, glow: 0.8, margin: margin, scale: scale) {
                context.draw(status, in: CGRect(x: glass.maxX - glassPadding - 3 - margin, y: headerOrigin.y + 2 - margin, width: 3 + 2 * margin, height: 3 + 2 * margin))
            }
            if let grid {
                let unlit = (0..<grid.rows).flatMap { y in (0..<grid.columns).map { DotFont.Dot(x: $0, y: y, level: 1) } }
                let off = NSColor(srgbRed: 0.55, green: 0.75, blue: 0.80, alpha: 0.075)
                if let image = DotPainter.image(unlit, columns: grid.columns, rows: grid.rows, pitch: pitch, color: off, glow: 0, margin: 0, scale: scale) {
                    context.draw(image, in: CGRect(x: rect.minX + grid.rect.minX, y: rect.minY + grid.rect.minY, width: grid.rect.width, height: grid.rect.height))
                }
            }
        }
    }

    // MARK: Drawing

    /// The whole view (the card and its margin) drawn by `draw`, which gets the card's rect.
    private static func drawn(card: CGSize, scale: CGFloat, _ draw: (CGRect) -> Void) -> CGImage? {
        let inset = StageGeometry.speechInset
        return image(size: CGSize(width: card.width + 2 * inset, height: card.height + 2 * inset), scale: scale) { _ in
            draw(CGRect(x: inset, y: inset, width: card.width, height: card.height))
        }
    }
    /// An image `size` points big at `scale`, drawn with AppKit in points.
    static func image(size: CGSize, scale: CGFloat, _ draw: (CGRect) -> Void) -> CGImage? {
        let width = max(1, Int((size.width * scale).rounded(.up))), height = max(1, Int((size.height * scale).rounded(.up)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(CGRect(origin: .zero, size: size))
        NSGraphicsContext.current = previous
        return context.makeImage()
    }
}

private extension NSFont {
    /// The rounded design of this font (SF Rounded), for the names over Moku's lines.
    var rounded: NSFont { fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: pointSize) } ?? self }
}
