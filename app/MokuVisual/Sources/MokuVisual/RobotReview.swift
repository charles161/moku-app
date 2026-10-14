import AppKit
import MokuKit

extension MokuVisualDiagnostics {
    /// Tetsu's look for review (next-wave.md §7), through the app's own renderer at twice the size: a still of every
    /// expression on its display (face-<name>.png), the boot-up and the reading moments, and eight frames of each main
    /// clip (clip-<name>-<k>.png). Run with MOKU_COMPANION=<id>; with another companion's assets it shows that one, so
    /// the same run on older assets gives the before.
    public static func robotLook(stage: MokuCharacterStage, directory: URL) async throws {
        stage.setHidden(true)
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let renderer = stage.view.real else { throw CocoaError(.fileReadUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        renderer.setAuditResolution(2)
        func save(_ image: CGImage, _ name: String) throws {
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
        }
        _ = try await renderer.auditFrame(mood: .content, clip: nil, seconds: 0, user: true)
        for mood in Mood.allCases {
            try save(try await renderer.auditFrame(mood: mood, clip: nil, seconds: 0, user: true).0, "face-\(mood.rawValue)")
            if let display = renderer.displayImage { try save(display, "display-\(mood.rawValue)") }
        }
        // Moments drawn on the display: a blink's steps, the pat's heart, thinking (the spinner), scanning, the boot-up.
        let moments: [(String, [String: Float])] = [("blink-half", ["blink_L": 0.5, "blink_R": 0.5]), ("blink-narrow", ["blink_L": 0.75, "blink_R": 0.75]),
            ("blink-closed", ["blink_L": 1, "blink_R": 1]), ("pat-heart", ["px_heart": 1]), ("thinking-1", ["px_spin": 0.10]), ("thinking-2", ["px_spin": 0.30]),
            ("scanning-1", ["px_scan": 0.30, "eyes_narrow": 0.8]), ("scanning-2", ["px_scan": 0.62, "eyes_narrow": 0.8]),
            ("boot-1", ["px_boot": 0.2]), ("boot-2", ["px_boot": 0.42]), ("boot-3", ["px_boot": 0.66]), ("boot-4", ["px_boot": 0.82]),
            ("look-left", ["__gazeX": -0.45]), ("look-right", ["__gazeX": 0.45]),
            // Waking from a doze (the eyes flicker on), the drift's beats (a pout, a huff when cross) and the ask (">_").
            ("wake-1", ["px_wake": 0.05]), ("wake-2", ["px_wake": 0.15]), ("wake-3", ["px_wake": 0.45]), ("wake-4", ["px_wake": 0.55]),
            ("pout", ["pout": 0.6, "lid_sad": 0.6]), ("huff", ["cheeks_puff": 0.6, "brows_angry": 1]),
            ("ask-on", ["px_cursor": 1, "brows_angry": 1]), ("ask-off", ["px_cursor": 0.25, "brows_angry": 1])]
        for (name, values) in moments {
            renderer.displayOverrides = values
            try save(try await renderer.auditFrame(mood: .content, clip: nil, seconds: 0, user: true).0, "face-\(name)")
        }
        renderer.displayOverrides = [:]
        // The talents, as Core Animation lays them in Tetsu's own window: the scan beam, and the hologram over its head.
        if stage.companion?.isMachine == true, let parent = renderer.imageLayer.superlayer {
            func layers(_ name: String) throws {
                let scale: CGFloat = 2, size = parent.bounds.size
                let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.setFillColor(CGColor(srgbRed: 0.93, green: 0.94, blue: 0.93, alpha: 1)); context.fill(CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
                context.scaleBy(x: scale, y: scale); parent.render(in: context)
                try save(context.makeImage()!, name)
            }
            renderer.setAuditResolution(1)
            // The scan, held at five points of its sweep: the beam and the matrix's column in step.
            for (k, progress) in [0.05, 0.25, 0.5, 0.75, 0.95].enumerated() {
                renderer.reviewScan(at: progress)
                _ = try await renderer.auditFrame(mood: .content, clip: nil, seconds: 0, gaze: SIMD2(-0.5, 0.2))
                renderer.reviewScan(at: progress)  // again: the frame above set the head the beam comes from
                try layers("talent-scan-\(k)")
            }
            renderer.displayOverrides = [:]
            _ = try await renderer.auditFrame(mood: .content, clip: nil, seconds: 0, gaze: SIMD2(-0.5, 0.2))
            renderer.playDisplayMoment("px_scan")
            try layers("talent-scan")
            _ = try await renderer.auditFrame(mood: .happy, clip: nil, seconds: 0, user: true)
            renderer.showHologram(units: 16)
            try layers("talent-hologram")
            // The chest LEDs breathing, at the top of a breath, as the layers are composed over the frame.
            for mood in [Mood.content, .disappointed, .annoyed, .sleepy] {
                _ = try await renderer.auditFrame(mood: mood, clip: nil, seconds: 0, user: true)
                try layers("lights-\(mood.rawValue)")
            }
            renderer.setAuditResolution(2)
        }
        if ProcessInfo.processInfo.environment["MOKU_ROBOT_FACES_ONLY"] == "1" { renderer.setAuditResolution(1); renderer.stop(); return }
        for clip in ["hello_wave", "big_celebrate", "pat_reaction", "scan", "nod", "stretch", "yawn", "drink_water", "sleep_loop", "cheer"] {
            let (_, duration) = try await renderer.auditFrame(mood: clip == "sleep_loop" ? .sleepy : .content, clip: clip, seconds: 0)
            for k in 0..<8 {
                try save(try await renderer.auditFrame(mood: clip == "sleep_loop" ? .sleepy : .content, clip: clip, seconds: duration * Double(k) / 7).0, "clip-\(clip)-\(k)")
            }
        }
        renderer.setAuditResolution(1)
        renderer.stop()
    }
}

extension MokuVisualDiagnostics {
    /// `--hover-check <dir>`: the pointer comes onto the companion and stays 1.6 s, then leaves; every drawn frame's
    /// largest joint turn (hover.json: time, gap ms, degrees) and every third frame as a still (hover-<n>.png).
    public static func hoverCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let real = stage.view.real else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.setHidden(false); stage.setWorkState(.focused); stage.setMood(.content); stage.watchScreenCenter()
        try await Task.sleep(for: .seconds(4))
        final class Film { var rows: [[Double]] = []; var last: [SIMD4<Float>]?; var lastT = 0.0; var n = 0 }
        let film = Film(), began = CACurrentMediaTime(), previous = real.onFrame
        real.onFrame = {
            previous?()
            let t = CACurrentMediaTime() - began
            let joints: [SIMD4<Float>] = real.jointsForDiagnostics.map { $0.1.rotation.vector }
            var turn = 0.0
            if let last = film.last {
                for (a, b) in zip(last, joints) { let dot = Double(min(1, abs((a * b).sum()))); turn = max(turn, 2 * acos(dot) * 180 / .pi) }
            }
            film.rows.append([t, (t - film.lastT) * 1000, turn]); film.last = joints; film.lastT = t
            if film.n % 3 == 0, let image = real.lastImage {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(String(format: "hover-%03d.png", film.n)))
            }
            film.n += 1
        }
        simulateHover(stage: stage, inside: true)
        try await Task.sleep(for: .seconds(1.6))
        simulateHover(stage: stage, inside: false)
        try await Task.sleep(for: .seconds(1.6))
        real.onFrame = previous
        try JSONSerialization.data(withJSONObject: ["hovers": real.hoverCount, "frames": film.rows], options: [.prettyPrinted]).write(to: directory.appendingPathComponent("hover.json"))
        stage.setHidden(true)
    }
}

extension MokuVisualDiagnostics {
    /// `--notice-check <dir>`: working (reading), it notices you (turns, locks on, smiles), looks back at the work, then
    /// blinks a few times. Every drawn frame: notice.json (time, gap ms, largest joint turn in degrees, phase) and every
    /// second frame as notice-<n>.png.
    public static func noticeCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let real = stage.view.real, let screen = NSScreen.screens.first else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let work = CGPoint(x: screen.frame.midX - 120, y: screen.frame.midY + 60)
        stage.setHidden(false); stage.setWorkState(.focused); stage.setMood(.content); stage.setAttention(.point(work))
        try await Task.sleep(for: .seconds(4))
        final class Film { var rows: [[Any]] = []; var last: [SIMD4<Float>]?; var lastT = 0.0; var n = 0; var phase = "work" }
        let film = Film(), began = CACurrentMediaTime(), previous = real.onFrame
        real.onFrame = {
            previous?()
            let t = CACurrentMediaTime() - began
            let joints: [SIMD4<Float>] = real.jointsForDiagnostics.map { $0.1.rotation.vector }
            var turn = 0.0
            if let last = film.last {
                for (a, b) in zip(last, joints) { let dot = Double(min(1, abs((a * b).sum()))); turn = max(turn, 2 * acos(dot) * 180 / .pi) }
            }
            film.rows.append([t, (t - film.lastT) * 1000, turn, film.phase]); film.last = joints; film.lastT = t
            if film.n % 2 == 0, let image = real.lastImage {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(String(format: "notice-%03d.png", film.n)))
            }
            film.n += 1
        }
        film.phase = "notice"; stage.setAttention(.user)
        try await Task.sleep(for: .seconds(2.6))
        film.phase = "back"; stage.setAttention(.point(work))
        try await Task.sleep(for: .seconds(2.0))
        film.phase = "blinks"
        for _ in 0..<5 { real.blink(); try await Task.sleep(for: .seconds(1.1)) }
        real.onFrame = previous
        try JSONSerialization.data(withJSONObject: ["frames": film.rows], options: [.prettyPrinted]).write(to: directory.appendingPathComponent("notice.json"))
        stage.setHidden(true)
    }
}

