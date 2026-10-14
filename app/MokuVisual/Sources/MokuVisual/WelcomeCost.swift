import AppKit
import MokuKit

extension MokuVisualDiagnostics {
    /// What the welcome costs while it's open: the same scripted 40 seconds every run (open, pick the other companion
    /// and back, what it reads, the permissions, Start and the companion going home, with a pointer moving the whole
    /// time), offscreen, with the process's CPU time, instructions, frames drawn and memory footprint (sampled every half
    /// second). welcome-cost.json. (The one-window welcome it replaced was measured the same way with its film decoded
    /// alongside: assets/previews/welcome-wow/cost/before-*.json.)
    public static func welcomeCost(stage: MokuCharacterStage, directory: URL, seconds: Double = 40) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.show()
        while stage.totalRenderedFrames == 0 && stage.rendererError == nil { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .seconds(3))  // loaded and settled before the clock starts
        let presenter = MokuOnboardingPresenter(stage: stage, offscreen: true)
        let screen = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        presenter.menuBarIcon = { CGRect(x: screen.maxX - 190, y: screen.maxY - 24, width: 26, height: 24) }
        var permissions = PermissionStatus(accessibility: false, screenRecording: false)
        let context = OnboardingContext(suggestedName: "Riley", permissions: { permissions }, requestPermission: { kind in
            if kind == .accessibility { permissions.accessibility = true }
        }, launchAtLogin: { false }, setLaunchAtLogin: { _ in })

        // Every frame the renderer finishes (a companion swap brings a new renderer: it's hooked as it arrives).
        final class Frames { var times: [Double] = [] }
        let frames = Frames()
        func hook() { if let real = stage.view.real, !(real.onFrameHooked) { let previous = real.onFrame; real.onFrame = { previous?(); frames.times.append(CACurrentMediaTime()) }; real.onFrameHooked = true } }
        let cpuBefore = processCPUSeconds(), workBefore = processWork(), framesBefore = stage.totalRenderedFrames
        let memoryBefore = physicalFootprint()
        var memoryPeak = memoryBefore, memorySamples = [Double]()
        let began = CACurrentMediaTime()
        let run = Task { await presenter.run(context) }
        // A pointer drawing slow circles over the window the whole time (the eyes follow it).
        presenter.pointer = { let t = CACurrentMediaTime() * 0.9; return CGPoint(x: screen.midX + 260 * cos(t), y: screen.midY + 180 * sin(t)) }
        presenter.settingsWindow = { nil }; presenter.welcomeInFront = { true }
        let first = Companion.current
        var steps: [(Double, String, @MainActor () -> Void)] = [
            (19, "what it reads", { presenter.state.next() }),
            (24, "allow Accessibility", { presenter.state.request(.accessibility) }),
            (30, "start", { presenter.state.start() }),
        ]
        // MOKU_WELCOME_SWAPS=0 leaves out the pick of the other companion and back (what the swap adds to the peak).
        if ProcessInfo.processInfo.environment["MOKU_WELCOME_SWAPS"] != "0" {
            steps.insert((10, "pick the other companion", { if let other = Companion.available.first(where: { $0 != first }) { presenter.state.choose(other) } }), at: 0)
            steps.insert((16, "and back", { presenter.state.choose(first) }), at: 1)
        }
        var next = 0
        while CACurrentMediaTime() - began < seconds {
            let t = CACurrentMediaTime() - began
            while next < steps.count, steps[next].0 <= t { steps[next].2(); next += 1 }
            hook()
            let memory = physicalFootprint(); memoryPeak = max(memoryPeak, memory)
            if Int(t * 2) > memorySamples.count - 1 { memorySamples.append(memory) }
            try await Task.sleep(for: .milliseconds(100))
        }
        let elapsed = CACurrentMediaTime() - began
        let cpu = processCPUSeconds() - cpuBefore, work = processWork()
        if !run.isCancelled { presenter.finish(completed: false) }
        _ = await run.value
        // Smoothness: the gaps between finished frames while it was drawing (gaps over 200 ms are rests, not stutters).
        // At the welcome's cap of 30 a second a frame is due every 33 ms; one over 50 ms is a dropped frame.
        let gaps = zip(frames.times, frames.times.dropFirst()).map { ($1 - $0) * 1000 }.filter { $0 < 200 }.sorted()
        func at(_ q: Double) -> Double { gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(Double(gaps.count) * q))] }
        let report: [String: Any] = [
            "frameGapsMs": ["count": gaps.count, "median": at(0.5), "p90": at(0.9), "p99": at(0.99), "max": gaps.last ?? 0, "over50": gaps.filter { $0 > 50 }.count],
            "seconds": elapsed, "companion": Companion.current.rawValue, 
            "processCPUSeconds": cpu, "processCPUPercentOfACore": cpu / elapsed * 100,
            "processInstructionsBillions": Double(work.instructions &- workBefore.instructions) / 1e9,
            "framesDrawn": stage.totalRenderedFrames - framesBefore,
            "memoryMiB": ["before": memoryBefore, "peak": memoryPeak, "end": physicalFootprint(), "samples": memorySamples],
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("welcome-cost.json"))
        stage.setHidden(true)
    }
}
