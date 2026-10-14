import AppKit
import Testing
import MokuKit
@testable import MokuVisual

/// The welcome's last moment (Charles: "the house should expand and shrink in place, not like move from top to bottom,
/// it should immediately darken the screen and grab attention"): a dim that comes in at once, a house that pulses in
/// place, gone after about three seconds or at once on a click or a key, letting every click through.

/// The dim is in within a sixth of a second; the house pulses 1 → 1.35 → 1 three times about its centre with no step
/// between 60 Hz frames, and is its own size again before the dim goes; it all ends, and Reduce Motion pulses nothing.
@Test func theSpotlightDimsAtOnceAndTheHousePulsesInPlace() {
    let spotlight = IconSpotlight(reduced: false)
    let frames = stride(from: 0.0, through: spotlight.duration, by: 1.0 / 60).map { spotlight.state(at: $0) }
    #expect(spotlight.state(at: 0).dim == 0 && abs(spotlight.state(at: IconSpotlight.fadeIn).dim - IconSpotlight.dim) < 0.001)
    #expect(spotlight.state(at: 0.08).dim > IconSpotlight.dim * 0.6)  // "immediately darken the screen"
    #expect(frames.allSatisfy { $0.scale >= 1 && $0.scale <= IconSpotlight.peak + 0.0001 })
    #expect(abs((frames.map(\.scale).max() ?? 1) - IconSpotlight.peak) < 0.01)
    var peaks = 0
    for i in 1..<(frames.count - 1) where frames[i].scale > frames[i - 1].scale && frames[i].scale >= frames[i + 1].scale && frames[i].scale > 1.3 { peaks += 1 }
    #expect(peaks == IconSpotlight.beats)
    for (a, b) in zip(frames, frames.dropFirst()) {
        #expect(abs(b.scale - a.scale) < 0.03)                      // no snap in the pulse
        #expect(abs(b.dim - a.dim) < 0.2 && abs(b.halo - a.halo) < 0.2)
    }
    #expect(spotlight.state(at: IconSpotlight.hold).scale == 1)      // the house is back to its size before the dim goes
    let end = spotlight.state(at: spotlight.duration)
    #expect(end.dim < 0.001 && end.halo < 0.001 && end.scale == 1 && spotlight.isOver(at: spotlight.duration))
    let calm = IconSpotlight(reduced: true)
    let still = stride(from: 0.0, through: calm.duration, by: 1.0 / 60).map { calm.state(at: $0) }
    #expect(still.allSatisfy { $0.scale == 1 })                       // Reduce Motion: a steady highlight
    #expect(calm.state(at: 1.5).halo > 0.5 && calm.state(at: 1.5).dim == IconSpotlight.dim)
}

/// A click or a key, whenever it comes, takes it all away quickly from wherever it was, with no jump.
@Test func aClickOrAKeyEndsTheSpotlightAtOnceFromWhereItWas() {
    let spotlight = IconSpotlight(reduced: false)
    for at in [0.05, 0.5, 1.0, 1.95, 2.9] {
        let before = spotlight.state(at: at), after = spotlight.state(at: at, dismissedAt: at)
        #expect(abs(before.dim - after.dim) < 0.001 && abs(before.scale - after.scale) < 0.001)  // continuous at the click
        let gone = spotlight.state(at: at + IconSpotlight.dismissal, dismissedAt: at)
        #expect(gone.dim < 0.001 && gone.scale == 1 && gone.halo < 0.001)
        #expect(spotlight.isOver(at: at + IconSpotlight.dismissal, dismissedAt: at) && !spotlight.isOver(at: at + 0.05, dismissedAt: at))
        let steps = stride(from: at, through: at + IconSpotlight.dismissal, by: 1.0 / 60).map { spotlight.state(at: $0, dismissedAt: at) }
        for (a, b) in zip(steps, steps.dropFirst()) { #expect(abs(b.dim - a.dim) < 0.2 && abs(b.scale - a.scale) < 0.06) }
    }
}

/// Its windows let every click through and never take the keyboard; a click, a key or the clock ends it, taking its
/// windows and every event monitor away and showing the real icon again. Built with `shows: false`: these tests never
/// put a window on the screen (Charles is using the Mac).
@MainActor @Suite(.serialized) struct SpotlightOverlayTests {
    private func overlay(listens: Bool = true, shown: @escaping (Bool) -> Void) -> IconSpotlightOverlay {
        _ = NSApplication.shared
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let house = CGContext(data: nil, width: 72, height: 72, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()
        return IconSpotlightOverlay(icon: CGRect(x: 1204, y: 879, width: 18, height: 18), screen: screen, house: house, reduced: false, showIcon: shown, listens: listens, shows: false)
    }
    @Test func clicksPassThroughAndNothingTakesTheKeyboard() {
        var shown: [Bool] = []
        let spotlight = overlay { shown.append($0) }
        #expect(spotlight.windows.count == 2)
        for window in spotlight.windows { #expect(window.ignoresMouseEvents && !window.canBecomeKey && !window.canBecomeMain && !window.isVisible) }
        #expect(shown.isEmpty)  // not shown: the real icon is never hidden
        #expect(spotlight.monitorCount == 2)
        spotlight.end()
        #expect(spotlight.monitorCount == 0 && spotlight.windows.allSatisfy { !$0.isVisible } && shown == [true])
    }
    @Test func aClickOrAKeyEndsItQuicklyAndLetsGoOfEverything() async {
        for event in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .keyDown] {
            var shown: [Bool] = [], ended = false
            let spotlight = overlay { shown.append($0) }
            spotlight.onEnd = { ended = true }
            try? await Task.sleep(for: .milliseconds(300))
            spotlight.handle(event)
            #expect(spotlight.dismissedAt != nil && spotlight.monitorCount == 0)  // listening stops at once
            spotlight.handle(event)  // a second one changes nothing
            try? await Task.sleep(for: .seconds(IconSpotlight.dismissal + 0.25))
            #expect(ended && spotlight.ended && shown.last == true && spotlight.windows.allSatisfy { !$0.isVisible }, "\(event)")
        }
    }
    @Test func itEndsByItselfAfterAboutThreeSeconds() async {
        var ended = false
        let spotlight = overlay(listens: false) { _ in }
        spotlight.onEnd = { ended = true }
        try? await Task.sleep(for: .seconds(IconSpotlight.hold))
        #expect(!ended)
        try? await Task.sleep(for: .seconds(IconSpotlight.fadeOut + 0.4))
        #expect(ended && spotlight.windows.allSatisfy { !$0.isVisible })
    }
}
