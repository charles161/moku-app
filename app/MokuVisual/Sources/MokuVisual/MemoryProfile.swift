import AppKit
import MokuKit

extension MokuVisualDiagnostics {
    /// `--memory-profile <dir>`: what the companion on stage holds in memory through a day's states, and whether it
    /// stays within a budget (the launch bar, docs/specs/launch-qa.md lens 3). The physical footprint (what Activity
    /// Monitor shows as Memory) is read after each phase has settled; memory.json has every phase, the launch time to
    /// the first frame, and the verdict. The footprint is also sampled every two seconds through the steady phases
    /// (everything but the load and the companion switch): it rises while frames are drawn and falls a few seconds after
    /// the last one, so a single reading says little. (After a switch the footprint keeps what RealityKit cached of the other
    /// companion, 90 to 190 MB: reported in the phases, not budgeted.) The check fails if the median of those samples is over
    /// `MOKU_MEMORY_BUDGET_MIB` (default 480) or their 95th percentile over `MOKU_MEMORY_PEAK_MIB` (default 560): the bar the build keeps, 20 to 40 MB over what it measures today (458 and 442 while frames draw, 330 a few seconds after the last; the launch target of 250 is not reached, see docs/specs/launch-qa.md), or if a
    /// switched-away companion is still alive. Run it as the app runs, with `MallocSpaceEfficient=1` in the environment.
    ///
    /// The phases: loaded, idle (working), every mood, every gesture, speech, a drift and the return, a move away and
    /// home, a pat, quiet again, a switch to the other companion and back (each: is the old one freed?), hidden,
    /// and half a minute of working quietly.
    public static func memoryProfile(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil && stage.rendererError == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let companion = stage.view.real?.companion else { throw CocoaError(.fileReadUnknown) }  // never hold the character itself: a held one is never freed
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        let budget = Double(env["MOKU_MEMORY_BUDGET_MIB"] ?? "") ?? 480, peakBudget = Double(env["MOKU_MEMORY_PEAK_MIB"] ?? "") ?? 560
        let hold = Double(env["MOKU_MEMORY_HOLD_SECONDS"] ?? "") ?? 0
        let quick = env["MOKU_MEMORY_QUICK"] == "1"  // skips the long phases (experiments)
        var phases: [[String: Any]] = []
        var steady: [(String, Double)] = []
        // The footprint every two seconds, except while loading or switching.
        var series: [Double] = [], sampling = false
        let sampler = Task { @MainActor in while !Task.isCancelled { try? await Task.sleep(for: .seconds(2)); if sampling { series.append(physicalFootprint()) } }}
        defer { sampler.cancel() }
        let launched = CACurrentMediaTime()
        func note(_ name: String, transient: Bool = false) {
            let now = physicalFootprint()
            phases.append(["phase": name, "footprintMiB": now.rounded(), "peakMiB": peakPhysicalFootprint().rounded(), "seconds": ((CACurrentMediaTime() - launched) * 10).rounded() / 10])
            if !transient { steady.append((name, now)) }
            NSLog("Moku memory %@: %.0f MiB (peak %.0f)", name, now, peakPhysicalFootprint())
        }
        stage.setHidden(false)
        try await Task.sleep(for: .seconds(3))
        note("loaded", transient: true)
        sampling = true
        stage.setWorkState(.focused); stage.setMood(.content); stage.watchScreenCenter()
        try await Task.sleep(for: .seconds(quick ? 6 : 10)); note("working")
        if hold > 0 { NSLog("Moku memory: holding %.0f s for vmmap/heap", hold); try await Task.sleep(for: .seconds(hold)) }

        if !quick {
            for mood in Mood.allCases { stage.setMood(mood); try await Task.sleep(for: .seconds(2.5)) }
            stage.setMood(.content); try await Task.sleep(for: .seconds(2)); note("every mood")
            for gesture in Gesture.allCases where gesture != .standUp && gesture != .sitDown { stage.perform(gesture); try await Task.sleep(for: .seconds(3)) }
            note("every gesture")
            for (tone, text) in [(SpeechLine.Tone.warm, "There you are."), (.firm, "Friend."), (.cheerful, "Look what we built.")] {
                stage.say(SpeechLine(text: text, tone: tone, duration: 2)); try await Task.sleep(for: .seconds(2.6))
            }
            note("speech")
            stage.setWorkState(.noticing); stage.setMood(.disappointed); stage.setAttention(.user); try await Task.sleep(for: .seconds(3))
            stage.setWorkState(.drifting); stage.setMood(.annoyed); try await Task.sleep(for: .seconds(4))
            stage.setWorkState(.focused); stage.setMood(.happy); stage.celebrateReturn(.full); try await Task.sleep(for: .seconds(4))
            stage.setMood(.content); stage.watchScreenCenter(); note("a drift and the return")
            await stage.move(to: .center); try await Task.sleep(for: .seconds(1)); await stage.move(to: .home)
            note("a move away and home")
            stage.perform(.patReaction); try await Task.sleep(for: .seconds(2)); stage.view.real?.setHover(true); try await Task.sleep(for: .seconds(2)); stage.view.real?.setHover(false)
            for expression in [MicroExpression.smile, .slowBlink, .brow, .ear] { stage.view.real?.microExpression(expression); try await Task.sleep(for: .seconds(2)) }
            try await Task.sleep(for: .seconds(8)); note("after a day's states")
        }

        // The Mac says it is short of memory: what does Moku let go of? The footprint rises and falls with the drawing, so
        // it is read for eight seconds on either side (every second): the median and the lowest reading.
        func watch(_ seconds: Int) async throws -> (median: Double, lowest: Double) {
            var readings: [Double] = []
            for _ in 0..<seconds { try await Task.sleep(for: .seconds(1)); readings.append(physicalFootprint()) }
            return (readings.sorted()[readings.count / 2], readings.min() ?? 0)
        }
        let before = try await watch(8)
        stage.view.real?.relieveMemory()
        let after = try await watch(8)
        phases.append(["phase": "after a memory-pressure event", "footprintMiB": after.median.rounded(), "beforeMedianMiB": before.median.rounded(), "beforeLowestMiB": before.lowest.rounded(),
                       "afterLowestMiB": after.lowest.rounded(), "peakMiB": peakPhysicalFootprint().rounded(), "seconds": ((CACurrentMediaTime() - launched) * 10).rounded() / 10])
        NSLog("Moku memory pressure relief: median %.0f → %.0f MiB, lowest %.0f → %.0f MiB", before.median, after.median, before.lowest, after.lowest)
        if !quick { stage.perform(.nod); try await Task.sleep(for: .seconds(3)); stage.perform(.drinkWater); try await Task.sleep(for: .seconds(14)) }  // what it let go of loads again, with no error

        // Switching: the other companion loads, the first must be freed.
        var switches: [[String: Any]] = []
        if Companion.available.count > 1 && env["MOKU_MEMORY_SWITCH"] != "0" {
            sampling = false
            weak var previous: RealityCharacter?
            for target in [Companion.available.first { $0 != companion }!, companion] {
                previous = stage.view.real
                let began = CACurrentMediaTime()
                CompanionChoice.choose(target)
                while (stage.companion != target || stage.totalRenderedFrames < 5) && CACurrentMediaTime() - began < 60 { try await Task.sleep(for: .milliseconds(100)) }
                let onStage = CACurrentMediaTime() - began
                try await Task.sleep(for: .seconds(6))
                let freed = previous == nil
                note("switched to \(target.rawValue)", transient: true)
                steady.append(("switched to \(target.rawValue) (+6 s)", physicalFootprint()))
                switches.append(["to": target.rawValue, "onStageSeconds": (onStage * 10).rounded() / 10, "previousFreed": freed, "footprintMiB": physicalFootprint().rounded()])
            }
        }
        if !switches.isEmpty {
            try await Task.sleep(for: .seconds(20)); note("20 s after switching", transient: true)
            malloc_zone_pressure_relief(nil, 0); try await Task.sleep(for: .seconds(2)); note("after malloc pressure relief", transient: true)
        }
        sampling = switches.isEmpty  // after a switch the footprint keeps what the framework cached of the other companion: noted, not budgeted
        stage.setHidden(true); try await Task.sleep(for: .seconds(5)); note("hidden")
        stage.setHidden(false); try await Task.sleep(for: .seconds(quick ? 5 : 30)); note("quiet again")

        sampling = false
        let peak = peakPhysicalFootprint()
        let worst = steady.max { $0.1 < $1.1 }, ordered = series.sorted()
        let median = ordered.isEmpty ? 0 : ordered[ordered.count / 2], p95 = ordered.isEmpty ? 0 : ordered[min(ordered.count - 1, Int(Double(ordered.count) * 0.95))]
        var failures: [String] = []
        if median > budget { failures.append(String(format: "the median footprint is %.0f MiB, over the %.0f MiB budget", median, budget)) }
        if p95 > peakBudget { failures.append(String(format: "the 95th percentile footprint is %.0f MiB, over %.0f MiB", p95, peakBudget)) }
        for entry in switches where entry["previousFreed"] as? Bool == false { failures.append("the companion switched away from (to \(entry["to"] ?? "?")) is still in memory") }
        let report: [String: Any] = ["companion": companion.rawValue, "launchToFirstFrameSeconds": ((stage.firstVisibleProcessAge ?? 0) * 10).rounded() / 10, "stageToFirstFrameSeconds": ((stage.firstVisibleSeconds ?? 0) * 10).rounded() / 10,
                                     "budgetMiB": budget, "peakBudgetMiB": peakBudget, "steadyMedianMiB": median.rounded(), "steadyP95MiB": p95.rounded(), "steadySamples": series.count, "peakMiB": peak.rounded(), "worstSteady": worst.map { ["phase": $0.0, "footprintMiB": $0.1.rounded()] } ?? [:],
                                     "phases": phases, "switches": switches, "failures": failures, "passed": failures.isEmpty]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("memory.json"))
        print(String(format: "memory: %@ steady median %.0f MiB, p95 %.0f MiB (%d samples), worst phase %.0f MiB (%@), peak %.0f MiB, budget %.0f / %.0f MiB: %@", companion.rawValue, median, p95, series.count, worst?.1 ?? 0, worst?.0 ?? "-", peak, budget, peakBudget, failures.isEmpty ? "ok" : failures.joined(separator: "; ")))
        stage.setHidden(true)
        if !failures.isEmpty { throw NSError(domain: "MokuVisual", code: 7, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]) }
    }
}
