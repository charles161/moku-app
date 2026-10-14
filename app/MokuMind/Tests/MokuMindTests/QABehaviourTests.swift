import CoreGraphics
import Foundation
import MokuKit
import Testing
@testable import MokuMind

/// Launch QA, lens 2 (docs/specs/launch-qa.md): what the realistic sessions (app/MokuMind/Sources/mokumind-qa) found, each
/// kept as the smallest engine scenario that fails without its fix.
@Suite("Launch QA: behaviour")
struct QABehaviourTests {
    // MARK: Sleep and wake (parameter 5)

    /// The Mac wakes and the first thing the engine hears is the person's app (or an answer to an old sample), not the
    /// next tick. The long away still has to play: a wave hello, and the continuous-work timers starting over.
    @Test func wakingFromAnEightHourSleepOnAFocusChangeStillGreetsAndStartsFresh() {
        var h = EngineHarness()
        h.send(.focusChanged(Fixtures.editorApp, Fixtures.editorWindow))
        h.work(2_400, context: Fixtures.editor)  // 40 minutes in, then the lid closes
        h.wait(8 * 3_600)
        let back = h.send(.focusChanged(Fixtures.editorApp, Fixtures.editorWindow))
        // The wave is the whole hello: no words over its head (the friends, 2026-10-14).
        #expect(back.gestures.contains(.wave))
        #expect(back.lines.isEmpty)
        #expect(h.status.focusStreakSec == 0)
    }

    @Test func wakingFromANightMidDriftOnAWorkingVerdictIsALongAwayNotAReturn() {
        var h = EngineHarness()
        h.work(600)
        h.drift(610)  // standing, red, asked to focus; then the lid closes
        h.wait(8 * 3_600)
        let back = h.send(.verdict(h.verdict(.working)))
        #expect(back.notableEventTypes.isEmpty)  // no return, no stone
        #expect(back.gestures.contains(.wave))  // a long away's hello, not a return's celebration
        #expect(back.returns.isEmpty)
        #expect(back.lines.isEmpty)
        #expect(back.gestures.contains(.sitDown))
    }

    // MARK: A neutral app in front (Preview, Finder, a system screen)

    /// What the brain says for Finder and Preview: neither work nor drift, so the state before stands (rule neutral-app).
    private func neutral(_ h: inout EngineHarness) -> Verdict {
        var verdict = h.verdict(.unknown)
        verdict.source = .shortcut
        verdict.reason = "[neutral-app] Preview: neither work nor drift"
        return verdict
    }

    /// Reading a PDF in Preview is the student's and the researcher's work. Your day keeps counting it (the timeline carries
    /// the state before an `unknown`), so the house has to as well, or the day says 3 hours focused and the house shows 2.
    @Test func aNeutralAppKeepsTheFocusBeforeItGoing() {
        var h = EngineHarness()
        h.send(.focusChanged(Fixtures.editorApp, Fixtures.editorWindow))
        h.work(300, context: Fixtures.editor)
        h.send(.focusChanged(AppInfo(bundleId: "com.apple.Preview", name: "Preview"), WindowInfo(title: "paper.pdf", url: nil)))
        var growth = 0
        for second in 1...600 {  // ten minutes of Preview, a verdict every 3 s
            if second % 3 == 0 { growth += h.send(.verdict(neutral(&h))).events(.focusGrowth).count }
            growth += h.pass(1).events(.focusGrowth).count
        }
        #expect(growth >= 9)
        #expect(h.status.phase == .focused)
        #expect(h.status.workState == .focused)
    }

    @Test func aNeutralAppDoesNotKeepCreditingForever() {
        var h = EngineHarness()
        h.send(.focusChanged(Fixtures.editorApp, Fixtures.editorWindow))
        h.work(300, context: Fixtures.editor)
        h.send(.focusChanged(AppInfo(bundleId: "com.apple.finder", name: "Finder"), WindowInfo(title: "Documents", url: nil)))
        var growth = 0
        for second in 1...(2 * 3_600) {  // two hours in Finder
            if second % 3 == 0 { growth += h.send(.verdict(neutral(&h))).events(.focusGrowth).count }
            growth += h.pass(1).events(.focusGrowth).count
        }
        #expect(growth <= 40)  // the half hour that is held, not the two hours
        #expect(h.status.workState == .idle)
    }

    /// A failed model call is `unknown` too, and it must still freeze the clocks: nothing was judged, and a dead brain
    /// can't mint focus minutes (the neutral rule is the only `unknown` that holds the state).
    @Test func aFailedJudgmentStillFreezesTheFocusClock() {
        var h = EngineHarness()
        h.work(300)
        var growth = 0
        for second in 1...600 {
            if second % 3 == 0 {
                var failed = h.verdict(.unknown)
                failed.source = .fallback
                failed.reason = "[jev-failed] timeout after 2 attempt(s)"
                growth += h.send(.verdict(failed)).events(.focusGrowth).count
            }
            growth += h.pass(1).events(.focusGrowth).count
        }
        #expect(growth <= 1)  // the minute of evidence the last working verdict covered
    }

    // MARK: Copy (parameter 11: what Moku says when Luna's line isn't ready)

    /// Progress is a home that goes up a piece at a time (a house, a rocket), not a forest: the website, the popover and Your
    /// day all say so. The built-in celebration line, the one a person hears when Luna is slow or the network is down, still
    /// said "Look, our forest grew!".
    @Test func noBuiltInLineTalksAboutAForest() {
        for kind in VoiceKind.allCases {
            let request = VoiceRequest(kind: kind, userName: "Charles", threadTitle: "the rate limiter", focusMinutes: 45, driftMinutes: 12,
                                       distraction: "youtube.com", nextUnit: "the roof", minutesToNextUnit: 3, completionLabel: "pushed login-flow")
            for text in FallbackLines.variants(for: request) { #expect(!text.lowercased().contains("forest"), "\(kind): \(text)") }
            let bare = VoiceRequest(kind: kind, userName: "Charles")
            for text in FallbackLines.variants(for: bare) { #expect(!text.lowercased().contains("forest"), "\(kind): \(text)") }
        }
    }
}
