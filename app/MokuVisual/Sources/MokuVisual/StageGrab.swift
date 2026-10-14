import AppKit
import MokuKit

extension Notification.Name { static let mokuResetHome = Notification.Name("MokuVisual.resetHome") }

extension NSScreen {
    /// Where Moku lives on this display: the visible frame, kept clear of a Dock that hides itself (the 2026-09-28 audit:
    /// at home Moku sat where the hidden Dock slides out).
    var stageFrame: CGRect {
        StageGeometry.clearOfHiddenDock(visible: visibleFrame, screen: frame,
                                        dockTile: CGFloat(CFPreferencesCopyAppValue("tilesize" as CFString, "com.apple.dock" as CFString) as? Double ?? 48))
    }
}

extension MokuCharacterStage {
    func displayKey(_ screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return screen.localizedName }
        return CFUUIDCreateString(nil, uuid) as String
    }
    func homeScreen() -> NSScreen? {
        let preferred = homeStore.string(forKey: "MokuVisual.homeDisplay")
        return NSScreen.screens.first { displayKey($0) == preferred } ?? NSScreen.screens.first
    }
    func homeOrigin(on screen: NSScreen, scale: CGFloat? = nil) -> CGPoint {
        let scale = scale ?? view.scale
        if let data = homeStore.data(forKey: "MokuVisual.home.\(displayKey(screen))"), let home = try? JSONDecoder().decode(SavedHome.self, from: data) { return home.origin(in: screen.stageFrame, scale: scale) }
        return StageGeometry.home(in: screen.stageFrame, scale: scale)
    }
    func saveHome() {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(CGPoint(x: panel.frame.midX, y: panel.frame.midY)) }) ?? homeScreen() else { return }
        let home = SavedHome(origin: panel.frame.origin, visible: screen.stageFrame, scale: view.scale)
        homeStore.set(try? JSONEncoder().encode(home), forKey: "MokuVisual.home.\(displayKey(screen))")
        homeStore.set(displayKey(screen), forKey: "MokuVisual.homeDisplay"); currentSpot = .home
    }
    func resetHome() {
        cancelGrab()
        for key in homeStore.dictionaryRepresentation().keys where key.hasPrefix("MokuVisual.home") { homeStore.removeObject(forKey: key) }
        Task { [weak self] in await self?.move(to: .home) }
    }
    func beginGrab(at cursor: CGPoint, press: CGPoint) {
        guard !inWelcome else { return }  // the welcome holds its companion
        cancelDirectedBeat(); travel.cancel(); moveGeneration += 1; moving = false
        grabbing = true
        dismissSpeech(); fadeCaption(); view.manpu.setSuppressed(true)  // the label fades, never vanishes
        // Held exactly where it was pressed: the grab starts within a few points, so there's no visible jump.
        grabOffset = CGPoint(x: press.x - panel.frame.minX, y: press.y - panel.frame.minY)
        view.real?.beginPickup(at: view.stagePoint(grabOffset)); view.lantern.setHidden(true)
        grabSamples = []; lastHand = nil; handVelocity = .zero; handAcceleration = .zero
        if case .held = carry {} else { dangle = Dangle() }
        carry = .held
        startCarrying()
        dragGrab(to: cursor)
    }
    /// The panel follows the pointer on every drag event, so it never trails it.
    func dragGrab(to cursor: CGPoint) {
        guard grabbing else { return }
        let now = CACurrentMediaTime()
        grabSamples.append((cursor, now)); grabSamples.removeAll { now - $0.1 > 0.1 }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? homeScreen() else { return }
        panel.setFrameOrigin(StageGeometry.clamped(CGPoint(x: cursor.x - grabOffset.x, y: cursor.y - grabOffset.y), to: screen.stageFrame, scale: view.scale))
    }
    /// Let go. Moving fast, it's a throw: it flies on along the line it was thrown and snaps onto the edge of the screen
    /// that line meets (`Flick`), where it stays. Otherwise it's set down where it is (flush with a side or the bottom it
    /// was dropped close to), settling softly either way.
    func releaseGrab() {
        guard grabbing else { return }; grabbing = false; view.dragging = false
        view.real?.endPickup(reduced: reduced)
        let now = CACurrentMediaTime(), velocity = releaseVelocity(now: now)
        if !reduced, hypot(velocity.x, velocity.y) > Self.throwSpeed,
           let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) }) ?? homeScreen() {
            let visible = screen.stageFrame, floor = StageGeometry.home(in: visible, scale: view.scale).y
            var flick = Flick(from: panel.frame.origin, velocity: velocity, xs: StageGeometry.originsX(in: visible, scale: view.scale),
                              ys: floor...max(floor, StageGeometry.originsY(in: visible, scale: view.scale).upperBound), tumble: dangle.angle)
            if view.real?.companion.isMachine == true { flick.tumbleSpin *= Flick.machineSpin }  // a robot barely tumbles
            carry = .flicked(flick)
            count?(.toss)
        } else {
            carry = .landing(from: panel.frame.origin, to: settledOrigin(panel.frame.origin), started: now)
            count?(.drag)
        }
        startCarrying()
    }
    /// Pointer speed at the release (points per second), over its last few samples; zero if it had stopped.
    private func releaseVelocity(now: Double) -> CGPoint {
        guard let first = grabSamples.first, let last = grabSamples.last, now - last.1 < 0.06, last.1 - first.1 > 0.02 else { return .zero }
        return CGPoint(x: (last.0.x - first.0.x) / (last.1 - first.1), y: (last.0.y - first.0.y) / (last.1 - first.1))
    }
    static let throwSpeed: CGFloat = 650
    private func settledOrigin(_ origin: CGPoint) -> CGPoint {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(CGRect(origin: origin, size: panel.frame.size)) }) ?? homeScreen() else { return origin }
        return StageGeometry.settled(origin, in: screen.stageFrame, scale: view.scale)
    }
    private func startCarrying() {
        guard carryTicker == nil else { return }
        carryTicker = DisplayTicker(view: view, onScreen: !rendersOffscreen) { [weak self] seconds in self?.stepCarry(seconds: seconds) ?? false }
    }
    /// One display frame of carrying, throwing or landing. Returns false when everything has come to rest.
    private func stepCarry(seconds: Double) -> Bool {
        guard let carry else { carryTicker = nil; return false }
        let origin = panel.frame.origin
        switch carry {
        case .held:
            // The hand is where the panel is (it follows the pointer); its sideways acceleration swings Moku.
            if let lastHand {
                let velocity = CGPoint(x: (origin.x - lastHand.x) / seconds, y: (origin.y - lastHand.y) / seconds)
                let smoothed = CGPoint(x: handVelocity.x + (velocity.x - handVelocity.x) * 0.35, y: handVelocity.y + (velocity.y - handVelocity.y) * 0.35)
                let acceleration = CGPoint(x: (smoothed.x - handVelocity.x) / seconds, y: (smoothed.y - handVelocity.y) / seconds)
                handAcceleration = CGPoint(x: handAcceleration.x + (acceleration.x - handAcceleration.x) * 0.5, y: 0)
                handVelocity = smoothed
            }
            lastHand = origin
            dangle.step(handAcceleration: max(-20_000, min(20_000, handAcceleration.x / view.scale)), seconds: seconds)
            view.real?.stepHold(seconds: seconds, angle: dangle.angle)
            return true
        case .flicked(var flick):
            flick.step(seconds: seconds)
            panel.setFrameOrigin(flick.position)
            view.real?.stepHold(seconds: seconds, angle: flick.tumble)
            if flick.finished {
                view.real?.bump(speed: flick.endSpeed)  // the snap onto the edge
                dangle = Dangle(angle: flick.tumble, spin: flick.tumbleSpin)
                self.carry = .landing(from: flick.to, to: flick.to, started: CACurrentMediaTime())
            } else {
                self.carry = .flicked(flick)
            }
            return true
        case let .landing(from, to, started):
            // Glide the last few points to the side it was dropped near; the swing (or tumble) rights itself.
            let k = MoodTiming.progress(age: CACurrentMediaTime() - started, duration: 0.28)
            panel.setFrameOrigin(CGPoint(x: from.x + (to.x - from.x) * CGFloat(k), y: from.y + (to.y - from.y) * CGFloat(k)))
            dangle.step(handAcceleration: 0, seconds: seconds, damping: Dangle.settleDamping)
            let moving = view.real?.stepHold(seconds: seconds, angle: dangle.isSettled ? 0 : dangle.angle) ?? false
            if k >= 1 && !moving && dangle.isSettled {
                self.carry = nil; carryTicker = nil; landGrab(); return false
            }
            return true
        }
    }
    /// Moku has come to rest after a carry, set down or thrown onto an edge: where it is now is home.
    func landGrab() {
        saveHome()
        if view.lantern.isCarried {
            Task { [weak self] in
                guard let self else { return }
                await view.real?.setCarrying(false); view.lantern.setCarried(false)
            }
        }
        if attention == .user { lookAtUser() } else { watchScreenCenter() }  // a walk or a drop faces the way it was
        workDirection.pause(now: CACurrentMediaTime()); refreshWorkLayers(); positionSpeech(); positionLabel()
    }
    func cancelGrab() {
        carryTicker?.stop(); carryTicker = nil; carry = nil; dangle = Dangle(); grabbing = false; view.dragging = false
        view.real?.endPickup(reduced: true); view.real?.stepHold(seconds: 1, angle: 0); refreshWorkLayers()
    }
}

/// Where a carried Moku is: in your hand, flying to the edge it was thrown at, or landing (gliding the last few points
/// to rest, then home is there).
enum Carry {
    case held
    case flicked(Flick)
    case landing(from: CGPoint, to: CGPoint, started: Double)
}

/// Calls back once per display refresh (a CADisplayLink), for motion that must keep pace with the screen, not
/// the renderer. Offscreen (diagnostics), a 60 Hz timer stands in. The callback returns false to stop.
@MainActor final class DisplayTicker: NSObject {
    private var link: CADisplayLink?
    private var timer: Timer?
    private var last: CFTimeInterval = 0
    private let tick: (Double) -> Bool
    init(view: NSView, onScreen: Bool, tick: @escaping (Double) -> Bool) {
        self.tick = tick
        super.init()
        if onScreen {
            link = view.displayLink(target: self, selector: #selector(step(_:)))
            link?.add(to: .main, forMode: .common)
        } else {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.fire(CACurrentMediaTime()) } }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
    }
    @objc private func step(_ link: CADisplayLink) { fire(link.timestamp) }
    private func fire(_ now: CFTimeInterval) {
        let seconds = last == 0 ? 1.0 / 60 : min(1.0 / 30, max(0.001, now - last)); last = now
        if !tick(seconds) { stop() }
    }
    func stop() { link?.invalidate(); link = nil; timer?.invalidate(); timer = nil }
}
