import Foundation
import Testing
import MokuKit
@testable import MokuVisual

@Test func clickPatAndSustainedGrabAreDistinct() {
    var r = GrabRecognizer()
    r.begin(at: .zero, onHead: true, time: 0)
    r.update(to: CGPoint(x: 2, y: 1), time: 0.1)
    #expect(r.end(time: 0.2) == .click)
    r.begin(at: .zero, onHead: true, time: 0)
    r.update(to: CGPoint(x: 15, y: 1), time: 0.1)
    r.update(to: CGPoint(x: -2, y: 2), time: 0.2)
    #expect(r.end(time: 0.3) == .pat)
    r.begin(at: .zero, onHead: false, time: 0)
    r.update(to: CGPoint(x: 10, y: 0), time: 0.05)
    r.update(to: CGPoint(x: 20, y: 0), time: 0.15)
    #expect(r.grabbed && r.end(time: 0.2) == .grab)
    r.update(to: .zero, time: 0.3)
    #expect(r.end(time: 0.4) == .grab)
}
@Test func holdThenMoveGrabsAndBodyStrokeNeverPats() {
    var r = GrabRecognizer(); r.begin(at: .zero, onHead: true, time: 0)
    r.update(to: CGPoint(x: 5, y: 0), time: 0.3)
    #expect(r.grabbed)
    // On the body a grab starts at once (Moku comes with the pointer), so a stroke there just moves it.
    r.begin(at: .zero, onHead: false, time: 0)
    r.update(to: CGPoint(x: 5, y: 0), time: 0.01)
    #expect(r.grabbed)
    r.update(to: .zero, time: 0.1)
    #expect(r.end(time: 0.2) == .grab)
}
@Test func pickingUpEasesInAndSettingDownSettlesWithoutASnap() {
    // Moku's lift spring, stepped at 60 fps: no frame jumps more than a fraction of the way.
    var lift = Spring(), frames = 0, biggestStep: Float = 0
    while !(lift.isSettled(at: 1)) && frames < 120 {
        let before = lift.value
        lift.step(toward: 1, seconds: 1.0 / 60, stiffness: 160, damping: 17)
        biggestStep = max(biggestStep, abs(lift.value - before)); frames += 1
    }
    #expect(biggestStep < 0.2)            // eased in over several frames, not snapped
    #expect(frames < 60)                  // held within a second
    var peak: Float = 1
    for _ in 0..<120 { lift.step(toward: 0, seconds: 1.0 / 60, stiffness: 160, damping: 17); peak = min(peak, lift.value) }
    #expect(peak < 0 && peak > -0.2)      // set down with a small, soft squash past rest
    #expect(lift.isSettled(at: 0))
}
@Test func theSwaySwingsBackToHangingStraightWhenTheDragStops() {
    var sway = Spring()
    for _ in 0..<30 { sway.step(toward: 0.8, seconds: 1.0 / 60, stiffness: 55, damping: 6) }  // half a second of dragging
    #expect(sway.value > 0.4)
    var crossed = false
    for _ in 0..<150 { sway.step(toward: 0, seconds: 1.0 / 60, stiffness: 55, damping: 6); if sway.value < 0 { crossed = true } }
    #expect(crossed)                      // it swings past, like a plush on a string…
    #expect(abs(sway.value) < 0.02)       // …and hangs straight within a few seconds
    // A late frame can't blow it up.
    var late = Spring(); late.step(toward: 1, seconds: 2, stiffness: 160, damping: 17)
    #expect(late.value.isFinite && late.value < 1.3)
}
@Test func savedHomeRoundTripsAndAdaptsToDisplayChanges() throws {
    let visible = CGRect(x: -1920, y: 50, width: 1920, height: 1030), origin = CGPoint(x: -700, y: 480)
    let home = SavedHome(origin: origin, visible: visible, scale: 1)
    let restored = try JSONDecoder().decode(SavedHome.self, from: JSONEncoder().encode(home))
    #expect(abs(restored.origin(in: visible, scale: 1).x - origin.x) < 0.001 && abs(restored.origin(in: visible, scale: 1).y - origin.y) < 0.001)
    let smaller = CGRect(x: 0, y: 80, width: 1024, height: 600)
    #expect(restored.origin(in: smaller, scale: 1) == StageGeometry.clamped(restored.origin(in: smaller, scale: 1), to: smaller, scale: 1))
}

@Test func movingTheHandSwingsMokuAndItSettlesHangingStraight() {
    var dangle = Dangle()
    for _ in 0..<12 { dangle.step(handAcceleration: 6_000, seconds: 1.0 / 120) }  // a quick move to the right
    #expect(dangle.angle < -0.05)                                              // the body lags to the left
    var crossed = false
    for _ in 0..<600 { dangle.step(handAcceleration: 0, seconds: 1.0 / 120); if dangle.angle > 0.01 { crossed = true } }
    #expect(crossed)                                                           // swings through…
    #expect(dangle.isSettled)                                                  // …and hangs straight within 5 s
    var wild = Dangle(); for _ in 0..<60 { wild.step(handAcceleration: 50_000, seconds: 1.0 / 60) }
    #expect(abs(wild.angle) <= Dangle.limit + 1e-9)                            // never flips over
}
@Test func aThrowSnapsToTheEdgeItWasThrownToward() {
    let xs: ClosedRange<CGFloat> = 0...1000, ys: ClosedRange<CGFloat> = 6...600
    // The edge the line meets: right at the height the line reaches it, the floor before the left side, the top.
    #expect(StageGeometry.edge(from: CGPoint(x: 500, y: 300), toward: CGPoint(x: 1000, y: 200), xs: xs, ys: ys) == CGPoint(x: 1000, y: 400))
    #expect(StageGeometry.edge(from: CGPoint(x: 500, y: 100), toward: CGPoint(x: -200, y: -470), xs: xs, ys: ys) == CGPoint(x: 460, y: 6))
    #expect(StageGeometry.edge(from: CGPoint(x: 400, y: 6), toward: CGPoint(x: 0, y: 2400), xs: xs, ys: ys) == CGPoint(x: 400, y: 600))
    #expect(StageGeometry.edge(from: CGPoint(x: 1200, y: -40), toward: .zero, xs: xs, ys: ys) == CGPoint(x: 1000, y: 6))  // no direction: on screen
    // Flicked right and up from mid-screen: straight along its line, never back, onto the right side, faster at the start
    // than on arrival, and soon.
    var flick = Flick(from: CGPoint(x: 700, y: 300), velocity: CGPoint(x: 1500, y: 600), xs: xs, ys: ys)
    #expect(flick.to == CGPoint(x: 1000, y: 420))
    var previous = flick.position, steps = 0
    while !flick.finished && steps < 600 {
        flick.step(seconds: 1.0 / 120)
        let now = flick.position
        #expect(now.x >= previous.x - 1e-9 && now.y >= previous.y - 1e-9)
        #expect(abs((now.y - 300) * 300 - (now.x - 700) * 120) < 0.5)        // on the line it was thrown along
        previous = now; steps += 1
    }
    #expect(flick.position == flick.to && steps < 90)                          // there within 0.7 s
    #expect(flick.startSpeed > flick.endSpeed && flick.endSpeed > 0)            // slowing, and arriving with a snap
    #expect(flick.tumble < 0)                                                  // tumbled with the throw
    // A flick straight up from the floor ends at the top and stays there; a short one along the floor still travels to
    // the side it was thrown toward, at the shortest flight.
    var up = Flick(from: CGPoint(x: 400, y: 6), velocity: CGPoint(x: 0, y: 2400), xs: xs, ys: ys)
    while !up.finished { up.step(seconds: 1.0 / 60) }
    #expect(up.position == CGPoint(x: 400, y: 600))
    let short = Flick(from: CGPoint(x: 980, y: 6), velocity: CGPoint(x: 700, y: 0), xs: xs, ys: ys)
    #expect(short.to == CGPoint(x: 1000, y: 6) && short.duration == Flick.shortest)
}

/// The welcome holds its companion: a drag there did nothing useful and saved the drop point, at the welcome's size, as
/// its home, so the welcome's end went there. Pressing and moving now does nothing until the welcome is over.
@MainActor @Test func theWelcomesCompanionCannotBeCarriedOff() {
    let stage = MokuCharacterStage(rendersOffscreen: true)
    let feet = CGPoint(x: 600, y: 400)
    stage.enterWelcome(feet: feet, scale: 2)
    stage.beginGrab(at: CGPoint(x: 640, y: 440), press: CGPoint(x: 630, y: 430))
    #expect(!stage.grabbing)
    stage.releaseGrab()
    stage.leaveWelcome()
    stage.beginGrab(at: CGPoint(x: 640, y: 440), press: CGPoint(x: 630, y: 430))
    #expect(stage.grabbing)  // out of the welcome, as ever
    stage.cancelGrab()
}

/// The welcome's companion has no right-click menu: Hide took it out of the welcome's window, and Your day, Settings or a
/// break (which the welcome ignores) went over or past the welcome. Out of the welcome, the menu is as ever.
@MainActor @Test func theWelcomesCompanionHasNoRightClickMenu() {
    let stage = MokuCharacterStage(rendersOffscreen: true)
    stage.enterWelcome(feet: CGPoint(x: 600, y: 400), scale: 2)
    #expect(stage.contextMenu() == nil)
    stage.leaveWelcome()
    #expect(stage.contextMenu()?.items.map(\.title).contains("Settings…") == true)
}

/// A friend's welcome showed an empty stage (2026-10-07, a photo of "HELLO, BRU" with no Tetsu): they had hidden the
/// companion before, and "Say hi again" (or a reinstall, which keeps the setting) opened the welcome with it still hidden.
/// The welcome brings it out, says so once (`shown` by the welcome), and it stays out afterwards.
@Test @MainActor func theWelcomeBringsOutAHiddenCompanion() {
    UserDefaults.standard.removeObject(forKey: MokuPreferences.hiddenKey)
    let stage = MokuCharacterStage(rendersOffscreen: true)
    var events: [(String, [String: UsageValue])] = []
    stage.track = { name, props in events.append((name, props)) }
    stage.setHidden(false)
    stage.setHiddenByPerson(true)
    #expect(stage.hidden)
    events.removeAll()
    stage.enterWelcome(feet: CGPoint(x: 600, y: 400), scale: 2)
    #expect(!stage.hidden, "the welcome's companion is hidden: an empty stage")
    #expect(!stage.hiddenByPerson)
    #expect(events.map(\.0) == ["shown"] && events.first?.1["by"] == .word("welcome"))
    stage.leaveWelcome()
    #expect(!stage.hidden)
    // Its own defaults, never Moku's: an offscreen stage doesn't hide the real one.
    #expect(UserDefaults.standard.object(forKey: MokuPreferences.hiddenKey) == nil)
}
