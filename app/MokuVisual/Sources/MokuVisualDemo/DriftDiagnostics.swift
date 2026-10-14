import AppKit
import simd
import MokuKit
import MokuMind
import MokuVisual

@MainActor func captureImmediateDrift(model: DemoModel, directory: String) async throws {
    let folder = URL(fileURLWithPath: directory), stage = model.stage
    let verdict = try JSONDecoder().decode(Verdict.self, from: Data(contentsOf: folder.appendingPathComponent("verdict.json")))
    guard verdict.state == .drifting, verdict.reason.hasPrefix("[known-feed]") else { throw CocoaError(.fileReadCorruptFile) }
    stage.setHidden(false); stage.setMood(.content); stage.setAttention(.point(CGPoint(x: 0, y: 1400)))
    try await Task.sleep(for: .seconds(2))
    var config = CompanionConfig.standard; config.graceSec = 1
    var engine = BehaviorEngine(config: config)
    var commands = [[String: Any]](), frames = [[String: Any]]()
    let start = CACurrentMediaTime()
    func apply(_ effects: [EngineEffect]) {
        for effect in effects {
            guard case let .character(command) = effect else { continue }
            commands.append(["seconds": CACurrentMediaTime()-start, "command": String(describing: command)])
            switch command {
            case .setMood(let mood): stage.setMood(mood)
            case .setAttention(let target): stage.setAttention(target)
            case .perform(let gesture): stage.perform(gesture)
            case .setWorkState(let state): stage.setWorkState(state)
            case .setHidden(let hidden): stage.setHidden(hidden)
            case .dismissSpeech: stage.dismissSpeech()
            default: break
            }
        }
    }
    apply(engine.handle(.verdict(Verdict(sampleId: "work", state: .working, thread: nil, isNewThread: false, confidence: 1, source: .shortcut, reason: "scripted work", latencyMs: 0)), now: .now))
    apply(engine.handle(.verdict(verdict), now: .now))
    var nextCapture = 0.0, changed = false, returned = false, firstFace: Double?, firstGlance: Double?, firstAttention: Double?
    while CACurrentMediaTime()-start < 14 {
        let elapsed = CACurrentMediaTime()-start
        apply(engine.tick(now: .now))
        if elapsed >= 5 && !changed {
            changed = true
            stage.setMood(.disappointed); stage.setWorkState(.drifting)
        }
        if elapsed >= 9 && !returned {
            returned = true; stage.celebrateReturn(.full)
        }
        let state = MokuVisualDiagnostics.state(stage: stage)
        if firstAttention == nil, state["attentionToUser"] as? Bool == true { firstAttention = elapsed }
        if firstFace == nil, state["displayedMood"] as? String == "annoyed", (state["annoyedStrength"] as? Float ?? 0) > 0.01 { firstFace = elapsed }
        if firstGlance == nil, state["looksAtUser"] as? Bool == true { firstGlance = elapsed }
        if elapsed >= nextCapture {
            let name = String(format: "%04d.png", Int((elapsed*1000).rounded()))
            try MokuVisualDiagnostics.captureStage(stage: stage, to: folder.appendingPathComponent(name))
            frames.append(["seconds": elapsed, "file": name, "state": state, "silhouettePass": MokuVisualDiagnostics.silhouette(stage: stage)])
            nextCapture += 0.25
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    func progress(near seconds: Double) -> Double {
        guard let frame = frames.min(by: { abs(($0["seconds"] as! Double)-seconds) < abs(($1["seconds"] as! Double)-seconds) }),
              let state = frame["state"] as? [String: Any], let value = state["moodProgress"] as? Float else { return -1 }
        return Double(value)
    }
    let driftFrames = frames.filter { (1.5...8.9).contains($0["seconds"] as! Double) }
    let headSpeeds = zip(driftFrames, driftFrames.dropFirst()).map { a, b -> Double in
        let qa = (a["state"] as! [String: Any])["headRotation"] as! [Float]
        let qb = (b["state"] as! [String: Any])["headRotation"] as! [Float]
        let dot = zip(qa,qb).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        return 2 * acos(Double(min(1, abs(dot)))) * 180 / .pi / ((b["seconds"] as! Double) - (a["seconds"] as! Double))
    }
    let checks: [String: Bool] = [
        "allTransitionSilhouettes": frames.allSatisfy { $0["silhouettePass"] as? Bool == true },
        "noEntryClips": MokuVisualDiagnostics.clipHistory(stage: stage).isEmpty,
        "annoyedHalfwayAt2_5": (0.3...0.7).contains(progress(near: 2.5)),
        "disappointedHalfwayAt6_5": (0.3...0.7).contains(progress(near: 6.5)),
        "happyRampedBy9_75": progress(near: 9.75) > 0.8,
        "contentHalfwayAt12_5": (0.3...0.7).contains(progress(near: 12.5)),
        "driftHeadUnder30DegreesPerSecond": (headSpeeds.max() ?? 1000) < 30,
        "firstAttentionWithin1_3": (firstAttention ?? 1000) <= 1.3,
        "firstAnnoyedBlendWithin1_5": (firstFace ?? 1000) <= 1.5,
        "eyeContactWithin1_8": (firstGlance ?? 1000) <= 1.8
    ]
    let result: [String: Any] = ["verdictReason": verdict.reason, "graceSec": 1, "firstAnnoyedBlendFrameSec": firstFace ?? -1, "firstUserGlanceFrameSec": firstGlance ?? -1, "firstAttentionFrameSec": firstAttention ?? -1, "maxSampledDriftHeadDegreesPerSec": headSpeeds.max() ?? 0, "checks": checks, "commands": commands, "frames": frames, "error": stage.rendererError ?? "none", "note": "Actual known-feed focus rule → actual BehaviorEngine with graceSec=1 → real stage. At 5 s, a scripted disappointed/drifting escalation isolates the gradual mood change from later movement tiers. At 9 s, a full return beat completes the focus → drift → return sequence."]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("drift-check.json"))
    stage.setHidden(true)
    guard checks.values.allSatisfy({ $0 }), stage.rendererError == nil else { throw CocoaError(.validationMissingMandatoryProperty) }
}

/// Charles, 2026-10-14 (a screenshot of Moku facing him mid-drift): "during drift instead of watching me, it can be sad and
/// then go on to look the screen like the focus used to". The real engine through a drift on the real character: work,
/// then a drifting verdict, 20 s of ticks. Every quarter second, whether Moku's eyes are on the user (drift-gaze.json), and
/// a frame at the moments that matter. Passes when the eyes go to the user only around the sad move (its first ~8 s).
@MainActor func captureDriftGaze(model: DemoModel, directory: String) async throws {
    let folder = URL(fileURLWithPath: directory), stage = model.stage
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    stage.setHidden(false); stage.setMood(.content)
    try await Task.sleep(for: .seconds(2))
    var engine = BehaviorEngine(config: .standard)
    func apply(_ effects: [EngineEffect]) {
        for case let .character(command) in effects {
            switch command {
            case .setMood(let mood): stage.setMood(mood)
            case .setAttention(let target): stage.setAttention(target)
            case .perform(let gesture): stage.perform(gesture)
            case .setWorkState(let state): stage.setWorkState(state)
            default: break
            }
        }
    }
    let work = Verdict(sampleId: "w", state: .working, thread: nil, isNewThread: false, confidence: 1, source: .shortcut, reason: "work", latencyMs: 0)
    apply(engine.handle(.attention(CGPoint(x: 500, y: 600)), now: .now))
    apply(engine.handle(.verdict(work), now: .now))
    for _ in 0..<15 { apply(engine.tick(now: .now)); try await Task.sleep(for: .milliseconds(100)) }
    let drift = Verdict(sampleId: "d", state: .drifting, thread: nil, isNewThread: false, confidence: 1, source: .shortcut, reason: "feed", latencyMs: 0)
    let start = CACurrentMediaTime()
    apply(engine.handle(.verdict(drift), now: .now))
    var samples = [[String: Any]](), nextSample = 0.0, shots: Set<Int> = [1, 3, 10, 18]
    while CACurrentMediaTime() - start < 20 {
        let elapsed = CACurrentMediaTime() - start
        apply(engine.tick(now: .now))
        if elapsed >= nextSample {
            let state = MokuVisualDiagnostics.state(stage: stage)
            samples.append(["seconds": elapsed, "looksAtUser": state["looksAtUser"] ?? false, "attentionToUser": state["attentionToUser"] ?? false,
                            "mood": state["displayedMood"] ?? "", "workState": state["workState"] ?? ""])
            nextSample += 0.25
        }
        if let second = shots.first(where: { elapsed >= Double($0) }) {
            shots.remove(second)
            try MokuVisualDiagnostics.captureStage(stage: stage, to: folder.appendingPathComponent(String(format: "drift-%02ds.png", second)))
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    let late = samples.filter { ($0["seconds"] as? Double ?? 0) >= 9 }
    let passed = !late.contains { $0["attentionToUser"] as? Bool == true }
    let report: [String: Any] = ["passed": passed, "samples": samples,
                                 "eyesOnUserAfter9s": late.filter { $0["attentionToUser"] as? Bool == true }.count]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("drift-gaze.json"))
    if !passed { throw CocoaError(.validationMultipleErrors) }
}
