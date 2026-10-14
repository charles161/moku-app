import AppKit
import Darwin
import MokuKit

extension MokuVisualDiagnostics {
    /// Everything the kernel counts for this process: CPU time, wakeups, the energy it estimates, instructions.
    struct ProcessUsage {
        var cpuSeconds = 0.0, packageIdleWakeups: UInt64 = 0, interruptWakeups: UInt64 = 0, energyNanojoules: UInt64 = 0
        var instructions: UInt64 = 0, cycles: UInt64 = 0
    }

    static func processUsage() -> ProcessUsage {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) } }
        guard result == 0 else { return ProcessUsage() }
        var timebase = mach_timebase_info(); mach_timebase_info(&timebase)
        let seconds = Double(info.ri_user_time &+ info.ri_system_time) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        return ProcessUsage(cpuSeconds: seconds, packageIdleWakeups: info.ri_pkg_idle_wkups, interruptWakeups: info.ri_interrupt_wkups,
                            energyNanojoules: info.ri_energy_nj, instructions: info.ri_instructions, cycles: info.ri_cycles)
    }

    /// `--idle-energy <dir>`: what the companion costs while nothing is scripted, in the states a working day is made of,
    /// with the stage's own life running (its 10 Hz tick, blinks, glances, fidgets, ear flicks, breathing). Per state, over
    /// MOKU_IDLE_SECONDS (default 60): CPU as a share of a core, wakeups a second (the kernel's package-idle wakeups and
    /// interrupt wakeups: what keeps the Mac out of its deep idle states), frames drawn and the longest stretch with none,
    /// the energy the kernel estimates for the process (milliwatts), and instructions retired. idle-energy.json.
    /// The check fails if the working state retires more than MOKU_IDLE_INSTR_BUDGET billions of instructions a minute
    /// (default 18: about 3% of a core on a quiet Mac; the share of a core itself swings with the Mac's load, so it's
    /// reported, not budgeted), or if the hidden state draws more than 0.1 frames a second. (A hidden
    /// process still shows about 20 wakeups a second: a thread in the USD library that RealityKit's imports start polls
    /// at 50 ms for the rest of the process's life, 0.3 mW.)
    public static func idleEnergy(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil && stage.rendererError == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let real = stage.view.real else { throw CocoaError(.fileReadUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        let seconds = Double(env["MOKU_IDLE_SECONDS"] ?? "") ?? 60
        let workingBudget = Double(env["MOKU_IDLE_INSTR_BUDGET"] ?? "") ?? 18
        let states: [(String, @MainActor () -> Void)] = [
            ("hidden", { stage.setHidden(true) }),
            ("working", { stage.setHidden(false); stage.setWorkState(.focused); stage.setMood(.content); stage.setAttention(.point(CGPoint(x: 600, y: 500))) }),
            ("break (dozing)", { stage.setHidden(false); stage.setWorkState(.onBreak); stage.setMood(.sleepy); stage.setAttention(.wander) }),
            ("drift (sad)", { stage.setHidden(false); stage.setWorkState(.noticing); stage.setMood(.disappointed); stage.setAttention(.user) }),
        ]
        let only = env["MOKU_IDLE_STATES"].map { Set($0.split(separator: ",").map(String.init)) }  // e.g. working,drift
        var report: [String: Any] = ["companion": real.companion.rawValue, "seconds": seconds]
        var failures: [String] = []
        for (name, enter) in states {
            if let only, !only.contains(name.split(separator: " ").first.map(String.init) ?? name) { continue }
            enter()
            try await Task.sleep(for: .seconds(6))  // the mood and gaze settle
            let current = stage.view.real
            var frameTimes: [Double] = []
            let previous = current?.onFrame
            current?.onFrame = { previous?(); frameTimes.append(CACurrentMediaTime()) }
            let before = processUsage(), framesBefore = current?.renderedFrames ?? 0, began = CACurrentMediaTime()
            let skipsBefore = current?.busySkips ?? 0
            let eventsBefore = current?.lifeEvents ?? [:], microsBefore = current?.microCount ?? 0, hitsBefore = current?.microCacheHits ?? 0
            try await Task.sleep(for: .seconds(seconds))
            let elapsed = CACurrentMediaTime() - began, after = processUsage()
            current?.onFrame = previous
            let gaps = zip(frameTimes, frameTimes.dropFirst()).map { $1 - $0 }.filter { $0 < 0.25 }.sorted()  // gaps inside a burst of frames
            let wakeups = Double((after.packageIdleWakeups &- before.packageIdleWakeups) + (after.interruptWakeups &- before.interruptWakeups)) / elapsed
            let row: [String: Any] = [
                "cpuPercentOfACore": (after.cpuSeconds - before.cpuSeconds) / elapsed * 100,
                "wakeupsPerSecond": wakeups,
                "packageIdleWakeupsPerSecond": Double(after.packageIdleWakeups &- before.packageIdleWakeups) / elapsed,
                "framesDrawn": (current?.renderedFrames ?? 0) - framesBefore, "framesPerSecond": Double((current?.renderedFrames ?? 0) - framesBefore) / elapsed,
                "longestQuietSeconds": zip(frameTimes, frameTimes.dropFirst()).map { $1 - $0 }.max() ?? elapsed,
                "burstFrameGapP95Ms": (gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(Double(gaps.count) * 0.95))]) * 1000, "burstFrameGapMaxMs": (gaps.last ?? 0) * 1000,
                "displayTicksSkippedWhileDrawing": (current?.busySkips ?? 0) - skipsBefore,
                "energyMilliwatts": Double(after.energyNanojoules &- before.energyNanojoules) / elapsed / 1e6,
                "instructionsBillionsPerMinute": Double(after.instructions &- before.instructions) / elapsed * 60 / 1e9,
                "footprintMiB": physicalFootprint().rounded(),
                "lifeEvents": (current?.lifeEvents ?? [:]).merging(eventsBefore) { $0 - $1 }.filter { $0.value != 0 },
                "microExpressions": (current?.microCount ?? 0) - microsBefore, "microCacheHits": (current?.microCacheHits ?? 0) - hitsBefore,
                "microCacheFrames": current?.microCacheFrames ?? 0,
            ]
            report[name] = row
            NSLog("Idle %@: %@", name, "\(row)")
            if name == "working", let work = row["instructionsBillionsPerMinute"] as? Double, work > workingBudget { failures.append(String(format: "working retires %.1f B instructions a minute, over the %.1f budget", work, workingBudget)) }
            if name == "hidden", let fps = row["framesPerSecond"] as? Double, fps > 0.1 { failures.append(String(format: "hidden still draws %.2f frames a second", fps)) }
        }
        report["failures"] = failures
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("idle-energy.json"))
        print(report.filter { $0.key != "failures" }.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
        stage.setHidden(true)
        if !failures.isEmpty { throw NSError(domain: "MokuVisual", code: 8, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]) }
    }
}
