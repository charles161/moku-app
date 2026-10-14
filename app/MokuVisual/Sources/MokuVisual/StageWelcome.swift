import AppKit
import MokuKit

/// The welcome's companion (docs/specs/welcome-wow.md): the same live character, life-size in the welcome window, placed
/// by its feet at any size, faded (seated) to where it goes next, and home at its own size when it's over.
/// Life-size costs more to draw, so while it's in the window it draws at most 30 frames a second.
extension MokuCharacterStage {
    /// The size the person chose in Settings (what it goes home at).
    var chosenScale: CGFloat { MokuPreferences.size(in: homeStore) }
    /// Its feet on screen at `scale`, wherever the panel is.
    var feetOnScreen: CGPoint { CGPoint(x: panel.frame.minX + StageGeometry.feet.x * view.scale, y: panel.frame.minY + StageGeometry.feet.y * view.scale) }
    /// Its feet at home, at `scale`.
    func homeFeet(scale: CGFloat) -> CGPoint {
        let screen = homeScreen() ?? NSScreen.screens.first
        let origin = screen.map { homeOrigin(on: $0, scale: scale) } ?? .zero
        return CGPoint(x: origin.x + StageGeometry.feet.x * scale, y: origin.y + StageGeometry.feet.y * scale)
    }
    /// Puts it at `scale` with its feet at `feet`, at once (sized, drawn at that size, and the panel to match).
    func place(feet: CGPoint, scale: CGFloat) {
        travel.cancel(); moveGeneration += 1; moving = false
        if scale != view.scale {
            view.setScale(scale); view.real?.setResolution(for: scale)
            panel.setContentSize(StageGeometry.panelSize(scale: scale))
        }
        panel.setFrameOrigin(CGPoint(x: feet.x - StageGeometry.feet.x * scale, y: feet.y - StageGeometry.feet.y * scale))
        positionSpeech(); positionLabel(); updateHit(refreshPointer: true)
    }
    /// The welcome opens: the companion appears where it sits in the window (no walk in), at `scale`. One the person had
    /// hidden comes out and stays out: "Say hi again" (or a reinstall, which keeps the setting) showed an empty stage.
    func enterWelcome(feet: CGPoint, scale: CGFloat) {
        cancelGrab(); inWelcome = true
        place(feet: feet, scale: scale)
        view.real?.frameCap = 30
        if hiddenByPerson { setHiddenByPerson(false, by: "welcome") }
        setHidden(false)
    }
    /// The seated move: it fades out where it sits and in at `feet` and `scale` (its own size while it's out of sight).
    func fade(toFeet feet: CGPoint, scale: CGFloat, out: Double = 0.3, in fadeIn: Double = 0.45) async {
        await NSAnimationContext.runAnimationGroup { context in context.duration = out; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); panel.animator().alphaValue = 0 }
        guard !hidden else { return }
        place(feet: feet, scale: scale)
        await NSAnimationContext.runAnimationGroup { context in context.duration = fadeIn; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); panel.animator().alphaValue = 1 }
    }
    /// The seated landing: a small squash and back about its feet (Moku only: Tetsu is a machine and doesn't squash).
    func settle() async {
        guard !reduced, companion?.isMachine != true else { return }
        let began = CACurrentMediaTime(), scale = view.scale, loop = FrameLoop()
        settleLoop = loop
        await loop.run(view: view, onScreen: panel.isVisible && !rendersOffscreen) { [weak self] in
            guard let self, settleLoop === loop else { return false }
            let t = CACurrentMediaTime() - began
            view.setScale(scale, squash: SeatedSettle.squash(at: t))
            return t < SeatedSettle.duration
        }
        view.setScale(scale); settleLoop = nil
    }
    /// The welcome is over: home at its own size, drawing at its usual pace.
    func leaveWelcome() {
        inWelcome = false
        view.real?.frameCap = nil
        settleLoop = nil; view.setScale(view.scale)  // a settle on its way ends at its next frame, its shape whole
        let home = homeFeet(scale: chosenScale)
        if view.scale != chosenScale || hypot(feetOnScreen.x - home.x, feetOnScreen.y - home.y) > 2 { place(feet: home, scale: chosenScale) }
        panel.alphaValue = hidden ? panel.alphaValue : 1
        currentSpot = .home
        refreshHidden()  // a film that began during the welcome hides it now
    }
}

/// Steps something once per display frame (a timer offscreen) until the step says it's done, then returns.
@MainActor final class FrameLoop {
    private var ticker: DisplayTicker?
    func run(view: NSView, onScreen: Bool, step: @escaping @MainActor () -> Bool) async {
        guard step() else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            MainActor.assumeIsolated {
                ticker = DisplayTicker(view: view, onScreen: onScreen) { _ in
                    MainActor.assumeIsolated {
                        if step() { return true }
                        done.resume(); return false
                    }
                }
            }
        }
        ticker = nil
    }
}
