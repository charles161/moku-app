import AppKit
import MokuKit

/// Judges a `QATrace` beat by beat (QATrace.swift). Every rule is on what's seen, not on what's asked for, and is the
/// one the app's own reels already use where there is one: a stutter is a still frame between two moving ones or a
/// frame held on screen while moving (`LifeRecorder.verdict`); a snap is one frame far above its neighbours.
struct QAFinding: Equatable {
    var kind: String       // stutter, held, joint snap, joint stall, face snap, face stair, picture pop, layer pop, window step
    var t: Double
    var detail: String
    var json: [String: Any] { ["kind": kind, "t": (t * 100).rounded() / 100, "detail": detail] }
    static func == (a: QAFinding, b: QAFinding) -> Bool { a.kind == b.kind && a.t == b.t && a.detail == b.detail }
}

struct QABeat {
    var name: String
    var t0: Double
    var t1: Double
    /// A beat where the picture and the poses are expected to jump about (a throw, a fade, a switch): only
    /// stutters are judged in it.
    var rough = false
    /// The pointer moves the window (a drag): its path is the hand's, so it isn't judged.
    var pointerDriven = false
}

struct QABeatReport {
    var beat: QABeat
    var frames = 0
    var fps = 0.0
    var medianGapMs = 0.0
    var maxTurn = 0.0, maxTurnJoint = ""
    var findings: [QAFinding] = []
    func count(_ kind: String) -> Int { findings.filter { $0.kind == kind }.count }
    var json: [String: Any] {
        ["beat": beat.name, "t0": (beat.t0 * 10).rounded() / 10, "t1": (beat.t1 * 10).rounded() / 10, "frames": frames, "fps": (fps * 10).rounded() / 10, "medianGapMs": (medianGapMs * 10).rounded() / 10,
         "maxTurnDegPerFrame": (maxTurn * 100).rounded() / 100, "maxTurnJoint": maxTurnJoint, "findings": findings.map(\.json)]
    }
}

@MainActor enum QAJudge {
    /// Weights that move fast on purpose: a blink, a nose twitch, a display's own channels.
    static func fastByDesign(_ name: String) -> Bool { name.hasPrefix("blink") || name == "nose_twitch" || name.hasPrefix("px_") || name.hasPrefix("led_") || name == "sleep_z" }

    /// Shapes the blink eases out of the way as it closes (RealityCharacter.pose).
    static let blinkAffected: Set<String> = ["eyes_happy", "eyes_proud", "eyes_narrow", "eyes_wide", "lid_flat", "lid_sad", "lid_smile_lower", "cheeks_raise"]

    static func judge(_ trace: QATrace, beats: [QABeat], machine: Bool) -> [QABeatReport] {
        let frames = trace.frames
        let weightNames = Array(Set(frames.flatMap { $0.face.keys })).sorted()
        var reports: [QABeatReport] = []
        // The window's own path (a throw, a glide, a scoot) on a 33 ms grid (the samples are timed by the main thread, and the
        // window moves with a 60 Hz tick, so single steps alternate): its speed mustn't jump about. A jump while the companion
        // can't be seen (a seated move's gap) is the move.
        var speeds: [(t: Double, v: Double, hidden: Bool)] = []
        let samples = trace.samples
        if let first = samples.first, let last = samples.last {
            var k = 0, previous = first, grid = first.t + 0.033
            while grid <= last.t {
                while k + 1 < samples.count, samples[k + 1].t <= grid { k += 1 }
                let now = samples[k]
                speeds.append((grid, hypot(now.origin.x - previous.origin.x, now.origin.y - previous.origin.y) / 0.033, now.hidden || previous.hidden))
                previous = now; grid += 0.033
            }
        }
        for beat in beats {
            var report = QABeatReport(beat: beat)
            let indices = frames.indices.filter { frames[$0].t >= beat.t0 && frames[$0].t < beat.t1 }
            report.frames = indices.count
            let gaps = indices.dropFirst().map { frames[$0].gap }.filter { $0 < 0.12 }.sorted()
            let nominal = gaps.isEmpty ? 1.0 / 30 : gaps[gaps.count / 2]
            report.medianGapMs = nominal * 1000; report.fps = 1 / nominal
            // The display's blinks on a machine hold one frame on purpose (collapse, hold, open).
            for i in indices where i > 0 && i + 1 < frames.count {
                let a = frames[i - 1], f = frames[i], b = frames[i + 1]
                let busy = { (x: QATrace.Frame) in x.motion > 0.15 }
                if f.motion < 0.02, busy(a), busy(b), f.gap < 0.1, b.gap < 0.1, !displayMoment(trace, at: f.t) {
                    report.findings.append(QAFinding(kind: "stutter", t: f.t, detail: String(format: "still frame between moving ones (motion %.2f, %.2f, %.2f)", a.motion, f.motion, b.motion)))
                }
                if f.gap > 2.5 * nominal, f.gap < 0.25, busy(a), busy(f), !(machine && displayMoment(trace, at: f.t)) {
                    report.findings.append(QAFinding(kind: "held", t: f.t, detail: String(format: "frame arrived %.0f ms after the one before (nominal %.0f ms) while moving", f.gap * 1000, nominal * 1000)))
                }
                if beat.rough { continue }
                // Joints: one frame far above both neighbours is a snap; a stop between two turns of the same joint is a stall.
                for j in 0..<f.turns.count {
                    let turn = f.turns[j], before = a.turns[j], after = b.turns[j]
                    if Double(turn) > report.maxTurn { report.maxTurn = Double(turn); report.maxTurnJoint = trace.jointNames[j] }
                    if turn > 3, turn > 3 * max(before, after) {
                        report.findings.append(QAFinding(kind: "joint snap", t: f.t, detail: String(format: "%@ turned %.1f° in one frame (%.1f° before, %.1f° after)", trace.jointNames[j], turn, before, after)))
                    }
                    if turn < 0.03, before > 1.5, after > 1.5, f.gap < 2.2 * nominal {
                        report.findings.append(QAFinding(kind: "joint stall", t: f.t, detail: String(format: "%@ stood still for a frame between turns of %.1f° and %.1f°", trace.jointNames[j], before, after)))
                    }
                }
                // Face weights: Moku's are continuous, so a jump or a step in a ramp is a fault. A display's are dots.
                if machine { continue }
                for name in weightNames where !fastByDesign(name) && !name.hasPrefix("ears_") && !(blinkAffected.contains(name) && (blinkWindow(trace, at: f.t) || blinking(frames, around: i))) {
                    let v0 = a.face[name] ?? 0, v1 = f.face[name] ?? 0, v2 = b.face[name] ?? 0
                    let d1 = v1 - v0, d2 = v2 - v1
                    if abs(d1) > 0.3, abs(d1) > 2.5 * abs(d2) {
                        report.findings.append(QAFinding(kind: "face snap", t: f.t, detail: String(format: "%@ moved %.2f in one frame (%.2f → %.2f), then %.2f", name, d1, v0, v1, d2)))
                    }
                    if abs(d2) < 1e-4, abs(d1) > 0.03, i + 2 < frames.count, f.gap < 2.2 * nominal, b.gap < 2.2 * nominal {
                        let d3 = (frames[i + 2].face[name] ?? 0) - v2
                        if abs(d3) > 0.03, d1 * d3 > 0 { report.findings.append(QAFinding(kind: "face stair", t: b.t, detail: String(format: "%@ held at %.2f for a frame inside a move (%+.2f, 0, %+.2f)", name, v1, d1, d3))) }
                    }
                }
                // The picture: the character appearing, going or jumping across the frame between two frames.
                if f.coverage > 0.01, a.coverage > 0.01 {
                    let jump = abs(f.coverage - a.coverage) / a.coverage
                    if jump > 0.18, f.gap < 0.1 { report.findings.append(QAFinding(kind: "picture pop", t: f.t, detail: String(format: "the character covers %.1f%% then %.1f%% of the frame in one frame", a.coverage * 100, f.coverage * 100))) }
                    if abs(f.box.minY - a.box.minY) > 0.07 || abs(f.box.midX - a.box.midX) > 0.07, f.gap < 0.1 {
                        report.findings.append(QAFinding(kind: "picture pop", t: f.t, detail: String(format: "the character's box jumped (top %.2f → %.2f, centre %.2f → %.2f)", a.box.minY, f.box.minY, a.box.midX, f.box.midX)))
                    }
                }
            }
            // Layers and windows.
            for e in trace.layerEvents where e.t >= beat.t0 && e.t < beat.t1 { report.findings.append(QAFinding(kind: "layer pop", t: e.t, detail: e.what)) }
            let after = trace.samples.indices.filter { trace.samples[$0].t >= beat.t0 && trace.samples[$0].t < beat.t1 && $0 > 0 }
            for k in after {
                let a = trace.samples[k - 1], b = trace.samples[k]
                guard b.t - a.t < 0.05 else { continue }
                let dt = max(0.001, b.t - a.t)
                for (name, x, y) in [("companion window", a.panel, b.panel), ("thread label", a.label, b.label), ("break timer", a.breakTimer, b.breakTimer)] {
                    if abs(y - x) > 0.6 { report.findings.append(QAFinding(kind: "window step", t: b.t, detail: String(format: "%@ opacity %.2f → %.2f in %.0f ms", name, x, y, dt * 1000))) }
                }
                if !beat.rough, hypot(b.origin.x - a.origin.x, b.origin.y - a.origin.y) > 12, b.panel > 0.1 {
                    report.findings.append(QAFinding(kind: "window step", t: b.t, detail: String(format: "the companion's window jumped %.0f pt while visible (alpha %.2f)", hypot(b.origin.x - a.origin.x, b.origin.y - a.origin.y), b.panel)))
                }
                if !beat.rough, hypot(b.layerShift.x - a.layerShift.x, b.layerShift.y - a.layerShift.y) > 6 {
                    report.findings.append(QAFinding(kind: "layer pop", t: b.t, detail: String(format: "the picture layer jumped %.1f pt in %.0f ms", hypot(b.layerShift.x - a.layerShift.x, b.layerShift.y - a.layerShift.y), dt * 1000)))
                }
            }
            // The window's own path (a throw, a glide, a scoot): its speed between samples mustn't jump about. Samples are
            // timed by the main thread, so the speed is judged per second, and a step is a spike when it's far above both
            // neighbours.
            for k in speeds.indices.dropFirst().dropLast() where speeds[k].t >= beat.t0 && speeds[k].t < beat.t1 && !speeds[k].hidden && !beat.pointerDriven {
                let v = speeds[k].v, before = speeds[k - 1].v, after = speeds[k + 1].v
                if v > 800, v > 3 * max(before, after) { report.findings.append(QAFinding(kind: "path spike", t: speeds[k].t, detail: String(format: "the window moved at %.0f pt/s for one step of 33 ms (%.0f before, %.0f after)", v, before, after))) }
            }
            reports.append(report)
        }
        return reports
    }

    /// Whether a blink is under way in the frames around `i` (a blink during a clip isn't in the life log).
    private static func blinking(_ frames: [QATrace.Frame], around i: Int) -> Bool {
        (max(0, i - 5)...min(frames.count - 1, i + 5)).contains { (frames[$0].face["blink_L"] ?? 0) > 0.2 }
    }

    /// Whether `t` is inside one of a display's own moments (a blink, a spinner, a lock, a scan), which draw in whole
    /// frames at their own pace (RealityCharacter.playDisplayMoment).
    private static func displayMoment(_ trace: QATrace, at t: Double) -> Bool {
        let lengths: [String: Double] = ["px_blink": 0.6, "px_blink2": 0.8, "px_refresh": 0.7, "px_wake": 1.1, "px_lock": 1.0, "px_spin": 1.5, "px_scan": 2.8, "blink": 0.6]
        return trace.events.contains { e in lengths[e.what].map { t >= e.t - 0.1 && t <= e.t + $0 } ?? false }
    }

    /// Whether `t` is inside a display blink or refresh (its collapse, a held line, its opening, about 0.6 s at most).
    private static func blinkWindow(_ trace: QATrace, at t: Double) -> Bool {
        trace.events.contains { ["blink", "px_blink", "px_blink2", "px_refresh", "px_wake"].contains($0.what) && t >= $0.t - 0.1 && t <= $0.t + 0.7 }
    }
}
