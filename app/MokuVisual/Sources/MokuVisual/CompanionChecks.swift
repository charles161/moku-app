import AppKit
import SwiftUI
import MokuKit

extension MokuVisualDiagnostics {
    /// Switching companions on a live stage (moku-and-friends.md, Runtime). The choice stays in this process (never the
    /// shared defaults). Moku sad mid-drift, then every other bundled companion in turn, then Moku again: each must take
    /// over in the same mood and work state, with a character drawn on every sampled frame (no blank flash), and the
    /// day's home and its names must follow. Writes companion-<id>.png (the stage), popover-<id>.png (today's home at
    /// 150 focused minutes), settings-general.png and welcome-hello.png when there's a choice, and companion-check.json.
    public static func companionCheck(stage: MokuCharacterStage, directory: URL) async throws {
        CompanionChoice.keepInMemory(starting: .moku)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stage.show()
        while stage.view.real == nil && stage.rendererError == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard stage.view.real != nil else { throw CocoaError(.fileReadUnknown) }
        stage.setWorkState(.drifting); stage.setMood(.disappointed)
        try await Task.sleep(for: .seconds(3.5))
        var report: [String: Any] = ["available": Companion.available.map(\.rawValue)]
        var switches: [[String: Any]] = []
        var homes: [String: Any] = [:]
        func still(_ companion: Companion) async throws {
            try stage.capture(to: directory.appendingPathComponent("companion-\(companion.rawValue).png"))
            var world = sampleWorld(hours: 20, today: 150, returns: 4); world.threads = []
            let scene = HomeScene(); scene.open(points: 150)
            let opened = CACurrentMediaTime()
            while !scene.hasFrame && scene.error == nil && CACurrentMediaTime() - opened < 120 { try await Task.sleep(for: .milliseconds(100)) }
            homes[companion.rawValue] = ["firstFrameSeconds": CACurrentMediaTime() - opened, "error": scene.error ?? "none", "layout": companion.homeLayoutPath]
            try await Task.sleep(for: .milliseconds(600))
            let view = NSHostingView(rootView: HomeView(model: WorldModel(snapshot: world), state: ForestPresentation(), scene: scene))
            view.frame = CGRect(x: 0, y: 0, width: 370, height: HomeView.height)
            try NSBitmapImageRep(cgImage: ReviewCapture.view(view)).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("popover-\(companion.rawValue).png"))
            scene.close()
        }
        try await still(.moku)
        for companion in Companion.available.dropFirst() + [.moku] {
            let started = CACurrentMediaTime()
            CompanionChoice.choose(companion)
            // Every 1/60 s: is a character drawn (some character layer with a picture, not faded out)?
            var samples = 0, blank = 0, onStageAfter = -1.0
            while CACurrentMediaTime() - started < 20 {
                let drawn = stage.view.stage.sublayers?.contains { layer in layer.contents != nil && layer.opacity > 0.01 && layer.frame == stage.view.real?.imageLayer.frame } ?? false
                samples += 1; if !drawn { blank += 1 }
                if onStageAfter < 0 && stage.companion == companion { onStageAfter = CACurrentMediaTime() - started }
                if stage.companion == companion && stage.totalRenderedFrames > 30 && CACurrentMediaTime() - started > 1.5 { break }
                try await Task.sleep(for: .milliseconds(16))
            }
            try await Task.sleep(for: .seconds(1.5))
            switches.append(["to": companion.rawValue, "onStage": stage.companion?.rawValue ?? "none", "onStageAfterSeconds": onStageAfter,
                             "samples": samples, "blankSamples": blank, "mood": "\(stage.mood)", "workState": "\(stage.workState)",
                             "characterLayers": stage.view.stage.sublayers?.filter { $0.frame == stage.view.real?.imageLayer.frame }.count ?? 0,
                             "homeNames": DayHouse.names.home])
            if companion != .moku { try await still(companion) }
        }
        report["switches"] = switches; report["homes"] = homes
        // Settings › General, and the welcome's first card, with the choice on show.
        if Companion.hasChoice {
            let model = SettingsModel(); model.config = .standard; model.name = "Charles"
            let general = NSHostingView(rootView: SettingsTab.general.view(model)); general.frame.size = general.fittingSize
            try NSBitmapImageRep(cgImage: ReviewCapture.view(general)).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("settings-general.png"))
            let welcome = OnboardingModel(); welcome.suggestedName = "Charles"; welcome.greetedAt = .distantPast; welcome.choosing = true; welcome.companion = .moku
            let size = MokuOnboardingPresenter.size(for: welcome)
            let card = NSHostingView(rootView: OnboardingView(model: welcome, size: size)); card.frame.size = size
            try await Task.sleep(for: .milliseconds(150))
            try NSBitmapImageRep(cgImage: ReviewCapture.view(card)).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("welcome-hello.png"))
            if let other = Companion.available.last, other != .moku {  // and with another one picked: it says hello
                welcome.companion = other
                try await Task.sleep(for: .milliseconds(150))
                try NSBitmapImageRep(cgImage: ReviewCapture.view(card)).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("welcome-hello-\(other.rawValue).png"))
            }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("companion-check.json"))
        stage.setHidden(true)
        let failed = switches.contains { ($0["onStage"] as? String) != ($0["to"] as? String) || ($0["blankSamples"] as? Int ?? 1) > 0 || ($0["characterLayers"] as? Int ?? 0) != 1 }
        if failed { throw CocoaError(.validationMissingMandatoryProperty) }
    }
}
