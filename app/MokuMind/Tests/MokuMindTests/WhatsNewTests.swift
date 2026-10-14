import CoreGraphics
import Foundation
import MokuKit
import Testing
@testable import MokuMind

/// "What's new" after an update (docs/specs/next-0-1-9.md §1): once per version, never after a fresh install, at the first calm
/// moment, never in a meeting, a call, a break, a drift, away, the welcome or the first five minutes of a focus streak, and its
/// link names the version.
@Suite("What's new")
struct WhatsNewTests {
    static let point = CGPoint(x: 640, y: 420)
    static let cursor = AppInfo(bundleId: "com.todesktop.230313mzl4w4u92", name: "Cursor")
    static let file = WindowInfo(title: "SettingsWindow.swift — bunny", url: nil)
    static let chrome = AppInfo(bundleId: "com.google.Chrome", name: "Google Chrome")
    static let youtube = WindowInfo(title: "Lo-fi beats - YouTube", url: "https://www.youtube.com/watch?v=1")

    /// Whether it may go up now, with Moku watching since the harness began.
    static func calm(_ h: EngineHarness) -> Bool { h.engine.isCalmForNews(now: h.now, watchingSince: EngineHarness.base) }

    /// Works in the editor for `seconds`, the pointer moving all along, then sits still for `still` seconds, still working.
    static func work(_ h: inout EngineHarness, _ seconds: Double, still: Double = 6) {
        let editor = WorkContext(app: cursor, window: file)
        h.send(.focusChanged(cursor, file))
        h.send(.verdict(h.verdict(.working), context: editor))
        h.pass(seconds, judging: .working, context: editor, cursor: point)
        h.pass(still, judging: .working, context: editor)
    }

    // MARK: The words and the link

    @Test func theLinkNamesTheVersion() {
        #expect(WhatsNew.link(version: "0.1.9").absoluteString == "https://hellomoku.com/changelog#0.1.9")
        #expect(WhatsNew.link(version: "0.1.10").absoluteString == "https://hellomoku.com/changelog#0.1.10")
    }

    @Test func itsSaidInTheCompanionsBubbleWithItsVersion() {
        var h = EngineHarness()
        let said = h.engine.sayWhatsNew("0.1.9", now: h.now)
        #expect(said.lines == [SpeechLine(text: "I updated! See what’s new", tone: .cheerful, duration: 15, whatsNew: "0.1.9")])
        #expect(said.gazes == [.user])
        #expect(said.gestures == [.smile])
        #expect(said.voiceRequests.isEmpty)  // built in: no model call
    }

    // MARK: Once per version, never after a fresh install

    @MainActor @Test func onlyAnUpdateHasNewsAndOnlyOncePerVersion() {
        let suite = "moku-whats-new-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // A fresh install isn't an update.
        let first = UsageEvents.recordLaunch(version: "0.1.8", onboarded: false, loginItem: false, defaults: defaults)
        #expect(WhatsNew.pending(version: "0.1.8", updated: first.updated, defaults: defaults) == nil)
        // An update is, and it waits for its moment across launches (quit before a calm moment).
        let update = UsageEvents.recordLaunch(version: "0.1.9", onboarded: true, loginItem: false, defaults: defaults)
        #expect(WhatsNew.pending(version: "0.1.9", updated: update.updated, defaults: defaults) == "0.1.9")
        let relaunch = UsageEvents.recordLaunch(version: "0.1.9", onboarded: true, loginItem: true, defaults: defaults)
        #expect(WhatsNew.pending(version: "0.1.9", updated: relaunch.updated, defaults: defaults) == "0.1.9")
        // Once said, never again for that version, even after going back to it.
        WhatsNew.told("0.1.9", defaults: defaults)
        #expect(WhatsNew.pending(version: "0.1.9", updated: false, defaults: defaults) == nil)
        #expect(WhatsNew.pending(version: "0.1.9", updated: true, defaults: defaults) == nil)
        // The next version has news of its own; one left untold by an older version is dropped.
        #expect(WhatsNew.pending(version: "0.1.10", updated: true, defaults: defaults) == "0.1.10")
        #expect(WhatsNew.pending(version: "0.1.11", updated: false, defaults: defaults) == nil)
    }

    // MARK: The first calm moment

    @Test func notBeforeTwoMinutesOfWatching() {
        var h = EngineHarness()
        h.pass(50); h.send(.attention(Self.point)); h.pass(10)
        #expect(!Self.calm(h))  // a minute in
        h.pass(50); h.send(.attention(Self.point)); h.pass(10)
        #expect(Self.calm(h))  // two minutes in, at the Mac, nothing going on
    }

    @Test func neverInTheFirstFiveMinutesOfAFocusStreak() {
        var h = EngineHarness()
        Self.work(&h, 120)
        #expect(!Self.calm(h))  // settling into the work
        Self.work(&h, 200)
        #expect(h.status.focusStreakSec >= 300)
        #expect(Self.calm(h))  // five minutes in, at a still moment
    }

    @Test func neverMidTypingNorWhenNobodysThere() {
        var h = EngineHarness()
        Self.work(&h, 320, still: 0)
        #expect(!Self.calm(h))  // the pointer moved this second
        h.pass(4, judging: .working)
        #expect(!Self.calm(h))
        h.pass(2, judging: .working)
        #expect(Self.calm(h))
        h.pass(70, judging: .working)
        #expect(!Self.calm(h))  // no input for over a minute: nobody's looking
    }

    @Test func aComebackIsACalmMomentOnceItsCelebrationIsOver() {
        var h = EngineHarness()
        Self.work(&h, 600)
        h.send(.focusChanged(Self.chrome, Self.youtube))
        h.drift(300, context: WorkContext(app: Self.chrome, window: Self.youtube))
        let back = h.send(.focusChanged(Self.cursor, Self.file)) + h.send(.attention(Self.point))
        #expect(back.lines.isEmpty && back.returns == [.full])  // no words over its head (the friends, 2026-10-14)
        #expect(!Self.calm(h))  // the celebration plays
        h.pass(8)
        #expect(Self.calm(h))  // the comeback, though the focus streak starts afresh
        #expect(h.status.focusStreakSec < 300)
        h.send(.attention(Self.point)); h.pass(60)
        #expect(!Self.calm(h))  // the moment has passed: back to settling into focus
    }

    @Test func aBreaksEndIsACalmMoment() {
        var h = EngineHarness()
        Self.work(&h, 60)
        h.send(.startBreak)
        h.pass(300)
        #expect(!Self.calm(h))  // never on a break
        h.send(.endBreak); h.send(.attention(Self.point))
        h.pass(4)
        #expect(!Self.calm(h))  // its own little moment first
        h.pass(3)
        #expect(Self.calm(h))
    }

    @Test func neverInAMeetingADriftOrAway() {
        var meeting = EngineHarness()
        Self.work(&meeting, 320)
        #expect(Self.calm(meeting))
        meeting.send(.meeting(Fixtures.inCall))
        #expect(!Self.calm(meeting))

        var drift = EngineHarness()
        Self.work(&drift, 320)
        drift.send(.focusChanged(Self.chrome, Self.youtube))
        drift.drift(20, context: WorkContext(app: Self.chrome, window: Self.youtube))
        #expect(!Self.calm(drift))

        var away = EngineHarness()
        Self.work(&away, 320)
        away.send(.verdict(away.verdict(.away)))
        away.pass(10, judging: .away)
        #expect(!Self.calm(away))
    }

    // MARK: The runtime

    /// Said once, at the first calm moment where the companion can be seen; the welcome and a hidden companion hold it back.
    @MainActor @Test func theRuntimeSaysItOnceAndNeverInTheWelcome() async {
        let rig = Rig()
        var told: [String] = [], usage: [String] = []
        rig.runtime.whatsNew = "0.1.9"
        rig.runtime.onWhatsNewTold = { told.append($0) }
        rig.runtime.usage = { name, props in if name == "whats_new", case let .word(what)? = props["what"] { usage.append(what) } }
        rig.runtime.start()
        // The welcome: Moku isn't watching, so nothing is said however long it takes.
        rig.runtime.setManualControl(true)
        await rig.run(300, from: 0) { t in if Int(t) % 30 == 0 { rig.runtime.apply(.attention(Self.point)) } }
        #expect(!rig.stage.lines.contains { $0.whatsNew != nil })
        // The welcome's end starts the two minutes again; the companion out of sight holds it back.
        rig.runtime.setManualControl(false)
        rig.world.visible = false
        await rig.run(150, from: 300) { t in if Int(t) % 30 == 0 { rig.runtime.apply(.attention(Self.point)) } }
        #expect(!rig.stage.lines.contains { $0.whatsNew != nil })
        rig.world.visible = true
        await rig.run(10, from: 450)
        #expect(rig.stage.lines.filter { $0.whatsNew != nil }.map(\.whatsNew) == ["0.1.9"])
        // Told (and counted as shown) only once the bubble that went up is over: one the stage never put up stays untold.
        #expect(told.isEmpty && usage.isEmpty)
        rig.stage.onWhatsNew?("0.1.9", false)
        #expect(told == ["0.1.9"] && usage == ["shown", "closed"])
        // Never again.
        await rig.run(300, from: 460) { t in if Int(t) % 30 == 0 { rig.runtime.apply(.attention(Self.point)) } }
        #expect(rig.stage.lines.filter { $0.whatsNew != nil }.count == 1)
        rig.finish()
    }

    @MainActor @Test func aClickOpensThatVersionsChangelog() {
        let rig = Rig()
        var opened: [URL] = [], usage: [String] = []
        rig.runtime.openLink = { opened.append($0) }
        rig.runtime.usage = { name, props in if name == "whats_new", case let .word(what)? = props["what"] { usage.append(what) } }
        rig.runtime.start()
        rig.stage.onWhatsNew?("0.1.9", true)
        rig.stage.onWhatsNew?("0.1.9", false)
        #expect(opened.map(\.absoluteString) == ["https://hellomoku.com/changelog#0.1.9"])
        #expect(usage == ["shown", "opened", "shown", "closed"])
        rig.finish()
    }

    /// The answer says how many seconds the bubble stayed up: put up, then closed 12 s later, the event has 12. Once
    /// answered, the time is used up, so an answer with no bubble going up says nothing about seconds.
    @MainActor @Test func theAnswerSaysHowManySecondsTheBubbleWasUp() async {
        let rig = Rig()
        var events: [[String: UsageValue]] = []
        rig.runtime.whatsNew = "0.1.9"
        rig.runtime.usage = { name, props in if name == "whats_new" { events.append(props) } }
        rig.runtime.start()
        // Watching from the start: the bubble goes up at the first calm moment, a couple of minutes in.
        var t = 0.0
        repeat {
            t += 1
            await rig.run(1, from: t - 1) { now in if Int(now) % 30 == 0 { rig.runtime.apply(.attention(Self.point)) } }
        } while !rig.stage.lines.contains { $0.whatsNew != nil } && t < 300
        #expect(rig.stage.lines.contains { $0.whatsNew != nil })
        rig.manualClock.set(t + 12)
        rig.stage.onWhatsNew?("0.1.9", false)
        rig.stage.onWhatsNew?("0.1.9", true)
        #expect(events == [["what": .word("shown")], ["what": .word("closed"), "seconds": .int(12)],
                           ["what": .word("shown")], ["what": .word("opened")]])
        rig.finish()
    }
}
