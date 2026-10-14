import AppKit
import Testing
@testable import MokuVisual

/// Charles, 2026-10-08: "when I open media full screen Moku is still there, it shouldn't be." A film, a game or a slideshow
/// full screen on Moku's display hides it; it comes back when that ends. A full-screen window on another display does not
/// touch it. It adds to the other reasons to be hidden (a call, "Hide Moku") and never overrides them.
@MainActor @Suite struct FullScreenHidingTests {
    private func stage() -> MokuCharacterStage {
        UserDefaults.standard.removeObject(forKey: MokuPreferences.hiddenKey)
        let stage = MokuCharacterStage(rendersOffscreen: true)
        stage.displayIDOverride = 7
        stage.setHidden(false)
        return stage
    }

    @Test func aFullScreenFilmOnMokusDisplayHidesItAndTheEndBringsItBack() {
        let stage = stage()
        #expect(!stage.hidden)
        stage.setFullScreenDisplays([7])
        #expect(stage.hidden)
        stage.setFullScreenDisplays([])
        #expect(!stage.hidden)
    }

    @Test func aFullScreenWindowOnAnotherDisplayLeavesItBe() {
        let stage = stage()
        stage.setFullScreenDisplays([9])
        #expect(!stage.hidden)
    }

    @Test func fullScreenNeverBringsBackAMokuThePersonPutAway() {
        let stage = stage()
        stage.setHiddenByPerson(true)
        stage.setFullScreenDisplays([7])
        stage.setFullScreenDisplays([])
        #expect(stage.hidden, "the person's Hide Moku outlasts the film")
        stage.setHiddenByPerson(false)
        #expect(!stage.hidden)
        UserDefaults.standard.removeObject(forKey: MokuPreferences.hiddenKey)
    }

    @Test func aCallEndingDuringAFilmDoesNotBringItBack() {
        let stage = stage()
        stage.setFullScreenDisplays([7])
        stage.setHidden(true)   // a meeting begins
        stage.setHidden(false)  // and ends, the film still on
        #expect(stage.hidden)
        stage.setFullScreenDisplays([])
        #expect(!stage.hidden)
    }

    @Test func theWelcomeIsNeverHiddenByFullScreen() {
        let stage = stage()
        stage.setFullScreenDisplays([7])
        #expect(stage.hidden)
        stage.enterWelcome(feet: CGPoint(x: 600, y: 400), scale: 2)
        #expect(!stage.hidden, "the welcome's companion must show")
        stage.leaveWelcome()
        #expect(stage.hidden, "the film is still on after the welcome")
        stage.setFullScreenDisplays([])
    }

    /// The friends, 2026-10-14: hidden in the apps they pick. A fourth reason beside a call, "Hide Moku" and full screen.
    @Test func anAppMokuStepsAsideForHidesItWhileInFront() {
        let stage = stage()
        stage.setSteppingAsideForApp(true)
        #expect(stage.hidden)
        stage.setSteppingAsideForApp(false)
        #expect(!stage.hidden)
    }

    @Test func leavingThatAppNeverBringsBackAMokuThePersonPutAway() {
        let stage = stage()
        stage.setHiddenByPerson(true)
        stage.setSteppingAsideForApp(true)
        stage.setSteppingAsideForApp(false)
        #expect(stage.hidden)
        stage.setHiddenByPerson(false)
        UserDefaults.standard.removeObject(forKey: MokuPreferences.hiddenKey)
    }

    @Test func theWelcomeIsNeverHiddenForAnApp() {
        let stage = stage()
        stage.setSteppingAsideForApp(true)
        stage.enterWelcome(feet: CGPoint(x: 600, y: 400), scale: 2)
        #expect(!stage.hidden)
        stage.leaveWelcome()
        #expect(stage.hidden)
        stage.setSteppingAsideForApp(false)
    }
}
