import AppKit
import Testing
import MokuKit
@testable import MokuVisual

/// Charles, 2026-10-14: no task labels popping up ("launching moku desktop app"); hovering Moku shows the task and its
/// minutes today, and the label goes when the pointer leaves.
@MainActor @Suite struct HoverTaskTests {
    private func stage() -> MokuCharacterStage {
        UserDefaults.standard.removeObject(forKey: MokuPreferences.hiddenKey)
        let stage = MokuCharacterStage(rendersOffscreen: true)
        stage.setHidden(false)
        return stage
    }

    private func hover(_ stage: MokuCharacterStage, _ inside: Bool) async throws {
        stage.simulatedHover = inside; stage.updateHit()
        try await Task.sleep(for: .milliseconds(inside ? 400 : 700))
        stage.updateHit()
    }

    @Test func hoveringShowsTheTaskAndItsMinutesUntilThePointerLeaves() async throws {
        let stage = stage()
        stage.currentTask = { TaskNow(title: "building Moku", minutesToday: 84) }
        try await hover(stage, true)
        #expect(stage.captionShowing)
        #expect(stage.lastCaption == "building Moku · 1h 24m")
        try await hover(stage, false)
        #expect(!stage.captionShowing)
    }

    @Test func withNoTaskHoveringShowsNoLabel() async throws {
        let stage = stage()
        stage.currentTask = { nil }
        try await hover(stage, true)
        #expect(!stage.captionShowing)
    }
}
