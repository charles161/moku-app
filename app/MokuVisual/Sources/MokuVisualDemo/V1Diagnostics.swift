import AppKit
import MokuKit
import MokuVisual

@MainActor func captureV1(model: DemoModel, directory: String) async {
    let stage = model.stage, folder = URL(fileURLWithPath: directory)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    stage.setHidden(false); try? await Task.sleep(for: .seconds(3))
    var checks: [String: Any] = [:]
    for mood in Mood.allCases {
        stage.setMood(mood); stage.setAttention(.user)
        try? await Task.sleep(for: .seconds(2.5))
        try? stage.capture(to: folder.appendingPathComponent("front-\(mood.rawValue).png"))
        if [.content, .sleepy, .disappointed].contains(mood) { stage.setAttention(.point(CGPoint(x: 0, y: 1400))) }
        try? await Task.sleep(for: .seconds(0.6))
        try? stage.capture(to: folder.appendingPathComponent("usual-\(mood.rawValue).png"))
        try? MokuVisualDiagnostics.captureStage(stage: stage, to: folder.appendingPathComponent("stage-\(mood.rawValue).png"))
    }
    stage.setMood(.content); stage.setWorkState(.focused); stage.setAttention(.point(CGPoint(x: 0, y: 1400)))
    try? await Task.sleep(for: .seconds(2))
    try? stage.capture(to: folder.appendingPathComponent("gaze-work.png"))
    stage.setWorkState(.grace); stage.setAttention(.point(CGPoint(x: 1800, y: 50)))
    try? await Task.sleep(for: .seconds(0.5))
    try? stage.capture(to: folder.appendingPathComponent("gaze-hold.png"))
    checks["holdsPlace"] = MokuVisualDiagnostics.state(stage: stage)
    stage.setAttention(.user); try? await Task.sleep(for: .seconds(1))
    try? stage.capture(to: folder.appendingPathComponent("gaze-user.png"))
    for state in WorkState.allCases {
        stage.setWorkState(state); MokuVisualDiagnostics.settledLantern(stage: stage)
        try? await Task.sleep(for: .seconds(0.7))
        try? MokuVisualDiagnostics.captureStage(stage: stage, to: folder.appendingPathComponent("lantern-\(state.rawValue).png"))
    }
    stage.setWorkState(.longDrift); await stage.move(to: .center)
    try? await Task.sleep(for: .seconds(1))
    try? MokuVisualDiagnostics.captureStage(stage: stage, to: folder.appendingPathComponent("lantern-carried.png"))
    checks["carried"] = MokuVisualDiagnostics.state(stage: stage)
    stage.celebrateReturn(.full); try? await Task.sleep(for: .seconds(8))
    checks["homeReturn"] = MokuVisualDiagnostics.state(stage: stage)
    for size in [ReturnSize.small, .full] {
        stage.setWorkState(.drifting); stage.celebrateReturn(size)
        for (label, delay) in [("arrival", 0.2), ("happy", 0.7), ("nod", 0.6), ("settled", 0.9)] {
            try? await Task.sleep(for: .seconds(delay))
            try? MokuVisualDiagnostics.captureStage(stage: stage, to: folder.appendingPathComponent("return-\(size.rawValue)-\(label).png"))
        }
    }
    checks["grab"] = await MokuVisualDiagnostics.exerciseGrab(stage: stage, directory: folder)
    checks["final"] = MokuVisualDiagnostics.state(stage: stage)
    checks["clipHistory"] = MokuVisualDiagnostics.clipHistory(stage: stage)
    try? MokuVisualDiagnostics.captureManualControl(stage: stage, world: model.worldModel, presenter: CaptureWorld(), scenes: [], to: folder.appendingPathComponent("manual-control.png"))
    if let data = try? JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: folder.appendingPathComponent("checks.json")) }
}

@MainActor func benchmarkV1(model: DemoModel, path: String) async {
    let stage = model.stage
    func cpu() -> Double { var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6 }
    func memory() -> [String: Double] {
        var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? ["residentMiB": Double(info.resident_size) / 1048576, "physicalFootprintMiB": Double(info.phys_footprint) / 1048576] : [:]
    }
    stage.setHidden(false); stage.setMood(.content); stage.setWorkState(.focused); stage.setAttention(.point(CGPoint(x: 0, y: 1400)))
    while stage.totalRenderedFrames == 0 && stage.rendererError == nil { try? await Task.sleep(for: .milliseconds(100)) }
    try? await Task.sleep(for: .seconds(6))
    var results: [String: Any] = [:]
    for (name, state, seconds) in [("focused", WorkState.focused, 35.0), ("drift", .concerned, 150.0), ("hidden", .away, 15.0)] {
        stage.setWorkState(state)
        if name == "hidden" { stage.setHidden(true) }
        let firstFrame = stage.totalRenderedFrames, firstMicro = stage.totalMicroExpressions, firstSaccade = stage.totalReadingSaccades
        let start = ProcessInfo.processInfo.systemUptime, initialCPU = cpu()
        try? await Task.sleep(for: .seconds(seconds))
        let duration = ProcessInfo.processInfo.systemUptime - start
        results[name] = ["seconds": duration, "cpuPercent": (cpu() - initialCPU) / duration * 100, "renderedFrames": stage.totalRenderedFrames - firstFrame, "microExpressions": stage.totalMicroExpressions - firstMicro, "saccades": stage.totalReadingSaccades - firstSaccade, "memory": memory(), "state": MokuVisualDiagnostics.state(stage: stage)]
    }
    if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: path)) }
}

@MainActor private final class CaptureWorld: WorldPresenter { func openWorld() {}; func closeWorld() {}; func celebrate(_ stage: ForestStage) {} }
