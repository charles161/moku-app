import Foundation
import QuartzCore
import MokuKit

/// How much of its little life Moku keeps, for the energy bar (docs/specs/launch-qa.md, lens 3). Fidgets, ear flicks and
/// reading darts each draw frames of their own; this stretches the waits between them when the Mac asks for less. Blinks,
/// moods and everything the person asked for (a break, a drift, a return) are never touched, and a move that has begun
/// plays at full rate.
enum PowerPolicy {
    /// 1 on a Mac with power to spare; 2 in Low Power Mode, when the Mac is running hot (a serious thermal state or worse)
    /// or short of memory (see `shortOfMemoryUntil`).
    static func waitScale(lowPower: Bool, thermal: ProcessInfo.ThermalState, shortOfMemory: Bool = false) -> Double {
        lowPower || shortOfMemory || thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue ? 2 : 1
    }

    /// When the Mac last said it was short of memory, plus two minutes (RealityCharacter.relieveMemory sets it).
    @MainActor static var shortOfMemoryUntil = -100.0

    /// A dozing Moku is asleep: its fidgets and ear flicks come a third as often (its dream twitches are its own).
    static func sleepScale(for mood: Mood) -> Double { mood == .sleepy ? 3 : 1 }

    /// After this long in unbroken focus (no drift, return, pat or break) Moku settles: you are deep in the work, and a
    /// companion that keeps fidgeting at minute twenty is a distraction as well as a cost (docs/specs/launch-qa.md, lens 3).
    static let longFocusSeconds = 600.0

    /// How much longer the waits get after `focusedFor` seconds of unbroken focus (nil: not focused). `moves`: the little
    /// moves (fidgets, ear or antenna flicks, the face's little moves) come half as often. `eyes`: the reading darts and
    /// blinks a third less often: people blink far less while they read a screen, so it still looks like reading (a blink
    /// is the biggest single cost in frames, a quarter of the working state's).
    static func focusScale(focusedFor seconds: Double?) -> (moves: Double, eyes: Double) {
        guard let seconds, seconds >= longFocusSeconds else { return (1, 1) }
        return (2, 1.5)
    }

    /// The scale now. MOKU_POWER_SCALE overrides it (checks).
    @MainActor static var current: Double {
        if let given = ProcessInfo.processInfo.environment["MOKU_POWER_SCALE"].flatMap(Double.init), given >= 1 { return given }
        let info = ProcessInfo.processInfo
        return waitScale(lowPower: info.isLowPowerModeEnabled, thermal: info.thermalState, shortOfMemory: CACurrentMediaTime() < shortOfMemoryUntil)
    }
}

/// How long Moku has watched you work without a break in it. Working starts the clock; a drift (or anything else that isn't
/// working: a break, being away) stops it, and a return or a pat starts it over. After `PowerPolicy.longFocusSeconds`
/// the waits between little moves grow (`PowerPolicy.focusScale`).
struct FocusClock {
    private(set) var since: Double?
    /// Checks only: MOKU_FOCUS_AGE=<seconds> starts the clock that many seconds in the past, so a check need not wait ten minutes.
    let headStart: Double
    init(headStart: Double = ProcessInfo.processInfo.environment["MOKU_FOCUS_AGE"].flatMap(Double.init) ?? 0) { self.headStart = headStart }

    /// The work state changed (to a new one): working starts the clock, anything else stops it.
    mutating func became(_ state: WorkState, now: Double) { since = state == .focused ? now - headStart : nil }
    /// A return or a pat: unbroken focus starts over (nothing to do when not focused).
    mutating func interrupted(now: Double) { if since != nil { since = now - headStart } }
    func scale(now: Double) -> (moves: Double, eyes: Double) { PowerPolicy.focusScale(focusedFor: since.map { now - $0 }) }
}
