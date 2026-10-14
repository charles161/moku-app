import Foundation
import Testing
@testable import MokuKit

@Test func thinkingStatusIsQuietUntilTheCloudHasRestedTwoMinutes() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(ThinkingStatus.from(answering: false, judge: "ok", since: nil, now: now) == .brainDown)
    #expect(ThinkingStatus.from(answering: true, judge: "ok", since: nil, now: now) == .fine)
    #expect(ThinkingStatus.from(answering: true, judge: nil, since: nil, now: now) == .fine)  // an older brain
    #expect(ThinkingStatus.from(answering: true, judge: "backoff", since: now.addingTimeInterval(-90), now: now) == .fine)
    #expect(ThinkingStatus.from(answering: true, judge: "backoff", since: now.addingTimeInterval(-120), now: now) == .cloudResting)
    #expect(ThinkingStatus.from(answering: true, judge: "paused", since: now, now: now) == .accessRefused)
    #expect(ThinkingStatus.from(answering: true, judge: "backoff", since: now.addingTimeInterval(-300), local: "running", now: now) == .thinkingOnMac)
    #expect(ThinkingStatus.from(answering: true, judge: "paused", since: now, local: "running", now: now) == .thinkingOnMac)
    #expect(ThinkingStatus.from(answering: true, judge: "backoff", since: now.addingTimeInterval(-300), local: "downloading", now: now) == .cloudResting)
    #expect(ThinkingStatus.fine.line == nil)
    // A refused Mac (the trial ended) was told "the access key was refused": nobody ever held a key. The popover says so plainly and links Settings.
    #expect(ThinkingStatus.accessRefused.line?.contains("key") == false && ThinkingStatus.accessRefused.line?.contains("isn’t on for this Mac") == true)
    #expect(ThinkingStatus.cloudResting.line?.contains("usual work apps") == true)
}

// The governor (docs/specs/governor.md): this Mac's daily share of the online brain is used. The relay's answer is
// not a blip, so it's said at once, plainly, without the Settings link (nothing there would change it).
@Test func aDailyShareUsedSaysForTheRestOfTodayAtOnce() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(ThinkingStatus.from(answering: true, judge: "resting", since: now, now: now) == .restingToday)
    #expect(ThinkingStatus.from(answering: true, judge: "resting", since: now, local: "running", now: now) == .thinkingOnMac)
    #expect(ThinkingStatus.restingToday.line == "Moku’s thinking offline for the rest of today. It still knows your usual work apps.")
}

@Test func accessStatusCountsTrialDaysAndSaysSoPlainly() {
    let start = Date(timeIntervalSince1970: 1_000_000), end = start.addingTimeInterval(21 * 86_400)
    let trial = AccessStatus(plan: .trial, expiresAt: end)
    #expect(trial.daysLeft(now: start) == 21)
    #expect(trial.daysLeft(now: end.addingTimeInterval(-3_600)) == 1)
    #expect(trial.line(now: end.addingTimeInterval(-3_600)) == "Free trial: the last day of Moku’s cloud brain.")
    #expect(trial.line(now: start) == "Free trial: 21 days of Moku’s cloud brain left.")
    #expect(trial.daysLeft(now: end.addingTimeInterval(10)) == 0)
    #expect(trial.line(now: end.addingTimeInterval(10)).contains("has ended"))
    #expect(AccessStatus(plan: .tester).daysLeft() == nil)
}

@Test func forestStagesFollowThresholds() {
    #expect(ForestStage.at(points: 0) == .seed)
    #expect(ForestStage.at(points: 29.9) == .seed)
    #expect(ForestStage.at(points: 30) == .sprout)
    #expect(ForestStage.at(points: 50_000) == .ancientForest)
    #expect(ForestStage.progress(points: 75) == 0.5)
    #expect(ForestStage.progress(points: 50_000) == 1)
}

@Test func verdictDecodesBrainJSON() throws {
    let json = """
    {"sampleId":"s1","state":"working","thread":{"id":"t1","title":"DSA · Trees"},"isNewThread":false,
     "confidence":0.93,"source":"jev","reason":"LeetCode trees problem","latencyMs":640}
    """
    let verdict = try MokuJSON.decoder().decode(Verdict.self, from: Data(json.utf8))
    #expect(verdict.state == .working)
    #expect(verdict.thread?.title == "DSA · Trees")
    #expect(verdict.goal == nil && !verdict.isSwitch)
}

@Test func verdictCarriesTheGoalAndASwitch() throws {
    // Goal-aware judging: another goal than the current one is a switch, calm, and names its goal.
    let json = """
    {"sampleId":"s2","state":"working","thread":{"id":"t2","title":"Potluck side project","provisional":false},"isNewThread":false,
     "confidence":0.8,"source":"jev","reason":"[goal] p=0.80","latencyMs":512,"activity":null,"completion":null,"category":"building",
     "goal":{"id":"t2","title":"Potluck side project","provisional":false},"switch":true}
    """
    let verdict = try MokuJSON.decoder().decode(Verdict.self, from: Data(json.utf8))
    #expect(verdict.goal?.title == "Potluck side project")
    #expect(verdict.isSwitch)
    let again = try MokuJSON.decoder().decode(Verdict.self, from: try MokuJSON.encoder().encode(verdict))
    #expect(again == verdict)
    let object = try JSONSerialization.jsonObject(with: try MokuJSON.encoder().encode(verdict)) as? [String: Any]
    #expect(object?["switch"] as? Bool == true)
}

@Test func datesTravelAsEpochMilliseconds() throws {
    let event = CompanionEvent(ts: Date(timeIntervalSince1970: 1_758_000_000), type: .returnGrowth, value: 2)
    let data = try MokuJSON.encoder().encode(event)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect((object?["ts"] as? Double) == 1_758_000_000_000)
    #expect(try MokuJSON.decoder().decode(CompanionEvent.self, from: data) == event)
}

@Test func fractionalDatesEncodeAsWholeMilliseconds() throws {
    let event = CompanionEvent(ts: Date(timeIntervalSince1970: 1_790_000_000.123456), type: .nudged)
    let json = String(decoding: try MokuJSON.encoder().encode(event), as: UTF8.self)
    #expect(json.contains("\"ts\":1790000000123"))
    #expect(!json.contains("1790000000123."))
}

@Test func threadRefProvisionalDefaultsToFalse() throws {
    let named = try MokuJSON.decoder().decode(ThreadRef.self, from: Data(#"{"id":"t1","title":"DSA · Trees"}"#.utf8))
    #expect(named.provisional == false)
    let placeholder = try MokuJSON.decoder().decode(ThreadRef.self, from: Data(#"{"id":"t1","title":"Code · a.py","provisional":true}"#.utf8))
    #expect(placeholder.provisional)
}

@Test func usageValuesTravelAsPlainJSONValues() throws {
    let props: [String: UsageValue] = ["first_launch": .bool(true), "ram_gb": .int(16), "launched_by": .word("login")]
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let json = String(decoding: try encoder.encode(props), as: UTF8.self)
    #expect(json == #"{"first_launch":true,"launched_by":"login","ram_gb":16}"#)
    #expect(try JSONDecoder().decode([String: UsageValue].self, from: Data(json.utf8)) == props)
}
