import CoreGraphics
import Foundation
import MokuKit
import Testing
@testable import MokuMind

@Suite("Focus")
struct FocusTests {
    @Test func workingVerdictsMeanContentFocus() {
        var h = EngineHarness()
        h.work(60)
        #expect(h.status.phase == .focused)
        #expect(h.status.mood == .content)
        // Nothing to say while the user works; one nod as the task starts (Charles, 2026-10-14), nothing else.
        #expect(h.allEffects.lines.isEmpty)
        #expect(h.allEffects.gestures == [.nod])
    }

    @Test func becomesProudAfterContinuousFocusOnce() {
        var h = EngineHarness()
        h.work(2_700 + 600)
        #expect(h.times { $0.isMood(.proud) }.first == 2_700)
        #expect(h.status.mood == .proud)  // and back to proud after any look-up
    }

    @Test func earnsOneGrowthPointPerFocusedMinuteForTheCurrentThread() {
        var h = EngineHarness()
        h.work(600)
        let growth = h.allEffects.events(.focusGrowth)
        #expect(growth.count == 10)
        #expect(growth.allSatisfy { $0.value == 1 && $0.threadId == Fixtures.thread.id })
        #expect(h.times { $0.isEvent(.focusGrowth) } == stride(from: 60.0, through: 600, by: 60).map { $0 })
    }

    @Test func focusNeedsFreshEvidence() {
        var h = EngineHarness()
        // One working verdict, then the brain goes quiet for 10 minutes.
        h.send(.verdict(h.verdict(.working)))
        h.pass(600)
        // Only the minute the verdict vouches for counts.
        #expect(h.allEffects.events(.focusGrowth).count == 1)
        #expect(h.status.focusStreakSec == 60)
    }

    @Test func attentionFollowsTheWorkAtMostFiveTimesASecond() {
        var h = EngineHarness()
        h.work(5)
        let before = h.allEffects.gazes.count
        // 30 cursor updates within one second.
        var sent: [EngineEffect] = []
        for step in 0..<30 {
            sent += h.send(.attention(CGPoint(x: 100 + step, y: 200)))
            h.wait(1.0 / 30)
        }
        #expect(sent.gazes.count <= 5)
        #expect(sent.gazes.count >= 4)
        // The newest point is not lost: it goes out on the next tick.
        h.wait(0.5)
        let flushed = h.tick().gazes
        #expect(flushed == [.point(CGPoint(x: 129, y: 200))])
        #expect(h.allEffects.gazes.count == before + sent.gazes.count + 1)
    }

    @Test func workContextKeepsTheSiteForBrowsersAndOnlyTheAppOtherwise() {
        #expect(Fixtures.youtube == WorkContext(bundleId: "com.apple.Safari", host: "youtube.com"))
        #expect(Fixtures.editor == WorkContext(bundleId: "com.apple.dt.Xcode", host: nil))
        #expect(WorkContext(app: Fixtures.editorApp, window: WindowInfo(title: "Other.swift", url: nil)) == Fixtures.editor)
        #expect(Fixtures.youtube.isSamePlace(as: WorkContext(bundleId: "com.apple.Safari")))
        #expect(!Fixtures.youtube.isSamePlace(as: Fixtures.docs))
    }
}

@Suite("A nod for the task")
struct ThreadLabelTests {
    static let placeholder = ThreadRef(id: "t-new", title: "Code · inorder_traversal.py", provisional: true)
    static let named = ThreadRef(id: "t-new", title: "DSA · Tree Traversal")

    /// Charles, 2026-10-14: the task labels ("launching moku desktop app") aren't needed; Moku shows it knows you're
    /// working with its body. Where it used to name a task, it nods; hovering Moku shows the task (the stage's).
    @Test func aTaskGetsANodOnceItsRealTitleArrivesAndNoLabel() {
        var h = EngineHarness()
        let first = h.work(3, thread: Self.placeholder)
        #expect(first.gestures.filter { $0 == .nod }.isEmpty)  // never for a placeholder
        let named = h.work(600, thread: Self.named)
        #expect(named.gestures.filter { $0 == .nod }.count == 1)
        #expect(!h.allEffects.contains { if case .character(.say) = $0 { true } else { false } })
    }

    @Test func aTaskGetsANodAgainOnlyAfterALongGap() {
        var h = EngineHarness()
        let other = ThreadRef(id: "t-other", title: "Docs · Onboarding")
        h.work(600, thread: Self.named)
        h.work(600, thread: other)
        h.work(60, thread: Self.named)  // back after 10 minutes: no nod
        h.work(1_800, thread: other)
        h.work(60, thread: Self.named)  // back after 30 minutes: a nod again
        #expect(h.allEffects.gestures.filter { $0 == .nod }.count == 3)
    }

    @Test func noNodDuringAMeeting() {
        var h = EngineHarness()
        h.send(.meeting(Fixtures.inCall))
        let during = h.work(60, thread: Self.named)
        #expect(during.gestures.filter { $0 == .nod }.isEmpty)
    }
}

@Suite("Focus look-ups")
struct FocusLookUpTests {
    static let charles: CompanionConfig = {
        var config = CompanionConfig.standard
        config.smileEverySec = 240
        config.breakAfterSec = 1_000_000  // keep break suggestions out of the way
        config.proudAfterSec = 1_000_000
        return config
    }()

    /// When each look-up (a smile) started.
    static func lookUps(_ h: EngineHarness) -> [Double] {
        h.log.compactMap { item in if case .character(.perform(.smile)) = item.effect { item.t } else { nil } }
    }

    @Test(arguments: [60.0, 240] as [Double])
    func lookUpsComeEveryMinuteOfContinuousFocusExactly(every: Double) {
        // Charles: "make it once per minute - on continuous focus". No jitter, no floor.
        var config = Self.charles
        config.smileEverySec = every
        var h = EngineHarness(config: config)
        h.work(every * 10)
        let starts = Self.lookUps(h)
        #expect(starts.count == 10)
        let gaps = zip([0] + starts, starts).map { $1 - $0 }
        #expect(gaps.allSatisfy { abs($0 - every) <= 1 }, "gaps \(gaps)")
    }

    @Test func aDriftStartsTheMinuteAgain() {
        var config = Self.charles
        config.smileEverySec = 60
        var h = EngineHarness(config: config)
        h.work(50)
        h.drift(30)  // past grace: a real drift
        let back = h.now.timeIntervalSince(EngineHarness.base)
        h.work(70)
        // The return's own happy moment plays at `back`; the look-ups are the ones after it.
        let starts = Self.lookUps(h).filter { $0 > back }
        // Not 10 s after coming back (50 + 10 would make a minute): a full minute of focus after it.
        #expect(starts.count == 1)
        #expect(starts.first.map { abs($0 - (back + 60)) <= 2 } == true, "look-ups \(starts), back at \(back)")
    }

    /// Charles, 2026-10-08 ("moku seems to close his eyes kinda even without me patting it"): every look-up is a smile
    /// with its eyes open, never happy closed eyes (those are for a pat).
    @Test func everyLookUpIsASmileWithItsEyesOpen() {
        for seed in 1...20 as ClosedRange<UInt64> {
            var h = EngineHarness(config: Self.charles, seed: seed)
            h.work(3_000)
            #expect(Self.lookUps(h).count >= 8)
            #expect(!h.allEffects.moods.contains(.happy), "seed \(seed)")
        }
    }

    @Test func aSmileLooksUpAndGoesBackToTheWork() throws {
        var h = EngineHarness(config: Self.charles, seed: 1)
        h.send(.attention(Fixtures.cursor))
        h.work(1_000)
        let smile = try #require(Self.lookUps(h).first)
        #expect(h.effects(from: smile, to: smile).gazes == [.user])
        // Held about 2.5 s: back on the work at the next whole second after it.
        #expect(h.effects(from: smile + 1, to: smile + 2).gazes.isEmpty)
        #expect(h.effects(from: smile + 3, to: smile + 3).gazes == [.point(Fixtures.cursor)])
    }

    @Test func nothingOutsideFocus() {
        var h = EngineHarness(config: Self.charles, seed: 3)
        h.pass(1_200, judging: .unknown)  // just launched, the brain unsure
        h.drift(1_200)
        h.send(.verdict(h.verdict(.away)))
        h.pass(1_200, judging: .away)
        h.send(.meeting(Fixtures.inCall))
        h.pass(1_200, judging: .working)
        h.send(.meeting(.none))
        h.send(.startBreak)
        h.pass(1_000)
        #expect(!h.allEffects.gestures.contains(.smile))
        #expect(!h.allEffects.moods.contains(.happy))
    }

    @Test func aDueLookUpWaitsForALineAndADueBreakCutsALookUpShort() {
        var config = Self.charles
        config.breakAfterSec = 240
        config.smileEverySec = 240
        var h = EngineHarness(config: config, seed: 5)
        h.work(2_000)
        let breaks = h.times { $0.isEvent(.breakSuggested) }
        let starts = Self.lookUps(h)
        #expect(breaks.count >= 6)
        // No look-up starts while a break line is up.
        for start in starts {
            #expect(!breaks.contains { start > $0 && start < $0 + 6 })
        }
        // Breaks keep their schedule: every 240 s of focus, never pushed back by a look-up.
        for (previous, next) in zip(breaks, breaks.dropFirst()) {
            #expect(next - previous == 240)
        }
    }
}
