import AppKit
import MokuKit

/// When to follow the person's work to another display (Charles, 2026-10-14: "is it active only on the active screen and
/// not show up on every screen"): one companion, which moves to the display the work is on once the work has stayed
/// there `after` seconds. A glance back to its own display starts the wait again.
struct ScreenFollow {
    static let after: TimeInterval = 30
    private var candidate: String?
    private var since: TimeInterval?
    /// Waiting to see whether the work stays on another display.
    var waiting: Bool { candidate != nil }

    /// `work`: the display the work is on (nil: not known); `own`: the companion's. The display to move to, once.
    mutating func update(work: String?, own: String?, now: TimeInterval) -> String? {
        guard let work, let own, work != own else { candidate = nil; since = nil; return nil }
        guard candidate == work, let since else { candidate = work; since = now; return nil }
        guard now - since >= Self.after else { return nil }
        candidate = nil; self.since = nil
        return work
    }
}

extension MokuCharacterStage {
    /// A point where the person works (AppKit global coordinates): when it has stayed on another display long enough,
    /// the companion fades there, seated, to that display's home, and that display becomes its home display.
    func followWork(to point: CGPoint) {
        guard NSScreen.screens.count > 1, !inWelcome, !hidden, workState == .focused else { return }
        lastWorkPoint = point
        defer {
            // Reading on the other display sends no new points: look again once the wait is over.
            if screenFollow.waiting, followCheck == nil {
                followCheck = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(ScreenFollow.after + 0.5))
                    guard let self, !Task.isCancelled else { return }
                    followCheck = nil
                    if let point = lastWorkPoint { followWork(to: point) }
                }
            }
        }
        let work = NSScreen.screens.first { $0.frame.contains(point) }
        let own = NSScreen.screens.first { $0.frame.contains(CGPoint(x: panel.frame.midX, y: panel.frame.midY)) }
        guard let target = screenFollow.update(work: work.map(displayKey), own: own.map(displayKey), now: CACurrentMediaTime()),
              let screen = NSScreen.screens.first(where: { displayKey($0) == target }),
              !grabbing, !moving, speechTask == nil else { return }
        homeStore.set(target, forKey: "MokuVisual.homeDisplay")
        let origin = homeOrigin(on: screen)
        let feet = CGPoint(x: origin.x + StageGeometry.feet.x * view.scale, y: origin.y + StageGeometry.feet.y * view.scale)
        Task { [weak self] in
            guard let self else { return }
            await fade(toFeet: feet, scale: view.scale)
            currentSpot = .home
            refreshHidden()  // full screen on the new display, say
            await settle()
        }
    }
}
