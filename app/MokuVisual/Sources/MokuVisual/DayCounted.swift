import AppKit
import CoreText
import QuartzCore
import MokuKit

// "Today counted" (docs/specs/next-three.md §3): once a day, as work winds down, a small card beside the companion with
// today's house (or rocket) as it stands, the day in three numbers, the top tasks and a line in the companion's voice. A
// click opens Your day; ✕ closes it. When it shows is MokuMind's (DayCountedPlan); this is how it looks and behaves.
// Each companion's own style: Moku's plush paper, like its speech bubbles; Tetsu's display panel, its LED and glass.

// MARK: What it says

/// The card's words and numbers, from Your day's own summary: the same three numbers and the same top tasks.
struct DayCountedContent: Equatable {
    struct Figure: Equatable { let value: String; let label: String }
    struct Task: Equatable { let title: String; let minutes: String }
    let companion: Companion
    let yesterday: Bool
    let farewell: Bool
    /// The day (YYYY-MM-DD) and its focused minutes, which the house is drawn at.
    let date: String
    let minutes: Int
    let header: String
    let figures: [Figure]
    let tasks: [Task]
    let line: String
    let footer: String
    /// "Saturday 4 October".
    let dayName: String

    /// Under an hour of focus is a light day: the words stay kind.
    static let lightDayMinutes = 60
    static let maxTasks = 2

    @MainActor init(summary: TodaySummary, companion: Companion, yesterday: Bool = false, farewell: Bool = false) {
        self.companion = companion; self.yesterday = yesterday; self.farewell = farewell
        date = summary.date; minutes = summary.focusedMinutes
        header = yesterday ? "YESTERDAY COUNTED" : "TODAY COUNTED"
        // As Your day's three numbers have them (TodayView.metric, the popover's DayGlance).
        figures = [Figure(value: minutesText(summary.focusedMinutes), label: "focused"),
                   Figure(value: "\(summary.returns)", label: summary.returns == 1 ? "return" : "returns"),
                   Figure(value: minutesText(summary.longestFocusMinutes), label: "longest")]
        // Your day's first task cards (TodayModel.goalCards): real tasks of 10 minutes or more, longest first.
        tasks = summary.goals.filter { !$0.isOther && $0.minutes >= TodayModel.goalCardMinutes }.prefix(Self.maxTasks)
            .map { Task(title: $0.title, minutes: minutesText($0.minutes)) }
        // Luna's note when the brain still has a true one (it reuses the day note's call, never a new one), else the
        // companion's own line.
        line = summary.note.map { $0.replacingOccurrences(of: "'", with: "’") }
            ?? Self.line(minutes: summary.focusedMinutes, companion: companion, yesterday: yesterday)
        footer = farewell ? "See you tomorrow" : "Your day"
        dayName = TodayModel.date(summary.date)?.formatted(.dateTime.weekday(.wide).day().month(.wide)) ?? summary.date
    }

    /// The companion's own line, from how far the day's house (or rocket) got. No streaks, no scores; a light day is
    /// told it counted too.
    static func line(minutes: Int, companion: Companion, yesterday: Bool) -> String {
        let pieces = DayHouse.built(Double(minutes))
        let stage = Double(minutes) >= DayHouse.goalMinutes ? 5 : (DayHouse.stageStarts.lastIndex { pieces >= $0 } ?? 0)
        let light = minutes < lightDayMinutes
        switch companion {
        case .moku:
            let facts = yesterday
                ? ["We got the ground ready", "We put up the frame", "We put up the walls", "We got the roof on", "It felt like home by the end", "We built the whole house"]
                : ["The ground is ready", "The frame is standing", "The walls are up", "The roof is on", "It feels like home now", "The whole house is built"]
            let close = light ? "Small days count too." : yesterday ? "Let’s build again today." : "Thank you for today."
            return "\(facts[stage]). \(close)"
        case .tetsu:
            let facts = ["Pad poured", "Gantry up", "Hull sealed", "Nose cone on", "Launch-ready", "Rocket complete"]
            let close = light ? "Small days count too." : yesterday ? "Ready for today." : "Good shift."
            return "\(facts[stage])\(yesterday ? " yesterday" : ""). \(close)"
        }
    }

    /// What VoiceOver reads.
    var spoken: String {
        let numbers = figures.map { "\($0.value) \($0.label)" }.joined(separator: ", ")
        let work = tasks.map { "\($0.title), \($0.minutes)" }.joined(separator: ". ")
        let title = header.prefix(1) + header.dropFirst().lowercased()
        return [title + ".", numbers + ".", work.isEmpty ? nil : work + ".", line].compactMap { $0 }.joined(separator: " ")
    }
}

// MARK: The card

/// The card, drawn once when it's made (the paper or the display, the house, every word); its entrance and exit are
/// Core Animation, so nothing is drawn per frame. With Reduce Motion it fades in and out, and Tetsu's cursor holds still.
@MainActor final class DayCountedCardView: NSView, LayerSnapshot {
    let content: DayCountedContent
    let style: SpeechStyle
    let dark: Bool
    let reduced: Bool
    /// The drawn card in the view; the margin around it is room for its shadow.
    let card: CGRect
    static let inset: CGFloat = 12
    /// ✕ and a click anywhere else on the card.
    var onClose: (() -> Void)?
    var onOpen: (() -> Void)?

    private let cardLayer = CALayer()
    private let hoverLayer = CALayer()
    private let cursorLayer = CALayer()
    private let parts: Parts
    private let scale: CGFloat
    private var hovering = false

    /// Everything drawn, in the card's points (origin bottom-left).
    struct Parts {
        var chrome: CGImage?
        /// ✕'s place, and what lights there under the pointer.
        var close = CGRect.zero
        var closeHover: CGImage?
        var closeHoverFrame = CGRect.zero
        /// Tetsu's prompt cursor.
        var cursor: CGImage?
        var cursorFrame = CGRect.zero
    }

    init(content: DayCountedContent, house: CGImage?, style: SpeechStyle, dark: Bool, scale: CGFloat, reduced: Bool) {
        self.content = content; self.style = style; self.dark = dark; self.reduced = reduced; self.scale = scale
        let built = style == .led ? DayCountedDrawing.display(content, house: house, dark: dark, scale: scale)
                                  : DayCountedDrawing.paper(content, house: house, dark: dark, scale: scale)
        parts = built.parts
        card = CGRect(x: Self.inset, y: Self.inset, width: built.size.width, height: built.size.height)
        super.init(frame: CGRect(x: 0, y: 0, width: built.size.width + 2 * Self.inset, height: built.size.height + 2 * Self.inset))
        layer = CALayer(); wantsLayer = true  // layer-hosting: the layers below are ours
        layer?.masksToBounds = false
        cardLayer.frame = bounds
        configure(cardLayer, parts.chrome)
        layer?.addSublayer(cardLayer)
        hoverLayer.frame = parts.closeHoverFrame.offsetBy(dx: Self.inset, dy: Self.inset); configure(hoverLayer, parts.closeHover); hoverLayer.opacity = 0
        hoverLayer.actions?["opacity"] = nil  // ✕ lights softly under the pointer
        cardLayer.addSublayer(hoverLayer)
        if let cursor = parts.cursor {
            cursorLayer.frame = parts.cursorFrame.offsetBy(dx: Self.inset, dy: Self.inset); configure(cursorLayer, cursor)
            cardLayer.addSublayer(cursorLayer)
        }
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel(content.spoken)
        setAccessibilityHelp(content.farewell ? "Closes" : "Opens Your day")
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Close") { [weak self] in self?.onClose?(); return true }])
    }
    required init?(coder: NSCoder) { nil }

    private func configure(_ layer: CALayer, _ image: CGImage?) {
        layer.contents = image; layer.contentsScale = scale; layer.contentsGravity = .resize
        layer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
    }

    // MARK: In and out

    /// Comes in from the corner nearest the companion (`fromRight`: the companion is to its right). Moku's paper pops up
    /// with a little give, like a plush; Tetsu's display switches on like an old tube, a bright line opening to the
    /// panel. Reduce Motion: a fade.
    func playEntrance(fromRight: Bool) {
        let now = cardLayer.convertTime(CACurrentMediaTime(), from: nil)
        let corner = CGPoint(x: fromRight ? card.maxX : card.minX, y: card.minY)
        setAnchor(style == .led ? CGPoint(x: card.midX, y: card.midY) : corner)
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1; fade.beginTime = now; fade.fillMode = .backwards
        fade.duration = reduced ? 0.22 : style == .led ? 0.08 : 0.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        cardLayer.add(fade, forKey: "in")
        if !reduced {
            switch style {
            case .paper:
                let pop = CASpringAnimation(keyPath: "transform.scale")
                pop.fromValue = 0.9; pop.toValue = 1; pop.mass = 1; pop.stiffness = 230; pop.damping = 19; pop.initialVelocity = 0
                pop.duration = pop.settlingDuration; pop.beginTime = now; pop.fillMode = .backwards
                cardLayer.add(pop, forKey: "pop")
            case .led:
                let open = CABasicAnimation(keyPath: "transform.scale.y")
                open.fromValue = 0.03; open.toValue = 1; open.duration = 0.2; open.beginTime = now; open.fillMode = .backwards
                open.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                cardLayer.add(open, forKey: "open")
            }
        }
        if style == .led && !reduced, parts.cursor != nil {
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [1, 0]; blink.keyTimes = [0, 0.5, 1]; blink.calculationMode = .discrete
            blink.duration = 1.06; blink.beginTime = now + 0.3; blink.repeatDuration = 30
            cursorLayer.add(blink, forKey: "blink")
        }
    }

    /// How long the exit takes.
    var exitSeconds: Double { reduced ? 0.2 : style == .led ? 0.22 : 0.2 }

    /// Goes: the paper settles back and fades; the display collapses to a line and then a dot, as a tube switches off.
    func playExit() {
        let now = cardLayer.convertTime(CACurrentMediaTime(), from: nil)
        // From wherever it is: an entrance cut short goes out from there, without a jump.
        let shown = cardLayer.presentation(), opacity = shown?.opacity ?? 1, scale = shown?.transform.m22 ?? 1
        cardLayer.removeAllAnimations()
        cardLayer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = opacity; fade.toValue = 0; fade.beginTime = now
        if reduced || style == .paper {
            fade.duration = exitSeconds; fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            cardLayer.add(fade, forKey: "out")
            if !reduced {
                let shrink = CABasicAnimation(keyPath: "transform.scale"); shrink.fromValue = scale; shrink.toValue = 0.95 * scale
                shrink.duration = exitSeconds; shrink.beginTime = now; shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
                shrink.fillMode = .forwards; shrink.isRemovedOnCompletion = false
                cardLayer.add(shrink, forKey: "shrink")
            }
            return
        }
        setAnchor(CGPoint(x: card.midX, y: card.midY))
        let line = CAKeyframeAnimation(keyPath: "transform.scale.y")
        line.values = [scale, 0.03, 0.03]; line.keyTimes = [0, 0.55, 1]; line.duration = exitSeconds; line.beginTime = now
        line.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.6, 0, 0.9, 0.6), CAMediaTimingFunction(name: .linear)]
        line.fillMode = .forwards; line.isRemovedOnCompletion = false
        let dot = CAKeyframeAnimation(keyPath: "transform.scale.x")
        dot.values = [1, 1, 0.04]; dot.keyTimes = [0, 0.55, 1]; dot.duration = exitSeconds; dot.beginTime = now
        dot.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeIn)]
        dot.fillMode = .forwards; dot.isRemovedOnCompletion = false
        let glow = CAKeyframeAnimation(keyPath: "opacity")
        glow.values = [opacity, opacity, 0]; glow.keyTimes = [0, 0.7, 1]; glow.duration = exitSeconds; glow.beginTime = now
        cardLayer.add(line, forKey: "line"); cardLayer.add(dot, forKey: "dot"); cardLayer.add(glow, forKey: "out")
    }

    /// The card's presentation as it animates (for the demo's smoothness check): opacity and scale, once it's on screen.
    var presented: (opacity: Float, scaleX: CGFloat, scaleY: CGFloat)? {
        cardLayer.presentation().map { ($0.opacity, $0.transform.m11, $0.transform.m22) }
    }

    private func setAnchor(_ point: CGPoint) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cardLayer.anchorPoint = CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)
        cardLayer.position = point
        CATransaction.commit()
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: card, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseEntered(with event: NSEvent) { hovering = true; updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { hovering = false; setCloseLit(false) }
    var isHovered: Bool { hovering }
    private func updateHover(_ event: NSEvent) { setCloseLit(closeArea.contains(convert(event.locationInWindow, from: nil))) }
    private func setCloseLit(_ lit: Bool) {
        CATransaction.begin(); CATransaction.setAnimationDuration(0.12)
        hoverLayer.opacity = lit ? 1 : 0
        CATransaction.commit()
    }
    /// ✕, with room for a finger.
    private var closeArea: CGRect { parts.close.offsetBy(dx: Self.inset, dy: Self.inset).insetBy(dx: -4, dy: -4) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { card.contains(convert(point, from: superview)) ? self : nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeArea.contains(point) { onClose?() } else if card.contains(point) { onOpen?() }
    }
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }

    // MARK: Snapshot

    func snapshot(scale: CGFloat) -> CGImage? {
        let width = Int((bounds.width * scale).rounded()), height = Int((bounds.height * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale); context.interpolationQuality = style == .led ? .none : .high
        if let chrome = parts.chrome { context.draw(chrome, in: bounds) }
        if let cursor = parts.cursor { context.draw(cursor, in: parts.cursorFrame.offsetBy(dx: Self.inset, dy: Self.inset)) }
        return context.makeImage()
    }
}

// MARK: Drawing

@MainActor enum DayCountedDrawing {
    typealias Built = (size: CGSize, parts: DayCountedCardView.Parts)

    // MARK: Moku's paper

    static let paperWidth: CGFloat = 268
    /// The house's window on the card: wide, like a postcard's picture.
    static let pictureAspect: CGFloat = 1.6

    static func paper(_ content: DayCountedContent, house: CGImage?, dark: Bool, scale: CGFloat) -> Built {
        let width = paperWidth, pad: CGFloat = 16, inner = width - 2 * pad
        let ink = SpeechInk.paperText(dark: dark), accent = SpeechInk.paper(.cheerful, dark: dark), quiet = ink.withAlphaComponent(dark ? 0.66 : 0.6)
        let header = NSAttributedString(string: content.header, attributes: [.font: rounded(9, .semibold), .kern: 2, .foregroundColor: accent])
        let wrap = NSMutableParagraphStyle(); wrap.lineSpacing = 2; wrap.lineBreakMode = .byWordWrapping; wrap.alignment = .natural; wrap.baseWritingDirection = .natural
        let lineFont = SpeechBubbleView.paperFont(size: 14.5)
        let line = NSAttributedString(string: content.line, attributes: [.font: lineFont, .foregroundColor: ink, .paragraphStyle: wrap])
        let lineHeight = min(measure(line, width: inner), measure(NSAttributedString(string: "A\nA\nA\nA", attributes: [.font: lineFont, .paragraphStyle: wrap]), width: inner))
        let pictureHeight = (inner / pictureAspect).rounded()
        let taskRow: CGFloat = 18
        // Top down.
        var y: CGFloat = 15
        let headerTop = y; y += 12 + 10
        let pictureTop = y; y += pictureHeight + 12
        let figuresTop = y; y += 37 + 10
        let tasksTop = y; if !content.tasks.isEmpty { y += 9 + taskRow * CGFloat(content.tasks.count) + 7 }
        let lineTop = y; y += lineHeight + 11
        let footerTop = y; y += 13 + 13
        let size = CGSize(width: width, height: y)
        func rect(_ top: CGFloat, _ height: CGFloat, x: CGFloat = pad, width w: CGFloat = inner) -> CGRect { CGRect(x: x, y: size.height - top - height, width: w, height: height) }

        var parts = DayCountedCardView.Parts()
        let closeCentre = CGPoint(x: width - pad - 4, y: size.height - headerTop - 5)
        parts.close = CGRect(x: closeCentre.x - 9, y: closeCentre.y - 9, width: 18, height: 18)
        parts.closeHoverFrame = CGRect(x: closeCentre.x - 11, y: closeCentre.y - 11, width: 22, height: 22)
        parts.closeHover = SpeechBubbleView.image(size: parts.closeHoverFrame.size, scale: scale) { r in
            ink.withAlphaComponent(dark ? 0.16 : 0.09).setFill(); NSBezierPath(ovalIn: r).fill()
        }
        parts.chrome = drawn(size: size, scale: scale) { r in
            sheet(r, accent: accent, dark: dark)
            header.draw(at: CGPoint(x: r.minX + pad, y: r.minY + size.height - headerTop - 11))
            // ✕
            let c = CGPoint(x: r.minX + closeCentre.x, y: r.minY + closeCentre.y), k: CGFloat = 3.6
            let cross = NSBezierPath(); cross.move(to: CGPoint(x: c.x - k, y: c.y - k)); cross.line(to: CGPoint(x: c.x + k, y: c.y + k))
            cross.move(to: CGPoint(x: c.x - k, y: c.y + k)); cross.line(to: CGPoint(x: c.x + k, y: c.y - k))
            cross.lineWidth = 1.3; cross.lineCapStyle = .round; quiet.setStroke(); cross.stroke()
            // The house at dusk, in a window with soft corners.
            let picture = rect(pictureTop, pictureHeight).offsetBy(dx: r.minX, dy: r.minY)
            NSGraphicsContext.saveGraphicsState()
            let frame = NSBezierPath(roundedRect: picture, xRadius: 11, yRadius: 11); frame.addClip()
            if let context = NSGraphicsContext.current?.cgContext { dusk(context, picture); if let house { fill(context, house, picture) } }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(dark ? 0.35 : 0.1).setStroke(); frame.lineWidth = 1; frame.stroke()
            // The three numbers.
            let column = inner / 3
            for (i, figure) in content.figures.enumerated() {
                let x = r.minX + pad + CGFloat(i) * column
                NSAttributedString(string: figure.value, attributes: [.font: SpeechBubbleView.paperFont(size: 19).withWeight(.medium), .foregroundColor: ink])
                    .draw(at: CGPoint(x: x, y: r.minY + size.height - figuresTop - 23))
                NSAttributedString(string: figure.label, attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: quiet])
                    .draw(at: CGPoint(x: x + 1, y: r.minY + size.height - figuresTop - 37))
            }
            // The top tasks, under a stitched rule.
            if !content.tasks.isEmpty {
                let ruleY = r.minY + size.height - tasksTop - 1
                let rule = NSBezierPath(); rule.move(to: CGPoint(x: r.minX + pad, y: ruleY)); rule.line(to: CGPoint(x: r.minX + width - pad, y: ruleY))
                rule.lineWidth = 1; rule.setLineDash([2.4, 3.4], count: 2, phase: 0); rule.lineCapStyle = .round
                accent.withAlphaComponent(0.4).setStroke(); rule.stroke()
                for (i, task) in content.tasks.enumerated() {
                    let row = rect(tasksTop + 9 + CGFloat(i) * taskRow, taskRow).offsetBy(dx: r.minX, dy: r.minY)
                    let minutes = NSAttributedString(string: task.minutes, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: quiet])
                    let minutesWidth = ceil(minutes.size().width)
                    minutes.draw(at: CGPoint(x: row.maxX - minutesWidth, y: row.minY + 2))
                    accent.setFill(); NSBezierPath(ovalIn: CGRect(x: row.minX + 1, y: row.minY + 7, width: 4.5, height: 4.5)).fill()
                    let clip = NSMutableParagraphStyle(); clip.lineBreakMode = .byTruncatingTail; clip.alignment = .natural; clip.baseWritingDirection = .natural
                    NSAttributedString(string: task.title, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: ink, .paragraphStyle: clip])
                        .draw(with: CGRect(x: row.minX + 13, y: row.minY + 1, width: row.width - 13 - minutesWidth - 10, height: 16), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                }
            }
            // The companion's line.
            // (A few points to spare: a last line that only just fits would otherwise be cut with "…".)
            line.draw(with: rect(lineTop, lineHeight + 8).offsetBy(dx: r.minX, dy: r.minY), options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
            // The day, and where a click goes.
            let footerY = r.minY + size.height - footerTop - 12
            NSAttributedString(string: content.dayName, attributes: [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: quiet])
                .draw(at: CGPoint(x: r.minX + pad, y: footerY))
            let go = NSAttributedString(string: content.farewell ? content.footer : content.footer + "  →", attributes: [.font: rounded(10.5, .semibold), .foregroundColor: accent])
            go.draw(at: CGPoint(x: r.minX + width - pad - ceil(go.size().width), y: footerY))
        }
        return (size, parts)
    }

    /// The paper itself: warm, a soft shadow, a stitched edge, like the speech bubbles' felt patch, with the softer
    /// corners of a card.
    private static func sheet(_ rect: CGRect, accent: NSColor, dark: Bool) {
        let radius: CGFloat = 18
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.42 : 0.16); shadow.shadowBlurRadius = 9
        shadow.shadowOffset = NSSize(width: 0, height: -3); shadow.set()
        SpeechInk.paperFill(dark: dark).setFill(); shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState(); shape.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(dark ? 0.05 : 0.55), NSColor.white.withAlphaComponent(0)])?
            .draw(in: CGRect(x: rect.minX, y: rect.maxY - 80, width: rect.width, height: 80), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        accent.withAlphaComponent(dark ? 0.30 : 0.24).setStroke(); shape.lineWidth = 1; shape.stroke()
        let stitch = NSBezierPath(roundedRect: rect.insetBy(dx: 5, dy: 5), xRadius: radius - 5, yRadius: radius - 5)
        stitch.lineWidth = 1.1; stitch.lineCapStyle = .round; stitch.setLineDash([2.4, 3.4], count: 2, phase: 0)
        accent.withAlphaComponent(SpeechInk.stitchAlpha(dark: dark)).setStroke(); stitch.stroke()
    }

    /// The popover's dusk behind the house: indigo to rose to sand, a few stars and a soft moon (HomeSky).
    static func dusk(_ context: CGContext, _ rect: CGRect) {
        let colours = [CGColor(srgbRed: 0.93, green: 0.84, blue: 0.72, alpha: 1), CGColor(srgbRed: 0.80, green: 0.64, blue: 0.58, alpha: 1),
                       CGColor(srgbRed: 0.40, green: 0.36, blue: 0.50, alpha: 1), CGColor(srgbRed: 0.15, green: 0.18, blue: 0.32, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours as CFArray, locations: [0, 0.28, 0.58, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        let k = rect.width / 236  // sized for the card's picture, in points; the stills are drawn in pixels
        context.setFillColor(CGColor(gray: 1, alpha: 0.7))
        for (x, y, r) in [(0.12, 0.9, 0.6), (0.3, 0.82, 0.45), (0.46, 0.93, 0.5), (0.62, 0.78, 0.4), (0.22, 0.72, 0.45), (0.06, 0.66, 0.4)] as [(CGFloat, CGFloat, CGFloat)] {
            context.fillEllipse(in: CGRect(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height, width: r * 2 * k, height: r * 2 * k))
        }
        context.saveGState()
        context.setShadow(offset: .zero, blur: 12 * k, color: CGColor(srgbRed: 1, green: 0.92, blue: 0.72, alpha: 0.75))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.97, blue: 0.88, alpha: 1))
        context.fillEllipse(in: CGRect(x: rect.maxX - 34 * k, y: rect.maxY - 30 * k, width: 17 * k, height: 17 * k))
        context.restoreGState()
    }

    /// The render filling `rect`, cropped to its middle: the house sits a little below the centre of its frame.
    static func fill(_ context: CGContext, _ image: CGImage, _ rect: CGRect) {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let zoom = max(rect.width / w, rect.height / h)
        let drawn = CGSize(width: w * zoom, height: h * zoom)
        // 0.5 is centred; above it keeps more of the sky, so a roof, a chimney or a nose cone isn't cut.
        let x = rect.midX - drawn.width / 2, y = rect.minY - (drawn.height - rect.height) * 0.72
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: CGPoint(x: x, y: y), size: drawn))
    }

    // MARK: Tetsu's display

    static let displayWidth: CGFloat = 284
    private static let shell: CGFloat = 6, glassPad: CGFloat = 12

    static func display(_ content: DayCountedContent, house: CGImage?, dark: Bool, scale: CGFloat) -> Built {
        let width = displayWidth, inner = width - 2 * (shell + glassPad), left = shell + glassPad
        let cyan = SpeechInk.cyan, dim = cyan.withAlphaComponent(0.6), faint = cyan.withAlphaComponent(0.42)
        let header = DotText(content.header, width: 400, maxLines: 1)
        let footer = DotText("> " + content.footer.uppercased(), width: 400, maxLines: 1)
        let day = DotText(TodayModel.date(content.date)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).uppercased() ?? content.date, width: 400, maxLines: 1)
        // The line in dots when it reads well in three lines of them; a longer note (or a script the dots can't spell)
        // is set in type on the glass, still lit.
        let columns = Int(inner / 2)
        let dotLine = DotText(content.line, width: columns, maxLines: 99)
        let inDots = DotFont.spells(content.line) && dotLine.lines <= 3
        let lineFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium)
        let typeLine = lit(content.line, font: lineFont, color: cyan, lines: 4)
        let lineHeight = inDots ? CGFloat(dotLine.rows) * 2 : typeLine.height(inner)
        let pictureHeight = (inner / pictureAspect).rounded()
        let taskRow: CGFloat = 17
        var y: CGFloat = shell + 9
        let headerTop = y; y += CGFloat(header.rows) + 8
        let pictureTop = y; y += pictureHeight + 11
        let figuresTop = y; y += 22 + 4 + 11 + 9
        let tasksTop = y; if !content.tasks.isEmpty { y += taskRow * CGFloat(content.tasks.count) + 7 }
        let lineTop = y; y += lineHeight + 9
        let footerTop = y; y += CGFloat(footer.rows) + 9 + shell
        let size = CGSize(width: width, height: y)
        func top(_ t: CGFloat, _ h: CGFloat) -> CGFloat { size.height - t - h }

        var parts = DayCountedCardView.Parts()
        // ✕ in dots, top right of the glass: dim, lit under the pointer.
        let crossDots = (0..<7).flatMap { i in [DotFont.Dot(x: i, y: i), DotFont.Dot(x: 6 - i, y: i)] }
        let margin = DotPainter.glowMargin
        let cross = CGRect(x: width - left - 7, y: top(headerTop + 2, 7), width: 7, height: 7)
        parts.close = cross.insetBy(dx: -6, dy: -6)
        parts.closeHover = DotPainter.image(crossDots, columns: 7, rows: 7, pitch: 1, color: cyan, glow: 1, margin: margin, scale: scale)
        parts.closeHoverFrame = cross.insetBy(dx: -margin, dy: -margin)
        // The prompt's cursor after "> YOUR DAY".
        let cursorDots = (2...8).flatMap { row in (0..<4).map { DotFont.Dot(x: $0, y: row) } }
        parts.cursor = DotPainter.image(cursorDots, columns: 4, rows: footer.rows, pitch: 1, color: cyan, glow: 0.8, margin: margin, scale: scale)
        parts.cursorFrame = CGRect(x: left + CGFloat(footer.width) + 2 - margin, y: top(footerTop, CGFloat(footer.rows)) - margin,
                                   width: 4 + 2 * margin, height: CGFloat(footer.rows) + 2 * margin)

        parts.chrome = drawn(size: size, scale: scale) { r in
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let glass = panel(r, dark: dark)
            // The unlit matrix across the glass, as on the speech display.
            let off = NSColor(srgbRed: 0.55, green: 0.75, blue: 0.80, alpha: 0.06)
            let gridColumns = Int(inner / 2), gridRows = Int((glass.height - 2 * glassPad) / 2)
            if let grid = DotPainter.image((0..<gridRows).flatMap { y in (0..<gridColumns).map { DotFont.Dot(x: $0, y: y) } }, columns: gridColumns, rows: gridRows, pitch: 2, color: off, glow: 0, margin: 0, scale: scale) {
                context.draw(grid, in: CGRect(x: r.minX + left, y: glass.minY + glassPad, width: CGFloat(gridColumns) * 2, height: CGFloat(gridRows) * 2))
            }
            func dots(_ text: DotText, pitch: CGFloat, color: NSColor, glow: CGFloat, x: CGFloat, top t: CGFloat) {
                guard text.width > 0, let image = DotPainter.image(text.dots, columns: text.width, rows: text.rows, pitch: pitch, color: color, glow: glow, margin: margin, scale: scale) else { return }
                let w = CGFloat(text.width) * pitch, h = CGFloat(text.rows) * pitch
                context.draw(image, in: CGRect(x: r.minX + x - margin, y: r.minY + size.height - t - h - margin, width: w + 2 * margin, height: h + 2 * margin))
            }
            dots(header, pitch: 1, color: dim, glow: 0, x: left, top: headerTop)
            if let x = DotPainter.image(crossDots, columns: 7, rows: 7, pitch: 1, color: dim, glow: 0, margin: 0, scale: scale) {
                context.draw(x, in: cross.offsetBy(dx: r.minX, dy: r.minY))
            }
            // The rocket (or house) on the display: a night feed, scanlines over it.
            let picture = CGRect(x: r.minX + left, y: r.minY + top(pictureTop, pictureHeight), width: inner, height: pictureHeight)
            context.saveGState()
            context.addPath(CGPath(roundedRect: picture, cornerWidth: 6, cornerHeight: 6, transform: nil)); context.clip()
            night(context, picture)
            if let house { fill(context, house, picture) }
            context.setFillColor(CGColor(gray: 0, alpha: 0.17))
            var line = picture.minY
            while line < picture.maxY { context.fill(CGRect(x: picture.minX, y: line, width: picture.width, height: 0.75)); line += 2 }
            context.restoreGState()
            context.setStrokeColor(cyan.withAlphaComponent(0.38).cgColor); context.setLineWidth(0.75)
            context.addPath(CGPath(roundedRect: picture.insetBy(dx: 0.375, dy: 0.375), cornerWidth: 6, cornerHeight: 6, transform: nil)); context.strokePath()
            // The three numbers, in dots, their names dim under them.
            let column = inner / 3
            for (i, figure) in content.figures.enumerated() {
                let x = left + CGFloat(i) * column
                dots(DotText(figure.value, width: Int(column / 2), maxLines: 1), pitch: 2, color: cyan, glow: 1, x: x, top: figuresTop)
                dots(DotText(figure.label.uppercased(), width: Int(column), maxLines: 1), pitch: 1, color: dim, glow: 0, x: x, top: figuresTop + 26)
            }
            // The top tasks, as terminal lines.
            for (i, task) in content.tasks.enumerated() {
                let rowTop = tasksTop + CGFloat(i) * taskRow
                let minutes = lit(task.minutes, font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), color: dim, lines: 1)
                let minutesWidth = minutes.width
                minutes.draw(context, CGRect(x: r.minX + left + inner - minutesWidth, y: r.minY + top(rowTop, 14), width: minutesWidth, height: 14))
                lit("› " + task.title, font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), color: cyan, lines: 1)
                    .draw(context, CGRect(x: r.minX + left, y: r.minY + top(rowTop, 14), width: inner - minutesWidth - 10, height: 14))
            }
            // The line.
            if inDots { dots(dotLine, pitch: 2, color: cyan, glow: 1, x: left, top: lineTop) }
            else { typeLine.draw(context, CGRect(x: r.minX + left, y: r.minY + top(lineTop, lineHeight) - 6, width: inner, height: lineHeight + 6)) }
            // The prompt, and the day at the right.
            dots(footer, pitch: 1, color: cyan, glow: 0.6, x: left, top: footerTop)
            dots(day, pitch: 1, color: faint, glow: 0, x: left + inner - CGFloat(day.width), top: footerTop)
        }
        return (size, parts)
    }

    /// The display's shell (white plastic; graphite in dark mode) and its dark glass, as on Tetsu's speech display.
    /// Returns the glass.
    private static func panel(_ rect: CGRect, dark: Bool) -> CGRect {
        let shellShape = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
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
        let rim = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 15.25, yRadius: 15.25); rim.lineWidth = 0.75; rim.stroke()
        NSColor.black.withAlphaComponent(dark ? 0.5 : 0.16).setStroke(); shellShape.lineWidth = 0.75; shellShape.stroke()
        let glass = rect.insetBy(dx: shell, dy: shell)
        let glassShape = NSBezierPath(roundedRect: glass, xRadius: 11, yRadius: 11)
        NSGradient(colors: [NSColor(srgbRed: 0.035, green: 0.05, blue: 0.065, alpha: 1), NSColor(srgbRed: 0.008, green: 0.012, blue: 0.018, alpha: 1)])?
            .draw(in: glassShape, angle: -90)
        NSGraphicsContext.saveGraphicsState(); glassShape.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.06), NSColor.white.withAlphaComponent(0)])?
            .draw(in: CGRect(x: glass.minX, y: glass.maxY - 90, width: glass.width, height: 90), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.75).setStroke(); glassShape.lineWidth = 1; glassShape.stroke()
        return glass
    }

    /// The pad at night behind the rocket: deep blue going black, a few cold stars.
    static func night(_ context: CGContext, _ rect: CGRect) {
        let colours = [CGColor(srgbRed: 0.10, green: 0.16, blue: 0.24, alpha: 1), CGColor(srgbRed: 0.04, green: 0.07, blue: 0.12, alpha: 1)]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        let k = max(1, (rect.width / 248).rounded())  // a point on the card; the stills are drawn in pixels
        context.setFillColor(CGColor(srgbRed: 0.75, green: 0.95, blue: 1, alpha: 0.75))
        for (x, y) in [(0.1, 0.88), (0.24, 0.76), (0.4, 0.92), (0.58, 0.8), (0.74, 0.9), (0.9, 0.74), (0.33, 0.66)] as [(CGFloat, CGFloat)] {
            context.fill(CGRect(x: (rect.minX + x * rect.width).rounded(), y: (rect.minY + y * rect.height).rounded(), width: k, height: k))
        }
    }

    // MARK: Helpers

    /// Lit type on the glass (any script): the display's colour with its glow, cut to `lines` lines with "…".
    struct LitText {
        let text: NSAttributedString
        let lines: Int
        let color: NSColor
        var width: CGFloat { ceil(text.size().width) }
        func height(_ width: CGFloat) -> CGFloat {
            let setter = CTFramesetterCreateWithAttributedString(text)
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: width, height: 1000), nil)
            let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 12)
            let one = ceil(font.ascender - font.descender + font.leading) + 2
            return min(ceil(fit.height), one * CGFloat(lines))
        }
        func draw(_ context: CGContext, _ rect: CGRect) {
            context.saveGState()
            context.setShadow(offset: .zero, blur: 3.2, color: color.withAlphaComponent(0.85).cgColor)
            text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
            context.restoreGState()
        }
    }
    static func lit(_ string: String, font: NSFont, color: NSColor, lines: Int) -> LitText {
        let style = NSMutableParagraphStyle(); style.alignment = .natural; style.baseWritingDirection = .natural; style.lineSpacing = 2
        style.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        return LitText(text: NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]), lines: lines, color: color)
    }

    private static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
    private static func measure(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(with: CGSize(width: width, height: 2000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
    }
    /// The whole view (the card and its margin) drawn by `draw`, which gets the card's rect.
    private static func drawn(size: CGSize, scale: CGFloat, _ draw: (CGRect) -> Void) -> CGImage? {
        let inset = DayCountedCardView.inset
        return SpeechBubbleView.image(size: CGSize(width: size.width + 2 * inset, height: size.height + 2 * inset), scale: scale) { _ in
            draw(CGRect(x: inset, y: inset, width: size.width, height: size.height))
        }
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

// MARK: Where it goes

enum DayCountedGeometry {
    /// Between the card and the companion's body.
    static let gap: CGFloat = 10
    /// The card's window origin: beside the companion (to its left, or to its right when there's no room), the card's
    /// bottom at its feet, on screen. Also says whether the companion is to the card's right (where it comes in from).
    static func place(window size: CGSize, inset: CGFloat, companion panel: CGRect, visible: CGRect) -> (origin: CGPoint, companionOnRight: Bool) {
        let scale = StageGeometry.scale(of: panel)
        let centre = panel.minX + StageGeometry.characterFrame.midX * scale
        let bodyLeft = centre - StageGeometry.bodyLeft * scale, bodyRight = centre + StageGeometry.bodyRight * scale
        let drawn = CGSize(width: size.width - 2 * inset, height: size.height - 2 * inset)
        var left = bodyLeft - gap - drawn.width, onRight = true
        if left < visible.minX + 8 { left = bodyRight + gap; onRight = false }
        left = min(max(left, visible.minX + 8), visible.maxX - 8 - drawn.width)
        let bottom = min(max(panel.minY + StageGeometry.feet.y * scale, visible.minY + 6), visible.maxY - 8 - drawn.height)
        return (CGPoint(x: (left - inset).rounded(), y: (bottom - inset).rounded()), onRight)
    }
}

// MARK: Showing it

/// Puts the card up beside the companion and takes it down: on ✕, on a click (which opens Your day), a minute after the
/// person has been back at the Mac with it in view, at midnight, or when the companion is put away. Its house is one of
/// the bundled stills (DayCountedStills), so no renderer starts: while it's up, the card holds one picture.
@MainActor final class DayCountedPresenter {
    private(set) var panel: OverlayPanel?
    private(set) var view: DayCountedCardView?
    private var watch: Timer?
    private var seenSeconds = 0.0
    private var shownOn = ""
    private var goodbye: CheckedContinuation<Void, Never>?
    private var goodbyeTimer: Task<Void, Never>?
    /// Set by the world presenter: Your day, at this day.
    var onOpenDay: ((Date?) -> Void)?
    /// Usage: `day_card` (shown, opened, closed with ✕, or gone by itself).
    var track: UsageTracker?
    private var shownAs: (yesterday: Bool, farewell: Bool) = (false, false)
    /// The person is back with the card in view this long (in all): it bows out.
    static let seenFor = 60.0
    /// A goodbye on quit stays this long.
    static let goodbyeSeconds = 6.0
    /// Idle under this, the person is looking (for `seenFor`).
    static let presentIdle = 20.0

    var isShowing: Bool { panel != nil }
    private var companionObserver: NSObjectProtocol?

    init() {
        // Another companion chosen: this one's card goes with it.
        companionObserver = NotificationCenter.default.addObserver(forName: .mokuCompanionChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }
    isolated deinit { watch?.invalidate(); if let companionObserver { NotificationCenter.default.removeObserver(companionObserver) } }

    /// Whether the companion is on show on this desktop: not hidden or put away, not behind a full-screen app's space,
    /// the display awake.
    var companionInView: Bool {
        guard !VisualSessionState.shared.mokuHidden, !VisualSessionState.shared.onboarding, let window = VisualSessionState.shared.character?.window else { return false }
        return window.isVisible && window.isOnActiveSpace && window.occlusionState.contains(.visible) && window.alphaValue > 0.5
    }

    /// The card for `summary`, beside the companion. True once it's up.
    func show(_ summary: TodaySummary, yesterday: Bool, farewell: Bool = false) async -> Bool {
        guard !isShowing, companionInView else { return false }
        let house = DayCountedStills.load(minutes: summary.focusedMinutes, companion: .current)
        guard !isShowing, companionInView, let companion = VisualSessionState.shared.character?.window else { return false }
        let screen = companion.screen ?? NSScreen.main
        put(DayCountedContent(summary: summary, companion: .current, yesterday: yesterday, farewell: farewell), house: house,
            beside: companion.frame, visible: screen?.visibleFrame ?? companion.frame, scale: screen?.backingScaleFactor ?? 2)
        return true
    }

    /// Puts the card up beside a companion whose window is `frame`, on a screen whose visible part is `visible`.
    func put(_ content: DayCountedContent, house: CGImage?, beside frame: CGRect, visible: CGRect, scale: CGFloat) {
        let view = DayCountedCardView(content: content, house: house, style: SpeechStyle(content.companion), dark: Self.appearsDark,
                                      scale: scale, reduced: MotionPreference.reduced)
        let panel = OverlayPanel(size: view.frame.size)
        panel.contentView = view; panel.ignoresMouseEvents = false
        let placed = DayCountedGeometry.place(window: view.frame.size, inset: DayCountedCardView.inset, companion: frame, visible: visible)
        panel.setFrameOrigin(placed.origin)
        let day = content.yesterday ? TodayModel.date(content.date) : nil, farewell = content.farewell
        view.onClose = { [weak self] in self?.close(how: "closed") }
        view.onOpen = { [weak self] in
            guard let self else { return }
            close(how: "opened")
            if !farewell { onOpenDay?(day) }
        }
        self.panel = panel; self.view = view
        shownOn = TodayModel.key(Date()); seenSeconds = 0
        shownAs = (content.yesterday, farewell)
        cardEvent("shown")
        panel.orderFrontRegardless()
        view.playEntrance(fromRight: placed.companionOnRight)
        if !farewell { startWatching() }
    }

    /// Moku is quitting: the card as a goodbye, back once it's gone (✕, a click, or `goodbyeSeconds`). False if it couldn't show.
    func sayGoodbye(_ summary: TodaySummary) async -> Bool {
        guard await show(summary, yesterday: false, farewell: true) else { return false }
        await withCheckedContinuation { continuation in
            goodbye = continuation
            goodbyeTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.goodbyeSeconds))
                guard !Task.isCancelled else { return }
                self?.close(how: "timed_out")
            }
        }
        return true
    }

    /// Takes it down (the exit plays, then the window and its picture go). `how` is what `day_card` says: "opened",
    /// "closed" (✕) or "timed_out" (seen long enough, midnight, the companion put away); nil says nothing (a meeting).
    func close(how: String? = nil) {
        guard let panel, let view else { return }
        if let how { cardEvent(how) }
        self.panel = nil; self.view = nil
        watch?.invalidate(); watch = nil
        goodbyeTimer?.cancel(); goodbyeTimer = nil
        view.onClose = nil; view.onOpen = nil
        view.playExit()
        let finished = goodbye; goodbye = nil
        Task {
            try? await Task.sleep(for: .seconds(view.exitSeconds + 0.05))
            panel.orderOut(nil); panel.contentView = nil; panel.close()
            finished?.resume()
        }
    }

    /// Every 5 s while it's up: the person back and looking adds up to `seenFor`; midnight, or the companion put away
    /// or out of view (hidden, a full-screen app), takes it down. The pointer on it holds it.
    private func startWatching() {
        watch?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.look() } }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }
    private func look() {
        guard isShowing else { return }
        if TodayModel.key(Date()) != shownOn || VisualSessionState.shared.mokuHidden { close(how: "timed_out"); return }
        if view?.isHovered == true { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle < Self.presentIdle && companionInView { seenSeconds += 5 }
        if seenSeconds >= Self.seenFor { close(how: "timed_out") }
    }
    private func cardEvent(_ what: String) {
        track?("day_card", ["what": .word(what), "yesterday": .bool(shownAs.yesterday), "farewell": .bool(shownAs.farewell)])
    }

    static var appearsDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

// MARK: The house

/// The day's house (or Tetsu's rocket) at each piece count, 0 to 24, drawn by the app's own renderer over the card's sky
/// and bundled (assets/world/<home>/stills/piece-NN.jpg, about 30 KB each). The card loads one: drawing it live would start
/// RealityKit, about 250 MB for a moment and some 60 MB it keeps, for one picture. Remake them when a home changes:
/// `MokuVisualDemo --offscreen --today-counted-stills <dir>`, then copy <dir>/world into assets/world.
enum DayCountedStills {
    /// Pixels: the card's picture (1.6 to 1) at 2×, and a little over.
    static let pixels = (width: 512, height: 320)
    static func path(_ companion: Companion, pieces: Int) -> String { String(format: "world/%@/stills/piece-%02d.jpg", companion.homeKey, pieces) }
    /// The still for a day of `minutes` focused minutes: a piece every 10 minutes, the whole home at four hours.
    static func load(minutes: Int, companion: Companion) -> CGImage? {
        guard let url = MokuAssets.file(path(companion, pieces: DayHouse.built(Double(minutes))), companion: companion),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Draws every still for `companion` into `directory` (as world/<home>/stills/piece-NN.jpg), with one renderer.
    @MainActor static func make(companion: Companion, into directory: URL) async throws -> [URL] {
        let layout = try HomeLayout.load(companion.homeLayoutPath)
        let renderer = try await HomeWorldRenderer(kind: .treehouse, layout: layout, homeKey: companion.homeKey)
        let folder = directory.appendingPathComponent("world/\(companion.homeKey)/stills")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [URL] = []
        for pieces in 0...DayHouse.pieces {
            try await renderer.render(points: Double(pieces) * DayHouse.minutesPerPiece)
            guard let render = renderer.image(),
                  let context = CGContext(data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            let rect = CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
            if companion.isMachine { DayCountedDrawing.night(context, rect) } else { DayCountedDrawing.dusk(context, rect) }
            DayCountedDrawing.fill(context, render, rect)
            guard let still = context.makeImage() else { continue }
            let url = folder.appendingPathComponent(String(format: "piece-%02d.jpg", pieces))
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, still, [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary)
            if CGImageDestinationFinalize(destination) { written.append(url) }
        }
        return written
    }
}

// MARK: The menu bar side

extension MokuWorldPresenter {
    var canShowDayCounted: Bool { dayCounted.companionInView && !popover.isShown && !dayCounted.isShowing }
    func showDayCounted(_ summary: TodaySummary, yesterday: Bool) async -> Bool {
        guard canShowDayCounted else { return false }
        return await dayCounted.show(summary, yesterday: yesterday)
    }
    /// (Quitting from the popover closes it first; its close may still be animating, so it isn't in the way here.)
    func sayGoodbyeWithDayCounted(_ summary: TodaySummary) async -> Bool {
        guard dayCounted.companionInView, !dayCounted.isShowing else { return false }
        return await dayCounted.sayGoodbye(summary)
    }
    func closeDayCounted() { dayCounted.close() }
}

/// "Quit Moku" from Moku's own menus (the popover's, the menu bar icon's, the companion's, ⌘Q): the app may say goodbye
/// first (the day's card); with no handler set, Moku quits at once. A logout, a restart, an update or a signal never
/// comes this way.
@MainActor public enum QuitRequest {
    public static var handler: (@MainActor () -> Void)?
    static func send() { if let handler { handler() } else { NSApp.terminate(nil) } }
}
