import AppKit
import AVFoundation
import SwiftUI
import MokuKit

/// The welcome as someone would see it, drawn offscreen frame by frame from the app's own pieces: a drawn desk (never a
/// real screen), the welcome window's picture, the companion's own render where its window is, its speech, the window's
/// exit, System Settings (a stand-in where the app found it) and the spotlight on the icon.
@MainActor enum WelcomeDesk {
    /// Pictures that don't change from frame to frame, kept so a film can be drawn at its pace.
    private final class Cache { var desk: CGImage?; var deskFor: CGRect?; var speech: CGImage?; var speechFor: ObjectIdentifier?; var companion: CGImage?; var companionFor: ObjectIdentifier? }
    private static let cache = Cache()
    struct Scene {
        var stage: MokuCharacterStage
        var presenter: MokuOnboardingPresenter
        var icon: CGRect
        var pointer: CGPoint?
        var settings: (frame: CGRect, pane: String, on: Bool)?
    }
    static func draw(_ scene: Scene, screen: CGRect) throws -> CGImage {
        let width = Int(screen.width / 2) * 2, height = Int(screen.height / 2) * 2
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: -screen.minX, y: -screen.minY)
        // The desk doesn't change: drawn once.
        if cache.desk == nil || cache.deskFor != screen {
            let desk = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            desk.translateBy(x: -screen.minX, y: -screen.minY)
            wallpaper(desk, screen)
            work(desk, CGRect(x: screen.minX + 70, y: screen.maxY - 64 - 520, width: 600, height: 520))
            cache.desk = desk.makeImage(); cache.deskFor = screen
        }
        if let desk = cache.desk { context.draw(desk, in: screen) }
        let presenter = scene.presenter
        if let panel = presenter.panel, panel.isVisible || presenter.exit == nil && !presenter.state.starting, let content = panel.contentView {
            window(context, try ReviewCapture.view(content), frame: panel.frame, alpha: panel.alphaValue)
        }
        // System Settings comes to the front (the welcome steps back for it).
        if let settings = scene.settings { systemSettings(context, settings.frame, pane: settings.pane, on: settings.on) }
        if let exit = presenter.exit { leaving(context, exit.kind, at: CACurrentMediaTime() - exit.at, frame: exit.frame, picture: exit.picture) }
        // The spotlight dims everything but the icon (the menu bar too); the companion and its line stay over it.
        let lit = presenter.spotlight.map { ($0.icon, $0.model.state(at: CACurrentMediaTime() - $0.began, dismissedAt: $0.dismissedAt)) }
        menuBar(context, screen, icon: scene.icon, house: lit == nil)
        if let (icon, state) = lit { spotlight(context, screen, icon: icon, state: state) }
        companion(context, scene.stage)
        if scene.stage.speechTask != nil, scene.stage.speechPanel.alphaValue > 0.01, let content = scene.stage.speechPanel.contentView {
            // A bubble is drawn once (its typing and entrance are Core Animation): its picture is kept while it's up.
            if cache.speechFor != ObjectIdentifier(content) { cache.speech = try ReviewCapture.view(content); cache.speechFor = ObjectIdentifier(content) }
            context.saveGState(); context.setAlpha(scene.stage.speechPanel.alphaValue)
            if let speech = cache.speech { context.draw(speech, in: scene.stage.speechPanel.frame) }
            context.restoreGState()
        }
        if let pointer = scene.pointer { cursor(context, at: pointer) }
        return context.makeImage()!
    }

    private static func wallpaper(_ context: CGContext, _ screen: CGRect) {
        let colors = [CGColor(srgbRed: 0.84, green: 0.77, blue: 0.65, alpha: 1), CGColor(srgbRed: 0.79, green: 0.75, blue: 0.64, alpha: 1), CGColor(srgbRed: 0.58, green: 0.64, blue: 0.6, alpha: 1)]
        context.drawLinearGradient(CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 0.35, 1])!, start: CGPoint(x: screen.midX, y: screen.minY), end: CGPoint(x: screen.midX, y: screen.maxY), options: [])
        for (k, color) in [(0.42, CGColor(srgbRed: 0.56, green: 0.61, blue: 0.52, alpha: 0.55)), (0.3, CGColor(srgbRed: 0.49, green: 0.54, blue: 0.45, alpha: 0.6)), (0.17, CGColor(srgbRed: 0.42, green: 0.48, blue: 0.4, alpha: 0.55))] {
            let path = CGMutablePath(), base = screen.minY + screen.height * k
            path.move(to: CGPoint(x: screen.minX, y: screen.minY)); path.addLine(to: CGPoint(x: screen.minX, y: base))
            path.addCurve(to: CGPoint(x: screen.maxX, y: base + 10), control1: CGPoint(x: screen.minX + screen.width * 0.3, y: base + 70), control2: CGPoint(x: screen.minX + screen.width * 0.65, y: base - 50))
            path.addLine(to: CGPoint(x: screen.maxX, y: screen.minY)); path.closeSubpath()
            context.addPath(path); context.setFillColor(color); context.fillPath()
        }
    }
    private static func roundedShadowed(_ context: CGContext, _ rect: CGRect, radius: CGFloat, fill: CGColor, shadow: CGFloat = 0.3) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: CGColor(gray: 0, alpha: shadow))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); context.setFillColor(fill); context.fillPath()
        context.restoreGState()
    }
    private static func work(_ context: CGContext, _ rect: CGRect) {
        roundedShadowed(context, rect, radius: 14, fill: CGColor(srgbRed: 0.99, green: 0.988, blue: 0.97, alpha: 1), shadow: 0.2)
        context.setFillColor(CGColor(srgbRed: 0.945, green: 0.937, blue: 0.91, alpha: 1)); context.fill(CGRect(x: rect.minX, y: rect.maxY - 36, width: rect.width, height: 22))
        for (i, w) in [0.62, 0.9, 0.84, 0.88, 0.5].enumerated() {
            context.setFillColor(CGColor(gray: i == 0 ? 0.25 : 0.82, alpha: 1))
            context.fill(CGRect(x: rect.minX + 44, y: rect.maxY - 90 - CGFloat(i) * 30, width: (rect.width - 88) * w, height: i == 0 ? 14 : 8))
        }
    }
    /// A stand-in for System Settings, drawn where the app found its window (never a picture of the real one).
    private static func systemSettings(_ context: CGContext, _ rect: CGRect, pane: String, on: Bool) {
        roundedShadowed(context, rect, radius: 14, fill: CGColor(gray: 0.965, alpha: 1))
        context.setFillColor(CGColor(gray: 0.92, alpha: 1)); context.fill(CGRect(x: rect.minX, y: rect.minY, width: 210, height: rect.height).intersection(rect.insetBy(dx: 0, dy: 0)))
        for i in 0..<10 {
            context.setFillColor(i == 9 ? CGColor(srgbRed: 0.04, green: 0.48, blue: 1, alpha: 1) : CGColor(gray: 0.82, alpha: 1))
            context.fill(CGRect(x: rect.minX + 14, y: rect.maxY - 70 - CGFloat(i) * 28, width: i == 9 ? 182 : 120, height: i == 9 ? 24 : 9))
        }
        let row = CGRect(x: rect.minX + 232, y: rect.maxY - 150, width: rect.width - 252, height: 42)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(row)
        context.setFillColor(CGColor(gray: 0.3, alpha: 1)); context.fill(CGRect(x: rect.minX + 232, y: rect.maxY - 50, width: 140, height: 12))
        let toggle = CGRect(x: row.maxX - 50, y: row.midY - 11, width: 38, height: 22)
        context.addPath(CGPath(roundedRect: toggle, cornerWidth: 11, cornerHeight: 11, transform: nil))
        context.setFillColor(on ? CGColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1) : CGColor(gray: 0.86, alpha: 1)); context.fillPath()
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fillEllipse(in: CGRect(x: on ? toggle.maxX - 20 : toggle.minX + 2, y: toggle.minY + 2, width: 18, height: 18))
        if let icon = NSImage(named: NSImage.applicationIconName)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.draw(icon, in: CGRect(x: row.minX + 10, y: row.midY - 13, width: 26, height: 26))
        }
        _ = pane
    }
    private static func window(_ context: CGContext, _ picture: CGImage, frame: CGRect, alpha: CGFloat) {
        context.saveGState(); context.setAlpha(alpha)
        roundedShadowed(context, frame, radius: 18, fill: CGColor(srgbRed: 0.975, green: 0.963, blue: 0.934, alpha: 1), shadow: 0.3)
        context.addPath(CGPath(roundedRect: frame, cornerWidth: 18, cornerHeight: 18, transform: nil)); context.clip()
        context.draw(picture, in: frame)
        context.restoreGState()
    }
    /// The window going, drawn from the same WindowExit the screen plays.
    private static func leaving(_ context: CGContext, _ kind: WindowExit, at seconds: Double, frame: CGRect, picture: CGImage) {
        let state = kind.state(at: seconds)
        context.saveGState()
        context.setAlpha(state.shadow)
        roundedShadowed(context, frame, radius: 18, fill: CGColor(gray: 0, alpha: 0), shadow: 0.3 * state.shadow)
        context.restoreGState()
        context.saveGState(); context.setAlpha(state.opacity)
        switch kind {
        case .letGo(let center):
            // The paper with a soft hole growing from behind the companion: a mask drawn at a quarter size.
            let w = max(1, Int(frame.width / 4)), h = max(1, Int(frame.height / 4))
            let mask = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            mask.setFillColor(gray: 1, alpha: 1); mask.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let radius = state.hole * hypot(frame.width, frame.height) / 4, c = CGPoint(x: (center.x - frame.minX) / 4, y: (center.y - frame.minY) / 4)
            if radius > 0.5 {
                mask.drawRadialGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray, locations: [0, 0.62, 1])!,
                                        startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [.drawsAfterEndLocation])
            }
            if let image = mask.makeImage() { context.clip(to: frame, mask: image) }
            context.addPath(CGPath(roundedRect: frame, cornerWidth: 18, cornerHeight: 18, transform: nil)); context.clip()
            context.draw(picture, in: frame)
        case .powerOff:
            let rect = CGRect(x: frame.midX - frame.width * state.scaleX / 2, y: frame.midY - frame.height * state.scaleY / 2, width: frame.width * state.scaleX, height: frame.height * state.scaleY)
            context.setShadow(offset: .zero, blur: 18, color: CGColor(srgbRed: 0.35, green: 0.93, blue: 1, alpha: 0.9))
            context.draw(picture, in: rect)
            context.setFillColor(CGColor(srgbRed: 0.86, green: 0.98, blue: 1, alpha: state.flash)); context.fill(rect)
        case .fade:
            context.addPath(CGPath(roundedRect: frame, cornerWidth: 18, cornerHeight: 18, transform: nil)); context.clip()
            context.draw(picture, in: frame)
        }
        context.restoreGState()
    }
    private static func companion(_ context: CGContext, _ stage: MokuCharacterStage) {
        guard stage.panel.alphaValue > 0.01 else { return }
        // Drawn again only when the renderer has a new frame.
        let frame = stage.view.real?.lastImage.map { ObjectIdentifier($0) }
        if frame == nil || frame != cache.companionFor { cache.companion = try? MokuVisualDiagnostics.stageImage(stage: stage); cache.companionFor = frame }
        guard let image = cache.companion else { return }
        context.saveGState(); context.setAlpha(stage.panel.alphaValue)
        context.translateBy(x: stage.panel.frame.minX, y: stage.panel.frame.minY)
        context.concatenate(CATransform3DGetAffineTransform(stage.view.stage.transform))
        context.draw(image, in: CGRect(origin: .zero, size: StageGeometry.size))
        context.restoreGState()
    }
    private static func menuBar(_ context: CGContext, _ screen: CGRect, icon: CGRect, house: Bool) {
        context.setFillColor(CGColor(gray: 1, alpha: 0.42)); context.fill(CGRect(x: screen.minX, y: screen.maxY - 30, width: screen.width, height: 30))
        if house { self.house(context, at: icon, scale: 1) }
        for (i, w) in [30.0, 54, 26, 26, 30].enumerated() {
            context.setFillColor(CGColor(gray: 0.15, alpha: 0.6)); context.fill(CGRect(x: screen.minX + 20 + CGFloat(i) * 70, y: screen.maxY - 19, width: w, height: 8))
        }
    }
    /// The menu bar's house, `scale` times its size about its own centre.
    private static func house(_ context: CGContext, at icon: CGRect, scale: CGFloat) {
        guard let house = NSImage(systemSymbolName: "house.fill", accessibilityDescription: nil)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let rect = CGRect(x: icon.midX - 9 * scale, y: icon.midY - 8 * scale, width: 18 * scale, height: 16 * scale)
        context.saveGState(); context.setAlpha(0.85)
        context.clip(to: rect, mask: house)
        context.setFillColor(CGColor(gray: 0.1, alpha: 1)); context.fill(rect)
        context.restoreGState()
    }
    /// IconSpotlight, drawn: the dim with its soft clear hole round the icon, the halo and the house, pulsing in place.
    private static func spotlight(_ context: CGContext, _ screen: CGRect, icon: CGRect, state: IconSpotlight.State) {
        let centre = CGPoint(x: icon.midX, y: icon.midY)
        let dim = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: state.dim)] as CFArray,
                             locations: [0, IconSpotlight.inner / IconSpotlight.outer, 1])!
        context.saveGState(); context.clip(to: screen)
        context.drawRadialGradient(dim, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: IconSpotlight.outer, options: [.drawsAfterEndLocation])
        context.restoreGState()
        let halo = CGGradient(colorsSpace: nil, colors: [CGColor(srgbRed: 1, green: 0.97, blue: 0.86, alpha: 0.75 * state.halo), CGColor(srgbRed: 0.86, green: 0.93, blue: 0.8, alpha: 0.28 * state.halo), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 0.45, 1])!
        context.drawRadialGradient(halo, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 40, options: [])  // the halo brightens, it doesn't grow
        house(context, at: icon, scale: state.scale)
    }
    private static func cursor(_ context: CGContext, at point: CGPoint) {
        let path = CGMutablePath()
        let shape: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: -22), CGPoint(x: 6, y: -17), CGPoint(x: 10, y: -26), CGPoint(x: 13.5, y: -24.5), CGPoint(x: 9.5, y: -15.5), CGPoint(x: 17, y: -15.5)]
        path.addLines(between: shape.map { CGPoint(x: point.x + $0.x, y: point.y + $0.y) }); path.closeSubpath()
        context.addPath(path); context.setFillColor(CGColor(gray: 0.05, alpha: 1)); context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.setLineWidth(1.4)
        context.drawPath(using: .fillStroke)
    }
}

extension MokuVisualDiagnostics {
    /// The whole welcome for the companion on show (MOKU_COMPANION=moku|tetsu), offscreen, start to finish, scripted:
    /// it opens and says hello, a pointer moves and its eyes follow, the other's name is hovered (it leans in), Next,
    /// what it reads on the drawn window, Allow Accessibility (it goes and sits on System Settings, the switch goes on,
    /// it comes back), Allow Screen Recording (it goes, the person comes back without it: Quit & Reopen shows), and
    /// Start: its exit, home, and the spotlight on the icon. Writes welcome-<companion>.mp4 (frames drawn as they happen, at 30 a
    /// second) with a still every second, welcome-motion.csv (the companion's feet, size and opacity every frame, the
    /// window's exit), and welcome-checks.json (what happened, whether the companion ever moved while visible, and the
    /// renderer's frame gaps). Nothing is
    /// saved: the presenter is offscreen, and the companion stays in memory.
    public static func welcomeMovie(stage: MokuCharacterStage, directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let companion = Companion.current
        while stage.view.real == nil && stage.rendererError == nil { try await Task.sleep(for: .milliseconds(100)) }
        let screen = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = NSScreen.screens.first?.visibleFrame ?? screen
        let icon = CGRect(x: screen.maxX - 230, y: screen.maxY - 27, width: 26, height: 24)
        let presenter = MokuOnboardingPresenter(stage: stage, offscreen: true)
        presenter.menuBarIcon = { icon }
        var pointer = CGPoint(x: visible.midX - 160, y: visible.midY - 220)
        var settings: (frame: CGRect, pane: String, on: Bool)?, inFront = true
        presenter.pointer = { pointer }
        presenter.settingsWindow = { settings?.frame }
        presenter.welcomeInFront = { inFront }
        var permissions = PermissionStatus(accessibility: false, screenRecording: false)
        var requests = [String](), login = [Bool]()
        let context = OnboardingContext(suggestedName: "Charles", permissions: { permissions }, requestPermission: { kind in
            requests.append(kind.rawValue); inFront = false
            let frame = CGRect(x: visible.midX - 330, y: visible.midY - 260, width: 700, height: 470)
            settings = (frame, kind == .accessibility ? "Accessibility" : "Screen Recording", false)
        }, launchAtLogin: { login.last ?? false }, setLaunchAtLogin: { login.append($0) })

        final class Log { var frames: [Double] = []; var rows: [String] = ["t,feetX,feetY,scale,alpha,exit"] }
        let log = Log()
        let previous = stage.view.real?.onFrame
        stage.view.real?.onFrame = { previous?(); log.frames.append(CACurrentMediaTime()) }
        let run = Task { await presenter.run(context) }
        while presenter.panel == nil { try await Task.sleep(for: .milliseconds(20)) }
        let first = try WelcomeDesk.draw(.init(stage: stage, presenter: presenter, icon: icon, pointer: pointer), screen: screen)
        let movie = try ReviewMovie(url: directory.appendingPathComponent("welcome-\(companion.rawValue).mp4"), width: first.width, height: first.height, fps: 30)
        guard let window = presenter.panel?.frame else { throw CocoaError(.fileReadUnknown) }
        let layout = presenter.layout
        func inWindow(_ p: CGPoint) -> CGPoint { layout.screen(p, in: window) }
        let other = Companion.available.first { $0 != companion }
        // The pointer's path: points in the window (from its top-left) and when it gets there.
        let otherName = CGPoint(x: other == .tetsu ? 380 : 260, y: layout.size.height - WelcomeLayout.footer - 40)
        var path: [(Double, CGPoint)] = [(0, inWindow(CGPoint(x: 90, y: layout.size.height - 150))), (2.2, inWindow(CGPoint(x: 120, y: 120))),
                                         (3.6, inWindow(CGPoint(x: 540, y: 140))), (5.0, inWindow(CGPoint(x: 480, y: 380))), (6.4, inWindow(otherName)),
                                         (8.6, inWindow(otherName)), (9.6, inWindow(CGPoint(x: layout.size.width - 64, y: layout.size.height - 32)))]
        let allowAX = CGPoint(x: layout.size.width - 80, y: layout.readBand + 70), allowSR = CGPoint(x: layout.size.width - 80, y: layout.readBand + 140)
        path += [(14.5, inWindow(allowAX)), (16, inWindow(allowAX)), (17, CGPoint(x: visible.midX + 300, y: visible.midY + 60)), (24, inWindow(allowSR)),
                 (25.2, inWindow(allowSR)), (26.5, CGPoint(x: visible.midX + 300, y: visible.midY + 60)), (30.5, inWindow(CGPoint(x: layout.size.width - 64, y: layout.size.height - 32))), (32, inWindow(CGPoint(x: layout.size.width - 64, y: layout.size.height - 32)))]
        func pointerAt(_ t: Double) -> CGPoint {
            guard let after = path.firstIndex(where: { $0.0 >= t }) else { return path.last!.1 }
            guard after > 0 else { return path[0].1 }
            let (t0, a) = path[after - 1], (t1, b) = path[after]
            let k = CGFloat(WelcomeMotion.ease((t - t0) / max(0.01, t1 - t0)))
            return CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
        }
        let start = CACurrentMediaTime()
        var done: Set<String> = [], exitSeen = Set<String>()
        var moves: [(t: Double, feet: CGPoint, alpha: CGFloat)] = []
        func once(_ name: String, at time: Double, _ t: Double, _ action: () -> Void) { if t >= time && !done.contains(name) { done.insert(name); action() } }
        while CACurrentMediaTime() - start < 45 {
            let t = CACurrentMediaTime() - start
            pointer = pointerAt(t)
            if let other { once("hover", at: 6.6, t) { presenter.state.hover(other) }; once("unhover", at: 8.8, t) { presenter.state.hover(nil) } }
            once("next", at: 10, t) { presenter.state.next() }
            once("allow accessibility", at: 16, t) { presenter.state.request(.accessibility) }
            once("switched on", at: 20.5, t) { permissions.accessibility = true; settings?.on = true }
            once("back", at: 22.5, t) { settings = nil; inFront = true }
            once("start", at: 26, t) { presenter.state.start() }
            let scene = WelcomeDesk.Scene(stage: stage, presenter: presenter, icon: icon, pointer: presenter.state.starting ? nil : pointer, settings: settings)
            try await movie.append(WelcomeDesk.draw(scene, screen: screen), at: t)
            let feet = stage.feetOnScreen
            if let exit = presenter.exit { exitSeen.insert("\(exit.kind)") }
            log.rows.append(String(format: "%.4f,%.2f,%.2f,%.4f,%.3f,%@", t, feet.x, feet.y, stage.view.scale, stage.panel.alphaValue, presenter.exit.map { "\($0.kind)".components(separatedBy: "(").first! } ?? ""))
            moves.append((t, feet, stage.panel.alphaValue))
            if done.contains("start") && presenter.panel == nil { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        let result = await run.value
        try await movie.finish()
        stage.view.real?.onFrame = previous
        try log.rows.joined(separator: "\n").write(to: directory.appendingPathComponent("welcome-motion.csv"), atomically: true, encoding: .utf8)
        // The seated move: the companion changes place only while it's out of sight. A step of more than 8 points between
        // frames with it more than a tenth visible on both would be a jump. (Moku's scoot from the screen's edge for its
        // wave, 21 points over 0.45 s, is a slide well under that.)
        let jumps = zip(moves, moves.dropFirst()).filter { a, b in hypot(b.feet.x - a.feet.x, b.feet.y - a.feet.y) > 8 && min(a.alpha, b.alpha) > 0.1 }.count
        let gaps = zip(log.frames, log.frames.dropFirst()).map { ($1 - $0) * 1000 }.filter { $0 < 200 }
        let checks: [String: Any] = [
            "companion": companion.rawValue, "name": result.name, "completed": result.completed, "requests": requests, "login": login,
            "pointLine": presenter.pointLine ?? "", "pointedAtIcon": presenter.pointedAt == icon, "exits": Array(exitSeen),
            "visibleJumps": jumps,
            "rendererFrames": log.frames.count, "rendererGapMsMax": gaps.max() ?? 0, "rendererGapsOver50ms": gaps.filter { $0 > 50 }.count,
            "rendererGapMsMedian": gaps.sorted().dropFirst(gaps.count / 2).first ?? 0, "atHome": hypot(stage.feetOnScreen.x - stage.homeFeet(scale: stage.chosenScale).x, stage.feetOnScreen.y - stage.homeFeet(scale: stage.chosenScale).y) < 2,
            "scaleAtEnd": stage.view.scale, "rendererError": stage.rendererError ?? "none",
        ]
        try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("welcome-checks.json"))
        stage.setHidden(true)
        guard result.completed, presenter.pointedAt == icon, requests == ["accessibility"], login == [true], jumps == 0,
              stage.rendererError == nil else { throw NSError(domain: "Welcome movie", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(checks)"]) }
    }

    /// The welcome's look, offscreen, at its moments, for each companion (welcome-<companion>-<moment>.png), drawn on
    /// the desk with the companion's own render where it sits: hello, the other leaning in, what it reads, Accessibility
    /// on and Screen Recording waiting (Quit & Reopen), sitting on System Settings, the window going, and pointing at the
    /// icon. Then the same window on a short screen (1024 × 600) and with Increase Contrast. welcome-look.json has sizes.
    public static func welcomeLook(stage: MokuCharacterStage, directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let screen = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = NSScreen.screens.first?.visibleFrame ?? screen
        let icon = CGRect(x: screen.maxX - 230, y: screen.maxY - 27, width: 26, height: 24)
        var report: [String: Any] = [:]
        for companion in Companion.available {
            CompanionChoice.keepInMemory(starting: companion)
            stage.showCompanion(companion)
            let asked = CACurrentMediaTime()
            while stage.companion != companion && CACurrentMediaTime() - asked < 20 { try await Task.sleep(for: .milliseconds(100)) }
            let presenter = MokuOnboardingPresenter(stage: stage, offscreen: true)
            presenter.menuBarIcon = { icon }; presenter.pointSeconds = 2
            var permissions = PermissionStatus(accessibility: false, screenRecording: false)
            var settings: (frame: CGRect, pane: String, on: Bool)?, inFront = true
            presenter.settingsWindow = { settings?.frame }; presenter.welcomeInFront = { inFront }
            let context = OnboardingContext(suggestedName: "Charles", permissions: { permissions }, requestPermission: { kind in
                inFront = false; settings = (CGRect(x: visible.midX - 330, y: visible.midY - 260, width: 700, height: 470), kind == .accessibility ? "Accessibility" : "Screen Recording", false)
            }, launchAtLogin: { false }, setLaunchAtLogin: { _ in })
            let run = Task { await presenter.run(context) }
            while presenter.panel == nil { try await Task.sleep(for: .milliseconds(20)) }
            func shot(_ moment: String, wait: Double) async throws {
                try await Task.sleep(for: .seconds(wait))
                let image = try WelcomeDesk.draw(.init(stage: stage, presenter: presenter, icon: icon, pointer: nil, settings: settings), screen: screen)
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("welcome-\(companion.rawValue)-\(moment).png"))
            }
            try await shot("1-hello", wait: 3.2)
            if let other = Companion.available.first(where: { $0 != companion }) { presenter.state.hover(other); try await shot("2-leaning-in", wait: 0.8); presenter.state.hover(nil) }
            presenter.state.next(); try await shot("3-what-it-reads", wait: 5.5)
            presenter.state.request(.accessibility); try await shot("4-on-system-settings", wait: 2.2)
            permissions.accessibility = true; settings?.on = true; try await Task.sleep(for: .seconds(1.2)); settings = nil; inFront = true
            presenter.state.start(); try await shot("6-the-window-goes", wait: 0.25)
            try await shot("7-home-pointing", wait: 2.6)
            _ = await run.value
            report[companion.rawValue] = ["window": [presenter.layout.size.width, presenter.layout.size.height]]
        }
        // A short screen and Increase Contrast: the window alone, at what it reads (it scrolls under the drawn window).
        for companion in Companion.available {
            let model = OnboardingModel(); model.suggestedName = "Charles"; model.companion = companion; model.choosing = Companion.hasChoice; model.page = .read
            model.readStartedAt = .distantPast; model.readStep = 4; model.asked = [.screenRecording]; model.permissions = PermissionStatus(accessibility: true, screenRecording: false)
            for (name, height, appearance) in [("short", 600.0, nil as NSAppearance?), ("contrast", visible.height, NSAppearance(named: companion.isMachine ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua))] {
                let size = MokuOnboardingPresenter.size(for: model, visible: CGRect(x: 0, y: 0, width: 1024, height: height))
                let card = NSHostingView(rootView: OnboardingView(model: model, size: size)); card.frame.size = size
                if let appearance { card.appearance = appearance }
                try await Task.sleep(for: .milliseconds(200))
                try NSBitmapImageRep(cgImage: ReviewCapture.view(card)).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("welcome-\(companion.rawValue)-\(name).png"))
                report["\(companion.rawValue)-\(name)"] = [size.width, size.height]
            }
        }
        DotsCache.release()
        CompanionChoice.keepInMemory(starting: .moku)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("welcome-look.json"))
        stage.setHidden(true)
    }
}

extension MokuVisualDiagnostics {
    /// The welcome's last moment, offscreen, for each companion, by Start and by Skip, with Reduce Motion off and on,
    /// and once more with a click ending it early: one film (spotlight.mp4, a caption on each part), stills of each at
    /// its moments (spotlight-<companion>-<path>-<motion>-<moment>.png), and spotlight.json (each frame's dim, the
    /// house's size and where its centre is, and the fastest change of each between frames).
    public static func welcomeSpotlight(stage: MokuCharacterStage, directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        while stage.view.real == nil && stage.rendererError == nil { try await Task.sleep(for: .milliseconds(100)) }
        let screen = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let icon = CGRect(x: screen.maxX - 230, y: screen.maxY - 27, width: 26, height: 24)
        var movie: ReviewMovie?
        var filmTime = 0.0, report: [[String: Any]] = []
        func caption(_ image: CGImage, _ text: String) -> CGImage {
            let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.white]
            let size = (text as NSString).size(withAttributes: attributes)
            NSColor(calibratedWhite: 0, alpha: 0.55).setFill(); NSBezierPath(roundedRect: CGRect(x: 24, y: 24, width: size.width + 28, height: size.height + 14), xRadius: 10, yRadius: 10).fill()
            (text as NSString).draw(at: CGPoint(x: 38, y: 31), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
            return context.makeImage()!
        }
        var parts: [(Companion, String, Bool, Double?)] = []
        for companion in Companion.available { for reduced in [false, true] { for path in ["start", "skip"] { parts.append((companion, path, reduced, nil)) } } }
        parts.append((.moku, "start", false, 1.0))  // a click 1 s in ends it at once
        for (companion, path, reduced, clickAt) in parts {
            if stage.companion != companion {
                CompanionChoice.keepInMemory(starting: companion); stage.showCompanion(companion)
                let asked = CACurrentMediaTime()
                while stage.companion != companion && CACurrentMediaTime() - asked < 20 { try await Task.sleep(for: .milliseconds(100)) }
            }
            MotionPreference.override = reduced
            let presenter = MokuOnboardingPresenter(stage: stage, offscreen: true)
            presenter.menuBarIcon = { icon }; presenter.pointSeconds = 3.8
            let context = OnboardingContext(suggestedName: "Charles", permissions: { PermissionStatus(accessibility: true, screenRecording: true) }, requestPermission: { _ in },
                                            launchAtLogin: { true }, setLaunchAtLogin: { _ in })
            let run = Task { await presenter.run(context) }
            while presenter.panel == nil { try await Task.sleep(for: .milliseconds(20)) }
            try await Task.sleep(for: .seconds(1.2))
            if path == "start" { presenter.state.next(); try await Task.sleep(for: .seconds(0.8)); presenter.state.start() } else { presenter.state.skip() }
            let label = "\(companion.name) · \(path == "start" ? "Start" : "Skip for now") · \(reduced ? "Reduce Motion" : "motion")\(clickAt != nil ? " · a click ends it" : "")"
            let began = CACurrentMediaTime()
            var rows: [[Double]] = [], stills: Set<String> = [], clicked = false
            let moments: [(String, Double)] = [("0-dims", 0.08), ("1-peak", 0.51), ("2-between", 0.87), ("3-last-peak", 1.95), ("4-fading", 3.05)]
            while CACurrentMediaTime() - began < 9 {
                let image = try WelcomeDesk.draw(.init(stage: stage, presenter: presenter, icon: icon), screen: screen)
                if movie == nil { movie = try ReviewMovie(url: directory.appendingPathComponent("spotlight.mp4"), width: image.width, height: image.height, fps: 30) }
                let t = CACurrentMediaTime() - began
                try await movie!.append(caption(image, label), at: filmTime + t)
                if let spot = presenter.spotlight {
                    let s = CACurrentMediaTime() - spot.began, state = spot.model.state(at: s, dismissedAt: spot.dismissedAt)
                    rows.append([s, Double(state.dim), Double(state.scale), Double(spot.icon.midX), Double(spot.icon.midY)])
                    if let clickAt, !clicked, s >= clickAt { clicked = true; presenter.dismissSpotlight() }
                    for (name, at) in moments where clickAt == nil && s >= at && !stills.contains(name) {
                        stills.insert(name)
                        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("spotlight-\(companion.rawValue)-\(path)-\(reduced ? "reduced" : "motion")-\(name).png"))
                    }
                }
                if presenter.panel == nil && presenter.spotlight == nil && t > 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            _ = await run.value
            filmTime += CACurrentMediaTime() - began + 0.3
            let steps = zip(rows, rows.dropFirst()).map { ($1[1] - $0[1], $1[2] - $0[2], max(0.001, $1[0] - $0[0])) }
            report.append(["part": label, "frames": rows.count, "pointedAtIcon": presenter.pointedAt == icon, "line": presenter.pointLine ?? "",
                           "maxDimPerSecond": steps.map { abs($0.0) / $0.2 }.max() ?? 0, "maxScalePerSecond": steps.map { abs($0.1) / $0.2 }.max() ?? 0,
                           "largestScale": rows.map { $0[2] }.max() ?? 1, "houseCentreMoves": Set(rows.map { "\($0[3]),\($0[4])" }).count > 1])
        }
        MotionPreference.override = nil
        CompanionChoice.keepInMemory(starting: .moku)
        try await movie?.finish()
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("spotlight.json"))
        stage.setHidden(true)
    }
}
