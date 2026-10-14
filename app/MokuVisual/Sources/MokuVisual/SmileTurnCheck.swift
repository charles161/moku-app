import AppKit
import MokuKit

/// Charles (2026-10-04): "the opening eye and closing animation during slow turns after smile for Moku is not very
/// smooth opening and eye closing, its jittery". The look-up as the engine plays it (EngineFocus.lookUp): Moku turns
/// to you, the eyes close into happy arcs (a smile gesture, or the happy mood), it holds 2.5 s, then turns back to the
/// work as the eyes open. Every rendered frame is recorded.
extension MokuVisualDiagnostics {
    /// `--smile-turn <dir>`: for each look-up (`smile`, `happyEyes`): turn-<kind>.csv (per frame: time, gap, the lid
    /// weights as posed and as sent to the mesh, the head's yaw and pitch, the eyes' look, the eye region's image
    /// change), eyes-<kind>/e-<n>.png (the eyes, 2x), and smile-turn.json: frames, gaps (median, largest), held frames
    /// (a gap over 1.5 times the median while the lids move), the largest lid step a frame and how even the steps are
    /// (frames whose lid weight didn't change between moving neighbours: steps), and the render path.
    public static func smileTurnCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let real = stage.view.real, let screen = NSScreen.screens.first else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.setHidden(false)
        stage.timer?.invalidate(); stage.timer = nil  // only the look-up moves Moku: no blinks, flicks or darts of its own
        let work = CGPoint(x: screen.frame.midX - 260, y: screen.frame.midY + 120)
        stage.setWorkState(.focused); stage.setMood(.content); stage.setAttention(.point(work))
        var report: [String: Any] = ["renderPath": real.renderPathDescription]
        for kind in ["smile", "happyEyes"] {
            try await Task.sleep(for: .seconds(3.5))
            struct Row { var t, gap: Double; var posed, sent: [String: Float]; var yaw, pitch: Double; var eyes: SIMD2<Float>; var image: CGImage? }
            var rows: [Row] = []
            let start = CACurrentMediaTime(), previous = real.onFrame
            real.onFrame = {
                previous?()
                let t = CACurrentMediaTime() - start, q = real.displayedHeadRotation
                let yaw = Double(atan2(2 * (q.w * q.y + q.x * q.z), 1 - 2 * (q.y * q.y + q.x * q.x))) * 180 / .pi
                let pitch = Double(asin(max(-1, min(1, 2 * (q.w * q.x - q.y * q.z))))) * 180 / .pi
                rows.append(Row(t: t, gap: rows.last.map { t - $0.t } ?? 0, posed: real.shownFace, sent: real.sentFace, yaw: yaw, pitch: pitch, eyes: real.displayedEyeLook,
                                image: real.lastImage?.cropping(to: CGRect(x: 225, y: 230, width: 190, height: 100))))
            }
            // As the engine does it: look at the user and smile (or be happy); 2.5 s later, back to the work, content.
            stage.setAttention(.user)
            if kind == "smile" { stage.perform(.smile) } else { stage.setMood(.happy) }
            try await Task.sleep(for: .seconds(2.5))
            stage.setAttention(.point(work)); stage.setMood(.content)
            try await Task.sleep(for: .seconds(3))
            real.onFrame = previous
            // The eye region's change frame to frame (mean grey difference, 0–255), as the eye sees the lids move.
            func grey(_ image: CGImage?) -> [Double]? {
                guard let image else { return nil }
                let w = image.width, h = image.height
                var rgba = [UInt8](repeating: 0, count: w * h * 4)
                guard let c = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return stride(from: 0, to: rgba.count, by: 4).map { (Double(rgba[$0]) + 2 * Double(rgba[$0 + 1]) + Double(rgba[$0 + 2])) / 4 }
            }
            let greys = rows.map { grey($0.image) }
            var eyeMotion = [Double](repeating: 0, count: rows.count)
            for i in rows.indices.dropFirst() { if let a = greys[i], let b = greys[i - 1], a.count == b.count { eyeMotion[i] = zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.count) } }
            let lids = ["blink_L", "blink_R", "eyes_happy", "eyes_proud", "lid_smile_lower", "lid_flat", "lid_sad", "eyes_narrow", "eyes_wide", "smile", "cheeks_raise"]
            let header = "frame,t,gap_ms," + lids.map { "posed_\($0)" }.joined(separator: ",") + "," + lids.map { "sent_\($0)" }.joined(separator: ",") + ",head_yaw,head_pitch,eyes_x,eyes_y,eye_motion"
            let lines = rows.enumerated().map { i, r in
                ([String(i), String(format: "%.4f", r.t), String(format: "%.1f", r.gap * 1000)] + lids.map { String(format: "%.4f", r.posed[$0] ?? 0) } + lids.map { String(format: "%.4f", r.sent[$0] ?? 0) }
                 + [String(format: "%.3f", r.yaw), String(format: "%.3f", r.pitch), String(format: "%.4f", r.eyes.x), String(format: "%.4f", r.eyes.y), String(format: "%.3f", eyeMotion[i])]).joined(separator: ",")
            }
            try ([header] + lines).joined(separator: "\n").write(to: directory.appendingPathComponent("turn-\(kind).csv"), atomically: true, encoding: .utf8)
            let folder = directory.appendingPathComponent("eyes-\(kind)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (i, r) in rows.enumerated() { if let image = r.image { try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(String(format: "e-%04d.png", i))) } }
            // The lids' closing (how shut the eyes are, as sent): its steps frame to frame while it moves.
            func shut(_ f: [String: Float]) -> Double { Double(max(f["eyes_happy"] ?? 0, f["eyes_proud"] ?? 0, ((f["blink_L"] ?? 0) + (f["blink_R"] ?? 0)) / 2)) }
            let steps = zip(rows, rows.dropFirst()).map { abs(shut($1.sent) - shut($0.sent)) }
            let gaps = rows.dropFirst().map(\.gap).sorted(), median = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
            var held = 0, stalls = 0
            for k in steps.indices.dropFirst().dropLast() {
                // A frame that came late while the lids were moving.
                if (steps[k - 1] > 0.004 || steps[k] > 0.004) && rows[k].gap > 1.5 * median { held += 1 }
                // The lids still for a frame between two frames where they moved: they stepped.
                if steps[k] < 0.0005 && steps[k - 1] > 0.004 && steps[k + 1] > 0.004 { stalls += 1 }
            }
            let movingSteps = steps.filter { $0 > 0.0005 }.sorted()
            report[kind] = ["frames": rows.count, "medianGapMs": median * 1000, "largestGapMs": (gaps.last ?? 0) * 1000,
                            "heldFramesWhileLidsMove": held, "lidStalls": stalls, "largestLidStepPerFrame": steps.max() ?? 0,
                            "medianLidStepWhileMoving": movingSteps.isEmpty ? 0 : movingSteps[movingSteps.count / 2],
                            "largestEyeMotion": eyeMotion.max() ?? 0, "fpsWhileMoving": median > 0 ? 1 / median : 0]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("smile-turn.json"))
        }
        stage.setHidden(true)
    }
}
