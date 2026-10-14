import Foundation
import MokuKit

/// One moment of work: the app and window in front, the task it was on, and when.
struct WorkMoment: Sendable, Equatable {
    var app: AppInfo
    var window: WindowInfo?
    var place: WorkContext
    var thread: ThreadRef?
    var goal: ThreadRef?
    var at: Date
}

/// The last moment of work, noted on every working verdict for what's in front (with the window that sample was taken of),
/// a pat ("this is fine") and a switch to another window of the same app while working. A drift keeps the moment before it.
/// (It named the work in "Where was I?", removed on 2026-10-14: the friends found it "100% inaccurate".)
extension BehaviorEngine {
    /// Work, now: at `place` (nil: what's in front) in `window` (nil: the window in front), on `thread` and `goal`. A moment
    /// with no task of its own keeps its place's task from the moment before, if that was the same place.
    mutating func noteWork(now: Date, place: WorkContext?, window: WindowInfo?, thread: ThreadRef?, goal: ThreadRef?) {
        guard let app = focusApp, let place = place ?? focus, place.bundleId == app.bundleId else { return }
        let samePlace = lastWork?.place == place
        lastWork = WorkMoment(app: app, window: window ?? focusWindow, place: place, thread: thread ?? (samePlace ? lastWork?.thread : nil),
                              goal: goal ?? (samePlace ? lastWork?.goal : nil), at: now)
    }

    /// "Delete my data": the last moment of work (an app, a window title, a task) goes with the rest, and so does the copy
    /// a drift under way keeps of the moment it left.
    mutating func forgetWork() {
        lastWork = nil
        drift?.leftWork = nil
    }
}
