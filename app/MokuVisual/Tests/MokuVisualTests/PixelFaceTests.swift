import Foundation
import Testing
import MokuKit
@testable import MokuVisual

// Tetsu's display (next-wave.md §7): the shared face weights pick whole pixel-art frames, so a change is crisp.

@MainActor @Test func aBlinkIsPixelSteps() {
    let steps = stride(from: Float(0), through: 1, by: 0.05).map { PixelFace.frame(for: ["blink_L": $0, "blink_R": $0], gaze: .zero, cross: false).eyes[0] }
    #expect(Set(steps) == ["open", "half", "narrow", "line"])
    #expect(steps.first == "open" && steps.last == "line")
}

@MainActor @Test func moodsPickTheirFrames() {
    func eyes(_ face: [String: Float], cross: Bool = false) -> PixelFace.Frame { PixelFace.frame(for: face, gaze: .zero, cross: cross) }
    #expect(eyes([:]).eyes == ["open", "open"])
    #expect(eyes(["eyes_happy": 0.85]).eyes == ["happy", "happy"])
    #expect(eyes(["brows_concern": 0.6, "lid_sad": 0.8, "blink_L": 0.35, "blink_R": 0.35]).eyes == ["sad", "sad"])
    let cross = eyes(["brows_angry": 1, "blink_L": 0.25, "blink_R": 0.25])
    #expect(cross.eyes == ["angry", "angry"] && cross.palette == "cross")
    let sleepy = eyes(["eyes_dot": 1, "sleep_z": 1])
    #expect(sleepy.eyes == ["dot", "dot"] && sleepy.zed == "z")
    let pat = eyes(["px_heart": 1])
    #expect(pat.eyes == ["heart", "heart"] && pat.palette == "heart")
    #expect(eyes([:], cross: true).palette == "cross")  // standing cross a while: amber
    #expect(eyes(["px_spin": 0.3]).spinner != nil)
    #expect(eyes(["px_boot": 0.4]).boot != nil)
}

@MainActor @Test func theGazeMovesTheEyesByWholeDots() {
    let left = PixelFace.frame(for: [:], gaze: SIMD2(-0.45, 0), cross: false).offset
    let right = PixelFace.frame(for: [:], gaze: SIMD2(0.45, 0), cross: false).offset
    #expect(left == SIMD2(-3, 0) && right == SIMD2(3, 0))
    #expect(PixelFace.frame(for: [:], gaze: SIMD2(0.05, 0), cross: false).offset == .zero)
}

@Test func onlyTetsuIsAMachine() {
    #expect(Companion.tetsu.isMachine && !Companion.moku.isMachine)
}

@MainActor @Test func servoEasesLandExactlyAndOvershootATouch() {
    #expect(ServoTiming.progress(age: 0, duration: 2.4) == 0)
    #expect(ServoTiming.progress(age: 2.4, duration: 2.4) == 1)
    let samples = stride(from: 0.0, through: 2.4, by: 0.01).map { ServoTiming.progress(age: $0, duration: 2.4) }
    let peak = samples.max() ?? 0
    #expect(peak > 1.0 && peak < 1.15)           // a tiny overshoot, then it settles
    #expect(ServoTiming.progress(age: 0.6, duration: 2.4) > 0.9)  // quick: most of the move happens early
}
