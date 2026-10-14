import AppKit
import MokuKit
import MokuVisual

@MainActor private final class SilentWorld: WorldPresenter {
    func openWorld() {}
    func closeWorld() {}
    func celebrate(_ stage: ForestStage) {}
}

@MainActor func captureBrief2(model: DemoModel, directory: String) async {
    model.stage.setHidden(false)
    let folder = URL(fileURLWithPath: directory)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? await Task.sleep(for: .seconds(3))
    model.stage.setMood(.content)
    model.stage.setAttention(.point(CGPoint(x: 0, y: 2000)))
    try? await Task.sleep(for: .seconds(1))
    try? model.stage.capture(to: folder.appendingPathComponent("gaze-work.png"))
    model.stage.setAttention(.user)
    try? await Task.sleep(for: .seconds(1.2))
    try? model.stage.capture(to: folder.appendingPathComponent("gaze-user.png"))
    MokuVisualDiagnostics.simulateHover(stage: model.stage, inside: true)
    try? await Task.sleep(for: .seconds(0.65))
    try? model.stage.capture(to: folder.appendingPathComponent("hover-delight.png"))
    try? await Task.sleep(for: .seconds(1.5))
    let heldFrames = model.stage.totalRenderedFrames
    try? await Task.sleep(for: .seconds(1))
    let heldDelta = model.stage.totalRenderedFrames - heldFrames
    MokuVisualDiagnostics.simulateHover(stage: model.stage, inside: false)
    try? await Task.sleep(for: .seconds(0.6))
    try? model.stage.capture(to: folder.appendingPathComponent("hover-released.png"))
    model.stage.setMood(.curious)
    try? await Task.sleep(for: .seconds(0.8))
    MokuVisualDiagnostics.playMicro(stage: model.stage, name: "brow")
    try? await Task.sleep(for: .seconds(0.2))
    try? model.stage.capture(to: folder.appendingPathComponent("micro-brow.png"))
    model.stage.setMood(.disappointed)
    try? await Task.sleep(for: .seconds(3.5))
    try? model.stage.capture(to: folder.appendingPathComponent("folded-arms.png"))
    model.stage.setMood(.happy); model.stage.perform(.wave)
    try? await Task.sleep(for: .seconds(1.5))
    try? model.stage.capture(to: folder.appendingPathComponent("unfold-then-wave.png"))
    try? await Task.sleep(for: .seconds(2))
    model.stage.setMood(.disappointed)
    try? await Task.sleep(for: .seconds(1))
    await model.stage.move(to: .center)
    try? await Task.sleep(for: .seconds(1.5))
    model.stage.setMood(.content)
    let results: [String: Any] = ["heldHoverFramesInOneSecond": heldDelta, "hoverReactions": model.stage.totalHoverReactions, "microExpressions": model.stage.totalMicroExpressions, "clipHistory": MokuVisualDiagnostics.clipHistory(stage: model.stage), "error": model.stage.rendererError ?? "none", "firstVisibleSource": model.stage.firstVisibleSource ?? "none"]
    if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: folder.appendingPathComponent("brief2-checks.json")) }
    try? MokuVisualDiagnostics.captureManualControl(stage: model.stage, world: model.worldModel, presenter: SilentWorld(), scenes: [ManualScene(id: "day", title: "A day with Moku", play: { _ in })], to: folder.appendingPathComponent("manual-control.png"))
    try? MokuVisualDiagnostics.captureWorld(model: model.worldModel, to: folder.appendingPathComponent("world-manual.png"))
}
