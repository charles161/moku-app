import Foundation
import MokuKit
import Testing
@testable import MokuMind
@testable import MokuMindReplay

@Suite("Scripted days")
struct DayScenarioTests {
    static let day: DayRecord = {
        var script = ScriptedDay.standard
        script.config = .charles
        return DayReplay.run(script)
    }()

    static func minutes(_ minutes: Double, _ seconds: Double = 0) -> Double { minutes * 60 + seconds }

    @Test func theTaskGetsANodOnceLunaHasNamedIt() {
        let nods = Self.day.effects.compactMap { item -> Double? in item.effect == .character(.perform(.nod)) ? item.t : nil }
        // The first verdict (t = 1 s) carries the placeholder "Code · LoginView.swift"; the named one comes 3 s later.
        // A nod, no label (Charles, 2026-10-14).
        #expect(nods.first == 4)
    }

    @Test func focusBringsASmile() {
        let day = Self.day
        // 15 minutes of focus (from 0:01), give or take 30%.
        let first = day.firstTime { $0 == .character(.perform(.smile)) || $0 == .character(.setMood(.happy)) }
        #expect(first.map { (1 + 630...1 + 1_170).contains($0) } == true)
        #expect(day.effects(from: 0, to: Self.minutes(15)).lines.isEmpty)
    }

    @Test func aShortDriftAndASmallReturnEarnAGrowthBonus() {
        let day = Self.day
        // The new window is sniffed as it comes to the front (it isn't judged yet); ten seconds of grace, then the one
        // sad move (a sigh, the sad face, a look at the user), then the normal face and the work again.
        let drift = day.effects(from: Self.minutes(16), to: Self.minutes(17, 29))
        #expect(drift.gestures == [.sniff, .sigh])
        #expect(drift.moods == [.disappointed, .content])
        let gazes = day.effects(from: Self.minutes(16), to: Self.minutes(17, 29)).gazes
        #expect(gazes.filter { $0 == .user }.count == 1 && gazes.last != .user)  // the look at the user is once
        #expect(drift.lines.isEmpty)
        #expect(drift.workStates == [.grace, .noticing])
        let back = day.effects(from: Self.minutes(17, 30), to: Self.minutes(17, 30))
        #expect(back.returns == [.small])
        #expect(back.notableEventTypes == [.shortDrift, .returned, .returnGrowth])
        #expect(back.events(.returnGrowth).first?.value == 1.6)  // 16 focused minutes before the drift
    }

    @Test func aLongDriftClimbsEveryStepThenTheReturnIsCelebrated() {
        let day = Self.day
        let drift = day.effects(from: Self.minutes(30), to: Self.minutes(47, 59))
        #expect(drift.notableEventTypes == [.longDriftStarted, .nudged])
        #expect(drift.workStates == [.grace, .noticing, .concerned, .drifting, .longDrift])
        #expect(drift.moods == [.disappointed, .content])  // the one sad move, then the normal face to the end
        #expect(drift.gestures == [.sniff, .sigh, .standUp])  // the new window's sniff, the sad step's sigh, then tall
        // No words over its head, not even ten minutes in (the friends, 2026-10-14): it stands where it is.
        #expect(drift.lines.isEmpty)
        #expect(drift.moves.isEmpty)
        #expect(drift.feedback.isEmpty)

        let back = day.effects(from: Self.minutes(48), to: Self.minutes(48))
        #expect(back.lines.isEmpty)  // the return is the celebration alone
        #expect(back.returns == [.full])
        #expect(back.moves.isEmpty)
        #expect(back.notableEventTypes == [.returned])
        #expect(back.events(.returnGrowth).isEmpty)
    }

    @Test func aFinishedPushIsCelebratedOnceTheTypingStops() {
        let day = Self.day
        #expect(day.events(.completed).map(\.t) == [Self.minutes(60, 1)])
        let celebration = day.effects(from: Self.minutes(60, 1), to: Self.minutes(60, 9))
        #expect(celebration.gestures == [.celebrate])
        // The celebration is the body alone: no line, and Luna isn't asked for one (the friends, 2026-10-14).
        #expect(celebration.voiceRequests.isEmpty)
        #expect(celebration.lines.isEmpty)
        // The cursor was last moving at 59:58: five still seconds later, not before.
        #expect(day.firstTime { $0 == .character(.perform(.celebrate)) } == Self.minutes(60, 3))
    }

    @Test func aTeaBreakIsNotDriftAndComingBackLaysAStone() {
        let day = Self.day
        let tea = day.effects(from: Self.minutes(90), to: Self.minutes(94, 59))
        #expect(tea.workStates == [.onBreak])
        #expect(tea.notableEventTypes.first == .breakStarted)
        #expect(tea.contains(.setOnBreak(true)))
        #expect(!tea.notableEventTypes.contains(.longDriftStarted))
        let back = day.effects(from: Self.minutes(95), to: Self.minutes(95))
        #expect(back.notableEventTypes == [.breakEnded, .returned])
        #expect(back.events(.breakEnded).first?.value == 300)
        #expect(back.events(.returnGrowth).isEmpty)
        #expect(back.returns == [.small])
        #expect(back.contains(.setOnBreak(false)))
    }

    @Test func theNewStageIsCuedAtOnceAndMokuCelebratesItAtTheBreak() {
        let day = Self.day
        let reached = day.events(.milestone).map(\.t)
        #expect(reached.count == 1)
        #expect(day.firstTime { $0 == .celebrateStage(.youngTree) } == reached.first)
        #expect(reached.first! < Self.minutes(90))
        let atTheBreak = day.effects(from: Self.minutes(90), to: Self.minutes(90, 5))
        #expect(atTheBreak.gestures.contains(.celebrate))
        #expect(atTheBreak.moods.first == .happy)
        #expect(atTheBreak.lines.isEmpty)  // no words over its head (the friends, 2026-10-14)
    }

    @Test func aBreakIsSuggestedAfterFiftyMinutesOfWork() {
        let day = Self.day
        let breaks = day.events(.breakSuggested)
        #expect(breaks.count == 1)
        #expect(day.effects(from: breaks[0].t, to: breaks[0].t).gestures == [.drinkWater])
    }

    @Test func aMeetingHidesMokuAndFreezesEverything() {
        let day = Self.day
        let meeting = day.effects(from: Self.minutes(70), to: Self.minutes(79, 59))
        // The call window comes to the front a moment before the call is known: a sniff, then Moku hides.
        #expect(meeting.commands == [.perform(.sniff), .dismissSpeech, .setHidden(true)])
        #expect(meeting.events.isEmpty)
        // Back once the call has been over for half a minute.
        #expect(day.effects(from: Self.minutes(80), to: Self.minutes(80, BehaviorEngine.meetingHoldSec - 1)).hiddenChanges.isEmpty)
        #expect(day.effects(from: Self.minutes(80, BehaviorEngine.meetingHoldSec), to: Self.minutes(80, BehaviorEngine.meetingHoldSec)).hiddenChanges == [false])
    }

    @Test func aPatDuringADriftCalmsEverythingDown() {
        let day = Self.day
        let pat = day.effects(from: Self.minutes(86, 30), to: Self.minutes(86, 30))
        #expect(pat.gestures == [.patReaction])  // Moku hadn't stood up yet: that's four minutes in
        #expect(pat.feedback.map(\.kind) == [.pat])
        #expect(pat.notableEventTypes == [.patted])
        // The patted site is work now: no escalation afterwards.
        #expect(day.effects(from: Self.minutes(86, 31), to: Self.minutes(88)).lines.isEmpty)
    }

    @Test func theForestReachesANewStage() {
        let day = Self.day
        let milestones = day.events(.milestone)
        #expect(milestones.map(\.event.value) == [Double(ForestStage.youngTree.rawValue)])
        #expect(day.effects.contains { $0.effect == .celebrateStage(.youngTree) })
        #expect(ForestStage.at(points: day.endPoints) == .youngTree)
    }

    @Test func theDayEndsCalm() {
        let status = Self.day.finalStatus
        #expect(status?.phase == .focused)
        #expect(status?.mood == .content)
        #expect(status?.atHome == true)
    }

    @Test func theTimelineReadsLikeTheDay() {
        let lines = Timeline.lines(Self.day)
        #expect(lines.contains("t=30:11  mood disappointed"))
        #expect(lines.contains("t=30:11  look at the user"))
        #expect(!lines.contains { $0.contains("mood annoyed") })  // sad only
        #expect(lines.contains("t=34:01  perform standUp"))
        #expect(lines.contains("t=40:01  event nudged"))  // the ask: standing tall, no words (the friends, 2026-10-14)
        #expect(lines.contains("t=40:01  lantern: longDrift"))
        #expect(lines.contains("t=48:00  celebrate the return (full)"))
        #expect(lines.contains("t=70:00  hide"))
        #expect(lines.contains("t=90:00  lantern: onBreak"))
    }

    @Test func aDayOfUnknownVerdictsNeverEscalates() {
        var script = ScriptedDay.standard
        // The brain can't make up its mind about YouTube, X or Reddit all day.
        script.moments = script.moments.map { moment in
            guard case var .use(place) = moment.action, place.judged == .drifting else { return moment }
            place.judged = .unknown
            var changed = moment
            changed.action = .use(place)
            return changed
        }
        let day = DayReplay.run(script)
        let effects = day.effects.map(\.effect)
        #expect(!effects.contains { $0.isEvent(.longDriftStarted) || $0.isEvent(.nudged) || $0.isEvent(.shortDrift) })
        #expect(!effects.moods.contains(.concerned))
        #expect(!effects.moods.contains(.curious))
        #expect(effects.lines.allSatisfy { $0.tone == .warm || $0.tone == .cheerful })
    }
}
