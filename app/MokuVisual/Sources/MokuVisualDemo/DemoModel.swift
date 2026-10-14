import AppKit
import SwiftUI
import MokuVisual
import MokuKit

@MainActor @Observable
final class DemoModel {
    /// `--onscreen` (with `--offscreen`): the checks run without the demo's windows, but Moku's panel shows on screen at the
    /// display's pace, as in the app (EnergyCheck).
    let stage = MokuCharacterStage(rendersOffscreen: CommandLine.arguments.contains("--offscreen") && !CommandLine.arguments.contains("--onscreen"))
    let worldModel = WorldModel(snapshot: WorldSnapshot(growthPoints: 120, todayFocusMinutes: 87, todayReturns: 4, longestFocusMinutesToday: 47, threads: [ThreadSummary(id: "auth", title: "Moku · A little company", summary: "Bringing the companion to life", focusMinutesToday: 52, focusMinutesTotal: 180, lastActiveAt: .now), ThreadSummary(id: "trees", title: "DSA · Trees", summary: "Making room for deep work", focusMinutesToday: 35, focusMinutesTotal: 90, lastActiveAt: .now)]))
    var world: (any WorldPresenter)?
    var points = 120.0
    var status = "Ready. A click opens the forest; a head stroke is a pat."
    var manualPanel: (any ManualControlPanel)?
    var monitor: Timer?
    init() {
        if !CommandLine.arguments.contains("--offscreen") { world = MokuVisualFactory.makeWorld(model: worldModel) }
        stage.onClick = { [weak self] in self?.status = "Click → world"; self?.world?.openWorld() }
        stage.onPat = { [weak self] in self?.status = "Pat received. This is fine." }
    }
    func grow(_ value: Double) {
        points = value; worldModel.snapshot.growthPoints = value
    }
    func openManualControl() {
        guard let world else { return }
        if manualPanel == nil {
            manualPanel = MokuVisualFactory.makeManualControl(stage: stage, world: worldModel, presenter: world, scenes: [
                ManualScene(id: "day", title: "A day with Moku", play: { [weak self] speed in await self?.playDay(speed: speed) })
            ])
            manualPanel?.onClose = { [weak self] in self?.world?.setManualControl(false) }
            world.onManualControl = { [weak self] on in
                if on { self?.openManualControl() } else { self?.manualPanel?.close() }
            }
        }
        world.setManualControl(true); manualPanel?.open()
    }
    func playDay(speed: Double) async {
        stage.setHidden(false); stage.setMood(.content)
        let beats: [(Mood, MokuKit.Gesture?, String?)] = [
            (.happy, .smile, nil), (.curious, .glance, nil), (.happy, .nod, "There you are."),
            (.concerned, .sigh, "Weren’t we working on Moku?"), (.disappointed, nil, nil),
            (.annoyed, nil, "Friend."), (.happy, .smile, "Welcome back."),
            (.proud, .celebrate, "Look what we grew."), (.content, .drinkWater, "A sip of water?")]
        for (index, beat) in beats.enumerated() {
            do { try await Task.sleep(for: .seconds(3 / max(1, speed))) } catch { return }
            guard !Task.isCancelled else { return }
            stage.setMood(beat.0)
            if let gesture = beat.1 { stage.perform(gesture) }
            if let line = beat.2 { stage.say(SpeechLine(text: line, tone: index == 5 ? .calling : .warm, duration: 4 / max(1, speed))) }
            if index == 1 { stage.setAttention(.point(CGPoint(x: 100, y: 600))) }
            if index == 2 { stage.setAttention(.user); grow(points + 15) }
            if index == 4 { await stage.move(to: .center) }
            if index == 6 { await stage.move(to: .home) }
            if index == 7 { grow(600); world?.celebrate(.tree) }
        }
    }
}
