import Testing
import Foundation
import simd
@testable import MokuVisual

@Test func homeRespectsDockAndNegativeDisplayOrigins() {
    let visible = CGRect(x: -1920, y: 74, width: 1920, height: 1000)
    let home = StageGeometry.home(in: visible, scale: 1)
    #expect(home.x + 160 < visible.maxX)
    #expect(home.y >= visible.minY)
}
@Test(arguments: [0.25, 1, 1.25] as [CGFloat])
func bunnySitsAtTheScreenSideWithLittlePaddingAtAnySize(scale: CGFloat) {
    // The body's extent scales with Moku; the padding is screen points, the same at every size.
    let mid = StageGeometry.characterFrame.midX * scale, pad = StageGeometry.edgePadding
    let bodyRight = StageGeometry.bodyRight * scale, bodyLeft = StageGeometry.bodyLeft * scale
    for visible in [CGRect(x: 0, y: 70, width: 1470, height: 856), CGRect(x: -2560, y: 0, width: 2560, height: 1415)] {
        // Home: the body's right side is `pad` from the screen's right side.
        let home = StageGeometry.home(in: visible, scale: scale)
        #expect(abs(home.x + mid + bodyRight - (visible.maxX - pad)) < 0.001)
        // Dragged or thrown past either side, the body stops `pad` inside it.
        let right = StageGeometry.clamped(CGPoint(x: visible.maxX + 500, y: visible.minY), to: visible, scale: scale)
        let left = StageGeometry.clamped(CGPoint(x: visible.minX - 500, y: visible.minY), to: visible, scale: scale)
        #expect(abs(right.x + mid + bodyRight - (visible.maxX - pad)) < 0.001)
        #expect(abs(left.x + mid - bodyLeft - (visible.minX + pad)) < 0.001)
        // The saved home keeps meaning "at the side" through a resolution change, and through a resize.
        let saved = SavedHome(origin: right, visible: visible, scale: scale)
        let wider = CGRect(x: visible.minX, y: visible.minY, width: visible.width + 400, height: visible.height)
        #expect(saved.x == 1 && abs(saved.origin(in: wider, scale: scale).x + mid + bodyRight - (wider.maxX - pad)) < 0.001)
        for other in [0.25, 0.5, 1.25] as [CGFloat] {
            let resized = saved.origin(in: visible, scale: other)
            #expect(abs(resized.x + (StageGeometry.characterFrame.midX + StageGeometry.bodyRight) * other - (visible.maxX - pad)) < 0.001)
        }
    }
}

@Test func theSpeechBubbleSitsJustAboveTheHeadAndAboveTheCaption() {
    let visible = CGRect(x: 0, y: 70, width: 1470, height: 856), bubble = CGSize(width: 282, height: 100), inset = StageGeometry.speechInset
    for scale in [0.25, 1, 1.25] as [CGFloat] {
        let panel = CGRect(origin: StageGeometry.home(in: visible, scale: scale), size: StageGeometry.panelSize(scale: scale))
        let alone = StageGeometry.speechOrigin(panel: panel, bubble: bubble, visible: visible, gap: 6, caption: nil)
        // The drawn bubble (inside its shadow margin) starts 6 points above the head, not at the panel's top.
        #expect(alone.y + inset == panel.minY + StageGeometry.headTop * scale + 6)
        #expect(alone.x + bubble.width <= visible.maxX - 8)
        // With the caption showing over the head, the bubble clears it.
        let captionOrigin = StageGeometry.captionOrigin(panel: panel, caption: CGSize(width: 180, height: 38), visible: visible, gap: 6)
        let caption = CGRect(origin: captionOrigin, size: CGSize(width: 180, height: 38))
        let stacked = StageGeometry.speechOrigin(panel: panel, bubble: bubble, visible: visible, gap: 6, caption: caption)
        #expect(stacked.y + inset > caption.maxY)
    }
    // Moku up at the top of the screen: the bubble hangs below it, on screen.
    let high = CGRect(x: 600, y: visible.maxY - 200, width: StageGeometry.size.width, height: StageGeometry.size.height)
    let below = StageGeometry.speechOrigin(panel: high, bubble: bubble, visible: visible, gap: 6, caption: nil)
    #expect(below.y + bubble.height - inset == high.minY && below.y >= visible.minY)
}

@Test func theCaptionAndTheEyesFollowMokusSize() {
    let visible = CGRect(x: 0, y: 70, width: 1470, height: 856), caption = CGSize(width: 180, height: 38)
    for scale in [0.25, 0.5, 1, 1.25] as [CGFloat] {
        let panel = CGRect(origin: StageGeometry.home(in: visible, scale: scale), size: StageGeometry.panelSize(scale: scale))
        #expect(StageGeometry.scale(of: panel) == scale)
        // Still `gap` screen points above the head, wherever the head now is.
        #expect(StageGeometry.captionOrigin(panel: panel, caption: caption, visible: visible, gap: 6).y == panel.minY + StageGeometry.headTop * scale + 6)
        #expect(StageGeometry.eyes(panel: panel) == CGPoint(x: panel.minX + StageGeometry.eyeLine.x * scale, y: panel.minY + StageGeometry.eyeLine.y * scale))
        // Resting on the Dock the same way at every size.
        #expect(panel.minY == visible.minY + 6)
    }
}

@Test func captionSitsJustAboveMokusHeadAndOnScreen() {
    let visible = CGRect(x: 0, y: 70, width: 1470, height: 856), caption = CGSize(width: 180, height: 38)
    let home = CGRect(origin: StageGeometry.home(in: visible, scale: 1), size: StageGeometry.size)
    let above = StageGeometry.captionOrigin(panel: home, caption: caption, visible: visible, gap: 6)
    #expect(above.y == home.minY + StageGeometry.headTop + 6)         // the gap is measured from the head
    #expect(above.y + caption.height < home.maxY)                       // well below the panel's old top edge
    #expect(above.x + caption.width <= visible.maxX - 8)                // on screen beside the edge
    // Moku up at the top of the screen: the caption stays on screen.
    let high = CGRect(x: 400, y: visible.maxY - 200, width: StageGeometry.size.width, height: StageGeometry.size.height)
    #expect(StageGeometry.captionOrigin(panel: high, caption: caption, visible: visible, gap: 120).y == visible.maxY - caption.height)
}

@Test func pathHasExactEndpointsAndNeverOvershoots() {
    let a = CGPoint(x: -900, y: 200), b = CGPoint(x: 800, y: 900)
    #expect(StageGeometry.path(from: a, to: b, progress: -1) == a)
    #expect(StageGeometry.path(from: a, to: b, progress: 2) == b)
    for t in stride(from: 0.0, through: 1, by: 0.01) {
        let p = StageGeometry.path(from: a, to: b, progress: t)
        #expect(p.x >= a.x && p.x <= b.x && p.y >= a.y && p.y <= b.y)
    }
}
@Test func ellipsePassesThroughTransparentCorners() {
    let r = CGRect(x: 0, y: 0, width: 100, height: 60)
    #expect(StageGeometry.contains(CGPoint(x: 50, y: 30), ellipse: r))
    #expect(!StageGeometry.contains(.zero, ellipse: r))
    #expect(!StageGeometry.contains(CGPoint(x: 50, y: 30), ellipse: .zero))
}

@Test func lineOfSightPassesThroughTheScreenCentreFromAnywhere() {
    let displays = [CGRect(x: 0, y: 0, width: 1470, height: 956), CGRect(x: -2560, y: 0, width: 2560, height: 1440), CGRect(x: 1470, y: -200, width: 1920, height: 1080)]
    for screen in displays {
        for (u, v) in [(0.05, 0.08), (0.95, 0.08), (0.05, 0.9), (0.95, 0.9), (0.5, 0.1), (0.1, 0.5), (0.7, 0.6)] {
            let eyes = CGPoint(x: screen.minX + screen.width * u, y: screen.minY + screen.height * v)
            let gaze = StageGeometry.centerGaze(eyes: eyes, screen: screen)
            // Seen by the user, the gaze ray points along its x/y components.
            let seen = atan2(sin(Double(gaze.y)), sin(Double(gaze.x)) * cos(Double(gaze.y)))
            let toCentre = atan2(screen.midY - eyes.y, screen.midX - eyes.x)
            #expect(abs(remainder(seen - toCentre, 2 * .pi)) < 1e-4)
        }
    }
}

@Test func homeCornerTurnsAboutFiftyDegreesOnEveryDisplay() {
    for screen in [CGRect(x: 0, y: 0, width: 1470, height: 956), CGRect(x: 0, y: 0, width: 2560, height: 1440), CGRect(x: -1920, y: 0, width: 1920, height: 1080)] {
        let home = StageGeometry.home(in: screen, scale: 1)
        let eyes = CGPoint(x: home.x + StageGeometry.eyeLine.x, y: home.y + StageGeometry.eyeLine.y)
        let gaze = StageGeometry.centerGaze(eyes: eyes, screen: screen)
        #expect(gaze.x < -0.75 && gaze.x > -0.95)   // left, toward the centre
        #expect(gaze.y > 0.3 && gaze.y < 0.55)      // and up
    }
    let centre = StageGeometry.centerGaze(eyes: CGPoint(x: 735, y: 478), screen: CGRect(x: 0, y: 0, width: 1470, height: 956))
    #expect(simd_length(centre) < 1e-6)
    let leftEdge = StageGeometry.centerGaze(eyes: CGPoint(x: 40, y: 900), screen: CGRect(x: 0, y: 0, width: 1470, height: 956))
    #expect(leftEdge.x > 0.5 && leftEdge.y < -0.2)  // right and down from the top-left
}

@Test func chestHeadAndEyesAddUpToTheGazeAndTheEyesLead() {
    for gaze in [SIMD2<Float>(0.4, -0.2), SIMD2<Float>(0.1, 0.05), SIMD2<Float>(-0.3, 0.15)] {
        let body = GazeSplit(gaze), eyes = body.eyes(toward: gaze)
        #expect(abs(body.chestYaw + body.headYaw + eyes.x - gaze.x) < 1e-5)
        #expect(abs(body.headPitch + eyes.y - gaze.y) < 1e-5)
    }
    // Before the body moves, the eyes already turn toward the new target, within their range.
    let early = GazeSplit(.zero).eyes(toward: SIMD2(-0.83, 0.42))
    #expect(early.x == -0.30 && early.y == 0.20)
}

/// Charles, 2026-10-14: "the head is too much slanting for moku and tetsu sometimes when they are in the corner, just a
/// slight one is enough". From a corner, looking at the middle of the screen, the head turns at most about 20° and tips
/// about 10°; the eyes carry more, and the look still lands within about a fifth of where it points.
@Test func aCornerLookTurnsTheHeadOnlySlightly() {
    for gaze in [SIMD2<Float>(-0.83, 0.42), SIMD2<Float>(0.85, 0.45), SIMD2<Float>(0.9, -0.3)] {
        let body = GazeSplit(gaze), eyes = body.eyes(toward: gaze)
        #expect(abs(body.headYaw) <= 0.35 && abs(body.headPitch) <= 0.18 && abs(body.chestYaw) <= 0.10)
        let reached = SIMD2(body.chestYaw + body.headYaw + eyes.x, body.headPitch + eyes.y)
        #expect(abs(reached.x) >= abs(gaze.x) * 0.8, "\(gaze): \(reached)")
        #expect(abs(reached.y) >= abs(gaze.y) * 0.8, "\(gaze): \(reached)")
    }
}

@Test func savedHomeSurvivesResolutionChangesAndUndockingHasAnExplicitFallback() {
    let main = DisplayRegion(id: "laptop", visible: CGRect(x: 0, y: 70, width: 1470, height: 850))
    let dock = DisplayRegion(id: "dock", visible: CGRect(x: -2560, y: 40, width: 2560, height: 1400))
    let saved = SavedHome(origin: CGPoint(x: -500, y: 90), visible: dock.visible, scale: 1)
    #expect(HomePlacement.resolve(savedDisplay: "dock", savedHome: saved, displays: [main,dock], scale: 1) == saved.origin(in: dock.visible, scale: 1))
    let resized = DisplayRegion(id: "dock", visible: CGRect(x: -1920, y: 30, width: 1920, height: 1000))
    let relocated = HomePlacement.resolve(savedDisplay: "dock", savedHome: saved, displays: [main,resized], scale: 1)!
    #expect(relocated == saved.origin(in: resized.visible, scale: 1))
    #expect(resized.visible.contains(CGRect(origin: relocated, size: StageGeometry.size)))
    #expect(HomePlacement.resolve(savedDisplay: "dock", savedHome: saved, displays: [main], scale: 1) == StageGeometry.home(in: main.visible, scale: 1))
    #expect(HomePlacement.resolve(savedDisplay: "dock", savedHome: saved, displays: [], scale: 1) == nil)
}
@Test func openPanelsRecoverToASurvivingDisplayAndFitItsResolution() {
    let main = DisplayRegion(id: "laptop", visible: CGRect(x: 0, y: 70, width: 900, height: 650))
    let recovered = HomePlacement.panel(CGRect(x: -2200, y: 500, width: 1120, height: 760), displays: [main])
    #expect(main.visible.contains(recovered))
    #expect(recovered.width == 876 && recovered.height == 626)
}

@Test func droppedNearASideMokuSitsExactlyAtItWithTheLittlePadding() {
    // Charles, 2026-09-28: "the left/right padding is very high again". A drop 40 pt short of the side had
    // been saved as home (x 0.97). Near a side (or the bottom) Moku now settles flush, with `edgePadding`.
    let visible = CGRect(x: 0, y: 70, width: 1470, height: 853), pad = StageGeometry.edgePadding
    let mid = StageGeometry.characterFrame.midX
    for scale in [0.5, 1, 1.25] as [CGFloat] {
        let xs = StageGeometry.originsX(in: visible, scale: scale)
        let nearRight = StageGeometry.settled(CGPoint(x: xs.upperBound - 40, y: 300), in: visible, scale: scale)
        #expect(abs(nearRight.x + (mid + StageGeometry.bodyRight) * scale - (visible.maxX - pad)) < 0.001)
        let nearLeft = StageGeometry.settled(CGPoint(x: xs.lowerBound + 40, y: 300), in: visible, scale: scale)
        #expect(abs(nearLeft.x + (mid - StageGeometry.bodyLeft) * scale - (visible.minX + pad)) < 0.001)
        let middle = CGPoint(x: (xs.lowerBound + xs.upperBound) / 2, y: 400)
        #expect(StageGeometry.settled(middle, in: visible, scale: scale) == middle)  // dropped in the open: stays
        #expect(StageGeometry.settled(CGPoint(x: middle.x, y: visible.minY + 12), in: visible, scale: scale).y == StageGeometry.home(in: visible, scale: scale).y)
    }
    // The saved home that caused it resolves to the side.
    let saved = try! JSONDecoder().decode(SavedHome.self, from: Data(#"{"x":0.9709388971684053,"y":0.0234375}"#.utf8))
    #expect(abs(saved.origin(in: visible, scale: 1).x + mid + StageGeometry.bodyRight - (visible.maxX - pad)) < 0.001)
}

@Test func mokuCanSitInTheTopCorners() {
    // Charles: "unable to put it in the top corner". The head (not the tall panel) stops `edgePadding` under the top.
    let visible = CGRect(x: 0, y: 70, width: 1470, height: 853)
    for scale in [0.5, 1, 1.25] as [CGFloat] {
        let xs = StageGeometry.originsX(in: visible, scale: scale), ys = StageGeometry.originsY(in: visible, scale: scale)
        let topRight = StageGeometry.settled(CGPoint(x: xs.upperBound - 30, y: ys.upperBound - 30), in: visible, scale: scale)
        #expect(topRight == CGPoint(x: xs.upperBound, y: ys.upperBound))
        #expect(abs(topRight.y + StageGeometry.headTop * scale - (visible.maxY - StageGeometry.edgePadding)) < 0.001)
        let topLeft = StageGeometry.settled(CGPoint(x: xs.lowerBound + 20, y: ys.upperBound + 500), in: visible, scale: scale)
        #expect(topLeft == CGPoint(x: xs.lowerBound, y: ys.upperBound))
    }
}
