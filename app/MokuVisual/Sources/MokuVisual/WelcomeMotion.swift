import AppKit
import QuartzCore

/// The welcome's moves (docs/specs/welcome-wow.md), each a pure function of time, so the screen (Core Animation, or a
/// step per display frame) and the offscreen film draw exactly the same thing. Nothing here jumps or hops: Charles,
/// 2026-10-04, "i hate the jumping animation"; companions stay seated, and move by fading out and in (a seated glide
/// was tried and read as floating).
enum WelcomeMotion {
    /// Eases in and out with no kick at either end (smootherstep): 0…1.
    static func ease(_ t: Double) -> Double { let t = min(1, max(0, t)); return t * t * t * (t * (t * 6 - 15) + 10) }
    /// Eases out (cubic): quick, then gentle.
    static func easeOut(_ t: Double) -> Double { let t = min(1, max(0, t)); return 1 - pow(1 - t, 3) }
}

/// The seated landing (Moku arriving in its corner as the welcome ends): a small squash and back, about the feet, so
/// it settles onto the desk like a plush set down. It never leaves its seat; at the end it's exactly its shape.
enum SeatedSettle {
    static let duration = 0.3
    static func squash(at seconds: Double) -> CGSize {
        let v = min(1, max(0, seconds / duration)), k = CGFloat(sin(.pi * v) * (1 - 0.35 * v))
        return v >= 1 ? CGSize(width: 1, height: 1) : CGSize(width: 1 + 0.02 * k, height: 1 - 0.04 * k)
    }
}

/// How the welcome window goes when it ends: Moku's window lets go (the paper dissolves outward from behind the
/// companion, which stays where it is: A7); Tetsu's powers off like an old screen (it squeezes to a bright line, then a
/// dot: C8); Skip, the close button and Reduce Motion fade it where it is.
enum WindowExit: Equatable {
    case letGo(center: CGPoint)
    case powerOff
    case fade

    var duration: Double {
        switch self { case .letGo: 0.45; case .powerOff: 0.56; case .fade: 0.3 }
    }
    /// The window `t` seconds in: how big the hole in the paper is (letGo, as a share of the window's diagonal), how
    /// far it's squeezed (powerOff: x and y scale, and the white of the line), and its opacity.
    struct State: Equatable { var hole: CGFloat = 0; var scaleX: CGFloat = 1; var scaleY: CGFloat = 1; var flash: CGFloat = 0; var opacity: CGFloat = 1; var shadow: CGFloat = 1 }
    func state(at seconds: Double) -> State {
        let u = min(1, max(0, seconds / duration))
        switch self {
        case .letGo:
            // Eases in: the paper starts going slowly behind the companion and is gone at the edges.
            let e = CGFloat(u * u * (3 - 2 * u))
            return State(hole: 1.75 * e, opacity: 1, shadow: max(0, 1 - 2.2 * CGFloat(u)))  // past every corner: nothing is left behind
        case .powerOff:
            // An old screen switching off: the height collapses to a line as it goes white (0–50%), the line pulls
            // in to a dot (50–82%), and the dot fades (82–100%).
            var state = State(shadow: max(0, 1 - 4 * CGFloat(u)))
            let squeeze = CGFloat(WelcomeMotion.ease(u / 0.5))
            state.scaleY = 1 - 0.988 * squeeze
            state.flash = min(1, squeeze * 1.15)
            if u > 0.5 { state.scaleX = 1 - 0.985 * CGFloat(WelcomeMotion.ease((u - 0.5) / 0.32)) }
            if u > 0.82 { state.opacity = 1 - CGFloat((u - 0.82) / 0.18) }
            return state
        case .fade:
            return State(opacity: 1 - CGFloat(WelcomeMotion.ease(u)), shadow: 1 - CGFloat(WelcomeMotion.ease(u)))
        }
    }
}

/// The welcome window going, on screen: a click-through panel in the window's place showing its picture (and a shadow
/// drawn like the window's), played from samples of `WindowExit`. The real window is gone at once, so nothing the
/// person can click is half there. The companion's own window is above it and isn't in the picture: it stays.
@MainActor final class WindowExitOverlay {
    private let panel: OverlayPanel
    init(picture: CGImage, frame: CGRect, exit: WindowExit, scale: CGFloat) {
        let margin: CGFloat = 60
        let bounds = frame.insetBy(dx: -margin, dy: -margin)
        panel = OverlayPanel(size: bounds.size)
        panel.level = .floating; panel.ignoresMouseEvents = true; panel.setFrame(bounds, display: false)
        let host = NSView(frame: CGRect(origin: .zero, size: bounds.size)); host.layer = CALayer(); host.wantsLayer = true
        panel.contentView = host
        let card = CALayer(), shadow = CALayer(), flash = CALayer()
        let local = CGRect(x: margin, y: margin, width: frame.width, height: frame.height)
        for layer in [shadow, card] { layer.frame = local; layer.cornerRadius = 18 }
        shadow.backgroundColor = NSColor(calibratedRed: 0.975, green: 0.963, blue: 0.934, alpha: 1).cgColor
        shadow.shadowColor = NSColor.black.cgColor; shadow.shadowOpacity = 0.3; shadow.shadowRadius = 24; shadow.shadowOffset = CGSize(width: 0, height: -12)
        card.contents = picture; card.contentsGravity = .resize; card.contentsScale = scale; card.masksToBounds = true
        flash.frame = card.bounds; flash.backgroundColor = NSColor(calibratedRed: 0.86, green: 0.98, blue: 1, alpha: 1).cgColor; flash.opacity = 0
        card.addSublayer(flash)
        host.layer?.addSublayer(shadow); host.layer?.addSublayer(card)
        let samples = (0...40).map { exit.state(at: exit.duration * Double($0) / 40) }
        func keyframes(_ path: String, _ values: [Any]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: path); animation.values = values; animation.calculationMode = .linear
            animation.duration = exit.duration; animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
            return animation
        }
        let last = samples[samples.count - 1]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shadow.opacity = Float(last.shadow)
        shadow.add(keyframes("opacity", samples.map { NSNumber(value: Double($0.shadow)) }), forKey: "exit")
        switch exit {
        case .letGo(let center):
            // A soft-edged hole that grows from behind the companion: a radial gradient mask, clear inside.
            let mask = CAGradientLayer(); mask.type = .radial; mask.frame = card.bounds
            let c = CGPoint(x: (center.x - frame.minX) / frame.width, y: (center.y - frame.minY) / frame.height)
            mask.startPoint = c
            mask.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.black.cgColor]
            let diagonal = hypot(frame.width, frame.height)
            func end(_ hole: CGFloat) -> NSValue { NSValue(point: CGPoint(x: c.x + max(0.001, hole) * diagonal / frame.width, y: c.y + max(0.001, hole) * diagonal / frame.height)) }
            func locations(_ hole: CGFloat) -> [NSNumber] { hole <= 0.0001 ? [0, 0, 0.0001] : [0, 0.62, 1] }
            mask.locations = locations(last.hole); mask.endPoint = end(last.hole).pointValue
            mask.add(keyframes("endPoint", samples.map { end($0.hole) }), forKey: "exit")
            mask.add(keyframes("locations", samples.map { locations($0.hole) }), forKey: "exitLocations")
            card.mask = mask; card.opacity = 1
        case .powerOff:
            card.transform = CATransform3DMakeScale(last.scaleX, last.scaleY, 1); card.opacity = Float(last.opacity); flash.opacity = Float(last.flash)
            card.add(keyframes("transform", samples.map { NSValue(caTransform3D: CATransform3DMakeScale(max(0.001, $0.scaleX), max(0.001, $0.scaleY), 1)) }), forKey: "exit")
            card.add(keyframes("opacity", samples.map { NSNumber(value: Double($0.opacity)) }), forKey: "exitOpacity")
            flash.add(keyframes("opacity", samples.map { NSNumber(value: Double($0.flash)) }), forKey: "exit")
            card.shadowColor = NSColor(calibratedRed: 0.35, green: 0.93, blue: 1, alpha: 1).cgColor; card.shadowRadius = 14; card.shadowOpacity = 0.9; card.masksToBounds = false
        case .fade:
            card.opacity = Float(last.opacity)
            card.add(keyframes("opacity", samples.map { NSNumber(value: Double($0.opacity)) }), forKey: "exit")
        }
        CATransaction.commit()
        panel.orderFrontRegardless()
    }
    func close() { panel.orderOut(nil); panel.close() }
}

/// Where System Settings' window is, when one is on screen: the companion goes and sits on its top edge while you flip
/// its switch. Windows' frames need no permission (their titles would; nothing here reads them). Found by the app's
/// process, not its name, which macOS translates.
enum SettingsWindowLocator {
    static let bundleID = "com.apple.systempreferences"
    @MainActor static func frame() -> CGRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let main = NSScreen.screens.first?.frame else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier, (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 300, rect.height > 200 else { continue }
            // Quartz counts down from the top of the main display; AppKit counts up from its bottom.
            return CGRect(x: rect.minX, y: main.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }
    /// Where the companion sits on that window: on its top edge, over the right-hand side where the switches are.
    static func perch(on window: CGRect) -> CGPoint { CGPoint(x: window.maxX - min(150, window.width * 0.2), y: window.maxY - 3) }
}
