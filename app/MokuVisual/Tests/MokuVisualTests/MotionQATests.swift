import AppKit
import Testing
import MokuKit
@testable import MokuVisual

/// Launch QA, lens 4 (docs/specs/launch-qa.md): the judge the demo's `--qa-motion` uses, and the fixes it found.
@MainActor
@Suite("Motion QA: the judge and what it found", .serialized)
struct MotionQATests {
    // MARK: The judge

    private func trace(frames: Int, gap: Double = 1.0 / 60, joints: [String] = ["head", "arm_L"], _ edit: (Int, inout QATrace.Frame) -> Void) -> QATrace {
        let t = QATrace(folder: nil)
        t.name(joints: joints)
        for i in 0..<frames {
            var frame = QATrace.Frame(t: Double(i) * gap, gap: i == 0 ? 0 : gap, turns: [Float](repeating: 0, count: joints.count), face: [:], motion: 0.4, coverage: 0.1, box: CGRect(x: 0.3, y: 0.2, width: 0.3, height: 0.5))
            edit(i, &frame)
            t.add(frame)
        }
        return t
    }
    private func judge(_ t: QATrace, machine: Bool = false) -> [QAFinding] {
        let end = (t.frames.last?.t ?? 0) + 0.1
        return QAJudge.judge(t, beats: [QABeat(name: "beat", t0: 0, t1: end)], machine: machine).flatMap(\.findings)
    }

    @Test func aSmoothTurnIsNotFlagged() {
        let smooth = trace(frames: 30) { i, f in f.turns = [Float(sin(Double(i) / 29 * .pi)) * 2, 0] }
        #expect(judge(smooth).isEmpty)
    }

    @Test func aJointThatJumpsInOneFrameIsASnap() {
        let snap = trace(frames: 30) { i, f in f.turns = [i == 15 ? 9 : 0.4, 0] }
        let found = judge(snap)
        #expect(found.contains { $0.kind == "joint snap" && $0.detail.contains("head") })
    }

    @Test func aJointThatStopsForAFrameInsideATurnIsAStall() {
        let stall = trace(frames: 30) { i, f in f.turns = [i == 15 ? 0 : 3, 0] }
        #expect(judge(stall).contains { $0.kind == "joint stall" })
    }

    @Test func aFrameHeldWhileMovingIsFlagged() {
        let held = trace(frames: 30) { i, f in if i == 15 { f.gap = 0.07 } }
        #expect(judge(held).contains { $0.kind == "held" })
    }

    @Test func aStillFrameBetweenMovingOnesIsAStutterExceptInABlink() {
        let still = trace(frames: 30) { i, f in f.motion = i == 15 ? 0 : 0.4 }
        #expect(judge(still).contains { $0.kind == "stutter" })
        // A display collapses its eyes, holds the line for a frame and opens them: that's its blink.
        let blink = trace(frames: 30) { i, f in f.motion = i == 15 ? 0 : 0.4 }
        blink.note("px_blink", at: 14.0 / 60)
        #expect(!judge(blink, machine: true).contains { $0.kind == "stutter" })
    }

    @Test func aFaceWeightThatJumpsOrStepsInsideARampIsFlagged() {
        let jump = trace(frames: 30) { i, f in f.face = ["eyes_happy": i < 15 ? 0 : 1] }
        #expect(judge(jump).contains { $0.kind == "face snap" && $0.detail.contains("eyes_happy") })
        // 0.1 a frame, held for one frame, then 0.1 a frame again.
        let stair = trace(frames: 30) { i, f in f.face = ["smile": i < 10 ? Float(i) * 0.04 : i == 10 ? 0.36 : Float(i - 1) * 0.04] }
        #expect(judge(stair).contains { $0.kind == "face stair" })
        let ramp = trace(frames: 30) { i, f in f.face = ["smile": Float(i) * 0.03] }
        #expect(judge(ramp).isEmpty)
    }

    @Test func aBlinkMayMoveTheLidsAndTheEyesAtOnce() {
        let blink = trace(frames: 30) { i, f in f.face = ["blink_L": i == 15 ? 1 : 0, "lid_smile_lower": i < 15 ? 0.6 : 0] }
        #expect(!judge(blink).contains { $0.kind == "face snap" })
    }

    @Test func theCharacterJumpingAcrossTheFrameIsAPop() {
        let pop = trace(frames: 30) { i, f in if i >= 15 { f.box = CGRect(x: 0.5, y: 0.2, width: 0.3, height: 0.5) } }
        #expect(judge(pop).contains { $0.kind == "picture pop" })
    }

    @Test func aWindowThatVanishesOutrightIsAStepButAFadeIsNot() {
        func samples(_ label: [Double]) -> QATrace {
            let t = trace(frames: 4) { _, _ in }
            for (i, alpha) in label.enumerated() {
                t.add(QATrace.Sample(t: Double(i) * 0.008, panel: 1, speech: 0, label: alpha, breakTimer: 0, origin: .zero, layerShift: .zero, layerScale: 1, layerTilt: 0, layerOpacity: 1))
            }
            return t
        }
        // The old label swap: 1.0 to 0 in a step. The new one fades (a quick start is 0.57 in the first sample).
        #expect(judge(samples([1, 1, 0, 0])).contains { $0.kind == "window step" && $0.detail.contains("thread label") })
        #expect(!judge(samples([1, 0.57, 0.3, 0])).contains { $0.kind == "window step" })
    }

    // MARK: What it found

    @Test func theHoverDelightEasesOnTheClockWhateverTheFrameBefore() {
        // The first frame after the renderer slept used to take all of it. Now the age is the pointer's, so a frame drawn
        // 20 ms after it arrived shows almost none.
        #expect(HoverDelight.strength(from: 0, rising: true, age: 0.02) < 0.05)
        #expect(HoverDelight.strength(from: 0, rising: true, age: 0.15) > 0.3 && HoverDelight.strength(from: 0, rising: true, age: 0.15) < 0.7)
        #expect(HoverDelight.strength(from: 0, rising: true, age: 0.3) == 1)
        #expect(HoverDelight.strength(from: 1, rising: false, age: 0.4) == 0)
        // In and out quickly: it leaves from where it was, never from 0 or 1.
        #expect(HoverDelight.strength(from: 0.4, rising: false, age: 0) == 0.4)
        var last: Float = 0
        for step in 0...30 { let s = HoverDelight.strength(from: 0, rising: true, age: Double(step) / 100); #expect(s >= last); last = s }
    }

    @Test func accentsOnThePaperReadWithIncreaseContrast() {
        func ratio(_ a: NSColor, _ b: NSColor) -> Double {
            func lin(_ c: CGFloat) -> Double { let c = Double(c); return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            func lum(_ c: NSColor) -> Double { let c = c.usingColorSpace(.sRGB)!; return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent) }
            let (x, y) = (lum(a), lum(b)); return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        let saved = ContrastPreference.override
        defer { ContrastPreference.override = saved }
        for dark in [false, true] {
            for tone in SpeechLine.Tone.allCases {
                ContrastPreference.override = false
                let normal = ratio(SpeechInk.paper(tone, dark: dark), SpeechInk.paperFill(dark: dark))
                ContrastPreference.override = true
                let increased = ratio(SpeechInk.paper(tone, dark: dark), SpeechInk.paperFill(dark: dark))
                #expect(increased >= 4.5, "\(tone) \(dark ? "dark" : "light"): \(increased)")
                #expect(increased >= normal, "\(tone) \(dark ? "dark" : "light")")
            }
        }
        ContrastPreference.override = false
        #expect(SpeechInk.stitchAlpha(dark: false) < 0.5)
        ContrastPreference.override = true
        #expect(SpeechInk.stitchAlpha(dark: false) > 0.7)
    }

    @Test func reduceMotionCanBePinnedForTheDemo() {
        let saved = MotionPreference.override
        defer { MotionPreference.override = saved }
        MotionPreference.override = true
        #expect(MotionPreference.reduced)
        MotionPreference.override = false
        #expect(!MotionPreference.reduced)
    }

    @Test func tetsusBreakTimerLightsOneDotPerStepOfTheBreakLeft() {
        func lit(_ fraction: Double) -> Int {
            let built = LEDBreak.dots(text: "18:42", fraction: fraction)
            return built.dots.filter { $0.y == built.rows - 1 && $0.level == 1 }.count
        }
        #expect(lit(0) == 0)
        #expect(lit(1) > lit(0.5) && lit(0.5) > lit(0.2) && lit(0.2) > 0)
        // The ✕ stands to the right of the time, and the picture is drawn for a wide strip with room for both.
        let built = LEDBreak.dots(text: "3:10", fraction: 0.2)
        #expect(built.dots.contains { $0.x >= built.timeColumns + 5 })
        #expect(built.columns > built.timeColumns)
        let strip = LEDBreak.strip(text: "3:10", fraction: 0.2, urgent: false, dark: false, scale: 2)
        #expect(strip.1 != nil && strip.0.height == LEDBreak.height)
    }

    @Test func theBeamErasesTopToBottomAndPrintsBottomToTop() {
        let stage = CALayer(); stage.bounds = CGRect(origin: .zero, size: StageGeometry.size)
        let host = CALayer(); host.bounds = CGRect(origin: .zero, size: CGSize(width: 160, height: 170))
        let beam = StageBeam()
        // Erasing: the block under the line shrinks from the top down, the line travelling with its top edge.
        beam.pose(stage: stage, host: host, scale: 0.5, erasing: true, progress: 0)
        #expect(stage.mask != nil)
        let topStart = stage.mask!.bounds.height
        beam.pose(stage: stage, host: host, scale: 0.5, erasing: true, progress: 1)
        let topEnd = stage.mask!.bounds.height
        #expect(topStart == StageBeam.top && topEnd == StageBeam.bottom)
        // Printing: it grows from the bottom up.
        beam.pose(stage: stage, host: host, scale: 0.5, erasing: false, progress: 0)
        #expect(stage.mask!.bounds.height == StageBeam.bottom)
        beam.pose(stage: stage, host: host, scale: 0.5, erasing: false, progress: 1)
        #expect(stage.mask!.bounds.height == StageBeam.top)
        // The light is drawn over the host (in the panel's points), not in the masked stage.
        #expect(host.sublayers?.contains { $0.name == "stageBeam line" } == true)
        beam.finish(stage: stage)
        #expect(stage.mask == nil)
        #expect(host.sublayers?.contains { $0.name == "stageBeam line" } != true)
    }
}
