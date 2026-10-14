import CoreGraphics
import Foundation
import Testing
import MokuKit
@testable import MokuVisual

// The energy and memory bars (docs/specs/launch-qa.md, lens 3): what a frame costs, and how much of its little life
// Moku keeps when the Mac asks for less. The whole-app bars (a memory budget per companion, CPU and wakeups at rest)
// are the demo's --memory-profile and --idle-energy checks.

@Test func aMacWithPowerToSpareKeepsAllOfMokusLife() {
    #expect(PowerPolicy.waitScale(lowPower: false, thermal: .nominal) == 1)
    #expect(PowerPolicy.waitScale(lowPower: false, thermal: .fair) == 1)
}

@Test func lowPowerModeAndAHotMacStretchTheWaitsBetweenLittleMoves() {
    #expect(PowerPolicy.waitScale(lowPower: true, thermal: .nominal) == 2)
    #expect(PowerPolicy.waitScale(lowPower: false, thermal: .serious) == 2)
    #expect(PowerPolicy.waitScale(lowPower: false, thermal: .critical) == 2)
}

@Test func aMacShortOfMemoryAlsoStretchesTheWaits() {
    #expect(PowerPolicy.waitScale(lowPower: false, thermal: .nominal, shortOfMemory: true) == 2)
    #expect(PowerPolicy.waitScale(lowPower: false, thermal: .nominal, shortOfMemory: false) == 1)
}

@Test func aFramePoolLetsGoOfItsSpareBuffersWhenTheMacIsShortOfMemory() {
    let pool = FramePool(byteCount: 64)
    autoreleasepool { _ = pool.take() }
    #expect(pool.idleBuffers == 1)
    pool.trim()
    #expect(pool.idleBuffers == 0)
}

@Test func aDozingMokuMovesAThirdAsOftenAsAnAwakeOne() {
    #expect(PowerPolicy.sleepScale(for: .sleepy) == 3)
    for mood in Mood.allCases where mood != .sleepy { #expect(PowerPolicy.sleepScale(for: mood) == 1) }
}

@Test func aFrameBufferGoesBackToItsPoolWhenTheLastImageOfItIsLetGo() {
    let pool = FramePool(byteCount: 16 * 16 * 4)
    #expect(pool.idleBuffers == 0)
    autoreleasepool {
        let buffer = pool.take()
        let image = buffer.image(side: 16)
        #expect(image != nil)
        #expect(pool.idleBuffers == 0)  // still in use: the image and the stage hold it
        _ = (buffer, image)
    }
    #expect(pool.idleBuffers == 1)
}

@Test func theNextFrameReusesTheBufferInsteadOfAllocatingAnother() {
    let pool = FramePool(byteCount: 16 * 16 * 4)
    var first: UnsafeMutableRawPointer?
    autoreleasepool { let buffer = pool.take(); first = buffer.bytes }
    let again = pool.take()
    #expect(again.bytes == first)
}

@Test func theImageOfAFrameShowsTheBytesDrawnIntoItsBuffer() {
    let pool = FramePool(byteCount: 4 * 4 * 4)
    let buffer = pool.take()
    buffer.bytes.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
    buffer.bytes.storeBytes(of: 200, toByteOffset: (2 * 4 + 1) * 4 + 3, as: UInt8.self)  // alpha of the pixel at (1, 2)
    #expect(buffer.alpha(x: 1, y: 2, side: 4) == 200)
    #expect(buffer.alpha(x: 0, y: 0, side: 4) == 0)
    #expect(buffer.image(side: 4)?.dataProvider?.data.map { CFDataGetLength($0) } == 64)
}

@Test func aPoolKeepsAFewBuffersAndFreesTheRest() {
    let pool = FramePool(byteCount: 64)
    autoreleasepool {
        let held = (0..<FramePool.kept + 3).map { _ in pool.take() }
        _ = held
    }
    #expect(pool.idleBuffers == FramePool.kept)
}

@Test func aRetiredPoolKeepsNothingForTheNextFrame() {
    let pool = FramePool(byteCount: 64)
    autoreleasepool { _ = pool.take() }
    #expect(pool.idleBuffers == 1)
    pool.retire()
    #expect(pool.idleBuffers == 0)
    autoreleasepool { _ = pool.take() }
    #expect(pool.idleBuffers == 0)  // a frame at the old size goes when it comes back
}

@Test func onlyPartlyCoveredPixelsAreCorrectedToTheirOwnColour() {
    var pixels: [UInt32] = [0, 0xFF20_4060, 0x8030_3030]  // empty, opaque, soft
    pixels.withUnsafeMutableBytes { SoftEdges.correct($0.baseAddress!, pixelCount: 3) }
    #expect(pixels[0] == 0)
    #expect(pixels[1] == 0xFF20_4060)
    #expect(pixels[2] != 0x8030_3030)
    #expect(pixels[2] >> 24 == 0x80)
}

// Calm after long focus (docs/specs/launch-qa.md, lens 3 follow-ups): ten unbroken minutes of focus halve the little moves.

@Test func tenUnbrokenMinutesOfFocusHalveTheLittleMovesAndSlowTheEyesALittle() {
    #expect(PowerPolicy.focusScale(focusedFor: nil).moves == 1)
    #expect(PowerPolicy.focusScale(focusedFor: 599).moves == 1)
    #expect(PowerPolicy.focusScale(focusedFor: 600).moves == 2)
    #expect(PowerPolicy.focusScale(focusedFor: 3600).moves == 2)
    #expect(PowerPolicy.focusScale(focusedFor: 599).eyes == 1)
    let eyes = PowerPolicy.focusScale(focusedFor: 600).eyes
    #expect(eyes > 1 && eyes <= 1.5)  // darts and blinks: less often, but never halved: it still looks like reading
}

@Test func theFocusClockRunsOnlyWhileWorkingAndAnyDriftBreakPatOrReturnResetsIt() {
    var clock = FocusClock(headStart: 0)
    #expect(clock.scale(now: 5_000).moves == 1)  // not working: no clock
    clock.became(.focused, now: 1_000)
    #expect(clock.scale(now: 1_599).moves == 1)
    #expect(clock.scale(now: 1_600).moves == 2)
    clock.became(.noticing, now: 1_700)          // a drift ends it
    #expect(clock.scale(now: 1_700).moves == 1)
    clock.became(.focused, now: 1_800)           // back to work: counting again from here
    #expect(clock.scale(now: 2_300).moves == 1)
    #expect(clock.scale(now: 2_400).moves == 2)
    clock.interrupted(now: 2_400)                // a pat starts it over
    #expect(clock.scale(now: 2_401).moves == 1)
    #expect(clock.scale(now: 3_000).moves == 2)
    clock.became(.focused, now: 3_100)           // the return's own restart
    #expect(clock.scale(now: 3_699).moves == 1)
    clock.became(.onBreak, now: 3_700)           // a break ends it too
    #expect(clock.scale(now: 9_999).moves == 1)
    clock.interrupted(now: 10_000)               // a pat while not focused starts nothing
    #expect(clock.scale(now: 99_999).moves == 1)
}

@Test func aFocusClockCanStartWellIntoTheStretchForChecks() {
    var clock = FocusClock(headStart: 600)
    clock.became(.focused, now: 100)
    #expect(clock.scale(now: 100).moves == 2)
    clock.interrupted(now: 200)
    #expect(clock.scale(now: 200).moves == 2)  // the same head start after a pat
}

@Test func theLittleMovesRhythmWaitsExactlyAsMuchLongerAsItIsToldTo() {
    var quick = LifeRhythm(now: 0), slow = LifeRhythm(now: 0)
    var a = LifeRandom(seed: 7), b = LifeRandom(seed: 7)
    _ = quick.next(mood: .content, now: 10, using: &a)
    _ = slow.next(mood: .content, now: 10, slowedBy: 2, using: &b)
    #expect(abs((slow.nextAt - 10) - 2 * (quick.nextAt - 10)) < 1e-9)
}

// Faces at 30 Hz on the CPU morph path (macOS 15 and 26): at most 30 mesh rebuilds a second, whatever the frame rate.

private func rebuildsPerSecond(frameRate: Double, seconds: Double = 10) -> Double {
    var last = -100.0, rebuilds = 0, t = 0.0
    while t < seconds {  // a face that changes on every frame, as a blink does
        if !FacialMorphs.holdsBack(sinceLastRebuild: t - last) { last = t; rebuilds += 1 }
        t += 1 / frameRate
    }
    return Double(rebuilds) / seconds
}

@Test func theCPUFaceChangesAtMostThirtyTimesASecondWhateverTheFrameRate() {
    #expect(abs(rebuildsPerSecond(frameRate: 60) - 30) < 0.5)
    #expect(abs(rebuildsPerSecond(frameRate: 120) - 30) < 0.5)
    #expect(abs(rebuildsPerSecond(frameRate: 30) - 30) < 0.5)  // the idle 30 fps ticker loses no frame to the limit
}

@Test func aSlowTickerIsNeverHeldBack() {
    #expect(abs(rebuildsPerSecond(frameRate: 12) - 12) < 0.2)  // micro-expressions bake at 12 fps
    #expect(abs(rebuildsPerSecond(frameRate: 24) - 24) < 0.2)
}

@Test func aThirtyFramesASecondTickerThatRunsALittleEarlyStillGetsItsFace() {
    // A timer-driven 30 fps ticker is not exact: frames 31 ms apart must still each show their face.
    var last = -100.0, shown = 0, t = 0.0
    for _ in 0..<300 {
        if !FacialMorphs.holdsBack(sinceLastRebuild: t - last) { last = t; shown += 1 }
        t += 0.031
    }
    #expect(shown == 300)
}
