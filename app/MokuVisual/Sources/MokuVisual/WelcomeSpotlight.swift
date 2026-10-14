import AppKit
import QuartzCore

/// The welcome's last moment (Charles, 2026-10-04: "the house should expand and shrink in place, not like move from top
/// to bottom, it should immediately darken the screen and grab attention"). The display with the menu bar icon dims at
/// once, with a soft clear spotlight round the icon, so the house is the only bright thing there; the house grows and
/// shrinks about its own centre, three beats, with a soft halo that brightens with it; and after about three
/// seconds, or at once on any click or key press, it's all gone. Nothing travels: the rings that used to pulse from the
/// icon read as moving down the screen (their top half was off it). With Reduce Motion the dim and the spotlight fade in
/// and the house is lit, still.
///
/// A pure function of time, so the screen (Core Animation, from samples of it) and the offscreen film draw the same.
struct IconSpotlight: Equatable {
    var reduced: Bool
    static let dim: CGFloat = 0.58
    static let fadeIn = 0.15
    static let hold = 2.8
    static let fadeOut = 0.4
    /// A click or a key ends it sooner, from wherever it is, this fast.
    static let dismissal = 0.22
    static let beats = 3
    static let beat = 0.72
    static let peak: CGFloat = 1.35
    /// The clear around the icon: fully clear within `inner`, fully dim from `outer` (points).
    static let inner: CGFloat = 34
    static let outer: CGFloat = 92
    var duration: Double { Self.hold + Self.fadeOut }

    struct State: Equatable { var dim: CGFloat; var scale: CGFloat; var halo: CGFloat }
    /// `seconds` in; `dismissedAt`, when a click or a key ended it early.
    func state(at seconds: Double, dismissedAt: Double? = nil) -> State {
        let t = max(0, seconds)
        var level = t < Self.fadeIn ? CGFloat(WelcomeMotion.easeOut(t / Self.fadeIn)) : t < Self.hold ? 1 : 1 - CGFloat(WelcomeMotion.ease((t - Self.hold) / Self.fadeOut))
        var scale: CGFloat = 1
        if !reduced {
            // Each beat swells and settles back (sin²: no kick at either end), starting once the dim is in.
            let u = (t - Self.fadeIn) / Self.beat
            if u > 0 && u < Double(Self.beats) { scale = 1 + (Self.peak - 1) * CGFloat(pow(sin(.pi * u.truncatingRemainder(dividingBy: 1)), 2)) }
        }
        if let dismissedAt, t > dismissedAt {
            // From where it was then, out quickly; the house shrinks back with it.
            let from = state(at: dismissedAt), k = CGFloat(WelcomeMotion.ease((t - dismissedAt) / Self.dismissal))
            if k >= 1 { return State(dim: 0, scale: 1, halo: 0) }
            return State(dim: from.dim * (1 - k), scale: from.scale + (1 - from.scale) * k, halo: from.halo * (1 - k))
        }
        level = max(0, min(1, level))
        let swell = (scale - 1) / (Self.peak - 1)
        return State(dim: Self.dim * level, scale: scale, halo: level * (reduced ? 0.75 : 0.45 + 0.55 * swell))
    }
    /// Over once it has faded (or been dismissed and faded).
    func isOver(at seconds: Double, dismissedAt: Double? = nil) -> Bool {
        if let dismissedAt { return seconds >= dismissedAt + Self.dismissal }
        return seconds >= duration
    }
}

/// The spotlight on screen: a dim over the icon's display (a click-through window with a soft clear hole round the
/// icon), and over the icon a halo and a picture of the house that pulse in place, while the real icon underneath is
/// hidden so there's one house. Clicks pass through everything to whatever is under them (the real icon opens the
/// popover); a click or a key anywhere ends it; it ends by itself after three seconds. Ending takes the windows and
/// every event monitor away and shows the real icon again.
@MainActor final class IconSpotlightOverlay {
    let spotlight: IconSpotlight
    let began = CACurrentMediaTime()
    private(set) var dismissedAt: Double?
    private let dimPanel: OverlayPanel
    private let housePanel: OverlayPanel
    private let dimLayer = CALayer(), haloLayer = CAGradientLayer(), houseLayer = CALayer()
    private var monitors: [Any] = []
    private var endTask: Task<Void, Never>?
    private let showIcon: (Bool) -> Void
    var onEnd: (() -> Void)?
    private(set) var ended = false
    /// The windows it puts up, for checks: both must let every click through.
    var windows: [NSWindow] { [dimPanel, housePanel] }
    var monitorCount: Int { monitors.count }

    /// `icon` is where the house is drawn in the menu bar (the button's image, not its wider window), on `screen` (the
    /// display it's on: only that one dims); `house` is the icon's picture as the menu bar draws it (nil: the halo
    /// alone, over the real icon); `above` are windows to keep over the dim (the companion and its speech); `showIcon`
    /// hides and shows the real icon. `listens` false leaves out the event monitors; `shows` false never puts anything
    /// on screen (tests and the geometry check: they build it, measure it and drive it, but nothing is ordered front).
    init(icon: CGRect, screen: CGRect, house: CGImage?, reduced: Bool, above: [NSWindow] = [], showIcon: @escaping (Bool) -> Void = { _ in }, listens: Bool, shows: Bool) {
        spotlight = IconSpotlight(reduced: reduced)
        self.showIcon = showIcon
        dimPanel = OverlayPanel(size: screen.size); housePanel = OverlayPanel(size: CGSize(width: 140, height: 140))
        for panel in [dimPanel, housePanel] { panel.ignoresMouseEvents = true; panel.level = .statusBar; panel.hasShadow = false }
        dimPanel.setFrame(screen, display: false)
        housePanel.setFrame(CGRect(x: icon.midX - 70, y: icon.midY - 70, width: 140, height: 140), display: false)
        // The dim, with its soft clear hole round the icon.
        let host = NSView(frame: CGRect(origin: .zero, size: screen.size)); host.layer = CALayer(); host.wantsLayer = true
        dimPanel.contentView = host
        dimLayer.frame = host.bounds; dimLayer.backgroundColor = NSColor.black.cgColor; dimLayer.opacity = 0
        let hole = CAGradientLayer(); hole.type = .radial; hole.frame = host.bounds
        let centre = CGPoint(x: (icon.midX - screen.minX) / screen.width, y: (icon.midY - screen.minY) / screen.height)
        hole.startPoint = centre; hole.endPoint = CGPoint(x: centre.x + IconSpotlight.outer / screen.width, y: centre.y + IconSpotlight.outer / screen.height)
        hole.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.black.cgColor]
        hole.locations = [0, NSNumber(value: Double(IconSpotlight.inner / IconSpotlight.outer)), 1]
        dimLayer.mask = hole
        host.layer?.addSublayer(dimLayer)
        // The halo and the house, about the icon's centre.
        let houseHost = NSView(frame: CGRect(x: 0, y: 0, width: 140, height: 140)); houseHost.layer = CALayer(); houseHost.wantsLayer = true
        housePanel.contentView = houseHost
        haloLayer.type = .radial; haloLayer.frame = CGRect(x: 30, y: 30, width: 80, height: 80)
        haloLayer.startPoint = CGPoint(x: 0.5, y: 0.5); haloLayer.endPoint = CGPoint(x: 1, y: 1)
        haloLayer.colors = [NSColor(calibratedRed: 1, green: 0.97, blue: 0.86, alpha: 0.75).cgColor, NSColor(calibratedRed: 0.86, green: 0.93, blue: 0.8, alpha: 0.28).cgColor, NSColor.clear.cgColor]
        haloLayer.locations = [0, 0.45, 1]; haloLayer.opacity = 0
        houseHost.layer?.addSublayer(haloLayer)
        if let house {
            houseLayer.contents = house; houseLayer.contentsGravity = .resizeAspect
            houseLayer.frame = CGRect(x: 70 - icon.width / 2, y: 70 - icon.height / 2, width: icon.width, height: icon.height)
            houseLayer.contentsScale = screenScale(screen)
            houseHost.layer?.addSublayer(houseLayer)
        }
        play(from: 0, dismissedAt: nil)
        if shows {
            dimPanel.orderFrontRegardless(); housePanel.orderFrontRegardless()
            if house != nil { showIcon(false) }
            for window in above where window.isVisible { window.orderFrontRegardless() }  // the companion and its line stay lit
        }
        if listens {
            monitors = [
                NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                    MainActor.assumeIsolated { self?.handle(event.type) }; return event  // never swallowed: it goes where it was going
                },
                NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                    MainActor.assumeIsolated { self?.handle(event.type) }
                },
            ].compactMap { $0 }
        }
        endTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(IconSpotlight.hold + IconSpotlight.fadeOut))
            self?.end()
        }
    }
    /// For the geometry check: where the dim's clear hole is drawn, as the layers are laid out (the dim's host layer
    /// with the dim at full strength, the mask in place, nothing animating), and where the house is drawn, on screen.
    var measure: (dim: CALayer, dimPanel: CGRect, house: CGRect, housePanel: CGRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dimLayer.removeAllAnimations(); dimLayer.opacity = 1
        CATransaction.commit()
        let house = houseLayer.frame.offsetBy(dx: housePanel.frame.minX, dy: housePanel.frame.minY)
        return (dimPanel.contentView!.layer!, dimPanel.frame, house, housePanel.frame)
    }
    private func screenScale(_ frame: CGRect) -> CGFloat { NSScreen.screens.first { $0.frame == frame }?.backingScaleFactor ?? 2 }
    /// A click or a key: it goes, quickly, from wherever it is. (The event itself carries on to where it was going.)
    func handle(_ type: NSEvent.EventType) {
        guard !ended, dismissedAt == nil else { return }
        let now = CACurrentMediaTime() - began
        dismissedAt = now
        removeMonitors()
        play(from: now, dismissedAt: now)
        endTask?.cancel()
        endTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(IconSpotlight.dismissal + 0.02))
            self?.end()
        }
    }
    /// Plays the spotlight from `from` seconds in, from samples of IconSpotlight.
    private func play(from: Double, dismissedAt: Double?) {
        let end = dismissedAt.map { $0 + IconSpotlight.dismissal } ?? spotlight.duration
        let span = max(0.01, end - from), count = max(2, Int(span * 60))
        let samples = (0...count).map { spotlight.state(at: from + span * Double($0) / Double(count), dismissedAt: dismissedAt) }
        func keyframes(_ path: String, _ values: [Any]) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: path); animation.values = values; animation.duration = span
            animation.calculationMode = .linear; animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
            return animation
        }
        let last = samples[samples.count - 1]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        dimLayer.opacity = Float(last.dim); haloLayer.opacity = Float(last.halo)
        dimLayer.add(keyframes("opacity", samples.map { NSNumber(value: Double($0.dim)) }), forKey: "spotlight")
        haloLayer.add(keyframes("opacity", samples.map { NSNumber(value: Double($0.halo)) }), forKey: "spotlight")
        let scales = samples.map { NSValue(caTransform3D: CATransform3DMakeScale($0.scale, $0.scale, 1)) }
        // The house grows and shrinks about its centre; the halo stays its size and brightens with it (a halo that grew
        // would grow down the screen: its top half is past the screen's edge).
        houseLayer.transform = CATransform3DMakeScale(last.scale, last.scale, 1)
        houseLayer.add(keyframes("transform", scales), forKey: "pulse")
        CATransaction.commit()
    }
    private func removeMonitors() { monitors.forEach(NSEvent.removeMonitor); monitors = [] }
    /// All gone: the windows, the monitors, and the real icon back.
    func end() {
        guard !ended else { return }
        ended = true
        endTask?.cancel(); endTask = nil
        removeMonitors()
        dimPanel.orderOut(nil); housePanel.orderOut(nil); dimPanel.close(); housePanel.close()
        showIcon(true)
        onEnd?()
    }
    isolated deinit { if !ended { monitors.forEach(NSEvent.removeMonitor); showIcon(true) } }
}
