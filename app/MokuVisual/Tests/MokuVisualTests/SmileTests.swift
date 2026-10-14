import Foundation
import Testing
@testable import MokuVisual
import MokuKit

// Charles: "sometimes it looks like moku isnt even smiling" (docs/specs/characters-perfect.md, "Moku: built").

@Test func aClipStartsAndEndsOnTheMoodsFace() {
    // A clip authored from a content face (lids 0.18 down, smile 0.3) leaves a happy face as it is on its first frame.
    #expect(ClipFace.weight(mood: 0.85, clip: 0, start: 0, name: "eyes_happy", pleased: true) == 0.85)
    #expect(ClipFace.weight(mood: 0, clip: 0.18, start: 0.18, name: "blink_L", pleased: true) == 0)
    #expect(ClipFace.weight(mood: 1, clip: 0.3, start: 0.3, name: "smile", pleased: true) == 1)
}

@Test func aClipMovesTheFaceByTheSameShare() {
    // Up by the same share of the room left: a clip's lids from 0.18 to 1 close the mood's open lids fully.
    #expect(abs(ClipFace.weight(mood: 0, clip: 1, start: 0.18, name: "blink_L", pleased: false) - 1) < 1e-5)
    // Down by the same share of the way to zero: a cheer's smile from 0.3 to 0 takes a happy smile to 0 (its open smile
    // takes over).
    #expect(abs(ClipFace.weight(mood: 1, clip: 0, start: 0.3, name: "smile", pleased: true)) < 1e-5)
    #expect(abs(ClipFace.weight(mood: 0.4, clip: 0.15, start: 0.3, name: "frown", pleased: false) - 0.2) < 1e-5)
}

@Test func inAPleasedMoodAClipNeverTakesTheSmileAway() {
    for name in SmileChannels.floor {
        #expect(ClipFace.weight(mood: 0.6, clip: 0, start: 0.5, name: name, pleased: true) == 0.6)
        #expect(ClipFace.weight(mood: 0.6, clip: 0, start: 0.5, name: name, pleased: false) < 0.6)
    }
    #expect(Mood.content.isPleased && Mood.happy.isPleased && Mood.proud.isPleased)
    #expect(!Mood.curious.isPleased && !Mood.disappointed.isPleased && !Mood.sleepy.isPleased)
}

@Test func thePleasedSlowBlinkClosesIntoArcsAndNeitherItNorTheLookUpSmileUsesLids() {
    let shapes: Set<String> = ["eyes_happy", "blink_L", "blink_R", "smile", "lid_smile_lower", "cheeks_raise", "blush_more"]
    for progress in stride(from: 0.05, to: 1, by: 0.05) {
        let blink = MicroSample(.slowBlink, progress: progress, shapes: shapes, pleased: true)
        #expect(blink.weights["blink_L"] == nil && blink.weights["blink_R"] == nil)
        let smile = MicroSample(.smile, progress: progress, shapes: shapes, pleased: true)
        #expect(smile.weights["blink_L"] == nil && smile.weights["blink_R"] == nil)
    }
    #expect((MicroSample(.slowBlink, progress: 0.45, shapes: shapes, pleased: true).weights["eyes_happy"] ?? 0) > 0.9)
    // A drift's slow blink is still lids.
    #expect((MicroSample(.slowBlink, progress: 0.45, shapes: shapes, pleased: false).weights["blink_L"] ?? 0) > 0.9)
}

/// Closed happy eyes are a pat's (Charles, 2026-10-08: "moku seems to close his eyes kinda even without me patting it").
/// The look-up smile and Moku's proud face, which come by themselves while you work, keep its eyes open.
@Test func theLookUpSmileAndTheProudFaceKeepTheEyesOpen() throws {
    let shapes: Set<String> = ["eyes_happy", "eyes_proud", "blink_L", "blink_R", "smile", "lid_smile_lower", "cheeks_raise", "blush_more"]
    for progress in stride(from: 0.05, to: 1, by: 0.05) {
        let smile = MicroSample(.smile, progress: progress, shapes: shapes, pleased: true)
        #expect((smile.weights["eyes_happy"] ?? 0) == 0 && (smile.weights["lid_smile_lower"] ?? 0) == 0)
        #expect(progress < 0.3 || progress > 0.7 || (smile.weights["smile"] ?? 0) > 0.2)  // still a smile
    }
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../assets/character/moods.json").standardized
    let moods = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])["moods"] as? [String: [String: Any]]
    let proud = try #require(moods?["proud"]?["blendShapes"] as? [String: Double])
    #expect((proud["eyes_happy"] ?? 0) == 0 && (proud["eyes_proud"] ?? 0) == 0 && (proud["smile"] ?? 0) > 0.5)
}

@Test func contentLidsAlwaysKeepTheSmile() {
    // Upper lids lowered on their own read as tired at 100 px: every content setting that lowers them raises the lower lids.
    for lids in LidTension.choices(for: .content) where (lids["blink_L"] ?? 0) > 0 || (lids["blink_R"] ?? 0) > 0 {
        #expect((lids["lid_smile_lower"] ?? 0) > 0)
    }
}

@Test func intoArcsTheSmileLeadsAndTheEyesCloseQuickly() {
    let bridge = SmileBridge(fromArcs: 0, toArcs: 0.85, toPleased: true, duration: 0.6)
    #expect(bridge.way == .intoArcs)
    // The lower lids are up (a smiling squint) before the arcs start closing, and the arcs close in a quarter second.
    #expect(bridge.squint(age: bridge.arcsAt) > 0.59)
    #expect(bridge.progress("eyes_happy", age: bridge.arcsAt) == 0)
    #expect(bridge.progress("eyes_happy", age: bridge.arcsAt + bridge.arcSeconds) == 1)
    #expect(bridge.arcSeconds <= 0.25)
    // A sad face clears in the first half.
    #expect(bridge.progress("frown", age: 0.3) == 1)
    // Everything leaves and lands with no jump.
    for name in ["eyes_happy", "frown", "smile"] {
        #expect(bridge.progress(name, age: 0) == 0 && bridge.progress(name, age: 0.6) == 1)
        var previous: Float = 0
        for step in 1...600 {
            let value = bridge.progress(name, age: 0.6 * Double(step) / 600)
            #expect(value >= previous && value - previous < 0.02)
            previous = value
        }
    }
    let out = SmileBridge(fromArcs: 0.85, toArcs: 0, toPleased: true, duration: 1.2)
    #expect(out.way == .outOfArcs && out.progress("eyes_happy", age: out.arcsAt + out.arcSeconds) == 1)
    #expect(out.squint(age: out.arcsAt + out.arcSeconds) > 0.59 && out.squint(age: 1.2) < 0.001)
    // Out of arcs into a drift: no squint.
    #expect(SmileBridge(fromArcs: 0.85, toArcs: 0, toPleased: false, duration: 3).way == .none)
}

// Moku's talents (next-wave.md §2), seated.

@Test func theComebackBounceStartsAndEndsAtRestAndStaysSeated() {
    let keys = HappyBounce.keys
    #expect(keys.first?.t == 0 && keys.last?.t == 1)
    #expect(keys.first?.lift == 0 && keys.first?.stretch == 1 && keys.last?.lift == 0 && keys.last?.stretch == 1)
    // A bounce on the spot: a few points up, never a hop away, and the squash keeps its volume within a few percent.
    #expect(keys.allSatisfy { $0.lift >= 0 && $0.lift <= 8 && abs($0.stretch - 1) <= 0.07 })
    #expect(HappyBounce.earLag(at: 0) == 0 && HappyBounce.earLag(at: HappyBounce.seconds + 0.4) == 0)
    var previous: Float = 0
    for n in 1...90 {
        let lag = HappyBounce.earLag(at: Double(n) / 60)
        #expect(abs(lag - previous) <= 0.025, "the ears turn under 1.5 degrees a frame at 60 fps")
        previous = lag
    }
}

@MainActor @Test func thePetalsTwirlInsideMokusWindowAndFadeAway() {
    let centre = CGPoint(x: StageGeometry.characterFrame.midX, y: StageGeometry.feet.y), count = PetalTwirl.colours.count
    for i in 0..<count {
        #expect(PetalTwirl.state(i, of: count, at: 0, centre: centre).opacity == 0)
        #expect(PetalTwirl.state(i, of: count, at: 1, centre: centre).opacity < 0.001)
        for step in 0...60 {
            let state = PetalTwirl.state(i, of: count, at: Double(step) / 60, centre: centre)
            #expect(state.point.x > 0 && state.point.x < StageGeometry.size.width && state.point.y > 0 && state.point.y < StageGeometry.size.height)
        }
    }
}

/// A minute of focus reads smile, ear, foot, smile: the little moves come about 20 and 40 s after the look-up, never with
/// it (Charles, 2026-10-06: "make sure its midway like into 20-40-60 seconds").
@Test func theLittleMovesComeBetweenTheMinutesSmiles() {
    var schedule = LittleMoveSchedule(nextEar: 5, nextMove: 9)  // both due early, as after a launch
    var ears: [Double] = [], moves: [Double] = []
    var t = 0.0
    while t < 180 {
        let smiling = t.truncatingRemainder(dividingBy: 60) < 3  // the look-up and smile, every minute, 3 s long
        if smiling { schedule.moment(at: t) }
        else {
            if t >= schedule.nextEar { ears.append(t); schedule.earDone(at: t, every: 20, jitter: 1) }
            if t >= schedule.nextMove { moves.append(t); schedule.moveDone(at: t, every: 25, jitter: 1) }
        }
        t = (t + 0.1).rounded(toPlaces: 1)
    }
    let all = (ears + moves).sorted()
    // Never during or right after a smile: nothing in the 15 s after one ends.
    #expect(all.allSatisfy { $0.truncatingRemainder(dividingBy: 60) >= 3 + 15 })
    // Never two little moves within 12 s of each other.
    #expect(zip(all, all.dropFirst()).allSatisfy { $1 - $0 >= 12 - 0.01 })
    // Each minute has its ear around 20 s and its paw or foot around 40 s.
    for minute in 0..<3 {
        let start = Double(minute) * 60
        #expect(ears.contains { $0 >= start + 18 && $0 <= start + 30 })
        #expect(moves.contains { $0 >= start + 38 && $0 <= start + 50 })
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double { let p = pow(10, Double(places)); return (self * p).rounded() / p }
}
