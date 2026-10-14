import AppKit
import Testing
import MokuKit
@testable import MokuVisual

/// Charles, 2026-10-14 (a screenshot of Moku facing him mid-drift): "during drift instead of watching me, it can be sad
/// and then go on to look the screen like the focus used to". The engine's one look at him (the sad move) then its look
/// back to the work were overridden: the stage dropped work points in a drift and rested its gaze on the user.
@MainActor @Suite struct DriftGazeTests {
    private func stage() -> MokuCharacterStage {
        UserDefaults.standard.removeObject(forKey: MokuPreferences.hiddenKey)
        let stage = MokuCharacterStage(rendersOffscreen: true)
        stage.setHidden(false)
        stage.setWorkState(.focused)
        return stage
    }

    @Test func afterTheSadLookADriftWatchesTheScreenLikeFocus() {
        let stage = stage()
        stage.setWorkState(.grace)
        stage.setWorkState(.noticing)
        stage.setAttention(.user)                          // the sad move's one look
        #expect(stage.attention == .user)
        stage.setAttention(.point(CGPoint(x: 400, y: 400))) // the engine's look back to the work
        #expect(stage.attention != .user)
        stage.setWorkState(.concerned)                      // two minutes in
        stage.setWorkState(.drifting)                       // four minutes in, standing
        #expect(stage.attention != .user)
    }

    @Test func aDriftTierBeginningDuringTheSadLookKeepsIt() {
        let stage = stage()
        stage.setWorkState(.grace)
        stage.setAttention(.user)
        stage.setWorkState(.noticing)  // the tier arrives with the look: the look stays
        #expect(stage.attention == .user)
    }
}
