import Foundation
import AppKit
import MokuKit
import MokuVisual

@MainActor
func benchmark(model: DemoModel, window: NSWindow?, path: String) async {
    model.monitor?.invalidate(); model.monitor = nil; window?.orderOut(nil)
    try? await Task.sleep(for: .seconds(5))
    func cpuTime() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    func residentMiB() -> Double {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
    func footprintMiB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    var result: [String: Any] = ["renderer": model.stage.rendererDescription, "date": ISO8601DateFormatter().string(from: .now)]
    for (name, hidden, duration) in [("idle", false, 30.0), ("noticing", false, 45.0), ("hidden", true, 15.0)] {
        if name == "noticing" { model.stage.setAttention(.user) }
        let firstMicro = model.stage.totalMicroExpressions
        let firstCachedMicro = model.stage.totalCachedMicros
        model.stage.setHidden(hidden)
        try? await Task.sleep(for: .seconds(1))
        let firstFrame = model.stage.totalRenderedFrames
        let start = cpuTime(), time = ProcessInfo.processInfo.systemUptime
        try? await Task.sleep(for: .seconds(duration))
        let elapsed = ProcessInfo.processInfo.systemUptime - time
        result[name] = ["seconds": elapsed, "cpuPercent": (cpuTime() - start) / elapsed * 100, "renderFPS": model.stage.framesPerSecond, "residentMiB": residentMiB(), "physicalFootprintMiB": footprintMiB(), "renderedFrames": model.stage.totalRenderedFrames - firstFrame, "microExpressions": model.stage.totalMicroExpressions - firstMicro, "cachedMicroReplays": model.stage.totalCachedMicros - firstCachedMicro]
    }
    model.stage.setHidden(false)
    model.stage.setAttention(.user)
    try? await Task.sleep(for: .seconds(2))
    let transitionCPU = cpuTime(), transitionTime = ProcessInfo.processInfo.systemUptime
    let transitionStartMemory = residentMiB()
    var transitionPeak = transitionStartMemory
    for mood in Mood.allCases {
        model.stage.setMood(mood)
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(100)); transitionPeak = max(transitionPeak, residentMiB()) }
    }
    let transitionSeconds = ProcessInfo.processInfo.systemUptime - transitionTime
    result["moodTransitions"] = ["seconds": transitionSeconds, "cpuPercent": (cpuTime() - transitionCPU) / transitionSeconds * 100, "startResidentMiB": transitionStartMemory, "peakResidentMiB": transitionPeak, "endResidentMiB": residentMiB(), "endPhysicalFootprintMiB": footprintMiB()]
    result["error"] = model.stage.rendererError
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: path)) }
    model.stage.setHidden(false); window?.makeKeyAndOrderFront(nil)
}

@MainActor
func captureAll(model: DemoModel, window: NSWindow?, directory: String) async {
    model.stage.setHidden(false)
    let folder = URL(fileURLWithPath: directory)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? await Task.sleep(for: .seconds(3))
    for mood in Mood.allCases {
        model.stage.setMood(mood)
        try? await Task.sleep(for: .seconds(mood == .disappointed ? 3.5 : 2.8)) // moods blend over 2.4 s
        try? model.stage.capture(to: folder.appendingPathComponent("mood-\(mood.rawValue).png"))
    }
    model.stage.setMood(.content)
    for gesture in MokuKit.Gesture.allCases {
        model.stage.perform(gesture)
        try? await Task.sleep(for: .seconds(0.9))
        try? model.stage.capture(to: folder.appendingPathComponent("gesture-\(gesture.rawValue).png"))
        try? await Task.sleep(for: .seconds(2.8))
    }
    for stage in ForestStage.allCases {
        var snapshot = model.worldModel.snapshot; snapshot.growthPoints = stage.threshold
        try? MokuVisualDiagnostics.captureWorld(model: WorldModel(snapshot: snapshot), to: folder.appendingPathComponent("world-\(stage.rawValue).png"))
    }
    if let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("demo.png"))
    }
    model.status = "Captured all moods, gestures and forest stages."
}

/// Each little movement, captured every 0.2 s from its start: fidget-<kind>-<ms>.png.
@MainActor
func fidgetFrames(model: DemoModel, directory: String) async {
    model.stage.setHidden(false)
    let folder = URL(fileURLWithPath: directory)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? await Task.sleep(for: .seconds(3))
    for kind in ["pawShift", "footWiggle", "headTilt", "weightShift", "pawsTogether"] {
        try? await Task.sleep(for: .seconds(1))
        guard let seconds = MokuVisualDiagnostics.fidget(stage: model.stage, name: kind) else { NSLog("fidget %@ refused", kind); continue }
        let start = Date(); var t = 0.0
        while t <= seconds + 0.2 {
            let wait = t - Date().timeIntervalSince(start)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            try? model.stage.capture(to: folder.appendingPathComponent(String(format: "fidget-%@-%05d.png", kind, Int((t * 1000).rounded()))))
            t += 0.2
        }
    }
}

/// One gesture, captured every `every` seconds from the moment it starts: gesture-<name>-<ms>.png.
@MainActor
func gestureFrames(model: DemoModel, name: String, directory: String, seconds: Double, every: Double = 0.5) async {
    guard let gesture = MokuKit.Gesture(rawValue: name) else { NSLog("No gesture named %@", name); return }
    model.stage.setHidden(false)
    let folder = URL(fileURLWithPath: directory)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? await Task.sleep(for: .seconds(3))
    model.stage.setMood(.content)
    try? await Task.sleep(for: .seconds(1))
    let start = Date()
    model.stage.perform(gesture)
    var t = 0.0
    while t <= seconds {
        let wait = t - Date().timeIntervalSince(start)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        try? model.stage.capture(to: folder.appendingPathComponent(String(format: "gesture-%@-%05d.png", name, Int((t * 1000).rounded()))))
        t += every
    }
}

@MainActor
func stress(model: DemoModel, path: String) async {
    func reports() -> [String] {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        return ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix("MokuVisualDemo-") && $0.hasSuffix(".ips") }.sorted()
    }
    func cpu() -> Double { var r = rusage(); getrusage(RUSAGE_SELF, &r); return Double(r.ru_utime.tv_sec+r.ru_stime.tv_sec)+Double(r.ru_utime.tv_usec+r.ru_stime.tv_usec)/1e6 }
    func memory() -> Double {
        var info=mach_task_basic_info();var count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<integer_t>.size)
        let status=withUnsafeMutablePointer(to:&info) { p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count) } }
        return status == KERN_SUCCESS ? Double(info.resident_size)/1_048_576 : -1
    }
    let before=reports(); let start=ContinuousClock.now; let startCPU=cpu()
    var iterations=0; var peak=memory(); var errors=[String]()
    while ContinuousClock.now-start < .seconds(300) {
        if iterations % 19 == 0 { model.stage.setWorkState(.longDrift) }
        if iterations % 19 == 2 { model.stage.celebrateReturn(.full) }
        model.stage.setMood(Mood.allCases[iterations % Mood.allCases.count])
        MokuVisualDiagnostics.simulateHover(stage: model.stage, inside: iterations % 9 == 0)
        if iterations % 9 == 0 {
            model.stage.setAttention(.user)
            try? await Task.sleep(for: .seconds(1.8))
        } else if iterations % 9 == 1 {
            MokuVisualDiagnostics.playMicro(stage: model.stage, name: ["brow", "pout", "slowBlink", "puff"][iterations % 4])
        } else { model.stage.perform(MokuKit.Gesture.allCases[iterations % MokuKit.Gesture.allCases.count]) }
        if iterations % 17 == 0 { model.stage.say(SpeechLine(text: "A quiet test.", tone: .warm, duration: 0.4)) }
        if iterations % 23 == 0 {
            let outbound = Task { await model.stage.move(to: .center) }
            try? await Task.sleep(for: .milliseconds(100))
            await model.stage.move(to: .home); await outbound.value
        }
        if iterations % 31 == 0 { model.stage.setHidden(true); try? await Task.sleep(for: .milliseconds(100)); model.stage.setHidden(false) }
        model.stage.setAttention(.point(CGPoint(x: iterations%2 == 0 ? 100 : 900, y: 700)))
        if iterations % 7 == 0 { model.stage.showThreadLabel("Stress · Thread \(iterations)") }
        try? await Task.sleep(for:.seconds(0.75))
        peak=max(peak,memory())
        if let error=model.stage.rendererError, !errors.contains(error) { errors.append(error) }
        iterations += 1
    }
    let elapsed=Double((ContinuousClock.now-start).components.seconds)
    let result: [String:Any] = ["seconds":elapsed,"cycles":iterations,"crashReportsBefore":before,"crashReportsAfter":reports(),"newCrashReports":reports().filter{!before.contains($0)},"firstVisibleSource":model.stage.firstVisibleSource ?? "none","frames":model.stage.totalRenderedFrames,"blinks":model.stage.totalBlinks,"hoverReactions":model.stage.totalHoverReactions,"microExpressions":model.stage.totalMicroExpressions,"cpuPercent":(cpu()-startCPU)/elapsed*100,"peakResidentMiB":peak,"endingResidentMiB":memory(),"errors":errors]
    if let data=try? JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:URL(fileURLWithPath:path)) }
    model.stage.setHidden(true)
}
