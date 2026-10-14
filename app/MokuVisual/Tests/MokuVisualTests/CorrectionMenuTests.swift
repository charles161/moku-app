import AppKit
import Testing
import MokuKit
@testable import MokuVisual

/// Charles, 2026-10-14: correct Moku from its right-click menu. "This is work" in a drift, "This isn't work" while it
/// thinks you work; neither at other times.
@MainActor @Suite struct CorrectionMenuTests {
    private func titles(_ stage: MokuCharacterStage) -> [String] { stage.contextMenu()?.items.map(\.title) ?? [] }

    @Test func theMenuOffersTheCorrectionThatFitsTheMoment() {
        let stage = MokuCharacterStage(rendersOffscreen: true)
        var heard: [Bool] = []
        stage.onCorrectNow = { heard.append($0) }
        stage.setWorkState(.drifting)
        #expect(titles(stage).contains("This is work") && !titles(stage).contains("This isn’t work"))
        stage.contextMenu()?.items.first { $0.title == "This is work" }.map { item in _ = item.target?.perform(item.action, with: item) }
        stage.setWorkState(.focused)
        #expect(titles(stage).contains("This isn’t work") && !titles(stage).contains("This is work"))
        stage.setWorkState(.onBreak)
        #expect(!titles(stage).contains("This is work") && !titles(stage).contains("This isn’t work"))
        #expect(heard == [true])
    }
}
