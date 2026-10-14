import AppKit
import MokuKit

/// Launch QA, lens 4: every everyday moment of the companion on show, on the clock, through the app's own stage, traced
/// and judged beat by beat (QATrace.swift, QAJudge.swift).
extension MokuVisualDiagnostics {
    /// `--qa-motion <dir>`: reading (blinks, darts, Tetsu's scan), the look-up smile, noticing you, hover, a pat, the
    /// sniff, the wave, a nod, a cheer, a stretch, a yawn, Tetsu's hologram, a bubble typing in and fading out, the thread
    /// label (and a swap of it), the drift ladder (sad, cross, sitting up tall and red, the ask), the return, the break
    /// (tea, doze, wake), a drag and a throw with its landing, and the seated moves home and away. Writes
    /// - qa.json (every beat: frames, frame rate, the largest joint turn, and what was found) and qa-beats.txt (the table);
    /// - frames/r-<n>.png (every frame the renderer drew, 320 px; `MOKU_QA_FRAMES=0` skips them) with frames.csv (time,
    ///   beat, gap, motion, coverage), turns.csv (each joint's turn per frame) and faces.csv (each weight per frame);
    /// - samples.csv (the windows and the picture layer, about 120 a second), events.csv and speech/ (the bubble, step by step).
    /// It throws when anything is found in a beat that isn't `rough` (a throw, a fade), so it can gate a build.
    public static func qaMotion(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let real = stage.view.real, let screen = NSScreen.screens.first else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let writeFrames = ProcessInfo.processInfo.environment["MOKU_QA_FRAMES"] != "0"
        let machine = real.companion.isMachine
        let speechFolder = directory.appendingPathComponent("speech")
        try fm.createDirectory(at: speechFolder, withIntermediateDirectories: true)

        stage.setHidden(false)
        stage.panel.setFrameOrigin(StageGeometry.home(in: screen.visibleFrame, scale: stage.view.scale)); stage.currentSpot = .home
        let work = CGPoint(x: screen.frame.midX - 120, y: screen.frame.midY + 60)
        stage.setWorkState(.focused); stage.setMood(.content); stage.setAttention(.point(work))
        try await Task.sleep(for: .seconds(4))

        let trace = QATrace(folder: writeFrames ? directory.appendingPathComponent("frames") : nil)
        let previous = real.onFrame
        real.onFrame = { previous?(); trace.frame(real) }
        var finished = false
        let sampler = Task { @MainActor in
            while !finished { trace.sample(stage: stage); try? await Task.sleep(for: .milliseconds(8)) }
        }

        func drop() -> CGPoint { stage.panel.frame.origin }
        // A drag as a hand does it (events at about 120 Hz), then a flick and a throw: it flies, lands, and fades home.
        func throwIt() {
            Task { @MainActor in
                let o = drop(), grip = CGPoint(x: o.x + 160, y: o.y + 90)
                stage.beginGrab(at: grip, press: grip)
                var cursor = grip
                for i in 1...40 {
                    let k = Double(i) / 40, eased = k * k * (3 - 2 * k)
                    cursor = CGPoint(x: grip.x - 140 * eased, y: grip.y + 120 * eased); stage.dragGrab(to: cursor)
                    try? await Task.sleep(for: .milliseconds(8))
                }
                try? await Task.sleep(for: .milliseconds(250))
                for _ in 1...18 { cursor = CGPoint(x: cursor.x + 10, y: cursor.y + 8); stage.dragGrab(to: cursor); try? await Task.sleep(for: .milliseconds(8)) }
                stage.releaseGrab()
            }
        }
        // The bubble or the label as it draws, every 0.1 s (typing in, held, fading), for review.
        func shoot(_ name: String, label: Bool = false, seconds: Double) {
            Task { @MainActor in
                let began = CACurrentMediaTime(); var n = 0
                while CACurrentMediaTime() - began < seconds {
                    if let content = label ? stage.labelPanel.contentView : stage.speechPanel.contentView, let image = try? ReviewCapture.view(content) {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: speechFolder.appendingPathComponent(String(format: "%@-%02d.png", name, n)))
                    }
                    n += 1; try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }

        // (when, name, rough, what happens): each beat lasts until the next one starts
        var script: [(Double, String, Bool, @MainActor () -> Void)] = []
        var cursor = 0.0
        func step(_ seconds: Double, _ name: String, rough: Bool = false, _ run: @escaping @MainActor () -> Void) { script.append((cursor, name, rough, run)); cursor += seconds }
        step(10, "reading", { stage.setWorkState(.focused); stage.setMood(.content); stage.setAttention(.point(work)) })
        step(5, "look-up smile", { stage.glance(.smile) })
        step(3, "notice you", { stage.setAttention(.user) })
        step(3, "back to work", { stage.setAttention(.point(work)) })
        step(3, "hover", { simulateHover(stage: stage, inside: true) })
        step(2, "hover ends", { simulateHover(stage: stage, inside: false) })
        step(3, "pat", { stage.perform(.patReaction) })
        step(3, "sniff", { stage.perform(.sniff) })
        step(4, "wave", { stage.perform(.wave) })
        step(3, "nod", { stage.perform(.nod) })
        step(6, "celebrate", { stage.setMood(.happy); stage.perform(.celebrate) })
        step(3, "cheer", { stage.perform(.cheer) })
        step(1, "settle", { stage.setMood(.content); stage.setAttention(.point(work)) })
        step(5, "stretch", { stage.perform(.stretch) })
        step(5, "yawn", { stage.perform(.yawn) })
        step(6, "hologram", { NotificationCenter.default.post(name: .mokuHousePieceLanded, object: nil, userInfo: ["units": 8]) })
        step(6, "bubble in", { stage.say(SpeechLine(text: "Nice focus. That's two hours of real work.", tone: .warm, duration: 4)); shoot("warm", seconds: 5) })
        step(2, "thread label", { stage.showThreadLabel("Quarterly plan"); shoot("label", label: true, seconds: 1.5) })
        step(6, "label swap", { stage.showThreadLabel("Inbox") })
        step(1, "grace", { stage.setWorkState(.grace) })
        step(6, "sad", { stage.setWorkState(.noticing); stage.setMood(.disappointed); stage.setAttention(.user) })
        step(6, "cross", { stage.setMood(.annoyed) })
        step(6, "sits up tall", { stage.perform(.standUp); stage.setWorkState(.drifting) })
        step(6, "the ask", { stage.setWorkState(.longDrift); stage.say(SpeechLine(text: "Charles, can we get back to the plan?", tone: .calling, duration: SpeechLine.untilDismissed)); shoot("ask", seconds: 3) })
        step(2, "the return", { stage.setMood(.happy); stage.celebrateReturn(.full); stage.setWorkState(.focused) })
        step(6, "welcome back", { stage.say(SpeechLine(text: "Welcome back!", tone: .cheerful, duration: 3)) })
        step(2, "settled", { stage.setMood(.content); stage.watchScreenCenter() })
        step(12, "break begins", { stage.setWorkState(.onBreak); stage.setMood(.content); stage.setAttention(.wander); stage.perform(.drinkWater); stage.setBreakTimer(until: Date().addingTimeInterval(600), total: 600) })
        step(7, "doze", { stage.setMood(.sleepy) })
        step(5, "wake", { stage.setBreakTimer(until: nil, total: 0); stage.setWorkState(.focused); stage.setMood(.happy); stage.celebrateReturn(.small) })
        step(4, "back to work", { stage.setMood(.content); stage.watchScreenCenter() })
        step(12, "picked up and thrown", rough: true, { throwIt() })
        step(5, "move to the middle", rough: true, { Task { @MainActor in await stage.move(to: .center) } })
        step(6, "move home", rough: true, { Task { @MainActor in await stage.move(to: .home) } })
        step(4, "settled at home", { stage.setMood(.content); stage.watchScreenCenter() })
        // MOKU_QA_ONLY=name,name keeps just those beats (back to back), to look at one moment again.
        if let only = ProcessInfo.processInfo.environment["MOKU_QA_ONLY"]?.split(separator: ",").map(String.init), !only.isEmpty {
            var t = 0.0, kept: [(Double, String, Bool, @MainActor () -> Void)] = []
            for (i, entry) in script.enumerated() where only.contains(entry.1) {
                let length = i + 1 < script.count ? script[i + 1].0 - entry.0 : 4
                kept.append((t, entry.1, entry.2, entry.3)); t += length
            }
            script = kept
        }
        let began = CACurrentMediaTime()
        for (at, name, _, action) in script {
            let wait = at - (CACurrentMediaTime() - began)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            trace.beat = name; action()
        }
        try await Task.sleep(for: .seconds(6))
        finished = true; await sampler.value
        real.onFrame = previous
        await trace.finish()
        stage.setBreakTimer(until: nil, total: 0)

        let end = CACurrentMediaTime() - trace.began
        let beats = script.enumerated().map { i, entry in QABeat(name: entry.1, t0: entry.0 + (began - trace.began), t1: i + 1 < script.count ? script[i + 1].0 + (began - trace.began) : end, rough: entry.2) }
        let reports = QAJudge.judge(trace, beats: beats, machine: machine)
        try writeQA(trace: trace, reports: reports, directory: directory, companion: real.companion, machine: machine)
        stage.setHidden(true)
        let failed = reports.contains { !$0.beat.rough && !$0.findings.isEmpty }
        NSLog("QA motion %@: %d beats, %d findings%@", real.companion.rawValue, reports.count, reports.reduce(0) { $0 + $1.findings.count }, failed ? " (see qa-beats.txt)" : "")
        if failed, ProcessInfo.processInfo.environment["MOKU_QA_STRICT"] == "1" { throw CocoaError(.validationMissingMandatoryProperty) }
    }

    /// Writes a trace and its verdicts: qa.json, qa-beats.txt and the csv files (see `qaMotion`).
    @MainActor static func writeQA(trace: QATrace, reports: [QABeatReport], directory: URL, companion: Companion, machine: Bool) throws {
        func pad(_ text: String, _ width: Int) -> String { text.padding(toLength: width, withPad: " ", startingAt: 0) }
        var table = [("beat", 22), ("t0", 6), ("frm", 5), ("fps", 4), ("deg/f", 7), ("joint", 14), ("stut", 5), ("held", 5), ("snap", 5), ("stall", 5), ("fsnp", 5), ("fstr", 5), ("pop", 5), ("win", 5)].map { pad($0.0, $0.1) }.joined(separator: " ") + "\n"
        for r in reports {
            let numbers = String(format: "%6.1f %5d %4.0f %7.2f", r.beat.t0, r.frames, r.fps, r.maxTurn)
            let counts = String(format: "%5d %5d %5d %5d %5d %5d %5d %5d", r.count("stutter"), r.count("held"), r.count("joint snap"), r.count("joint stall"), r.count("face snap"), r.count("face stair"), r.count("picture pop") + r.count("layer pop"), r.count("window step"))
            table += pad(r.beat.name, 22) + " " + numbers + " " + pad(r.maxTurnJoint, 14) + " " + counts + "\n"
        }
        table += "\n"
        for r in reports where !r.findings.isEmpty {
            table += "== \(r.beat.name) (\(String(format: "%.1f", r.beat.t0))–\(String(format: "%.1f", r.beat.t1)) s)\(r.beat.rough ? " [rough]" : "")\n"
            for f in r.findings.sorted(by: { $0.t < $1.t }).prefix(40) { table += String(format: "   %7.2f  ", f.t) + pad(f.kind, 14) + " " + f.detail + "\n" }
            if r.findings.count > 40 { table += "   … \(r.findings.count - 40) more\n" }
        }
        try table.write(to: directory.appendingPathComponent("qa-beats.txt"), atomically: true, encoding: .utf8)
        let summary: [String: Any] = ["companion": companion.rawValue, "machine": machine, "reduceMotion": MotionPreference.reduced, "date": ISO8601DateFormatter().string(from: .now), "beats": reports.map(\.json)]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("qa.json"))
        let names = Array(Set(trace.frames.flatMap { $0.face.keys })).sorted()
        var frameRows = ["frame,t,beat,gap_ms,motion,coverage,boxTop,boxMidX"], turnRows = ["frame,t," + trace.jointNames.joined(separator: ",")], faceRows = ["frame,t," + names.joined(separator: ",")]
        for (i, f) in trace.frames.enumerated() {
            frameRows.append(String(format: "%d,%.4f,%@,%.1f,%.3f,%.4f,%.3f,%.3f", i, f.t, f.beat.replacingOccurrences(of: ",", with: ";"), f.gap * 1000, f.motion, f.coverage, f.box.minY, f.box.midX))
            turnRows.append(String(format: "%d,%.4f,", i, f.t) + f.turns.map { String(format: "%.2f", $0) }.joined(separator: ","))
            faceRows.append(String(format: "%d,%.4f,", i, f.t) + names.map { String(format: "%.3f", f.face[$0] ?? 0) }.joined(separator: ","))
        }
        try frameRows.joined(separator: "\n").write(to: directory.appendingPathComponent("frames.csv"), atomically: true, encoding: .utf8)
        try turnRows.joined(separator: "\n").write(to: directory.appendingPathComponent("turns.csv"), atomically: true, encoding: .utf8)
        try faceRows.joined(separator: "\n").write(to: directory.appendingPathComponent("faces.csv"), atomically: true, encoding: .utf8)
        let sampleRows = ["t,panel,speech,label,breakTimer,originX,originY,layerX,layerY,layerScale,layerTilt,layerOpacity"] + trace.samples.map {
            String(format: "%.4f,%.2f,%.2f,%.2f,%.2f,%.1f,%.1f,%.2f,%.2f,%.4f,%.2f,%.2f", $0.t, $0.panel, $0.speech, $0.label, $0.breakTimer, $0.origin.x, $0.origin.y, $0.layerShift.x, $0.layerShift.y, $0.layerScale, $0.layerTilt, $0.layerOpacity) }
        try sampleRows.joined(separator: "\n").write(to: directory.appendingPathComponent("samples.csv"), atomically: true, encoding: .utf8)
        try (["t,statusLights,manpuMark,manpuMarkLeaving"] + trace.watched.map { String(format: "%.4f,%.3f,%.3f,%.3f", $0.t, $0.lights, $0.mark, $0.leaving) }).joined(separator: "\n").write(to: directory.appendingPathComponent("layers.csv"), atomically: true, encoding: .utf8)
        try (["t,event"] + trace.events.map { String(format: "%.4f,%@", $0.t, $0.what) }).joined(separator: "\n").write(to: directory.appendingPathComponent("events.csv"), atomically: true, encoding: .utf8)
    }
}

extension MokuVisualDiagnostics {
    /// `--beam-check <dir>`: Tetsu's seated move as stills (StageBeam.swift): the stage as it composites with the scan
    /// line held at eight places down (erasing) and up (printing), writing beam-erase-<n>.png and beam-reveal-<n>.png
    /// at 2×, on the paper colour. Run with MOKU_COMPANION=tetsu (with another, the same line over that companion).
    public static func beamCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let host = stage.view.layer else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.setHidden(false)
        stage.setWorkState(.focused); stage.setMood(.content); stage.watchScreenCenter()
        try await Task.sleep(for: .seconds(4))
        let size = stage.view.bounds.size, scale = stage.view.scale
        func still(_ name: String) throws {
            let w = Int(size.width * 2), h = Int(size.height * 2)
            let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor(calibratedRed: 0.965, green: 0.95, blue: 0.92, alpha: 1).cgColor); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.scaleBy(x: 2, y: 2)
            host.render(in: context)
            try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
        }
        for erasing in [true, false] {
            for n in 0..<8 {
                stage.view.beam.pose(stage: stage.view.stage, host: host, scale: scale, erasing: erasing, progress: CGFloat(n) / 7)
                try still(String(format: "beam-%@-%d.png", erasing ? "erase" : "reveal", n))
            }
        }
        stage.view.beam.finish(stage: stage.view.stage)
        // Tetsu's scan beam (RobotTalents.swift's ScanBeam), reading a window to its left, held at a quarter, half and
        // three quarters of its sweep, at 1× and 2×, over a light and a dark window: scan-<light|dark>-<1|2>x-<n>.png.
        if let real = stage.view.real, real.companion.isMachine {
            for (k, progress) in [0.25, 0.5, 0.75].enumerated() {
                real.reviewScan(at: progress)
                _ = try await real.auditFrame(mood: .content, clip: nil, seconds: 0, gaze: SIMD2(-0.55, 0.05))
                real.reviewScan(at: progress)  // again: the frame above posed the head the beam comes from
                for (window, colour) in [("light", NSColor(calibratedRed: 0.957, green: 0.949, blue: 0.925, alpha: 1)), ("dark", NSColor(calibratedRed: 0.118, green: 0.133, blue: 0.149, alpha: 1))] {
                    for factor in [1, 2] {
                        let w = Int(size.width) * factor, h = Int(size.height) * factor
                        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                        context.setFillColor(colour.cgColor); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
                        context.scaleBy(x: CGFloat(factor), y: CGFloat(factor)); host.render(in: context)
                        try NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("scan-\(window)-\(factor)x-\(k).png"))
                    }
                }
            }
            real.displayOverrides = [:]
        }
        stage.setHidden(true)
    }
}

extension MokuVisualDiagnostics {
    /// `--qa-switch <dir>`: the companion switched in the middle of a state (launch QA, parameter 9). Four states the
    /// switch can catch (sad in a drift, sitting up tall and red, dozing on a break, a celebration under way), each
    /// switched to the other companion and back, with the stage composited about 60 times a second as the old one fades
    /// out and the new one takes over: switch-<state>-<to>-<n>.png (every sixth sample, 320 px) and qa-switch.json (per
    /// switch: blank samples, how long both were on show, the mood and work state carried over, and the largest change
    /// in the picture between two samples). Needs a build that has both companions.
    public static func qaSwitch(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard Companion.available.count > 1, let screen = NSScreen.screens.first else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.setHidden(false)
        stage.panel.setFrameOrigin(StageGeometry.home(in: screen.visibleFrame, scale: stage.view.scale)); stage.currentSpot = .home
        let states: [(String, @MainActor () -> Void)] = [
            ("sad", { stage.setWorkState(.noticing); stage.setMood(.disappointed); stage.setAttention(.user) }),
            ("sitting-up-tall", { stage.setMood(.annoyed); stage.perform(.standUp); stage.setWorkState(.drifting) }),
            ("dozing", { stage.perform(.sitDown); stage.setWorkState(.onBreak); stage.setAttention(.wander); stage.setMood(.sleepy) }),
            ("celebrating", { stage.setWorkState(.focused); stage.setMood(.happy); stage.perform(.celebrate) }),
        ]
        var rows: [[String: Any]] = []
        for (name, setup) in states {
            for target in [Companion.available.first { $0 != Companion.current } ?? .moku, Companion.current] {
                let from = Companion.current
                stage.setWorkState(.focused); stage.setMood(.content); stage.watchScreenCenter(); stage.dismissSpeech()
                try await Task.sleep(for: .seconds(2))
                setup()
                try await Task.sleep(for: .seconds(name == "celebrating" ? 0.8 : 4.5))
                var shots: [CGImage] = []
                func composite() -> CGImage? {
                    let side = 320
                    guard let layers = stage.view.stage.sublayers?.filter({ $0.contents != nil && $0.frame == stage.view.real?.imageLayer.frame && $0.name == "character" }) else { return nil }
                    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.setFillColor(NSColor(calibratedRed: 0.965, green: 0.95, blue: 0.92, alpha: 1).cgColor); context.fill(CGRect(x: 0, y: 0, width: side, height: side))
                    // Bottom of the stack first.
                    for layer in layers {
                        let opacity = (layer.presentation() ?? layer).opacity
                        guard opacity > 0.001, CFGetTypeID(layer.contents as CFTypeRef) == CGImage.typeID else { continue }
                        context.setAlpha(CGFloat(opacity)); context.draw(layer.contents as! CGImage, in: CGRect(x: 0, y: 0, width: side, height: side))
                    }
                    return context.makeImage()
                }
                let meter = QAStats()
                var blank = 0, samples = 0, both = 0, onStageAt = -1.0, biggest = 0.0, lastPicture: [UInt8]?
                // MOKU_QA_PRELOAD=1: the target loaded ahead, as the welcome does (preloadCompanion).
                var preloadGapMs = 0.0, preloadSeconds = 0.0
                if ProcessInfo.processInfo.environment["MOKU_QA_PRELOAD"] == "1" {
                    // MOKU_QA_KEEP=1: both kept, as in the welcome (the one let go is the next one's preload).
                    if ProcessInfo.processInfo.environment["MOKU_QA_KEEP"] == "1" { stage.keepsBothCompanions = true }
                    stage.preloadCompanion(target)
                    let asked = CACurrentMediaTime(); var last = asked
                    // The longest the main thread went without a turn while the preload ran (a hitch in a live companion).
                    while stage.hasPreloaded != target, CACurrentMediaTime() - asked < 10 {
                        try await Task.sleep(for: .milliseconds(8))
                        let now = CACurrentMediaTime(); preloadGapMs = max(preloadGapMs, (now - last) * 1000 - 8); last = now
                    }
                    preloadSeconds = CACurrentMediaTime() - asked
                }
                let began = CACurrentMediaTime()
                CompanionChoice.choose(target)
                while CACurrentMediaTime() - began < 3.2 {
                    let layers = stage.view.stage.sublayers?.filter { $0.contents != nil && $0.name == "character" } ?? []
                    let visible = layers.filter { ($0.presentation() ?? $0).opacity > 0.01 }
                    samples += 1; if visible.isEmpty { blank += 1 }; if visible.count > 1 { both += 1 }
                    if onStageAt < 0, stage.companion == target { onStageAt = CACurrentMediaTime() - began }
                    if let image = composite() {
                        meter.add(index: samples, image: image)
                        let small = LifeRecorder.scaled(image, side: 80)
                        var px = [UInt8](repeating: 0, count: 80 * 80 * 4)
                        if let small, let context = CGContext(data: &px, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 320, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                            context.draw(small, in: CGRect(x: 0, y: 0, width: 80, height: 80))
                            if let last = lastPicture, last.count == px.count {
                                var total = 0; for i in 0..<px.count where i % 4 != 3 { total += abs(Int(px[i]) - Int(last[i])) }
                                biggest = max(biggest, Double(total) / Double(px.count / 4 * 3))
                            }
                            lastPicture = px
                        }
                        if samples % 6 == 0 { shots.append(image) }
                    }
                    try await Task.sleep(for: .milliseconds(16))
                }
                for (n, image) in shots.enumerated() {
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(String(format: "switch-%@-%@-to-%@-%02d.png", name, from.rawValue, target.rawValue, n)))
                }
                rows.append(["state": name, "from": from.rawValue, "to": target.rawValue, "samples": samples, "blankSamples": blank, "samplesWithBothOnShow": both,
                             "onStageAfterSeconds": onStageAt, "mood": "\(stage.mood)", "workState": "\(stage.workState)", "largestPictureChangeBetweenSamples": biggest, "preloadMainThreadGapMs": preloadGapMs, "preloadSeconds": preloadSeconds])
                try await Task.sleep(for: .seconds(1))
            }
        }
        stage.setWorkState(.focused); stage.setMood(.content)
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("qa-switch.json"))
        stage.setHidden(true)
    }

    /// `--qa-spam <dir>`: interaction spam (launch QA, parameter 10): fifty pats in a row, the pointer coming and going
    /// forty times, and ten grabs and throws, back to back, traced and judged like the reel's beats; then eight quiet seconds,
    /// after which nothing may be left over (held, carried, moving, hovered, a mark or a tilt on the picture, a window half
    /// faded). Writes qa-spam.json and qa-spam-beats.txt, with the same csv files as `--qa-motion`.
    public static func qaSpam(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let real = stage.view.real, let screen = NSScreen.screens.first else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.setHidden(false)
        let home = StageGeometry.home(in: screen.visibleFrame, scale: stage.view.scale)
        stage.panel.setFrameOrigin(home); stage.currentSpot = .home
        stage.setWorkState(.focused); stage.setMood(.content); stage.watchScreenCenter()
        try await Task.sleep(for: .seconds(4))
        let trace = QATrace(folder: ProcessInfo.processInfo.environment["MOKU_QA_FRAMES"] == "0" ? nil : directory.appendingPathComponent("frames"))
        let previous = real.onFrame
        real.onFrame = { previous?(); trace.frame(real) }
        var finished = false
        let sampler = Task { @MainActor in while !finished { trace.sample(stage: stage); try? await Task.sleep(for: .milliseconds(8)) } }
        let began = CACurrentMediaTime()
        var marks: [(String, Double)] = []
        func mark(_ name: String) { trace.beat = name; marks.append((name, CACurrentMediaTime() - trace.began)) }
        mark("fifty pats")
        for _ in 0..<50 { stage.perform(.patReaction); try await Task.sleep(for: .milliseconds(Int.random(in: 40...140))) }
        try await Task.sleep(for: .seconds(2.5))
        mark("hover in and out")
        for i in 0..<40 { simulateHover(stage: stage, inside: i % 2 == 0); try await Task.sleep(for: .milliseconds(Int.random(in: 60...260))) }
        simulateHover(stage: stage, inside: false)
        try await Task.sleep(for: .seconds(2))
        mark("ten grabs and throws")
        for k in 0..<10 {
            let o = stage.panel.frame.origin, grip = CGPoint(x: o.x + 160, y: o.y + 90)
            stage.beginGrab(at: grip, press: grip)
            var cursor = grip
            for i in 1...(6 + k) { cursor = CGPoint(x: cursor.x - 12, y: cursor.y + 9); stage.dragGrab(to: cursor); try await Task.sleep(for: .milliseconds(8)); _ = i }
            for _ in 1...10 { cursor = CGPoint(x: cursor.x + 14, y: cursor.y + 6); stage.dragGrab(to: cursor); try await Task.sleep(for: .milliseconds(8)) }
            stage.releaseGrab()
            try await Task.sleep(for: .milliseconds(Int.random(in: 100...900)))
        }
        mark("landing")
        try await Task.sleep(for: .seconds(4))
        mark("settled")
        try await Task.sleep(for: .seconds(6))
        let end = CACurrentMediaTime() - trace.began
        finished = true; await sampler.value
        real.onFrame = previous
        await trace.finish()
        _ = began
        let beats = marks.enumerated().map { i, m in QABeat(name: m.0, t0: m.1, t1: i + 1 < marks.count ? marks[i + 1].1 : end, rough: m.0 == "ten grabs and throws" || m.0 == "landing", pointerDriven: m.0 == "ten grabs and throws") }
        let reports = QAJudge.judge(trace, beats: beats, machine: real.companion.isMachine)
        try writeQA(trace: trace, reports: reports, directory: directory, companion: real.companion, machine: real.companion.isMachine)
        // What must be left of it, eight seconds on: nothing.
        let last = trace.samples.last
        var left: [String] = []
        if stage.grabbing { left.append("still grabbing") }
        if stage.carry != nil { left.append("still carried") }
        if stage.moving { left.append("still moving") }
        if real.holdingForDiagnostics { left.append("the picture is still held (tilt or squash)") }
        if let last, abs(last.layerTilt) > 0.2 || abs(last.layerScale - 1) > 0.01 || hypot(last.layerShift.x, last.layerShift.y) > 1.5 { left.append(String(format: "the picture layer is off rest (tilt %.2f°, scale %.3f, shift %.1f,%.1f)", last.layerTilt, last.layerScale, last.layerShift.x, last.layerShift.y)) }
        if let last, last.panel < 0.99 { left.append(String(format: "the window is at %.2f opacity", last.panel)) }
        if stage.mood != .content { left.append("mood \(stage.mood)") }
        let o = stage.panel.frame.origin
        let verdict: [String: Any] = ["leftOver": left, "panelOrigin": [o.x, o.y], "home": [home.x, home.y], "framesDrawn": trace.frames.count]
        try JSONSerialization.data(withJSONObject: verdict, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("qa-spam.json"))
        NSLog("QA spam %@: %@; %d findings", real.companion.rawValue, left.isEmpty ? "nothing left over" : left.joined(separator: ", "), reports.reduce(0) { $0 + $1.findings.count })
        stage.setHidden(true)
        if !left.isEmpty, ProcessInfo.processInfo.environment["MOKU_QA_STRICT"] == "1" { throw CocoaError(.validationMissingMandatoryProperty) }
    }
}
