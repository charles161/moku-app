import AppKit
import MokuKit

extension MokuVisualDiagnostics {
    /// `--spam <dir>`: interaction spam (launch QA, lens 3, parameter 10). MOKU_SPAM_COUNT (default 50) of each, one kind
    /// after the other: pats (five a second), the pointer coming onto Moku and leaving, drags (pick up, carry across the
    /// screen, put down) and throws (a flick, let go mid-motion: it flies, lands and goes home). Per kind: CPU as a share of
    /// a core, frames drawn, and the footprint after it. Afterwards, ten quiet seconds: nothing may still be held, moving or
    /// carried, Moku must be where it lives, the renderer must have no error, and the lowest footprint over twelve quiet
    /// seconds must be within MOKU_SPAM_GROWTH_MIB (default 60) of the lowest one before (the footprint rises while frames
    /// are drawn and falls a few seconds after the last, so only the lowest readings say what is kept). spam.json.
    public static func interactionSpam(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil && stage.rendererError == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let screen = NSScreen.screens.first, stage.view.real != nil else { throw CocoaError(.fileReadUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        let count = Int(env["MOKU_SPAM_COUNT"] ?? "") ?? 50, growthLimit = Double(env["MOKU_SPAM_GROWTH_MIB"] ?? "") ?? 60
        stage.setHidden(false); stage.setWorkState(.focused); stage.setMood(.content)
        stage.panel.setFrameOrigin(StageGeometry.home(in: screen.visibleFrame, scale: stage.view.scale))
        func lowestFootprint(over seconds: Int) async throws -> Double {
            var lowest = Double.infinity
            for _ in 0..<seconds { try await Task.sleep(for: .seconds(1)); lowest = min(lowest, physicalFootprint()) }
            return lowest
        }
        try await Task.sleep(for: .seconds(3))
        let startFootprint = try await lowestFootprint(over: 12)
        var kinds: [String: Any] = [:]
        func phase(_ name: String, _ run: () async throws -> Void) async throws {
            let before = processUsage(), frames = stage.totalRenderedFrames, began = CACurrentMediaTime()
            try await run()
            let elapsed = CACurrentMediaTime() - began, after = processUsage()
            let row: [String: Any] = ["seconds": elapsed, "cpuPercentOfACore": (after.cpuSeconds - before.cpuSeconds) / elapsed * 100, "frames": stage.totalRenderedFrames - frames,
                                      "framesPerSecond": Double(stage.totalRenderedFrames - frames) / elapsed, "footprintMiB": physicalFootprint().rounded()]
            kinds[name] = row
            NSLog("Spam %@: %@", name, "\(row)")
        }
        try await phase("pats") {
            for _ in 0..<count { stage.view.patted?(); try await Task.sleep(for: .milliseconds(200)) }
        }
        try await phase("hover") {
            for _ in 0..<count { stage.view.real?.setHover(true); try await Task.sleep(for: .milliseconds(250)); stage.view.real?.setHover(false); try await Task.sleep(for: .milliseconds(150)) }
        }
        let home = stage.homeOrigin(on: screen)
        try await phase("drags") {
            for _ in 0..<count {
                let origin = stage.panel.frame.origin, grip = CGPoint(x: origin.x + 160, y: origin.y + 80)
                stage.beginGrab(at: grip, press: grip)
                for i in 1...6 { stage.dragGrab(to: CGPoint(x: grip.x - CGFloat(i) * 40, y: grip.y + CGFloat(i) * 12)); try await Task.sleep(for: .milliseconds(40)) }
                stage.releaseGrab()
                try await Task.sleep(for: .milliseconds(700))
            }
        }
        try await phase("throws") {
            for _ in 0..<count {
                stage.panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - 300, y: screen.visibleFrame.minY + 200))
                let origin = stage.panel.frame.origin, grip = CGPoint(x: origin.x + 160, y: origin.y + 80)
                stage.beginGrab(at: grip, press: grip)
                for i in 1...12 { stage.dragGrab(to: CGPoint(x: grip.x - 60 + CGFloat(i) * 10, y: grip.y + CGFloat(i) * 8)); try await Task.sleep(for: .milliseconds(8)) }
                stage.releaseGrab()
                try await Task.sleep(for: .seconds(3.4))  // it flies, lands and fades home
            }
        }
        try await Task.sleep(for: .seconds(4))
        let end = try await lowestFootprint(over: 12), settledOrigin = stage.panel.frame.origin, lives = stage.homeOrigin(on: screen)
        var failures: [String] = []
        if stage.grabbing { failures.append("still held") }
        if stage.carry != nil { failures.append("still carried") }
        if stage.moving { failures.append("still moving") }
        if hypot(settledOrigin.x - lives.x, settledOrigin.y - lives.y) > 2 { failures.append(String(format: "not home: at (%.0f, %.0f), home (%.0f, %.0f)", settledOrigin.x, settledOrigin.y, lives.x, lives.y)) }
        if let error = stage.rendererError { failures.append("renderer: \(error)") }
        if end - startFootprint > growthLimit { failures.append(String(format: "the footprint grew %.0f MiB (limit %.0f)", end - startFootprint, growthLimit)) }
        _ = home
        let report: [String: Any] = ["companion": stage.companion?.rawValue ?? "none", "count": count, "kinds": kinds, "startFootprintMiB": startFootprint.rounded(), "endFootprintMiB": end.rounded(),
                                     "failures": failures, "passed": failures.isEmpty]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("spam.json"))
        print(String(format: "spam: %d of each, footprint %.0f → %.0f MiB, %@", count, startFootprint, end, failures.isEmpty ? "ok" : failures.joined(separator: "; ")))
        stage.setHidden(true)
        if !failures.isEmpty { throw NSError(domain: "MokuVisual", code: 11, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]) }
    }
}
