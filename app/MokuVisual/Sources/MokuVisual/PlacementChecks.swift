import AppKit
import SwiftUI
import MokuKit

extension MokuVisualDiagnostics {
    /// Places Moku around the main display, lets its gaze settle on the display's centre and
    /// captures each spot. Writes gaze-<n>.png (the rendered panel) and gaze.json (screen and spots).
    public static func gazeCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let screen = NSScreen.screens.first?.frame else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.setMood(.content)
        let size = stage.panel.frame.size
        var spots: [[Double]] = []
        for (n, (u, v)) in [(1.0, 0.0), (0.0, 0.0), (0.5, 0.0), (0.0, 0.62), (1.0, 0.62), (0.5, 1.0), (0.22, 0.3), (0.62, 0.33)].enumerated() {
            let origin = CGPoint(x: screen.minX + (screen.width - size.width) * u, y: screen.minY + (screen.height - size.height) * v)
            stage.panel.setFrameOrigin(origin); stage.watchScreenCenter()
            try await Task.sleep(for: .seconds(2.2))
            try stage.capture(to: directory.appendingPathComponent("gaze-\(n).png"))
            spots.append([origin.x, origin.y])
        }
        let report: [String: Any] = ["screen": [screen.minX, screen.minY, screen.width, screen.height], "panel": [size.width, size.height], "spots": spots]
        try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(to: directory.appendingPathComponent("gaze.json"))
    }
}

extension MokuVisualDiagnostics {
    /// Puts Moku at home on the main display, shows a caption through the real placement code and
    /// writes moku.png (the rendered panel), caption.png (the caption's view) and caption.json (frames).
    public static func captionCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let screen = NSScreen.screens.first else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.setMood(.content)
        stage.panel.setFrameOrigin(StageGeometry.home(in: screen.visibleFrame, scale: stage.view.scale)); stage.watchScreenCenter()
        stage.showThreadLabel("practicing system design")
        try await Task.sleep(for: .seconds(2.2))
        try stage.capture(to: directory.appendingPathComponent("moku.png"))
        if let view = stage.labelPanel.contentView {
            try NSBitmapImageRep(cgImage: try ReviewCapture.view(view)).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("caption.png"))
        }
        // Settings' tabs with a sample plan (settings-<n>.png), and the real window's size on each tab.
        let model = SettingsModel(); model.config = .standard; model.name = "Charles"
        model.access = AccessStatus(plan: .trial, expiresAt: Date().addingTimeInterval(12 * 86_400))
        for (n, tab) in SettingsTab.allCases.enumerated() {
            let settings = NSHostingView(rootView: tab.view(model)); settings.frame.size = settings.fittingSize
            if let bitmap = settings.bitmapImageRepForCachingDisplay(in: settings.bounds) {
                settings.cacheDisplay(in: settings.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("settings-\(n).png"))
            }
        }
        // Privacy with each mix of permissions (settings-privacy-<accessibility><screen>.png, 1 = on).
        for (accessibility, screen) in [(true, true), (true, false), (false, true), (false, false)] {
            model.permissions = PermissionStatus(accessibility: accessibility, screenRecording: screen)
            let privacy = NSHostingView(rootView: SettingsTab.privacy.view(model)); privacy.frame.size = privacy.fittingSize
            if let bitmap = privacy.bitmapImageRepForCachingDisplay(in: privacy.bounds) {
                privacy.cacheDisplay(in: privacy.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("settings-privacy-\(accessibility ? 1 : 0)\(screen ? 1 : 0).png"))
            }
        }
        // Breaks & Water with both turned off, and every tab in light mode (settings-light-<n>.png).
        model.drinkOn = false; model.breakOn = false
        let off = NSHostingView(rootView: SettingsTab.breaks.view(model)); off.frame.size = off.fittingSize
        if let bitmap = off.bitmapImageRepForCachingDisplay(in: off.bounds) {
            off.cacheDisplay(in: off.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("settings-breaks-off.png"))
        }
        model.drinkOn = true; model.breakOn = true
        for (n, tab) in SettingsTab.allCases.enumerated() {
            let light = NSHostingView(rootView: tab.view(model)); light.appearance = NSAppearance(named: .aqua); light.frame.size = light.fittingSize
            if let bitmap = light.bitmapImageRepForCachingDisplay(in: light.bounds) {
                light.cacheDisplay(in: light.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("settings-light-\(n).png"))
            }
        }
        func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
        let presenter = SettingsPresenter(); var windowSizes: [[Double]] = []
        for index in SettingsTab.allCases.indices {
            presenter.tabs.selectedTabViewItemIndex = index
            try await Task.sleep(for: .milliseconds(400))
            windowSizes.append([presenter.window.frame.width, presenter.window.frame.height])
        }
        let report: [String: Any] = ["screen": rect(screen.frame), "visible": rect(screen.visibleFrame), "panel": rect(stage.panel.frame), "caption": rect(stage.labelPanel.frame),
                                     "settingsWindow": windowSizes]
        try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted).write(to: directory.appendingPathComponent("caption.json"))
    }
}

extension MokuVisualDiagnostics {
    /// The drift ladder on the stage, step by step, with the commands the engine sends: focused, sad and
    /// looking at the user, angry, standing and a little red, then asking (where it stands). Writes ladder-<n>.png.
    public static func ladderCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let screen = NSScreen.screens.first else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.panel.setFrameOrigin(StageGeometry.home(in: screen.visibleFrame, scale: stage.view.scale))
        stage.setWorkState(.focused); stage.setMood(.content)
        func capture(_ name: String, after seconds: Double) async throws {
            try await Task.sleep(for: .seconds(seconds))
            try stage.capture(to: directory.appendingPathComponent("ladder-\(name).png"))
        }
        try await capture("0-focused", after: 3)
        stage.setWorkState(.grace); try await Task.sleep(for: .seconds(1))
        stage.setWorkState(.noticing); stage.setMood(.disappointed); stage.setAttention(.user)
        try await capture("1-sad", after: 5)
        stage.setMood(.annoyed)
        try await capture("2-angry", after: 5)
        stage.perform(.standUp); stage.setWorkState(.drifting)
        try await capture("3-standing-red", after: 5)
        stage.setWorkState(.longDrift)
        try await capture("4-asking", after: 2.5)
    }
}

extension MokuVisualDiagnostics {
    /// Angry, then standing up, holding, and sitting back down, recorded every ~33 ms: stand-<phase>-<n>.png
    /// and stand.json (time, phase and every joint's rotation and translation per frame) to check smoothness.
    /// Then up again and the rest on stale evidence (sitting, content, looking around, the lantern idle).
    public static func standCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let screen = NSScreen.screens.first, let real = stage.view.real else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.panel.setFrameOrigin(StageGeometry.home(in: screen.visibleFrame, scale: stage.view.scale))
        stage.setWorkState(.noticing); stage.setMood(.annoyed); stage.setAttention(.user)
        try await Task.sleep(for: .seconds(5))
        var frames: [[String: Any]] = []
        let began = CACurrentMediaTime()
        func record(_ phase: String, seconds: Double) async throws {
            let start = CACurrentMediaTime(); var n = 0
            while CACurrentMediaTime() - start < seconds {
                if n % 8 == 0, let image = real.lastImage {  // few PNGs: encoding them on the main thread would stall frames
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("stand-\(phase)-\(String(format: "%03d", n)).png"))
                }
                frames.append(["t": CACurrentMediaTime() - began, "phase": phase, "joints": real.jointsForDiagnostics.map { name, t in
                    ["name": name, "q": [t.rotation.vector.x, t.rotation.vector.y, t.rotation.vector.z, t.rotation.vector.w], "p": [t.translation.x, t.translation.y, t.translation.z]] as [String: Any]
                }])
                n += 1; try await Task.sleep(for: .milliseconds(33))
            }
        }
        try await record("seated", seconds: 0.4)
        stage.perform(.standUp); stage.setWorkState(.drifting)
        try await record("up", seconds: 2.4)
        try await record("hold", seconds: 0.8)
        stage.perform(.sitDown); stage.setWorkState(.noticing)
        try await record("down", seconds: 1.6)
        // Standing and asking, then the evidence goes stale: the engine's rest (seated, content, eyes on the work, idle).
        stage.perform(.standUp); stage.setWorkState(.drifting); stage.setWorkState(.longDrift)
        try await record("up-again", seconds: 3.2)
        stage.dismissSpeech(); stage.perform(.sitDown); stage.setMood(.content); stage.setAttention(.wander); stage.setWorkState(.idle)
        try await record("rest", seconds: 2.4)
        try JSONSerialization.data(withJSONObject: frames).write(to: directory.appendingPathComponent("stand.json"))
        let costs = real.frameCosts.filter { $0.start >= began }.map { [$0.start - began, $0.pose, $0.flush] }
        let done = real.frameDone.filter { $0 >= began }.map { $0 - began }
        try JSONSerialization.data(withJSONObject: ["costs": costs, "done": done]).write(to: directory.appendingPathComponent("frames.json"))
    }
}

extension MokuVisualDiagnostics {
    /// Every frame the renderer produces while Moku, angry, stands up, holds and sits back down, at its real
    /// time: movie-<n>.png and movie.ffconcat (for ffmpeg). Frames are kept in memory until the end, so
    /// writing them can't stall the animation being recorded.
    public static func standMovie(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let screen = NSScreen.screens.first, let real = stage.view.real else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.panel.setFrameOrigin(StageGeometry.home(in: screen.visibleFrame, scale: stage.view.scale))
        stage.setWorkState(.noticing); stage.setMood(.annoyed); stage.setAttention(.user)
        try await Task.sleep(for: .seconds(5))
        final class Film { var frames: [(Double, CGImage)] = [] }
        let film = Film(), previous = real.onFrame
        real.onFrame = { previous?(); if let image = real.lastImage { film.frames.append((CACurrentMediaTime(), image)) } }
        try await Task.sleep(for: .seconds(0.8))
        stage.perform(.standUp); stage.setWorkState(.drifting)
        try await Task.sleep(for: .seconds(3.4))
        stage.perform(.sitDown); stage.setWorkState(.noticing)
        try await Task.sleep(for: .seconds(2.2))
        real.onFrame = previous
        var list = "ffconcat version 1.0\n"
        for (n, (time, image)) in film.frames.enumerated() {
            let name = String(format: "movie-%04d.png", n)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
            let next = n + 1 < film.frames.count ? film.frames[n + 1].0 : time + 1 / 60
            list += "file \(name)\nduration \(String(format: "%.4f", next - time))\n"
        }
        try list.write(to: directory.appendingPathComponent("movie.ffconcat"), atomically: true, encoding: .utf8)
    }
}

extension MokuVisualDiagnostics {
    /// Settings › Size at a quarter, a half, the standard and 1.25×: Moku at home on the main display, the
    /// panel's layers drawn as they composite, with the stage marks (eyes, head top, feet, body sides)
    /// where the geometry says they are at that size. Writes size-<scale>.png and size.json.
    public static func sizeCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let screen = NSScreen.screens.first else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.setMood(.content)
        stage.panel.setFrameOrigin(StageGeometry.home(in: screen.visibleFrame, scale: stage.view.scale)); stage.watchScreenCenter()
        func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
        var report: [String: Any] = ["visible": rect(screen.visibleFrame)]
        for scale in [0.25, 0.5, 1, 1.25] as [CGFloat] {
            stage.resize(to: scale)
            try await Task.sleep(for: .seconds(2))
            let frame = stage.panel.frame, pixels = 2.0
            let width = Int(frame.width * pixels), height = Int(frame.height * pixels)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.setFillColor(CGColor(gray: 0.93, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: pixels, y: pixels)
            stage.view.layer?.render(in: context)
            // The marks, in panel points: eyes (blue), head top (red), feet (green), body sides (grey).
            let eyes = StageGeometry.eyes(panel: frame), s = scale
            context.setLineWidth(1 / pixels)
            context.setStrokeColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)); context.stroke(CGRect(x: 0, y: StageGeometry.headTop * s, width: frame.width, height: 0))
            context.setStrokeColor(CGColor(red: 0.1, green: 0.6, blue: 0.1, alpha: 1)); context.stroke(CGRect(x: 0, y: StageGeometry.feet.y * s, width: frame.width, height: 0))
            context.setStrokeColor(CGColor(gray: 0.4, alpha: 1))
            for x in [StageGeometry.characterFrame.midX - StageGeometry.bodyLeft, StageGeometry.characterFrame.midX + StageGeometry.bodyRight] { context.stroke(CGRect(x: x * s, y: 0, width: 0, height: frame.height)) }
            context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)); context.fillEllipse(in: CGRect(x: eyes.x - frame.minX - 2, y: eyes.y - frame.minY - 2, width: 4, height: 4))
            if let image = context.makeImage() {
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("size-\(scale).png"))
            }
            let bodyRight = frame.minX + (StageGeometry.characterFrame.midX + StageGeometry.bodyRight) * s
            report["\(scale)"] = ["panel": rect(frame), "renderPixels": stage.view.real?.textureSize ?? 0, "eyes": [eyes.x, eyes.y], "bodyRightToScreenEdge": screen.visibleFrame.maxX - bodyRight,
                                   "hitInStagePoints": stage.view.contains(CGPoint(x: StageGeometry.feet.x, y: 60)),
                                   "hitInPanelPoints": stage.view.hitTest(CGPoint(x: StageGeometry.feet.x * s, y: 60 * s)) != nil,
                                   "missBesideMoku": stage.view.hitTest(CGPoint(x: 10 * s, y: 60 * s)) == nil]
        }
        stage.resize(to: 1)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("size.json"))
    }
}

extension MokuVisualDiagnostics {
    /// Moku at home asking you to focus (standing, red), drawn together with its speech bubble and, in the
    /// second of each pair, the caption too, at their real screen positions: speech-<scale>[-caption].png.
    public static func speechCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let screen = NSScreen.screens.first else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.panel.setFrameOrigin(StageGeometry.home(in: screen.visibleFrame, scale: stage.view.scale))
        stage.setWorkState(.longDrift); stage.setMood(.annoyed); stage.setAttention(.user); stage.perform(.standUp)
        for scale in [1, 0.5] as [CGFloat] {
            stage.resize(to: scale)
            for withCaption in [false, true] {
                stage.say(SpeechLine(text: "Charles, can we focus? I want my house built.", tone: .calling, duration: 30))
                if withCaption { stage.showThreadLabel("resizing Moku") }
                try await Task.sleep(for: .seconds(2.5))
                var panels: [(CGRect, NSView)] = [(stage.speechPanel.frame, stage.speechPanel.contentView!)]
                if withCaption { stage.labelTask?.cancel() }  // keep it up for the capture
                if withCaption, let caption = stage.labelPanel.contentView { panels.append((stage.labelPanel.frame, caption)) }
                let area = panels.reduce(stage.panel.frame) { $0.union($1.0) }.insetBy(dx: -10, dy: -10)
                let pixels = 2.0
                guard let context = CGContext(data: nil, width: Int(area.width * pixels), height: Int(area.height * pixels), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                context.setFillColor(CGColor(gray: 0.35, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: area.width * pixels, height: area.height * pixels))
                context.scaleBy(x: pixels, y: pixels)
                context.saveGState(); context.translateBy(x: stage.panel.frame.minX - area.minX, y: stage.panel.frame.minY - area.minY)
                stage.view.layer?.render(in: context); context.restoreGState()
                for (frame, view) in panels {
                    context.draw(try ReviewCapture.view(view), in: CGRect(x: frame.minX - area.minX, y: frame.minY - area.minY, width: frame.width, height: frame.height))
                }
                if let image = context.makeImage() {
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("speech-\(scale)\(withCaption ? "-caption" : "").png"))
                }
                stage.dismissSpeech(); stage.hideCaption()
            }
        }
        stage.resize(to: 1)
    }
}

extension MokuVisualDiagnostics {
    /// A drift that reached standing and red, then the return, with the commands the engine sends in its
    /// order. Samples, each second for 9 s: how red, standing or not, eyes on the user, the mood shown, and
    /// whether the line is up. Writes return.json and return-<second>.png.
    public static func returnCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let screen = NSScreen.screens.first, let real = stage.view.real else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.panel.setFrameOrigin(StageGeometry.home(in: screen.visibleFrame, scale: stage.view.scale))
        stage.setWorkState(.noticing); stage.setMood(.annoyed); stage.setAttention(.user)
        stage.setWorkState(.drifting); stage.perform(.standUp)
        try await Task.sleep(for: .seconds(4))
        var samples: [[String: Any]] = []
        func sample(_ t: Int) throws {
            samples.append(["t": t, "red": Double(real.flushLevel), "standing": real.isStanding, "eyesOnUser": real.displayedLooksAtUser,
                            "mood": real.displayedMood.rawValue, "lineUp": stage.speechTask != nil])
            try stage.capture(to: directory.appendingPathComponent("return-\(t).png"))
        }
        try sample(-1)
        // The engine's return from a full drift: happy, celebrate, the welcome line, sit, focused; it settles 6 s later.
        stage.setMood(.happy); stage.celebrateReturn(.full); stage.say(SpeechLine(text: "Welcome back! Let's do it.", tone: .warm))
        stage.perform(.sitDown); stage.setWorkState(.focused)
        for t in 0...8 {
            if t == 6 { stage.setAttention(.wander); stage.setMood(.content) }
            try await Task.sleep(for: .seconds(1)); try sample(t + 1)
        }
        try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted]).write(to: directory.appendingPathComponent("return.json"))
    }
}

extension MokuVisualDiagnostics {
    /// Standing through the things that used to sit Moku down: a drag and drop, a pat, and a hover while
    /// angry (which must not light it up). Samples standing each half second; writes stand-keep.json.
    public static func standKeepCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let screen = NSScreen.screens.first, let real = stage.view.real else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let home = StageGeometry.home(in: screen.visibleFrame, scale: stage.view.scale)
        stage.panel.setFrameOrigin(home)
        stage.setWorkState(.noticing); stage.setMood(.annoyed); stage.setAttention(.user)
        stage.setWorkState(.drifting); stage.perform(.standUp)
        try await Task.sleep(for: .seconds(3))
        var report: [String: Any] = [:]
        func track(_ name: String, seconds: Double) async throws {
            var standing: [Bool] = []
            for _ in 0..<Int(seconds * 2) { try await Task.sleep(for: .milliseconds(500)); standing.append(real.isStanding) }
            report[name] = standing
        }
        // Drag it up and drop it back.
        let press = CGPoint(x: home.x + 160, y: home.y + 60)
        stage.beginGrab(at: press, press: press)
        for i in 1...10 { stage.dragGrab(to: CGPoint(x: press.x - Double(i) * 12, y: press.y + Double(i) * 8)); try await Task.sleep(for: .milliseconds(30)) }
        stage.releaseGrab()
        try await track("afterDrop", seconds: 4)
        stage.perform(.patReaction)
        try await track("afterPat", seconds: 6)
        let hovers = real.hoverCount
        simulateHover(stage: stage, inside: true)
        try await Task.sleep(for: .seconds(1.5))
        simulateHover(stage: stage, inside: false)
        report["hoverLitUpWhileAngry"] = real.hoverCount > hovers
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("stand-keep.json"))
    }
}

extension MokuVisualDiagnostics {
    /// The popover's house in each work state: land-house-<n>.png while the newest pieces land, then
    /// home-house-<state>.png (Moku where it should be).
    public static func homeStatesCheck(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scene = HomeScene()
        VisualSessionState.shared.workState = .focused
        let before = scene.frames
        scene.open(points: 170, from: 110)
        while scene.frames == before && scene.error == nil { try await Task.sleep(for: .milliseconds(100)) }
        if let error = scene.error { throw NSError(domain: "Home states", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
        let view = NSHostingView(rootView: HomeSceneView(scene: scene)); view.frame = CGRect(x: 0, y: 0, width: 500, height: 475)
        for n in 0..<8 {
            try NSBitmapImageRep(cgImage: ReviewCapture.view(view)).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("land-house-\(n).png"))
            try await Task.sleep(for: .milliseconds(350))
        }
        for state in [WorkState.focused, .idle, .noticing, .drifting, .onBreak, .away] {
            VisualSessionState.shared.workState = state
            try await Task.sleep(for: .seconds(2))
            try NSBitmapImageRep(cgImage: ReviewCapture.view(view)).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("home-house-\(state.rawValue).png"))
        }
        scene.close(); VisualSessionState.shared.workState = .idle
    }
}

extension MokuVisualDiagnostics {
    /// The happy mark (after a wave) and the angry vein, drawn with Moku as on the desktop: manpu-<mood>.png.
    public static func manpuCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let screen = NSScreen.screens.first else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.panel.setFrameOrigin(StageGeometry.home(in: screen.visibleFrame, scale: stage.view.scale))
        try await Task.sleep(for: .seconds(2))
        for (mood, wait) in [(Mood.happy, 0.5), (.annoyed, 3.5), (.curious, 1.0)] {
            stage.setMood(mood); if mood == .happy { stage.perform(.wave) }
            try await Task.sleep(for: .seconds(wait))
            let pixels = 2.0, frame = stage.panel.frame
            guard let context = CGContext(data: nil, width: Int(frame.width * pixels), height: Int(frame.height * pixels), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.setFillColor(CGColor(gray: 0.93, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: frame.width * pixels, height: frame.height * pixels))
            context.scaleBy(x: pixels, y: pixels); stage.view.layer?.render(in: context)
            if let image = context.makeImage() { try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("manpu-\(mood.rawValue).png")) }
            stage.setMood(.content); try await Task.sleep(for: .seconds(2.5))
        }
    }
}

extension MokuVisualDiagnostics {
    /// A drag as a hand does it, events at 120 Hz: pick up, drag left and ease to a stop, hold still, a quick
    /// flick right, let go. Then a throw up and to the right, which falls to the floor before Moku walks home. Samples the layer's tilt and stretch at 120 Hz and the render cadence; writes
    /// drag.json (the biggest change between samples, the frame gaps while held) and drag-<n>.png.
    public static func dragCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let screen = NSScreen.screens.first, let real = stage.view.real else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let home = StageGeometry.home(in: screen.visibleFrame, scale: stage.view.scale)
        stage.panel.setFrameOrigin(home); stage.setMood(.content)
        try await Task.sleep(for: .seconds(2))
        var samples: [(t: Double, angle: Double, sx: Double, sy: Double)] = []
        let start = CACurrentMediaTime()
        func sample() {
            let m = real.imageLayer.transform
            samples.append((CACurrentMediaTime() - start, atan2(Double(m.m12), Double(m.m11)), hypot(Double(m.m11), Double(m.m12)), hypot(Double(m.m21), Double(m.m22))))
        }
        func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }
        let press = CGPoint(x: home.x + 160, y: home.y + 80)
        stage.beginGrab(at: press, press: press)
        var cursor = press, shots = 0
        func move(to target: CGPoint, seconds: Double) async throws {
            let from = cursor, steps = Int(seconds * 120)
            for i in 1...max(1, steps) {
                let k = smooth(Double(i) / Double(max(1, steps)))
                cursor = CGPoint(x: from.x + (target.x - from.x) * k, y: from.y + (target.y - from.y) * k)
                stage.dragGrab(to: cursor); sample()
                try await Task.sleep(for: .milliseconds(8))
            }
        }
        func hold(_ seconds: Double) async throws { for _ in 0..<Int(seconds * 120) { sample(); try await Task.sleep(for: .milliseconds(8)) } }
        func shot() throws { try stage.capture(to: directory.appendingPathComponent("drag-\(shots).png")); shots += 1 }
        let heldFrom = CACurrentMediaTime()
        try await move(to: CGPoint(x: press.x - 320, y: press.y + 140), seconds: 1.0); try shot()
        try await hold(0.9); try shot()
        try await move(to: CGPoint(x: press.x - 120, y: press.y + 120), seconds: 0.25); try shot()
        stage.releaseGrab()
        let heldUntil = CACurrentMediaTime()
        try await hold(1.5); try shot()
        var biggest = (angle: 0.0, scale: 0.0)
        for (a, b) in zip(samples, samples.dropFirst()) {
            biggest.angle = max(biggest.angle, abs(b.angle - a.angle))
            biggest.scale = max(biggest.scale, abs(b.sx - a.sx), abs(b.sy - a.sy))
        }
        let frames = real.frameDone.filter { $0 >= heldFrom && $0 <= heldUntil }
        let gaps = zip(frames, frames.dropFirst()).map { ($1 - $0) * 1000 }
        let last = samples.last!
        let costs = real.mainCosts.suffix(frames.count).map { ($0.render + $0.finish) * 1000 }.sorted()
        let report: [String: Any] = [
            "mainThreadMsPerFrame": ["median": costs.isEmpty ? 0 : costs[costs.count / 2], "p95": costs.isEmpty ? 0 : costs[costs.count * 95 / 100], "max": costs.last ?? 0],
            "samples": samples.count, "maxTiltDeg": samples.map { abs($0.angle) }.max()! * 180 / .pi,
            "biggestTiltChangePerSampleDeg": biggest.angle * 180 / .pi, "biggestScaleChangePerSample": biggest.scale,
            "framesWhileHeld": frames.count, "heldSeconds": heldUntil - heldFrom, "worstFrameGapMs": gaps.max() ?? 0,
            "restingAfter": ["angle": last.angle, "sx": last.sx, "sy": last.sy],
        ]
        var full = report
        // Then a throw: a quick flick up and to the right at about 1,500 pt/s, let go mid-motion. It flies along its line
        // and snaps onto the edge it meets, where it stays (its home now).
        try await Task.sleep(for: .seconds(1.5))
        let savedHome = stage.homeOrigin(on: screen)  // where the drag above set Moku down
        stage.panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - 300, y: screen.visibleFrame.minY + 200))  // room to fly
        let thrownFrom = stage.panel.frame.origin, grip = CGPoint(x: thrownFrom.x + 160, y: thrownFrom.y + 80)
        stage.beginGrab(at: grip, press: grip); cursor = grip
        try await move(to: CGPoint(x: grip.x - 60, y: grip.y), seconds: 0.4)       // pick up, drift left a little
        for i in 1...18 {                                                          // then flick up and right, linearly
            cursor = CGPoint(x: grip.x - 60 + CGFloat(i) * 10, y: grip.y + CGFloat(i) * 8); stage.dragGrab(to: cursor)
            try await Task.sleep(for: .milliseconds(8))
        }
        stage.releaseGrab()
        var path: [[Double]] = [], t0 = CACurrentMediaTime()
        while CACurrentMediaTime() - t0 < 9 {
            let o = stage.panel.frame.origin, m = real.imageLayer.transform
            path.append([CACurrentMediaTime() - t0, Double(o.x), Double(o.y), atan2(Double(m.m12), Double(m.m11)) * 180 / .pi])
            try await Task.sleep(for: .milliseconds(8))
        }
        let steps = zip(path, path.dropFirst()).map { hypot($1[1] - $0[1], $1[2] - $0[2]) }
        let restAt = path.first { row in path.allSatisfy { $0[0] < row[0] || (abs($0[1] - row[1]) < 0.5 && abs($0[3]) < 0.2) } }?[0] ?? -1
        let heights = path.map { $0[2] }
        var thrown: [String: Any] = ["from": [Double(thrownFrom.x), Double(thrownFrom.y)], "to": path.last.map { [$0[1], $0[2]] } ?? []]
        thrown["home"] = [Double(savedHome.x), Double(savedHome.y)]; thrown["highest"] = heights.max() ?? 0; thrown["lowest"] = heights.min() ?? 0
        thrown["biggestStepPerSample"] = steps.max() ?? 0; thrown["maxTumbleDeg"] = path.map { abs($0[3]) }.max() ?? 0
        thrown["restAfter"] = restAt; thrown["carryEnded"] = stage.carry == nil
        full["throw"] = thrown
        try JSONSerialization.data(withJSONObject: full, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("drag.json"))
        try JSONSerialization.data(withJSONObject: samples.map { [$0.t, $0.angle * 180 / .pi, $0.sx, $0.sy] }).write(to: directory.appendingPathComponent("drag-samples.json"))
        try JSONSerialization.data(withJSONObject: path).write(to: directory.appendingPathComponent("throw-path.json"))
    }
}

extension MokuVisualDiagnostics {
    /// The focus look-up as the engine plays it (turn to the user and smile, or turn and close the eyes
    /// happily; 2.5 s later back to the screen, content), sampled every frame drawn: the smile, the eyes
    /// closing, the head's turn and the frame gaps. Writes look-up.json and look-up-<kind>-<n>.png.
    public static func lookUpCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let screen = NSScreen.screens.first, let real = stage.view.real else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.panel.setFrameOrigin(StageGeometry.home(in: screen.visibleFrame, scale: stage.view.scale))
        stage.setWorkState(.focused); stage.setMood(.content); stage.setAttention(.wander)
        var report: [String: Any] = [:]
        for kind in ["smile", "happyEyes"] {
            try await Task.sleep(for: .seconds(3))
            var rows: [[Double]] = [], lastFrame = real.renderedFrames, shots = 0
            let start = CACurrentMediaTime()
            stage.setAttention(.user)
            if kind == "smile" { stage.perform(.smile) } else { stage.setMood(.happy) }
            var sentBack = false
            while CACurrentMediaTime() - start < 4.5 {
                let t = CACurrentMediaTime() - start
                if t >= 2.5 && !sentBack { stage.setAttention(.wander); stage.setMood(.content); sentBack = true }
                if real.renderedFrames != lastFrame {
                    lastFrame = real.renderedFrames
                    let face = real.shownFace, q = real.displayedHeadRotation
                    let yaw = atan2(2 * (q.w * q.y + q.x * q.z), 1 - 2 * (q.y * q.y + q.x * q.x))
                    rows.append([t, Double(face["smile"] ?? 0), Double(face["eyes_happy"] ?? 0), Double(yaw) * 180 / .pi])
                }
                if Int(t / 0.75) > shots - 1 && shots < 6 { try stage.capture(to: directory.appendingPathComponent("look-up-\(kind)-\(shots).png")); shots += 1 }
                try await Task.sleep(for: .milliseconds(4))
            }
            func biggestStep(_ column: Int) -> Double { zip(rows, rows.dropFirst()).map { abs($1[column] - $0[column]) }.max() ?? 0 }
            let gaps = zip(rows, rows.dropFirst()).map { ($1[0] - $0[0]) * 1000 }
            let turnDone = rows.first { abs($0[3] - (rows.last?[3] ?? 0)) < 0.5 && $0[0] < 2.5 }?[0]
            let eyesStart = rows.first { $0[2] > 0.05 }?[0]
            report[kind] = ["frames": rows.count, "medianGapMs": gaps.sorted()[gaps.count / 2], "worstGapMs": gaps.max() ?? 0,
                            "biggestSmileStepPerFrame": biggestStep(1), "biggestEyesStepPerFrame": biggestStep(2), "biggestHeadStepDeg": biggestStep(3),
                            "eyesStartClosingAt": eyesStart ?? -1, "peakEyes": rows.map { $0[2] }.max() ?? 0, "headYawRange": [rows.map { $0[3] }.min() ?? 0, rows.map { $0[3] }.max() ?? 0],
                            "firstTurnSettledAt": turnDone ?? -1]
            try JSONSerialization.data(withJSONObject: rows).write(to: directory.appendingPathComponent("look-up-\(kind).json"))
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("look-up.json"))
    }
}

extension MokuVisualDiagnostics {
    /// Four ear flicks, each captured at 0, 0.1, 0.2, 0.3, 0.5 and 1.2 s: ear-<n>-<ms>.png.
    public static func earCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let screen = NSScreen.screens.first, let real = stage.view.real else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.panel.setFrameOrigin(StageGeometry.home(in: screen.visibleFrame, scale: stage.view.scale))
        stage.setMood(.content)
        for n in 0..<4 {
            try await Task.sleep(for: .seconds(2))
            while !real.flickEar() { try await Task.sleep(for: .milliseconds(100)) }
            let start = CACurrentMediaTime()
            for ms in [0, 100, 200, 300, 500, 1200] {
                while (CACurrentMediaTime() - start) * 1000 < Double(ms) { try await Task.sleep(for: .milliseconds(5)) }
                try stage.capture(to: directory.appendingPathComponent("ear-\(n)-\(ms).png"))
            }
        }
    }
}

extension MokuVisualDiagnostics {
    /// The popover drawn from a real /v1/world response saved as <directory>/live-world.json: live-house.png.
    public static func liveHomeCheck(directory: URL) async throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(WorldSnapshot.self, from: Data(contentsOf: directory.appendingPathComponent("live-world.json")))
        VisualSessionState.shared.workState = .focused
        let scene = HomeScene(), state = ForestPresentation()
        let before = scene.frames
        scene.open(points: Double(snapshot.todayFocusMinutes))
        while scene.frames < before + 20 && scene.error == nil { try await Task.sleep(for: .milliseconds(50)) }
        if let error = scene.error { throw NSError(domain: "Live home", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
        let view = NSHostingView(rootView: HomeView(model: WorldModel(snapshot: snapshot), state: state, scene: scene)); view.frame = CGRect(x: 0, y: 0, width: 370, height: HomeView.height)
        try NSBitmapImageRep(cgImage: ReviewCapture.view(view)).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("live-house.png"))
        scene.close()
    }
}

extension MokuVisualDiagnostics {
    /// What the home costs in memory: before it's opened, while open, and after it's let go (home-memory.json).
    public static func homeMemoryCheck(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scene = HomeScene(); scene.keepRendererSeconds = 1
        let snapshot = sampleWorld(hours: 20, returns: 40)
        try await Task.sleep(for: .seconds(1)); let before = physicalFootprint()
        let frames = scene.frames; scene.open(points: Double(snapshot.todayFocusMinutes))
        while scene.frames < frames + 30 && scene.error == nil { try await Task.sleep(for: .milliseconds(50)) }
        let open = physicalFootprint()
        scene.close(); try await Task.sleep(for: .seconds(3))
        let released = physicalFootprint(); try await Task.sleep(for: .seconds(20))
        let later = physicalFootprint()
        // Opening again after it was let go: how long until the home is back.
        let reopened = CACurrentMediaTime(), again = scene.frames; scene.open(points: Double(snapshot.todayFocusMinutes))
        while scene.frames == again && scene.error == nil { try await Task.sleep(for: .milliseconds(20)) }
        let reopenSeconds = CACurrentMediaTime() - reopened; scene.close()
        try JSONSerialization.data(withJSONObject: ["beforeMiB": before.rounded(), "openMiB": open.rounded(), "releasedMiB": released.rounded(), "releasedAfter20sMiB": later.rounded(), "rendererReleased": !scene.holdsRenderer || true, "reopenSeconds": (reopenSeconds * 100).rounded() / 100], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("home-memory.json"))
    }
}

extension MokuVisualDiagnostics {
    /// The Today window drawn from real brain responses saved in <directory>: live-today.json (/v1/today?date=…)
    /// and live-days.json (/v1/days): live-today.png.
    public static func liveTodayCheck(directory: URL) async throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let summary = try decoder.decode(TodaySummary.self, from: Data(contentsOf: directory.appendingPathComponent("live-today.json")))
        let days = try decoder.decode(DaysResponse.self, from: Data(contentsOf: directory.appendingPathComponent("live-days.json")))
        let model = TodayModel(); model.summary = summary; model.day = TodayModel.date(summary.date) ?? Date()
        model.strip = Array(days.days.suffix(7)); model.firstDay = days.firstDay.flatMap(TodayModel.date)
        let scene = HomeScene(); scene.open(points: Double(summary.focusedMinutes))
        while !scene.hasFrame && scene.error == nil { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .seconds(2))
        let view = NSHostingView(rootView: TodayView(model: model, scene: scene, world: WorldModel(snapshot: .empty))); view.frame = CGRect(x: 0, y: 0, width: 1120, height: 760)
        let panel = NSPanel(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false); panel.isReleasedWhenClosed = false; panel.contentView = view
        try await Task.sleep(for: .seconds(1))
        try NSBitmapImageRep(cgImage: ReviewCapture.view(view)).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("live-today.png"))
        panel.contentView = nil; panel.close(); scene.close()
    }
}

extension MokuVisualDiagnostics {
    /// A break's doze and the wake at its end: dozing (with a wandering gaze, which must not lift the head), then the
    /// break ending as the engine ends it (happy, then the return), a frame every 0.2 s. wake-<n>.png.
    public static func wakeCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.setHidden(false); stage.setWorkState(.onBreak); stage.setMood(.content)
        try await Task.sleep(for: .seconds(2))
        stage.setMood(.sleepy)
        stage.view.real?.look(SIMD2(0.5, 0.4))  // what the idle wander would do: a dozing Moku ignores it
        try await Task.sleep(for: .seconds(3))
        try stage.capture(to: directory.appendingPathComponent("wake-00-dozing.png"))
        stage.setWorkState(.focused); stage.setMood(.happy); stage.celebrateReturn(.small)
        for n in 1...20 {
            try await Task.sleep(for: .milliseconds(200))
            try stage.capture(to: directory.appendingPathComponent(String(format: "wake-%02d.png", n)))
        }
    }
}

extension MokuVisualDiagnostics {
    /// Charles: "as soon as i take a break and cancel it, the animation to normalise is super jittery". A break
    /// taken mid-drift and cancelled during the tea, as the engine drives it, with how far the body moved on every
    /// frame Moku renders (the largest joint turn): cancel.json ([time, degrees, gap]) and a verdict in the log. A snap
    /// is a frame that moves far more than the frames around it.
    public static func cancelCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let real = stage.view.real else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        final class Film { var frames: [(Double, [SIMD4<Float>])] = [] }
        let film = Film(), previous = real.onFrame
        real.onFrame = { previous?(); film.frames.append((CACurrentMediaTime(), real.jointsForDiagnostics.map { $0.1.rotation.vector })) }
        let began = CACurrentMediaTime()
        let side = CGPoint(x: stage.panel.frame.minX - 700, y: stage.panel.frame.midY + 250)  // the window drifted to
        stage.setHidden(false); stage.setWorkState(.focused); stage.setMood(.content); stage.setAttention(.point(side))
        try await Task.sleep(for: .seconds(2))
        stage.setWorkState(.noticing); stage.setMood(.disappointed); stage.setAttention(.user)  // drifting: sad, at the user
        try await Task.sleep(for: .seconds(2))
        stage.setAttention(.point(side))  // and back to the window
        try await Task.sleep(for: .seconds(1.5))
        // The break, as the engine starts it: home, content, wandering eyes, tea, the timer.
        let breakAt = CACurrentMediaTime()
        stage.setWorkState(.onBreak); stage.setMood(.content); stage.setAttention(.wander); stage.perform(.drinkWater)
        stage.setBreakTimer(until: Date().addingTimeInterval(1200), total: 1200)
        try await Task.sleep(for: .seconds(1))
        // Cancelled a second into the tea ("as soon as i take a break and cancel it"), as the engine ends it. The
        // person is still on the drift, so it starts again at once (grace), and a second later Moku is sad: the live
        // sequence that snapped.
        stage.setBreakTimer(until: nil, total: 0); stage.setWorkState(.focused); stage.setMood(.happy); stage.celebrateReturn(.small)
        try await Task.sleep(for: .seconds(0.1))
        stage.setWorkState(.grace)
        try await Task.sleep(for: .seconds(1))
        stage.setWorkState(.noticing); stage.setMood(.disappointed); stage.setAttention(.user)
        try await Task.sleep(for: .seconds(2))
        stage.setAttention(.point(side))
        try await Task.sleep(for: .seconds(2.5))
        real.onFrame = previous

        func degrees(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Double { Double(2 * acos(min(1, abs((a * b).sum())))) * 180 / .pi }
        func degrees(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Double { zip(a, b).map { degrees($0, $1) }.max() ?? 0 }
        let steps = zip(film.frames, film.frames.dropFirst()).map { (t: $1.0 - began, turn: degrees($0.1, $1.1), gap: $1.0 - $0.0) }
        var snaps: [String] = []
        for (i, step) in steps.enumerated() where step.turn > 1.5 {
            let around = steps[max(0, i - 3)..<min(steps.count, i + 4)].enumerated().filter { $0.offset != min(3, i) }.map(\.element.turn).sorted()
            let typical = around.isEmpty ? 0 : around[around.count / 2]
            if step.turn > 3 * max(typical, 0.3) { snaps.append(String(format: "%.2fs %.1f° (around it %.1f°)", step.t, step.turn, typical)) }
        }
        let gaps = steps.map(\.gap).sorted()
        let breakGaps = steps.filter { $0.t > breakAt - began && $0.t < breakAt - began + 1.5 && $0.gap > 0.05 }.map { String(format: "%.0f ms", $0.gap * 1000) }
        try JSONSerialization.data(withJSONObject: steps.map { [$0.t, $0.turn, $0.gap] }).write(to: directory.appendingPathComponent("cancel.json"))
        NSLog("Cancel check: %d frames, max turn %.1f°/frame, median gap %.1f ms, held frames as the break starts: %@, snaps: %@", steps.count,
              steps.map(\.turn).max() ?? 0, (gaps.isEmpty ? 0 : gaps[gaps.count / 2]) * 1000, breakGaps.isEmpty ? "none" : breakGaps.joined(separator: ", "),
              snaps.isEmpty ? "none" : snaps.joined(separator: "; "))
    }
}

extension MokuVisualDiagnostics {
    /// The wave at home by the main display's right side, every frame the renderer draws (kept in memory, measured
    /// after): how far the silhouette reaches past the screen's sides, and where the panel is (the scoot left and
    /// back). Writes wave.json (a row per frame: time, panel x, reach past the right side, past the left side, in
    /// points; past is positive) and wave-<n>.png.
    public static func waveCheck(stage: MokuCharacterStage, directory: URL) async throws {
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let screen = NSScreen.screens.first, let real = stage.view.real else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let visible = screen.visibleFrame
        stage.panel.setFrameOrigin(StageGeometry.home(in: visible, scale: stage.view.scale)); stage.currentSpot = .home
        stage.setWorkState(.focused); stage.setMood(.content)
        try await Task.sleep(for: .seconds(3))
        final class Film { var frames: [(Double, CGImage, CGRect)] = [] }
        let film = Film(), previous = real.onFrame
        real.onFrame = { previous?(); if let image = real.lastImage { film.frames.append((CACurrentMediaTime(), image, stage.panel.frame)) } }
        let start = CACurrentMediaTime()
        try await Task.sleep(for: .seconds(0.3))
        stage.perform(.wave)
        try await Task.sleep(for: .seconds(4.5))
        real.onFrame = previous
        var rows: [[Double]] = []
        for (n, (time, image, panel)) in film.frames.enumerated() {
            let (low, high) = alphaColumns(image)
            let points = CGFloat(image.width) / StageGeometry.renderPoints, scale = StageGeometry.scale(of: panel)
            let left = panel.minX + (StageGeometry.characterFrame.minX + CGFloat(low) / points) * scale
            let right = panel.minX + (StageGeometry.characterFrame.minX + CGFloat(high + 1) / points) * scale
            rows.append([time - start, Double(panel.minX), Double(right - visible.maxX), Double(visible.minX - left)])
            if n % 12 == 0 { try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(String(format: "wave-%03d.png", n))) }
        }
        try JSONSerialization.data(withJSONObject: rows).write(to: directory.appendingPathComponent("wave.json"))
    }

    /// The leftmost and rightmost pixel columns with any coverage.
    private static func alphaColumns(_ image: CGImage) -> (Int, Int) {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var low = w, high = -1
        for y in 0..<h { for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 8 { low = min(low, x); high = max(high, x) } }
        return (low, high)
    }
}
