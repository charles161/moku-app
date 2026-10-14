import AppKit
import Darwin
import MokuKit

extension MokuVisualDiagnostics {
    /// The same scripted minute every run, for comparing what Moku's drawing costs before and after a change: blinks,
    /// glances, a look-up with a smile, moods, a drift (sad, then cross) and the return. The stage's own 10 Hz tick
    /// (random blinks, ear flicks, fidgets) is stopped, so only the script moves Moku. Writes energy.json: the
    /// process's and the main thread's CPU time, frames drawn, main-thread milliseconds per frame (render + finish),
    /// the face morphs' milliseconds per update, and the gaps between finished frames.
    public static func energyMinute(stage: MokuCharacterStage, directory: URL, seconds: Double = 60) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let real = stage.view.real else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.timer?.invalidate(); stage.timer = nil
        stage.setWorkState(.focused); stage.setMood(.content); stage.watchScreenCenter()
        try await Task.sleep(for: .seconds(4))  // settled and asleep before the clock starts

        final class Log { var frames: [Double] = []; var main: [Double] = []; var morph: [Double] = [] }
        let log = Log(), previous = real.onFrame
        real.onFrame = { previous?(); log.frames.append(CACurrentMediaTime()) }
        let mainCostsBefore = real.mainCostsTotal, morphBefore = real.morphCosts.count, displayBefore = real.displayCosts.count
        let framesBefore = real.renderedFrames, skipsBefore = real.busySkips, heldBefore = real.faceChangesHeldBack, rebuildsBefore = real.faceRebuilds
        let cpuBefore = processCPUSeconds(), mainBefore = mainThreadCPUSeconds(), workBefore = processWork()
        let began = CACurrentMediaTime()

        let left = SIMD2<Float>(-0.55, 0.15), right = SIMD2<Float>(0.35, -0.1)
        var script: [(Double, String, @MainActor () -> Void)] = [
            (3, "glance left", { real.look(left) }),
            (7, "back to the screen", { stage.watchScreenCenter() }),
            (9, "look up and smile", { stage.glance(.smile) }),
            (14, "happy", { stage.setMood(.happy); stage.perform(.smile) }),
            (18, "content", { stage.setMood(.content) }),
            (20, "curious", { stage.setMood(.curious) }),
            (24, "content", { stage.setMood(.content) }),
            (26, "drift: grace", { stage.setWorkState(.grace) }),
            (27, "drift: sad", { stage.setWorkState(.noticing); stage.setMood(.disappointed) }),
            (33, "drift: cross", { stage.setMood(.annoyed) }),
            (38, "the return", { stage.setWorkState(.focused); stage.setMood(.happy); stage.celebrateReturn(.full) }),
            (43, "content", { stage.setMood(.content) }),
            (46, "ear flick", { real.flickEar() }),
            (50, "glance right", { real.look(right) }),
            (53, "back to the screen", { stage.watchScreenCenter() }),
        ]
        for t in stride(from: 2.0, to: seconds - 1, by: 4.5) { script.append((t, "blink", { real.blink() })) }
        for (at, _, action) in script.sorted(by: { $0.0 < $1.0 }) {
            let wait = at - (CACurrentMediaTime() - began)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            action()
        }
        let rest = seconds - (CACurrentMediaTime() - began)
        if rest > 0 { try await Task.sleep(for: .seconds(rest)) }
        let elapsed = CACurrentMediaTime() - began
        let cpu = processCPUSeconds() - cpuBefore, mainCPU = mainThreadCPUSeconds() - mainBefore
        let work = processWork(), instructions = Double(work.instructions &- workBefore.instructions), cycles = Double(work.cycles &- workBefore.cycles)
        real.onFrame = previous

        let frames = log.frames.filter { $0 >= began }
        let gaps = zip(frames, frames.dropFirst()).map { ($1 - $0) * 1000 }.filter { $0 < 200 }  // within animated stretches
        let main = real.mainCostsTotal.subtracting(mainCostsBefore)
        let morph = Array(real.morphCosts.dropFirst(morphBefore)).map { $0 * 1000 }
        let animatedSeconds = Set(frames.map { Int(($0 - began) * 4) }).count  // quarter-seconds with a frame
        func stats(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return ["count": 0] }
            func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
            return ["count": Double(sorted.count), "mean": sorted.reduce(0, +) / Double(sorted.count), "median": at(0.5), "p90": at(0.9), "p99": at(0.99), "max": sorted.last!]
        }
        let histogram = Dictionary(grouping: gaps, by: { min(100, Int(($0 / 4.1666).rounded()) * 4) }).mapValues(\.count)
        let report: [String: Any] = [
            "seconds": elapsed, "framesDrawn": real.renderedFrames - framesBefore, "framesShown": frames.count,
            "animatedSeconds": Double(animatedSeconds) / 4,
            "processCPUSeconds": cpu, "processCPUPercentOfACore": cpu / elapsed * 100,
            // Work done, not time taken: instructions and cycles retired by all of the process's threads. Steadier than
            // CPU time when the Mac is busy with other things (time spent waiting on a contended core still counts).
            "processInstructionsBillions": instructions / 1e9, "processCyclesBillions": cycles / 1e9,
            "mainThreadCPUSeconds": mainCPU, "mainThreadCPUPercentOfACore": mainCPU / elapsed * 100,
            "mainThreadMsPerFrame": ["render": stats(main.render.map { $0 * 1000 }), "finish": stats(main.finish.map { $0 * 1000 }),
                                     "total": stats(zip(main.render, main.finish).map { ($0 + $1) * 1000 })],
            "faceMorphMsPerUpdate": stats(morph), "faceMorphMsTotal": morph.reduce(0, +),
            "faceRebuilds": real.faceRebuilds - rebuildsBefore, "faceChangesHeldBack": real.faceChangesHeldBack - heldBefore,
            "displayMsPerRedraw": stats(Array(real.displayCosts.dropFirst(displayBefore)).map { $0 * 1000 }),
            "poseMsPerFrame": stats(real.frameCosts.map { $0.pose * 1000 }),
            "frameGapMs": stats(gaps), "frameGapHistogramMs": Dictionary(uniqueKeysWithValues: histogram.map { (String($0.key), $0.value) }),
            "framesPerAnimatedSecond": Double(frames.count) / max(0.25, Double(animatedSeconds) / 4),
            "onScreen": stage.panel.isVisible, "renderPath": real.renderPathDescription,
            "displayTicksSkippedWhileDrawing": real.busySkips - skipsBefore,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("energy.json"))
        print(String(format: "work: %.2f billion instructions, %.2f billion cycles", instructions / 1e9, cycles / 1e9))
        print(String(format: "energy: %.1f%% of a core (main thread %.1f%%), %d frames, %d ticks skipped, main %.2f ms/frame, morphs %.2f ms × %d",
                     cpu / elapsed * 100, mainCPU / elapsed * 100, frames.count, real.busySkips - skipsBefore,
                     (main.render.reduce(0, +) + main.finish.reduce(0, +)) * 1000 / Double(max(1, main.render.count)),
                     morph.reduce(0, +) / Double(max(1, morph.count)), morph.count))
    }

    /// Instructions and cycles retired by this process so far (proc_pid_rusage, RUSAGE_INFO_V4).
    static func processWork() -> (instructions: UInt64, cycles: UInt64) {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) } }
        return result == 0 ? (info.ri_instructions, info.ri_cycles) : (0, 0)
    }

    static func processCPUSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    /// Called on the main actor, so the current thread is the main thread.
    static func mainThreadCPUSeconds() -> Double {
        let thread = pthread_mach_thread_np(pthread_self())
        var info = thread_basic_info(), count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) } }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6 + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
    }
}

/// Main-thread seconds per frame, every frame since launch (diagnostics; the recent-frames list keeps only 600).
struct FrameCostLedger {
    private(set) var render: [Double] = []
    private(set) var finish: [Double] = []
    mutating func append(render: Double, finish: Double) {
        guard self.render.count < 200_000 else { return }
        self.render.append(render); self.finish.append(finish)
    }
    func subtracting(_ earlier: FrameCostLedger) -> FrameCostLedger {
        var rest = FrameCostLedger()
        rest.render = Array(render.dropFirst(earlier.render.count)); rest.finish = Array(finish.dropFirst(earlier.finish.count))
        return rest
    }
}
