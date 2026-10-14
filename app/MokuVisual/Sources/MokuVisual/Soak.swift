import AppKit
import Darwin
import MokuKit

extension MokuVisualDiagnostics {
    /// One line of the engine's stage commands (mokumind-qa --commands): seconds into the session, the command, its arguments.
    struct SoakCommand { var t: Double; var name: String; var args: [String] }

    static func soakCommands(_ file: URL) throws -> [SoakCommand] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, let t = Double(parts[0]) else { return nil }
            return SoakCommand(t: t, name: parts[1], args: Array(parts.dropFirst(2)))
        }
    }

    /// Plays one command on the stage. `speed`: how many times faster than real time the session runs (a bubble's or a
    /// break's length shortens with it, down to a floor, so they keep their place among the commands around them).
    @MainActor static func play(_ command: SoakCommand, on stage: MokuCharacterStage, speed: Double) async {
        let a = command.args
        switch command.name {
        case "setMood": if let mood = a.first.flatMap(Mood.init(rawValue:)) { stage.setMood(mood) }
        case "setAttention":
            switch a.first {
            case "user": stage.setAttention(.user)
            case "wander": stage.setAttention(.wander)
            case "point": if a.count >= 3, let x = Double(a[1]), let y = Double(a[2]) { stage.setAttention(.point(CGPoint(x: x, y: y))) }
            default: break
            }
        case "perform": if let gesture = a.first.flatMap(Gesture.init(rawValue:)) { stage.perform(gesture) }
        case "move":
            switch a.first {
            case "home": await stage.move(to: .home)
            case "center": await stage.move(to: .center)
            case "near": if a.count >= 3, let x = Double(a[1]), let y = Double(a[2]) { await stage.move(to: .near(CGPoint(x: x, y: y))) }
            default: break
            }
        case "say":
            if a.count >= 3 {
                let tone = SpeechLine.Tone(rawValue: a[0]) ?? .warm
                let seconds = a[1] == "forever" ? SpeechLine.untilDismissed : max(1.5, (Double(a[1]) ?? 6) / speed)
                stage.say(SpeechLine(text: a[2...].joined(separator: " "), tone: tone, duration: seconds))
            }
        case "think": stage.think()
        case "dismissSpeech": stage.dismissSpeech()
        case "setHidden": stage.setHidden(a.first == "true")
        case "showThreadLabel": stage.showThreadLabel(a.first ?? "")
        case "setWorkState": if let state = a.first.flatMap(WorkState.init(rawValue:)) { stage.setWorkState(state) }
        case "celebrateReturn": stage.celebrateReturn(a.first == "full" ? .full : .small)
        case "breakTimer":
            if let offset = a.first.flatMap(Double.init), a.count >= 2, let total = Double(a[1]) {
                stage.setBreakTimer(until: Date().addingTimeInterval(max(2, offset / speed)), total: max(2, total / speed))
            } else { stage.setBreakTimer(until: nil, total: 0) }
        default: break
        }
    }

    /// `--soak <dir>`: the stage under a long run of the engine's own stream (launch QA, lens 3, parameter 2: the soak).
    /// MOKU_SOAK_COMMANDS is a file of stage commands (`mokumind-qa --sessions soak --commands <file>`); MOKU_SOAK_HOURS
    /// (default 2) of the session's time, from MOKU_SOAK_FROM hours in (default 0), are played at MOKU_SOAK_SPEED times
    /// real time (default 6; 1 for real time), sampling every
    /// MOKU_SOAK_SAMPLE seconds (default 10): memory footprint, CPU as a share of a core, frames drawn, wakeups and
    /// instructions. soak.json has the samples and: the footprint's growth an hour (a least-squares line through the
    /// second half, past the settling), the CPU's mean and 95th percentile, and the frames drawn.
    /// The check fails if the footprint grows more than MOKU_SOAK_GROWTH_MIB_PER_HOUR (default 25) a simulated hour.
    public static func soak(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil && stage.rendererError == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard stage.view.real != nil else { throw CocoaError(.fileReadUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        guard let file = env["MOKU_SOAK_COMMANDS"] else { throw NSError(domain: "MokuVisual", code: 9, userInfo: [NSLocalizedDescriptionKey: "MOKU_SOAK_COMMANDS: a file from mokumind-qa --commands"]) }
        let hours = Double(env["MOKU_SOAK_HOURS"] ?? "") ?? 2, speed = max(1, Double(env["MOKU_SOAK_SPEED"] ?? "") ?? 6)
        let every = Double(env["MOKU_SOAK_SAMPLE"] ?? "") ?? 10, growthLimit = Double(env["MOKU_SOAK_GROWTH_MIB_PER_HOUR"] ?? "") ?? 25
        let from = (Double(env["MOKU_SOAK_FROM"] ?? "") ?? 0) * 3600  // start this far into the session (a window of it)
        let commands = try soakCommands(URL(fileURLWithPath: file)).filter { $0.t >= from && $0.t <= from + hours * 3600 }.map { SoakCommand(t: $0.t - from, name: $0.name, args: $0.args) }
        stage.setHidden(false); stage.setWorkState(.focused); stage.setMood(.content)
        try await Task.sleep(for: .seconds(4))

        struct Sample { var real: Double, simulated: Double, footprintMiB: Double, cpuPercent: Double, frames: Int, wakeups: Double, instructionsBillions: Double }
        var samples: [Sample] = []
        var lastUsage = processUsage(), lastFrames = stage.totalRenderedFrames, lastSampleAt = CACurrentMediaTime()
        let began = CACurrentMediaTime(), startFrames = lastFrames, startUsage = lastUsage
        func sample() {
            let now = CACurrentMediaTime(), usage = processUsage(), frames = stage.totalRenderedFrames, elapsed = now - lastSampleAt
            guard elapsed > 0.5 else { return }
            samples.append(Sample(real: now - began, simulated: (now - began) * speed, footprintMiB: physicalFootprint(), cpuPercent: (usage.cpuSeconds - lastUsage.cpuSeconds) / elapsed * 100,
                                  frames: frames - lastFrames, wakeups: Double((usage.packageIdleWakeups &- lastUsage.packageIdleWakeups) + (usage.interruptWakeups &- lastUsage.interruptWakeups)) / elapsed,
                                  instructionsBillions: Double(usage.instructions &- lastUsage.instructions) / 1e9))
            lastUsage = usage; lastFrames = frames; lastSampleAt = now
            if samples.count % 6 == 0, let s = samples.last { NSLog("Soak %.0f min simulated: %.0f MiB, %.1f%% CPU", s.simulated / 60, s.footprintMiB, s.cpuPercent) }
        }
        let sampler = Task { @MainActor in while !Task.isCancelled { try? await Task.sleep(for: .seconds(every)); sample() } }
        for command in commands {
            let wait = command.t / speed - (CACurrentMediaTime() - began)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            await play(command, on: stage, speed: speed)
        }
        let end = (hours * 3600) / speed - (CACurrentMediaTime() - began)
        if end > 0 { try await Task.sleep(for: .seconds(end)) }
        sampler.cancel(); sample()

        func percentile(_ values: [Double], _ q: Double) -> Double { values.isEmpty ? 0 : values.sorted()[min(values.count - 1, Int(Double(values.count) * q))] }
        let footprints = samples.map(\.footprintMiB), cpu = samples.map(\.cpuPercent)
        // The footprint's trend over the second half of the run (the first half is the load, the moods and the clips settling).
        let half = samples.suffix(samples.count / 2)
        var slope = 0.0  // MiB per simulated hour
        if half.count >= 4 {
            let xs = half.map { $0.simulated / 3600 }, ys = half.map(\.footprintMiB), mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            let covariance = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }, variance = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
            slope = variance > 0 ? covariance / variance : 0
        }
        let finishUsage = processUsage(), wall = CACurrentMediaTime() - began
        let report: [String: Any] = [
            "companion": stage.companion?.rawValue ?? "none", "simulatedHours": hours, "speed": speed, "realMinutes": wall / 60, "commands": commands.count,
            "framesDrawn": stage.totalRenderedFrames - startFrames, "meanCPUPercentOfACore": (finishUsage.cpuSeconds - startUsage.cpuSeconds) / wall * 100,
            "p95CPUPercentOfACore": percentile(cpu, 0.95), "maxCPUPercentOfACore": cpu.max() ?? 0,
            "footprintMiB": ["first": footprints.first ?? 0, "last": footprints.last ?? 0, "min": footprints.min() ?? 0, "max": footprints.max() ?? 0, "median": percentile(footprints, 0.5), "p95": percentile(footprints, 0.95)],
            "footprintGrowthMiBPerSimulatedHour": slope, "wakeupsPerSecond": Double((finishUsage.packageIdleWakeups &- startUsage.packageIdleWakeups) + (finishUsage.interruptWakeups &- startUsage.interruptWakeups)) / wall,
            "instructionsBillions": Double(finishUsage.instructions &- startUsage.instructions) / 1e9, "errors": stage.rendererError ?? "none",
            "samples": samples.map { ["real": $0.real, "simulated": $0.simulated, "footprintMiB": $0.footprintMiB, "cpuPercent": $0.cpuPercent, "frames": $0.frames, "wakeups": $0.wakeups] },
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("soak.json"))
        print(String(format: "soak: %@ %.1f simulated hours in %.1f min (%.0f×), footprint %.0f → %.0f MiB (peak %.0f, growth %+.1f MiB/h), CPU mean %.1f%% p95 %.1f%%, %d frames",
                     stage.companion?.rawValue ?? "?", hours, wall / 60, speed, footprints.first ?? 0, footprints.last ?? 0, footprints.max() ?? 0, slope, report["meanCPUPercentOfACore"] as? Double ?? 0, percentile(cpu, 0.95), stage.totalRenderedFrames - startFrames))
        stage.setHidden(true)
        if slope > growthLimit { throw NSError(domain: "MokuVisual", code: 10, userInfo: [NSLocalizedDescriptionKey: String(format: "the footprint grows %.1f MiB per simulated hour (limit %.0f)", slope, growthLimit)]) }
    }
}
