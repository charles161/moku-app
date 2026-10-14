import Foundation
import MokuKit
import Testing
@testable import MokuMind

@Suite("Remote flags: forceCalm")
struct ForceCalmTests {
    /// 20 focused minutes with forceCalm on, then a drift of `seconds` starting at t = 1200.
    static func calmDrift(for seconds: Double) -> EngineHarness {
        var h = EngineHarness()
        h.work(1_200)
        _ = h.engine.setForceCalm(true, now: h.now)
        h.drift(seconds)
        return h
    }

    @Test func mokuNeverReactsToADriftButStillRecordsIt() {
        let h = Self.calmDrift(for: 1_300)  // past the ask and the ignored-nudge report
        let drifting = h.effects(from: 1_200, to: 2_500)
        #expect(drifting.moods.isEmpty)
        #expect(drifting.gestures.isEmpty)
        #expect(drifting.lines.isEmpty)
        #expect(drifting.moves.isEmpty)
        #expect(!drifting.gazes.contains(.user))
        #expect(drifting.workStates == [.grace])  // the lantern stays lit, no drift expressions
        #expect(drifting.notableEventTypes == [.longDriftStarted])  // recorded, but no nudge
        #expect(drifting.feedback.isEmpty)
        #expect(h.status.phase == .drifting)
        #expect(h.status.focusStreakSec == 0)  // a long drift still ends the streak
    }

    @Test func mokuIsStillGladWhenYouComeBack() {
        var h = Self.calmDrift(for: 610)
        let back = h.send(.verdict(h.verdict(.working)))
        #expect(back.moods == [.happy])
        #expect(back.returns == [.full])
        #expect(back.lines.isEmpty)  // glad without words (the friends, 2026-10-14)
        #expect(back.gestures.isEmpty)  // it never stood up
        #expect(back.notableEventTypes == [.returned])
        #expect(back.feedback.isEmpty)  // no nudge, so no "returned after the nudge"
        #expect(h.pass(6, judging: .working).moods == [.content])
    }

    @Test func turnedOnMidDriftMokuSettlesAtOnce() {
        var h = LongDriftTests.driftingAfterFocus(for: 610)  // standing, past the ten-minute step
        let calming = h.engine.setForceCalm(true, now: h.now)
        #expect(calming.gestures == [.sitDown])
        #expect(calming.moods.isEmpty)  // the face was normal already, since the look back
        #expect(h.engine.mood == .content)
        #expect(!calming.gazes.contains(.user))  // eyes on the work already, since the one look at you
        #expect(h.engine.attentionTarget != .user)
        #expect(calming.workStates == [.grace])
        let after = h.pass(900, judging: .drifting)
        #expect(after.moods.isEmpty && after.gestures.isEmpty && after.lines.isEmpty && after.workStates.isEmpty)
        // The nudge that was said still gets its report.
        #expect(after.feedback.map(\.kind) == [.ignoredNudge])
    }

    @Test func offAgainTheNextDriftReactsAsBefore() {
        var h = Self.calmDrift(for: 120)
        h.work(600)
        #expect(h.engine.setForceCalm(false, now: h.now).isEmpty)
        let drifting = h.drift(90)
        #expect(drifting.moods == [.disappointed, .content])  // the one sad move, then the normal face
        #expect(drifting.gestures == [.sigh])
        #expect(drifting.gazes == [.user, .wander])  // the look at you, then the work
    }

    @Test func theDefaultChangesNothing() {
        func day(touchingTheSwitch: Bool) -> [EngineEffect] {
            var h = EngineHarness()
            if touchingTheSwitch { #expect(h.engine.setForceCalm(false, now: h.now).isEmpty) }
            h.work(1_200)
            h.drift(700)
            h.send(.verdict(h.verdict(.working)))
            h.work(600)
            return h.allEffects
        }
        #expect(!EngineHarness().engine.forceCalm)
        #expect(day(touchingTheSwitch: true) == day(touchingTheSwitch: false))
    }
}

@MainActor
@Suite("Remote flags: the runtime")
struct ForceCalmRuntimeTests {
    @Test func forceCalmReachesTheEngineAndOutlastsManualControl() {
        let (senses, feed) = AsyncStream.makeStream(of: SenseEvent.self)
        let runtime = CompanionRuntime(senses: senses, brain: FakeBrain(), stage: FakeStage(), world: FakeWorld(), worldModel: WorldModel(), clock: ManualClock())
        runtime.setForceCalm(true)
        #expect(runtime.engine.forceCalm)
        runtime.setManualControl(true)
        runtime.setManualControl(false)  // a fresh engine
        #expect(runtime.engine.forceCalm)
        runtime.setForceCalm(false)
        #expect(!runtime.engine.forceCalm)
        feed.finish()
    }
}

@Suite("Remote flags: the values")
struct RemoteFlagsValueTests {
    func decode(_ json: String) throws -> RemoteFlags { try JSONDecoder().decode(RemoteFlags.self, from: Data(json.utf8)) }

    @Test func aMissingOrMistypedKeyKeepsItsDefaultAndUnknownKeysAreIgnored() throws {
        #expect(try decode("{}") == .standard)
        #expect(try decode(#"{"forceCalm":true,"minVersion":"0.1.9","callsPerDay":5,"somethingNew":[1]}"#) == RemoteFlags(forceCalm: true, minVersion: "0.1.9"))
        #expect(try decode(#"{"cloudJudging":"no","minVersion":null}"#) == .standard)
        #expect(RemoteFlags.standard == RemoteFlags(cloudJudging: true, cloudVoice: true, forceCalm: false, minVersion: nil))
    }

    @Test func minVersionComparesVersionsNumerically() {
        let flags = RemoteFlags(minVersion: "0.1.10")
        #expect(flags.requiresUpdate(from: "0.1.7"))
        #expect(flags.requiresUpdate(from: "0.1.9"))
        #expect(!flags.requiresUpdate(from: "0.1.10"))
        #expect(!flags.requiresUpdate(from: "0.2"))
        #expect(!flags.requiresUpdate(from: "1.0.0"))
        #expect(RemoteFlags(minVersion: "0.2").requiresUpdate(from: "0.1.99"))
        #expect(!RemoteFlags.standard.requiresUpdate(from: "0.0.1"))
    }

    @Test func withCloudJudgingOffThePopoverSaysMokuIsThinkingOfflineAtOnce() {
        let off = RemoteFlags(cloudJudging: false)
        for status in [ThinkingStatus.fine, .cloudResting, .accessRefused] { #expect(off.thinkingStatus(from: status) == .cloudResting) }
        #expect(off.thinkingStatus(from: .brainDown) == .brainDown)
        #expect(off.thinkingStatus(from: .thinkingOnMac) == .thinkingOnMac)
        for status in [ThinkingStatus.fine, .cloudResting, .accessRefused, .brainDown, .thinkingOnMac] {
            #expect(RemoteFlags.standard.thinkingStatus(from: status) == status)
        }
        #expect(ThinkingStatus.cloudResting.line == "Moku’s thinking offline for now. It still knows your usual work apps.")
    }
}

@MainActor
@Suite("Remote flags: asking the relay")
struct RemoteFlagsClientTests {
    let device = String(repeating: "e", count: 64)

    struct Asked { var url: String; var token: String; var body: [String: String] }

    func store() -> UserDefaults { UserDefaults(suiteName: "moku-flags-\(UUID().uuidString)")! }

    func client(_ defaults: UserDefaults, answer: LockedBox<(String, Int)> = LockedBox(("{}", 200)), asked: LockedBox<[Asked]> = LockedBox([]),
                token: String? = "moku1.payload.sig", version: String = "0.1.8", now: LockedBox<Date> = LockedBox(Date(timeIntervalSince1970: 1_790_000_000)),
                offline: Bool = false) -> RemoteFlagsClient {
        RemoteFlagsClient(defaults: defaults, relay: URL(string: "https://relay.example")!, device: device, appVersion: version, token: { token },
                          post: { url, body, token in
                              if offline { throw URLError(.notConnectedToInternet) }
                              asked.mutate { $0.append(Asked(url: url.absoluteString, token: token, body: try! JSONSerialization.jsonObject(with: body) as! [String: String])) }
                              return (Data(answer.value.0.utf8), answer.value.1)
                          }, now: { now.value })
    }

    @Test func asksWithTheTokenSendingOnlyTheDeviceAndVersionAndKeepsTheAnswer() async {
        let defaults = store(), asked = LockedBox<[Asked]>([])
        let answer = LockedBox((#"{"cloudJudging":false,"cloudVoice":true,"forceCalm":true,"minVersion":null}"#, 200))
        let flags = client(defaults, answer: answer, asked: asked)
        var changes: [RemoteFlags] = []
        flags.onChange = { changes.append($0) }
        #expect(flags.current == .standard)
        #expect(await flags.refresh() == RemoteFlags(cloudJudging: false, forceCalm: true))
        #expect(asked.value.count == 1)
        #expect(asked.value[0].url == "https://relay.example/v1/flags" && asked.value[0].token == "moku1.payload.sig")
        #expect(asked.value[0].body == ["device": device, "version": "0.1.8"])
        await flags.refresh()  // the same answer: no change to hear
        #expect(changes == [RemoteFlags(cloudJudging: false, forceCalm: true)])
        // A restart starts from the last answer.
        #expect(client(defaults).current == RemoteFlags(cloudJudging: false, forceCalm: true))
    }

    @Test func withoutANewAnswerTheLastOneStays() async {
        let defaults = store(), asked = LockedBox<[Asked]>([])
        let answer = LockedBox((#"{"forceCalm":true}"#, 200))
        await client(defaults, answer: answer).refresh()
        for failure in [("{}", 401), ("not found", 404), ("<html>", 200), ("{}", 500)] {
            answer.mutate { $0 = failure }
            #expect(await client(defaults, answer: answer).refresh().forceCalm)
        }
        #expect(await client(defaults, offline: true).refresh().forceCalm)
        // No token (no access yet): nothing to ask with.
        #expect(await client(defaults, asked: asked, token: nil).refresh().forceCalm)
        #expect(asked.value.isEmpty)
    }

    @Test func belowMinVersionSparkleIsAskedAtMostHourly() async {
        let now = LockedBox(Date(timeIntervalSince1970: 1_790_000_000))
        let answer = LockedBox((#"{"minVersion":"0.1.9"}"#, 200))
        let flags = client(store(), answer: answer, version: "0.1.8", now: now)
        var checks = 0
        flags.checkForUpdates = { checks += 1 }
        await flags.refresh()
        await flags.refresh()
        #expect(checks == 1)
        now.mutate { $0 = $0.addingTimeInterval(3_601) }
        await flags.refresh()
        #expect(checks == 2)
        answer.mutate { $0 = (#"{"minVersion":"0.1.8"}"#, 200) }
        now.mutate { $0 = $0.addingTimeInterval(3_601) }
        await flags.refresh()
        #expect(checks == 2)  // this build is new enough
    }
}
