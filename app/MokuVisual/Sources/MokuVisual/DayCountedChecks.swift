import AppKit
import MokuKit

// The demo's checks for "Today counted" (DayCounted.swift). Nothing here touches a setting: the companion is passed in,
// never chosen, and the card's window is put far off screen.

extension MokuVisualDiagnostics {
    /// Sample days: a full one (3h 41m, two tasks), a light one (34m), the same full day with Luna's note, and one whose
    /// tasks and note are long, emoji, right to left and CJK.
    static func dayCountedSamples(date: Date = Date()) -> (full: TodaySummary, light: TodaySummary, note: TodaySummary, scripts: TodaySummary) {
        let key = TodayModel.key(date), start = Calendar.current.startOfDay(for: date).addingTimeInterval(9 * 3600)
        func goal(_ id: String, _ title: String, _ minutes: Int) -> GoalDay { GoalDay(id: id, title: title, minutes: minutes, firstAt: start, lastAt: start) }
        func day(_ minutes: Int, returns: Int, longest: Int, goals: [GoalDay], note: String? = nil) -> TodaySummary {
            TodaySummary(date: key, note: note, focusedMinutes: minutes, longestFocusMinutes: longest, returns: returns, unitsToday: minutes / 10,
                         segments: [], built: [], wandered: [], quickCheckMinutes: 0, comebacks: [], bestComeback: nil, completions: [], goals: goals)
        }
        let full = day(221, returns: 5, longest: 52, goals: [goal("g1", "building Moku’s settings", 96), goal("g2", "learning system design", 41),
                                                              goal("g3", "researching the market", 15), goal("g4", "planning the week", 6), goal("other", "Other work", 12)])
        let light = day(34, returns: 2, longest: 18, goals: [goal("g1", "reading the onboarding doc", 22), goal("g2", "answering email", 7)])
        var note = full
        note.note = "A long stretch on the settings screen, and you came back every time. I put up the round door."
        let scripts = day(97, returns: 4, longest: 38, goals: [goal("g1", "整理产品路线图和下季度的优先事项，还有给团队的更新", 64), goal("g2", "مراجعة تقرير الربع الثالث", 33)],
                          note: "Two good stretches today 🚀 and you came back 4 times. Élodie’s doc is done.")
        return (full, light, note, scripts)
    }

    /// "Today counted" for both companions, light and dark, at 1× and 2×, on a full day and a light day
    /// (today-counted-<companion>-<full|light>-<light|dark>-<1x|2x>.png); at 2× also yesterday's, the goodbye on quit,
    /// Luna's note, and long, emoji, right-to-left and CJK words (today-counted-<companion>-<variant>.png); a sheet per
    /// companion (today-counted-<companion>.png); and how long each card takes to draw (today-counted.json).
    public static func dayCountedLook(stage: MokuCharacterStage, directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let samples = dayCountedSamples()
        var timings: [[String: Any]] = []
        for companion in Companion.allCases {
            let full = DayCountedStills.load(minutes: samples.full.focusedMinutes, companion: companion)
            let light = DayCountedStills.load(minutes: samples.light.focusedMinutes, companion: companion)
            let middle = DayCountedStills.load(minutes: samples.scripts.focusedMinutes, companion: companion)
            var cells: [(String, CGImage)] = []
            func card(_ summary: TodaySummary, house: CGImage?, dark: Bool, scale: CGFloat, yesterday: Bool = false, farewell: Bool = false) -> CGImage? {
                let started = CACurrentMediaTime()
                let view = DayCountedCardView(content: DayCountedContent(summary: summary, companion: companion, yesterday: yesterday, farewell: farewell),
                                              house: house, style: SpeechStyle(companion), dark: dark, scale: scale, reduced: false)
                let ms = (CACurrentMediaTime() - started) * 1000
                if scale == 2 && !dark && !yesterday && !farewell { timings.append(["companion": companion.rawValue, "minutes": summary.focusedMinutes, "ms": (ms * 10).rounded() / 10, "points": [view.frame.width, view.frame.height]]) }
                return view.snapshot(scale: scale)
            }
            for (name, summary, house) in [("full", samples.full, full), ("light", samples.light, light)] {
                for dark in [false, true] {
                    for scale in [1, 2] as [CGFloat] {
                        guard let image = card(summary, house: house, dark: dark, scale: scale) else { continue }
                        try png(image, directory.appendingPathComponent("today-counted-\(companion.rawValue)-\(name)-\(dark ? "dark" : "light")-\(Int(scale))x.png"))
                        if scale == 2 { cells.append(("\(name) day · \(dark ? "dark" : "light")", image)) }
                    }
                }
            }
            for (name, summary, house, yesterday, farewell) in [("yesterday", samples.full, full, true, false), ("goodbye", samples.full, full, false, true),
                                                                ("note", samples.note, full, false, false), ("scripts", samples.scripts, middle, false, false)] {
                guard let image = card(summary, house: house, dark: false, scale: 2, yesterday: yesterday, farewell: farewell) else { continue }
                try png(image, directory.appendingPathComponent("today-counted-\(companion.rawValue)-\(name).png"))
                cells.append((name, image))
            }
            if let sheet = grid(cells, columns: 4) { try png(sheet, directory.appendingPathComponent("today-counted-\(companion.rawValue).png")) }
        }
        try JSONSerialization.data(withJSONObject: ["cards": timings], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("today-counted.json"))
    }

    /// The bundled stills of each companion's home, made again by the app's renderer (DayCountedStills): <dir>/world/….
    public static func dayCountedStills(stage: MokuCharacterStage, directory: URL) async throws {
        for companion in Companion.allCases where companion == .moku || companion.isBundled {
            let written = try await DayCountedStills.make(companion: companion, into: directory)
            NSLog("today counted: %d stills for %@", written.count, companion.rawValue)
        }
    }

    /// What the card costs and how it moves (today-counted-cost.json). For each companion, with the companion itself hidden
    /// so its drawing doesn't move the numbers: the physical footprint's median over 6 s with nothing happening (twice: how
    /// much it wanders by itself), with the card up (its house a bundled still), and after it's gone; then the card's
    /// opacity and scale every 1/60 s as it comes in and goes, with and without Reduce Motion, and the biggest step
    /// between two frames. The card's window is put far off screen, so nothing shows on the display.
    public static func dayCountedCost(stage: MokuCharacterStage, directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let samples = dayCountedSamples(), presenter = DayCountedPresenter()
        let away = CGRect(x: -6000, y: 300, width: 320, height: 340), visible = CGRect(x: -6900, y: 0, width: 1440, height: 900)
        // The companion hidden, so its own drawing doesn't move the footprint; then a quiet while for it to settle.
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        stage.setHidden(true)
        try await Task.sleep(for: .seconds(40))
        /// The footprint's median over `seconds`, read every 250 ms, and the highest reading.
        func read(_ seconds: Double) async throws -> (median: Double, highest: Double) {
            var readings: [Double] = []
            let until = CACurrentMediaTime() + seconds
            while CACurrentMediaTime() < until { readings.append(physicalFootprint()); try await Task.sleep(for: .milliseconds(250)) }
            return (readings.sorted()[readings.count / 2], readings.max() ?? 0)
        }
        func mib(_ value: Double) -> Double { (value * 10).rounded() / 10 }
        var memory: [[String: Any]] = []
        for companion in Companion.allCases {
            let quiet = try await read(6)       // nothing happening: how much the footprint wanders by itself
            let before = try await read(6)
            let started = CACurrentMediaTime()
            let house = DayCountedStills.load(minutes: samples.full.focusedMinutes, companion: companion)
            presenter.put(DayCountedContent(summary: samples.full, companion: companion), house: house, beside: away, visible: visible, scale: 2)
            let made = CACurrentMediaTime() - started
            let pixels = presenter.view.map { Int($0.bounds.width * 2) * Int($0.bounds.height * 2) } ?? 0
            try await Task.sleep(for: .seconds(2))
            let shown = try await read(6)
            presenter.close()
            try await Task.sleep(for: .seconds(2))
            let after = try await read(6)
            memory.append(["companion": companion.rawValue, "quietMedianMiB": mib(quiet.median), "beforeMedianMiB": mib(before.median), "shownMedianMiB": mib(shown.median),
                           "shownHighestMiB": mib(shown.highest), "afterMedianMiB": mib(after.median), "driftWithNothingMiB": mib(before.median - quiet.median),
                           "extraWhileShownMiB": mib(shown.median - before.median), "extraAfterMiB": mib(after.median - before.median),
                           "cardPictureMiB": mib(Double(pixels * 4) / 1_048_576), "madeInMs": (made * 10_000).rounded() / 10])
        }
        var motion: [[String: Any]] = []
        for companion in Companion.allCases {
            for reduced in [false, true] {
                MotionPreference.override = reduced
                presenter.put(DayCountedContent(summary: samples.full, companion: companion), house: nil, beside: away, visible: visible, scale: 2)
                guard let view = presenter.view else { continue }
                let entrance = await frames(view, seconds: 0.7)
                presenter.close()
                let exit = await frames(view, seconds: 0.35)
                try await Task.sleep(for: .milliseconds(300))
                motion.append(["companion": companion.rawValue, "reduceMotion": reduced, "in": entrance.frames, "out": exit.frames,
                               "biggestStepIn": entrance.biggest, "biggestStepOut": exit.biggest])
            }
        }
        MotionPreference.override = nil
        try JSONSerialization.data(withJSONObject: ["memory": memory, "motion": motion], options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("today-counted-cost.json"))
    }

    /// The card's presentation every 1/60 s for `seconds`: [opacity, x scale, y scale] per frame, and the biggest
    /// change from one frame to the next.
    private static func frames(_ view: DayCountedCardView, seconds: Double) async -> (frames: [[Double]], biggest: Double) {
        var out: [[Double]] = [], biggest = 0.0
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < seconds {
            guard let p = view.presented else { try? await Task.sleep(for: .milliseconds(2)); continue }  // not committed yet
            let frame = [Double(p.opacity), Double(p.scaleX), Double(p.scaleY)].map { ($0 * 1000).rounded() / 1000 }
            if let last = out.last { biggest = max(biggest, zip(frame, last).map { abs($0 - $1) }.max() ?? 0) }
            out.append(frame)
            try? await Task.sleep(for: .microseconds(16_667))
        }
        return (out, (biggest * 1000).rounded() / 1000)
    }

    private static func png(_ image: CGImage, _ url: URL) throws {
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Cards in a grid on a desktop-ish background, each with its caption.
    private static func grid(_ cells: [(String, CGImage)], columns: Int) -> CGImage? {
        guard !cells.isEmpty else { return nil }
        let pad = 28, caption = 30
        let cellWidth = cells.map(\.1.width).max()! + pad, cellHeight = cells.map(\.1.height).max()! + pad + caption
        let rows = (cells.count + columns - 1) / columns, width = cellWidth * min(columns, cells.count) + pad, height = cellHeight * rows + pad
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (index, (label, image)) in cells.enumerated() {
            let x = pad + (index % columns) * cellWidth, top = height - pad - (index / columns) * cellHeight
            let dark = label.contains("dark")
            context.setFillColor(dark ? CGColor(srgbRed: 0.13, green: 0.14, blue: 0.15, alpha: 1) : CGColor(srgbRed: 0.86, green: 0.87, blue: 0.84, alpha: 1))
            context.fill(CGRect(x: x - pad / 2, y: top - cellHeight + pad / 2, width: cellWidth, height: cellHeight))
            NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: dark ? NSColor(white: 0.65, alpha: 1) : NSColor(white: 0.35, alpha: 1)])
                .draw(at: CGPoint(x: x, y: top - 24))
            context.draw(image, in: CGRect(x: x, y: top - caption - image.height, width: image.width, height: image.height))
        }
        NSGraphicsContext.current = previous
        return context.makeImage()
    }
}
