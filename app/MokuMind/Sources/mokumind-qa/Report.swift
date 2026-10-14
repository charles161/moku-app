import Foundation

/// A session's numbers in plain words: what the brain said, what Moku did, and how that sits with what the person was doing.
enum Summary {
    static func text(_ r: SessionReport) -> String {
        var out: [String] = []
        let hours = r.seconds / 3600
        out.append("== \(r.name)  \(r.date)  \(String(format: "%.2f", hours)) h")
        let truths = r.truthSeconds.sorted { $0.value > $1.value }.map { "\($0.key) \(Int($0.value / 60)) min" }.joined(separator: ", ")
        out.append("   what the person did: \(truths)")

        // The brain.
        var rows: [String] = []
        for truth in ["work", "dictation", "neutral", "drift", "meeting", "teaBreak", "away"] {
            guard let counts = r.verdicts[truth], !counts.isEmpty else { continue }
            let total = counts.values.reduce(0, +)
            let mix = counts.sorted { $0.value > $1.value }.map { "\($0.key) \(Int((Double($0.value) / Double(total) * 100).rounded()))%" }.joined(separator: " ")
            rows.append("\(truth)(\(total)): \(mix)")
        }
        out.append("   verdicts per truth: " + rows.joined(separator: " | "))

        // Moku.
        let notDrift = ["work", "dictation", "neutral", "meeting", "teaBreak", "away"]
        let workSeconds = (r.truthSeconds["work"] ?? 0) + (r.truthSeconds["dictation"] ?? 0)
        let workHours = max(workSeconds / 3600, 0.0001)
        for step in ["sad", "angry", "standUp", "ask"] {
            let wrong = r.steps.filter { $0.step == step && notDrift.contains($0.truth) }
            let atWork = wrong.filter { $0.truth == "work" || $0.truth == "dictation" }
            let elsewhere = wrong.filter { !($0.truth == "work" || $0.truth == "dictation") }
            let right = r.steps.filter { $0.step == step && $0.truth == "drift" }
            out.append(String(format: "   %-8@ at work %2d (%.1f per hour of work), at neutral/calls/breaks/away %d | in real drifts %d",
                              step as NSString, atWork.count, Double(atWork.count) / workHours, elsewhere.count, right.count))
        }
        let screens = Dictionary(grouping: r.steps.filter { notDrift.contains($0.truth) && $0.step != "sad" }, by: { "\($0.step) on \($0.screen)" })
        if !screens.isEmpty {
            out.append("   beyond sad at the wrong time: " + screens.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value.count)" }.joined(separator: ", "))
        }
        let sadWork = r.steps.filter { $0.step == "sad" && ($0.truth == "work" || $0.truth == "dictation") }
        if !sadWork.isEmpty {
            let by = Dictionary(grouping: sadWork, by: \.screen).sorted { $0.value.count > $1.value.count }.prefix(8)
            out.append("   sad at work, by screen: " + by.map { "\($0.key) x\($0.value.count)" }.joined(separator: ", "))
        }
        out.append(String(format: "   Jev answered %d of %d samples; the same page judged both ways in turn, at work: %d (%.1f an hour)", r.jevCalls,
                          r.verdicts.values.flatMap { $0.values }.reduce(0, +), r.verdictFlipsAtWork, Double(r.verdictFlipsAtWork) / workHours))
        if let work = r.phaseSeconds["work"] {
            let wrongPhase = work["drifting", default: 0]
            out.append(String(format: "   Moku thought it was drifting for %.0f s of %.0f s of work (%.1f%%); credited %.0f focused minutes of %.0f",
                              wrongPhase, workSeconds, 100 * wrongPhase / max(workSeconds, 1), r.focusCreditedMinutes, workSeconds / 60))
        }

        // The real drifts.
        let real = r.drifts.filter { $0.seconds >= 30 }
        if !real.isEmpty {
            let caught = real.filter { $0.firstSadAfter != nil }
            let times = caught.compactMap(\.firstSadAfter).sorted()
            let median = times.isEmpty ? "-" : String(format: "%.1f s", times[times.count / 2])
            out.append("   real drifts of 30 s or more: \(real.count), Moku reacted to \(caught.count); first reaction after \(median) (median); the ask in \(real.filter { $0.askAfter != nil }.count) of \(real.filter { $0.seconds >= 600 }.count) that ran 10 min or more")
            for d in real {
                out.append(String(format: "      %@  %5.1f min  %@  first sad %@, reached %@", clockString(d.start), d.seconds / 60, d.screens.joined(separator: ","),
                                  d.firstSadAfter.map { String(format: "%.1f s", $0) } ?? "never", d.reached ?? "nothing"))
            }
        }
        let glances = r.drifts.filter { $0.seconds < 30 }
        if !glances.isEmpty {
            out.append("   glances (under 30 s): \(glances.count), Moku showed sad for \(glances.filter { $0.firstSadAfter != nil }.count)")
        }

        // Counts and the day.
        let counts = r.eventCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        out.append("   events: \(counts)")
        let busy = r.commandCounts.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        out.append(String(format: "   stage commands (%.1f a minute): %@", Double(r.commandCounts.values.reduce(0, +)) / max(r.seconds / 60, 1), busy as NSString))
        if r.brainErrors > 0 { out.append("   brain errors: \(r.brainErrors)") }
        if let day = r.yourDay {
            out.append("   Your day: focused \(day.focusedMinutes) min, longest \(day.longestFocusMinutes), returns \(day.returns), house pieces \(day.unitsToday), \(day.segments) segments, built \(day.builtRows) rows, wandered \(day.wanderedRows) rows + \(day.quickCheckMinutes) min of quick checks")
            out.append("   Your day adds up: goals \(day.goalMinutes) min, built rows \(day.builtMinutes) min, focus buckets \(day.categoryMinutes) min, against focused \(day.focusedMinutes); wandered rows \(day.wanderedMinutes) min + quick checks \(day.quickCheckMinutes)")
            for goal in day.goals { out.append("      goal: \(goal)") }
            if let note = day.note { out.append("      note: \(note)") }
        }
        for later in r.laterDays {
            out.append("   Your day \(later.date) (after midnight): focused \(later.focusedMinutes) min, longest \(later.longestFocusMinutes), returns \(later.returns), house pieces \(later.unitsToday), \(later.segments) segments")
        }
        for (reason, count) in r.awayReasons.sorted(by: { $0.value > $1.value }).prefix(8) {
            out.append("   away verdicts x\(count): \(reason)")
        }
        for line in r.lines.prefix(12) { out.append("   said: \(line)") }
        for note in r.notes { out.append("   note: \(note)") }
        return out.joined(separator: "\n")
    }

    static func clockString(_ t: Double) -> String {
        let total = Int(t)
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}
