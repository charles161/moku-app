import AppKit
import MokuKit

/// Charles: "sometimes it looks like moku isnt even smiling" (docs/specs/characters-perfect.md). Every frame in which
/// Moku should look pleased, through the app's own pose and renderer, with the face weights it showed, so each can be
/// judged at the size the app shows it. `assets/src/smile_sheets.py` lays them out as review sheets.
extension MokuVisualDiagnostics {
    /// `--smile-survey <dir>`: deterministic frames (no clock) written as `<group>/<name>.png` (640 px, the live size)
    /// with `survey.json`: per frame, its group, mood, label and the face weights shown.
    public static func smileSurvey(stage: MokuCharacterStage, directory: URL) async throws {
        stage.setHidden(true)
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let real = stage.view.real else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        real.setAuditResolution(1)
        var rows: [[String: Any]] = []
        let screen = SIMD2<Float>(-0.35, 0.12)  // watching the work, as when focused
        // MOKU_SURVEY_ONLY=moods,micro…: only those groups (look development).
        let only = ProcessInfo.processInfo.environment["MOKU_SURVEY_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        func wants(_ group: String) -> Bool { only?.contains(group) ?? true }
        func save(_ image: CGImage, group: String, name: String, mood: Mood, label: String) throws {
            let folder = directory.appendingPathComponent(group)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
            rows.append(["group": group, "name": name, "mood": mood.rawValue, "label": label,
                         "face": real.shownFace.filter { abs($0.value) > 0.004 && !$0.key.hasPrefix("ear") }.mapValues { Double($0) }])
        }
        // 1. The pleased moods held: watching the work, and looking at you.
        for mood in [Mood.content, .happy, .proud, .curious] where wants("moods") {
            for (where_, gaze, user) in [("screen", screen, false), ("you", SIMD2<Float>.zero, true)] {
                _ = try await real.auditFrame(mood: mood, clip: nil, seconds: 0, gaze: gaze, user: user)
                let (image, _) = try await real.auditFrame(mood: mood, clip: nil, seconds: 0, gaze: gaze, user: user)
                try save(image, group: "moods", name: "\(mood.rawValue)-\(where_)", mood: mood, label: "\(mood.rawValue), \(where_ == "you" ? "at you" : "at the work")")
            }
        }
        // 2. The lids a content Moku opens its blinks onto (LidTension), and a curious one's.
        for mood in [Mood.content, .curious] where wants("lids") {
            for (i, lids) in LidTension.choices(for: mood).enumerated() {
                let image = try await real.auditLife(mood: mood, move: nil, age: 0, lids: lids, gaze: screen)
                let words = lids.isEmpty ? "rest" : lids.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.2f", $0.value))" }.joined(separator: ", ")
                try save(image, group: "lids", name: "\(mood.rawValue)-\(i)", mood: mood, label: words)
            }
        }
        // 3. The little moves of the pleased moods, every 0.1 s.
        for mood in [Mood.content, .happy, .proud] where wants("moves") {
            for (kind, _) in LifeRhythm.vocabulary(for: mood) where !kind.onLayer {
                let move = LifeMove(kind: kind, side: 1, strength: 1)
                for (n, age) in stride(from: 0.0, through: move.seconds, by: 0.1).enumerated() {
                    let image = try await real.auditLife(mood: mood, move: move, age: age, gaze: mood == .content ? screen : .zero)
                    try save(image, group: "moves", name: "\(mood.rawValue)-\(kind.rawValue)-\(n)", mood: mood, label: "\(kind.rawValue) \(String(format: "%.1f", age)) s")
                }
            }
        }
        // 4. The micro-expressions a pleased mood plays (the look-up smile, the slow blink), every 10%.
        for mood in [Mood.content, .happy, .proud] where wants("micro") {
            for expression in MicroExpression.vocabulary(for: mood) {
                for step in 0...10 {
                    let image = try await real.auditMicro(mood: mood, expression: expression, progress: Double(step) / 10, gaze: .zero, user: true)
                    try save(image, group: "micro", name: "\(mood.rawValue)-\(expression.rawValue)-\(step)", mood: mood, label: "\(expression.rawValue) \(step * 10)%")
                }
            }
        }
        // 5. The clips of pleased moments (a pat, the waves, the nod, cheers), every 0.125 s, from content and happy.
        for mood in [Mood.content, .happy] where wants("clips") {
            for clip in ["pat_reaction", "wave", "hello_wave", "nod", "cheer", "celebrate", "big_celebrate"] {
                let (_, duration) = try await real.auditFrame(mood: mood, clip: clip, seconds: 0, gaze: .zero, user: true)
                for (n, t) in stride(from: 0.0, through: duration, by: 0.125).enumerated() {
                    let (image, _) = try await real.auditFrame(mood: mood, clip: clip, seconds: t, gaze: .zero, user: true)
                    try save(image, group: "clips", name: "\(mood.rawValue)-\(clip)-\(n)", mood: mood, label: "\(clip) \(String(format: "%.2f", t)) s")
                }
            }
        }
        // 6. Into and out of happy and proud, every 10%.
        for (from, to) in [(Mood.content, Mood.happy), (.happy, .content), (.content, .proud), (.proud, .content), (.disappointed, .happy), (.sleepy, .happy)] where wants("transitions") {
            for step in 0...10 {
                let (image, _) = try await real.auditTransition(from: from, to: to, progress: Double(step) / 10)
                try save(image, group: "transitions", name: "\(from.rawValue)-\(to.rawValue)-\(step)", mood: to, label: "\(from.rawValue) → \(to.rawValue) \(step * 10)%")
            }
        }
        // 7. The held arms (not pleased: a check that the held pose is where the folding clip leaves it, and where the
        // releasing clip picks it up).
        for (mood, into, out) in [(Mood.annoyed, "cross_arms", "uncross_arms"), (.disappointed, "fold_arms", "unfold_arms")] where wants("arms") {
            let (_, intoDuration) = try await real.auditFrame(mood: mood, clip: into, seconds: 0)
            let (end, _) = try await real.auditFrame(mood: mood, clip: into, seconds: intoDuration)
            try save(end, group: "arms", name: "\(mood.rawValue)-0-\(into)-end", mood: mood, label: "\(into), last frame")
            let (held, _) = try await real.auditFrame(mood: mood, clip: nil, seconds: 0)
            try save(held, group: "arms", name: "\(mood.rawValue)-1-held", mood: mood, label: "\(mood.rawValue), held")
            let (start, _) = try await real.auditFrame(mood: mood, clip: out, seconds: 0)
            try save(start, group: "arms", name: "\(mood.rawValue)-2-\(out)-start", mood: mood, label: "\(out), first frame")
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("survey.json"))
        real.stop()
    }

    /// `--pleased-reel <dir>`: the pleased moments as the app plays them, on the clock (the look-up smile, a happy
    /// look-up, the pointer resting on Moku, a pat, a wave, the full return from a drift and the small one, proud, a
    /// celebration), recorded frame by frame: `r-<n>.png`, `frames.csv` (time, what was going on, mood and the face
    /// weights shown) and the stutters and snaps found (pleased.json).
    public static func pleasedReel(stage: MokuCharacterStage, directory: URL) async throws {
        try await recordScript(stage: stage, directory: directory, report: "pleased.json", script: { real in [
            (0.5, "blink", { real.blink() }),
            (2, "look-up smile", { stage.glance(.smile) }),
            (7, "happy look-up", { stage.setAttention(.user); stage.setMood(.happy); stage.perform(.smile) }),
            (11, "content", { stage.setMood(.content); stage.watchScreenCenter() }),
            (14, "hover", { MokuVisualDiagnostics.simulateHover(stage: stage, inside: true) }),
            (16.5, "hover ends", { MokuVisualDiagnostics.simulateHover(stage: stage, inside: false) }),
            (18.5, "pat", { stage.perform(.patReaction) }),
            (22, "wave", { stage.perform(.wave) }),
            (26, "drift", { stage.setWorkState(.noticing); stage.setMood(.disappointed) }),
            // In the engine's order: the mood, the return, then the work state (syncWorkState runs last).
            (32, "full return", { stage.setMood(.happy); stage.celebrateReturn(.full); stage.setWorkState(.focused) }),
            (38, "content", { stage.setMood(.content); stage.watchScreenCenter() }),
            (41, "small return", { stage.setMood(.happy); stage.celebrateReturn(.small) }),
            (45, "content", { stage.setMood(.content); stage.watchScreenCenter() }),
            (48, "proud", { stage.setAttention(.user); stage.setMood(.proud) }),
            (52, "celebrate", { stage.setMood(.happy); stage.perform(.celebrate) }),
            (57, "content", { stage.setMood(.content); stage.watchScreenCenter() }),
        ] })
    }

    /// `--moments-reel <dir>`: the rest of Moku's day on the clock, with its own idle life running (the stage's tick:
    /// blinks, darts, ear flicks, little moves): reading the screen, a new window's sniff, the drift ladder (sad, cross,
    /// sitting up tall and red, the ask) and the comeback, a break (the tea, the doze, the gentle wake), and a throw.
    /// The same files as --pleased-reel, and moments.json.
    public static func momentsReel(stage: MokuCharacterStage, directory: URL) async throws {
        try await recordScript(stage: stage, directory: directory, report: "moments.json", tick: true, script: { real in
            let drop = { stage.panel.frame.origin }
            return [
                (0, "reading", { stage.setWorkState(.focused); stage.setMood(.content); stage.watchScreenCenter() }),
                (7, "sniff", { stage.perform(.sniff) }),
                (9, "ear flick", { _ = real.flickEar() }),
                (12, "grace", { stage.setWorkState(.grace) }),
                (13, "sad", { stage.setWorkState(.noticing); stage.setMood(.disappointed); stage.setAttention(.user) }),
                (19, "cross", { stage.setMood(.annoyed) }),
                (25, "sits up tall and red", { stage.perform(.standUp); stage.setWorkState(.drifting) }),
                (31, "the ask", { stage.setWorkState(.longDrift) }),
                (35, "comeback", { stage.setMood(.happy); stage.celebrateReturn(.full); stage.setWorkState(.focused) }),
                (40, "content", { stage.setMood(.content); stage.watchScreenCenter() }),
                (42, "tea", { stage.setWorkState(.onBreak); stage.setAttention(.wander); stage.perform(.drinkWater) }),
                (55, "doze", { stage.setMood(.sleepy) }),
                (62, "wake", { stage.setWorkState(.focused); stage.setMood(.happy); stage.celebrateReturn(.small) }),
                (66, "content", { stage.setMood(.content); stage.watchScreenCenter() }),
                (69, "picked up", { let o = drop(); stage.beginGrab(at: CGPoint(x: o.x + 160, y: o.y + 90), press: CGPoint(x: o.x + 160, y: o.y + 90)) }),
                (69.3, "carried", { let o = drop(); stage.dragGrab(to: CGPoint(x: o.x + 100, y: o.y + 200)) }),
                (69.6, "carried", { let o = drop(); stage.dragGrab(to: CGPoint(x: o.x + 40, y: o.y + 260)) }),
                (69.8, "thrown", { stage.releaseGrab() }),
            ]
        }, tail: 6)
    }

    /// Plays `script` (at seconds from the start, a beat's name, what to do) on the clock and records every frame drawn.
    /// `tick`: the stage's own idle life keeps running (otherwise only the script moves Moku).
    @MainActor static func recordScript(stage: MokuCharacterStage, directory: URL, report: String, tick: Bool = false, script: (RealityCharacter) -> [(Double, String, @MainActor () -> Void)], tail: Double = 4) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let real = stage.view.real else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.setHidden(false)
        if !tick { stage.timer?.invalidate(); stage.timer = nil }  // only the script moves Moku (no random blinks or flicks)
        stage.setWorkState(.focused); stage.setMood(.content); stage.watchScreenCenter()
        try await Task.sleep(for: .seconds(4))
        let recorder = LifeRecorder(folder: directory.appendingPathComponent("frames"))
        var faces: [(t: Double, beat: String, mood: String, face: [String: Float])] = []
        var beat = "content"
        let previous = real.onFrame
        let began = CACurrentMediaTime()
        recorder.began = began
        real.onFrame = { previous?(); recorder.frame(real); faces.append((CACurrentMediaTime() - began, beat, real.displayedMood.rawValue, real.shownFace)) }
        for (at, name, action) in script(real) {
            let wait = at - (CACurrentMediaTime() - began)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            beat = name; action()
        }
        try await Task.sleep(for: .seconds(tail))
        real.onFrame = previous
        await recorder.finish()
        try recorder.writeCSV(to: directory.appendingPathComponent("motion.csv"))
        let names = Set(faces.flatMap { $0.face.keys }).filter { !$0.hasPrefix("ear") }.sorted()
        let rows = faces.enumerated().map { i, f in ([String(i), String(format: "%.4f", f.t), f.beat.replacingOccurrences(of: ",", with: ";"), f.mood] + names.map { String(format: "%.3f", f.face[$0] ?? 0) }).joined(separator: ",") }
        try ((["frame,t,beat,mood"] + [names.joined(separator: ",")]).joined(separator: ",") + "\n" + rows.joined(separator: "\n")).write(to: directory.appendingPathComponent("faces.csv"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: recorder.verdict(), options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent(report))
        stage.setHidden(true)
    }
}

extension MokuVisualDiagnostics {
    /// `--arms-check <dir>`: the held arms let go, on the clock. Moku crosses its arms (annoyed), then a nod makes it
    /// uncross them first; the same with folded paws (disappointed). Writes motion.csv (every frame: the largest joint
    /// turn, image motion) and arms.json: the largest joint turn in a frame while each release plays.
    public static func armsCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let real = stage.view.real else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.setHidden(false)
        stage.timer?.invalidate(); stage.timer = nil
        stage.setWorkState(.noticing); stage.setAttention(.user)
        try await Task.sleep(for: .seconds(2))
        let recorder = LifeRecorder(folder: nil), previous = real.onFrame, began = CACurrentMediaTime()
        recorder.began = began
        real.onFrame = { previous?(); recorder.frame(real) }
        var report: [String: Any] = [:]
        for (mood, at) in [(Mood.annoyed, 0.0), (.disappointed, 9.0)] {
            if CACurrentMediaTime() - began < at { try await Task.sleep(for: .seconds(at - (CACurrentMediaTime() - began))) }
            stage.setMood(mood)
            try await Task.sleep(for: .seconds(5))
            let release = CACurrentMediaTime() - began
            stage.perform(.nod)
            try await Task.sleep(for: .seconds(2.5))
            let during = recorder.frames.filter { $0.t >= release && $0.t <= release + 1.2 }
            report[mood.rawValue] = ["releaseAt": release, "largestJointTurnDeg": during.map(\.joints).max() ?? 0, "frames": during.count]
        }
        real.onFrame = previous
        try recorder.writeCSV(to: directory.appendingPathComponent("motion.csv"))
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("arms.json"))
        stage.setHidden(true)
    }
}
