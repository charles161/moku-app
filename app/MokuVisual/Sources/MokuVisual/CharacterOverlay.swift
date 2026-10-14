import AppKit
import MokuKit

@MainActor
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// Moku's head stays on screen (StageGeometry); the empty panel above it may run into the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        // On every desktop, but not over full-screen apps (no .fullScreenAuxiliary): macOS leaves Moku off a full-screen
        // app's space, and it's there again when you leave it (the 2026-09-28 audit; docs/specs/next-wave.md §6).
        level = .statusBar; collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false; isReleasedWhenClosed = false; acceptsMouseMovedEvents = true
        // Moku's frames are sRGB. On a Display P3 screen, Core Animation would convert every frame's pixels on the CPU
        // (about 40% of the drawing cost, 2026-10-02); an sRGB window leaves that to the window server's GPU.
        colorSpace = .sRGB
    }
}

@MainActor
final class CharacterView: NSView {
    let puppet = PlushPuppet()
    let lantern = LanternLayer()
    let manpu = ManpuLayer()
    /// Moku's comeback petals (MokuTalents.swift).
    let petals = PetalTwirl()
    /// Tetsu's seated move: a scan line erases it where it sits and prints it where it's going (StageBeam.swift).
    let beam = StageBeam()
    var real: RealityCharacter?
    var clicked: (() -> Void)?
    var patted: (() -> Void)?
    var dragging = false
    var recognizer = GrabRecognizer()
    var pressPoint = CGPoint.zero
    var grabBegan: ((CGPoint, CGPoint) -> Void)?
    var grabMoved: ((CGPoint) -> Void)?
    var grabEnded: (() -> Void)?
    var menuRequested: ((NSEvent) -> Void)?
    /// Everything Moku draws, laid out in stage points (as at size 1) and scaled as one to its size.
    let stage = CALayer()
    private(set) var scale: CGFloat = 1
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        stage.anchorPoint = .zero; stage.bounds = CGRect(origin: .zero, size: StageGeometry.size); stage.position = .zero
        layer?.addSublayer(stage)
        puppet.root.frame.origin = CGPoint(x: StageGeometry.characterFrame.midX - 80, y: 5)
        // Charles: only the original contact shadow belongs at Moku's feet.
        stage.addSublayer(puppet.root)
        stage.addSublayer(manpu.root)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }
    // VoiceOver: the companion that's on show (it said "Moku" for Tetsu), and "press" does what a click does.
    override func accessibilityLabel() -> String? { "\(Companion.current.name), your companion" }
    override func accessibilityHelp() -> String? { "Opens today’s house" }
    override func accessibilityPerformPress() -> Bool { guard let clicked else { return false }; clicked(); return true }
    func setScale(_ scale: CGFloat, squash: CGSize = CGSize(width: 1, height: 1)) {
        self.scale = scale
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // A squash (the welcome's seated landing) is about the feet, so they stay where they are.
        let feet = StageGeometry.feet
        var transform = CATransform3DMakeTranslation(-feet.x, -feet.y, 0)
        transform = CATransform3DConcat(transform, CATransform3DMakeScale(squash.width, squash.height, 1))
        transform = CATransform3DConcat(transform, CATransform3DMakeTranslation(feet.x, feet.y, 0))
        stage.transform = CATransform3DConcat(transform, CATransform3DMakeScale(scale, scale, 1))
        CATransaction.commit()
    }
    /// Moku's body in the view's coordinates.
    var characterRect: CGRect {
        let frame = real?.imageLayer.frame ?? puppet.root.frame
        return CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
    }
    /// A point in the view (screen points from the panel's corner) in stage points.
    func stagePoint(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x / scale, y: point.y / scale) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Whether Moku itself (not the transparent panel around it) is under `point`, in stage points.
    func contains(_ point: CGPoint) -> Bool { real?.contains(point) ?? puppet.contains(CGPoint(x: point.x - puppet.root.frame.minX, y: point.y - puppet.root.frame.minY)) }
    override func hitTest(_ point: NSPoint) -> NSView? { contains(stagePoint(point)) ? self : nil }
    override func mouseDown(with event: NSEvent) {
        dragging = true
        let p = stagePoint(convert(event.locationInWindow, from: nil))
        let characterFrame = real?.imageLayer.frame ?? puppet.root.frame
        let local = CGPoint(x: p.x - characterFrame.minX, y: p.y - characterFrame.minY)
        let headPoint = puppet.head.convert(local, from: puppet.root)
        pressPoint = NSEvent.mouseLocation
        recognizer.begin(at: pressPoint, onHead: real != nil ? (contains(p) && abs(p.y - (real?.projectedHead.y ?? 95)) < 35) : StageGeometry.contains(headPoint, ellipse: CGRect(x: 4, y: 0, width: 106, height: 78)), time: event.timestamp)
    }
    override func mouseDragged(with event: NSEvent) {
        let wasGrabbed = recognizer.grabbed, cursor = NSEvent.mouseLocation
        if recognizer.update(to: cursor, time: event.timestamp) {
            if !wasGrabbed { grabBegan?(cursor, pressPoint) }
            grabMoved?(cursor)
        }
    }
    override func rightMouseDown(with event: NSEvent) { menuRequested?(event) }
    override func mouseUp(with event: NSEvent) {
        dragging = false
        switch recognizer.end(time: event.timestamp) { case .click: clicked?(); case .pat: patted?(); case .grab: if !recognizer.grabbed { grabBegan?(NSEvent.mouseLocation, pressPoint) }; grabEnded?(); case .cancelled: break }
    }
}

@MainActor
public final class MokuCharacterStage: CharacterStage {
    public var onPat: (@MainActor () -> Void)?
    public var onClick: (@MainActor () -> Void)?
    public var onTakeBreak: (@MainActor () -> Void)?
    /// A "What's new" bubble is over: clicked, or closed (WhatsNewBubble.swift).
    public var onWhatsNew: (@MainActor (_ version: String, _ opened: Bool) -> Void)?
    /// The version whose "What's new" bubble is up, until it's answered.
    var whatsNewUp: String?
    /// Set only in Charles's calibration build: "Calibrate…" in the right-click menu.
    public var onCalibrate: (@MainActor () -> Void)?
    /// Usage: the companion hidden and shown by the person, and the stand-in drawn instead of it (`trouble`).
    public var track: UsageTracker?
    /// Usage: hovers, drags, throws, talents and frames dropped, into the day's counts.
    public var count: UsageCounter?
    /// Hidden because the app asked (a meeting), and because the person chose "Hide Moku" (kept across launches).
    /// Moku shows only when neither holds, so a call ending never brings back a Moku the person put away. (Kept in
    /// `homeStore`: an offscreen stage never hides the real one.)
    var hiddenByApp = true
    var hiddenByPerson = false
    /// The displays with something full screen on them (a film, a game, a slideshow), from the senses. Moku steps aside
    /// while one of them is its own display (StageFullScreen.swift). Not kept across launches: the senses tell it again.
    var fullScreenDisplays: Set<UInt32> = []
    /// The app in front is one Moku steps aside for (StageFullScreen.swift).
    var steppingAsideForApp = false
    /// A test's stand-in for the display Moku is on.
    var displayIDOverride: UInt32?
    var visibilityObserver: NSObjectProtocol?
    /// A break's countdown over Moku's head (BreakTimer.swift).
    let breakPanel = OverlayPanel(size: CGSize(width: 130, height: 46))
    let breakTimer = BreakTimerModel()
    let panel = OverlayPanel(size: StageGeometry.size)
    let view = CharacterView(frame: CGRect(origin: .zero, size: StageGeometry.size))
    let labelPanel = OverlayPanel(size: CGSize(width: 200, height: 38))
    var labelTask: Task<Void, Never>?
    let speechPanel = OverlayPanel(size: CGSize(width: 282, height: 100))
    var speechTask: Task<Void, Never>?
    /// Bumps with every bubble shown or taken down, so a fade-out that finishes late never hides a newer bubble.
    var speechGeneration = 0
    var fadeTask: Task<Void, Never>?
    let travel = TravelCoordinator()
    var moveGeneration = 0
    var moving = false
    var assetTask: Task<Void, Never>?
    var companionTask: Task<Void, Never>?
    var companionObserver: NSObjectProtocol?
    let rendersOffscreen: Bool
    var readiness = VisualReadiness.loading
    public private(set) var firstVisibleSource: String?
    private let createdAt = CACurrentMediaTime()
    /// Launch time: seconds from the stage being made, and from the process starting, to the first picture of Moku.
    public private(set) var firstVisibleSeconds: Double?
    public private(set) var firstVisibleProcessAge: Double?
    public var totalBlinks: Int { view.real?.blinkCount ?? 0 }
    public var totalRenderedFrames: Int { view.real?.renderedFrames ?? 0 }
    public var rendererDescription: String { view.real == nil ? "Procedural stand-in" : "RealityKit · real assets" }
    /// The companion on stage (nil while it loads, or with the stand-in).
    public var companion: Companion? { view.real?.companion }
    public var framesPerSecond: Double { hidden ? 0 : (view.real?.fps ?? 30) }
    public var rendererError: String? { view.real?.error }
    var timer: Timer?
    var nextBlink = 0.0
    var hidden = true
    var mood: Mood = .content
    var attention: AttentionTarget = .wander
    var nextWander = 0.0
    var nextSettle = 0.0
    var hover = false
    var hoverDwell = HoverDwell()
    var workDirection = WorkDirection()
    var glanceTask: Task<Void, Never>?
    var returnTask: Task<Void, Never>?
    var isGlancing = false
    var caughtDuringGlance = false
    var returning = false
    var nextSaccade = 0.0
    /// When the next ear flick and little move are due (LittleMoveSchedule), and the jitter of the last bigger moment.
    var littleMoves = LittleMoveSchedule(nextEar: 0, nextMove: 0)
    private var momentJitter = 1.0, inMoment = false
    /// How long the current stretch of unbroken focus has lasted: a drift, a return, a pat or a break ends it, and after
    /// 10 minutes the little moves come half as often (PowerPolicy.focusScale).
    var focusClock = FocusClock()
    public var workState: WorkState { workDirection.state }
    public var totalReadingSaccades: Int { view.real?.saccadeCount ?? 0 }
    public var totalDriftGlances: Int { workDirection.glanceCount }
    var simulatedHover = false
    /// Following the work to another display (StageScreenFollow.swift).
    var screenFollow = ScreenFollow()
    var lastWorkPoint: CGPoint?
    var followCheck: Task<Void, Never>?
    /// "This is work" / "This isn't work" from the right-click menu (the app tells the brain).
    public var onCorrectNow: (@MainActor (Bool) -> Void)?
    /// The task and its minutes today, for the label a hover shows (ThreadLabel.swift).
    public var currentTask: (@MainActor () -> TaskNow?)?
    var lastMicro: MicroExpression?
    public var totalCachedMicros: Int { view.real?.microCacheHits ?? 0 }
    public var totalMicroExpressions: Int { view.real?.microCount ?? 0 }
    public var totalHoverReactions: Int { view.real?.hoverCount ?? 0 }
    var reduced: Bool { MotionPreference.reduced }
    var localMonitor: Any?, globalMonitor: Any?
    var screenObserver: NSObjectProtocol?
    var resetHomeObserver: NSObjectProtocol?
    var captionObserver: NSObjectProtocol?
    var sizeObserver: NSObjectProtocol?
    /// The Mac's memory pressure (warning, critical): the character lets go of what it can make again.
    var pressureSource: DispatchSourceMemoryPressure?
    var speechObserver: NSObjectProtocol?
    var lastCaption: String?
    /// The caption is up (or fading out); a speech bubble then sits above it.
    var captionShowing = false
    var grabbing = false
    /// In the welcome's window (enterWelcome to leaveWelcome): the welcome places it, so it can't be carried off, and a
    /// display change leaves it to the welcome.
    var inWelcome = false
    var grabOffset = CGPoint.zero
    var grabSamples: [(CGPoint, Double)] = []
    /// While Moku is carried, thrown or landing: the physics, stepped once per display refresh.
    var carry: Carry?
    var carryTicker: DisplayTicker?
    /// The welcome's seated landing, a step per display frame (StageWelcome.swift).
    var settleLoop: FrameLoop?
    var dangle = Dangle()
    var handVelocity = CGPoint.zero, handAcceleration = CGPoint.zero, lastHand: CGPoint?
    let homeStore: UserDefaults
    var accessibilityObserver: NSObjectProtocol?
    var currentSpot = StageSpot.home
    public init(rendersOffscreen: Bool = false) {
        self.rendersOffscreen = rendersOffscreen
        homeStore = rendersOffscreen ? UserDefaults(suiteName: "MokuVisual.offscreen.\(ProcessInfo.processInfo.processIdentifier)")! : .standard
        view.lantern.preferences = homeStore
        hiddenByPerson = homeStore.bool(forKey: MokuPreferences.hiddenKey)
        view.puppet.body.isHidden = true
        panel.contentView = view; panel.ignoresMouseEvents = true
        let scale = MokuPreferences.size(in: homeStore)
        view.setScale(scale); panel.setContentSize(StageGeometry.panelSize(scale: scale))
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.inWelcome else { return }  // the welcome re-places its companion itself
                self.travel.cancel(); self.moveGeneration += 1; self.cancelGrab(); self.cancelDirectedBeat()
                self.moving = false; self.view.real?.walk(false)
                let preferred = self.homeStore.string(forKey: "MokuVisual.homeDisplay")
                let saved = preferred.flatMap { self.homeStore.data(forKey: "MokuVisual.home.\($0)") }.flatMap { try? JSONDecoder().decode(SavedHome.self, from: $0) }
                let displays = NSScreen.screens.map { DisplayRegion(id: self.displayKey($0), visible: $0.stageFrame) }
                if let origin = HomePlacement.resolve(savedDisplay: preferred, savedHome: saved, displays: displays, scale: self.view.scale) { self.panel.setFrameOrigin(origin); self.currentSpot = .home }
                self.positionSpeech(); self.positionLabel(); self.updateHit(refreshPointer: true)
                if self.attention != .user { self.watchScreenCenter() }
                self.refreshHidden()  // its display may have changed
            }
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }; self.view.real?.reduced = self.reduced; self.view.lantern.apply(self.workState, reduced: self.reduced); self.refreshWorkLayers()
                if !self.hidden { self.view.manpu.mood(self.mood, reduced: self.reduced) }
                if !self.hidden { self.view.puppet.stop(); if self.view.real == nil { self.view.puppet.idle(reduced: self.reduced) } }
            }
        }
        resetHomeObserver = NotificationCenter.default.addObserver(forName: .mokuResetHome, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.resetHome() } }
        captionObserver = NotificationCenter.default.addObserver(forName: .mokuCaptionMoved, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.previewCaption() } }
        speechObserver = NotificationCenter.default.addObserver(forName: .mokuSpeechMoved, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.previewSpeech() } }
        sizeObserver = NotificationCenter.default.addObserver(forName: .mokuResized, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.resize(to: MokuPreferences.size(in: self.homeStore)) }
        }
        view.grabBegan = { [weak self] cursor, press in self?.beginGrab(at: cursor, press: press) }
        view.grabMoved = { [weak self] cursor in self?.dragGrab(to: cursor) }
        view.grabEnded = { [weak self] in self?.releaseGrab() }
        view.clicked = { [weak self] in self?.onClick?() }
        VisualSessionState.shared.character = view
        view.menuRequested = { [weak self] event in self?.showMenu(for: event) }
        VisualSessionState.shared.mokuHidden = hiddenByPerson
        visibilityObserver = NotificationCenter.default.addObserver(forName: .mokuVisibility, object: nil, queue: .main) { [weak self] note in
            let hidden = (note.userInfo?["hidden"] as? Bool) ?? false
            Task { @MainActor in self?.setHiddenByPerson(hidden) }
        }
        view.patted = { [weak self] in self?.perform(.patReaction); self?.onPat?() }
        installBreakTimer()
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.view.real?.relieveMemory() } }
        pressure.resume(); pressureSource = pressure
        if ProcessInfo.processInfo.environment["MOKU_PROCEDURAL"] != "1" {
            assetTask = Task { [weak self] in
                do {
                    guard let self else { return }
                    guard let real = try await RealityCharacter.load() else { useFallback(reason: "No character asset is available"); return }
                    place(real, below: view.manpu.root)
                    real.reduced = reduced; real.setMood(mood); setAttention(attention)
                    if !hidden { view.puppet.stop(); real.start(); refreshWorkLayers() }
                } catch { ErrorReports.report(.assetLoad, error); self?.useFallback(reason: error.localizedDescription) }
            }
            companionObserver = NotificationCenter.default.addObserver(forName: .mokuCompanionChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showCompanion(.current) }
            }
        } else { useFallback(reason: "Procedural mode explicitly requested") }
    }
    /// Puts a loaded character on the stage, under `layer`.
    private func place(_ real: RealityCharacter, below layer: CALayer) {
        real.onTalent = { [weak self] talent in self?.count?(.talent(talent)) }
        real.onFramesDropped = { [weak self] frames in self?.count?(.framesDropped(frames)) }
        view.real = real; real.imageLayer.name = "character"; view.setAccessibilityLabel("\(real.companion.name), your companion"); view.manpu.ownMarks = real.companion.ownMarks; real.hostView = view; real.imageLayer.frame = StageGeometry.characterFrame; real.alignGround(at: StageGeometry.feet.y); real.setResolution(for: view.scale)
        view.stage.insertSublayer(real.imageLayer, below: layer)
        real.onFrame = { [weak self] in
            guard let self else { return }
            if readiness == .loading { readiness = .realFrameReady; presentIfReady() }
            if let anchor = view.real?.projectedHead { view.manpu.anchor(at: anchor) }
        }
    }
    /// The other companion, loaded ahead while the welcome offers the choice: a switch is then a cross-fade at once,
    /// instead of 1.2 to 1.6 s of the old one while the new one loads, with the main thread held for most of it
    /// (Charles, 2026-10-06: "switching between moku and tetsu during onboarding is too lagging"). Not started, so it
    /// draws nothing until it's picked.
    private var preloaded: RealityCharacter?
    private var preloadTask: Task<Void, Never>?
    public func preloadCompanion(_ companion: Companion) {
        guard preloaded?.companion != companion, view.real?.companion != companion else { return }
        preloadTask?.cancel()
        preloadTask = Task { [weak self] in
            guard let loaded = try? await RealityCharacter.load(companion: companion), !Task.isCancelled else { return }
            self?.preloaded = loaded
        }
    }
    /// The welcome: both companions stay loaded while it offers the choice (about 200 MB more, for its few minutes).
    public var keepsBothCompanions = false
    /// Lets a preloaded companion go: the welcome is over and it wasn't picked (its meshes and textures are freed).
    public func dropPreloaded() {
        keepsBothCompanions = false
        preloadTask?.cancel(); preloadTask = nil; preloaded = nil
    }
    public var hasPreloaded: Companion? { preloaded?.companion }
    /// The companion on show changed (Settings, the welcome): its character loads while the old one carries on, then
    /// takes over in the same mood, gaze and work state (sad, standing, red, dozing), and the old one fades away.
    /// History, the name and today's progress are the brain's and the world's, so nothing else changes. A move, a
    /// carry or a drag finishes first.
    public func showCompanion(_ companion: Companion) {
        companionTask?.cancel()
        companionTask = Task { [weak self] in
            guard let self else { return }
            while moving || grabbing || carry != nil || view.real == nil && readiness == .loading {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
            guard let old = view.real, old.companion != companion else { return }
            let next: RealityCharacter
            await preloadTask?.value  // a preload under way finishes first: one load, not two
            if let ready = preloaded, ready.companion == companion {
                next = ready; preloaded = nil
                next.imageLayer.removeAllAnimations(); next.imageLayer.opacity = 1  // shown before and faded out: whole again
            } else {
                do {
                    guard let loaded = try await RealityCharacter.load(companion: companion) else { NSLog("Moku: %@ has no character", companion.rawValue); return }
                    next = loaded
                } catch { NSLog("Moku: %@ didn't load: %@", companion.rawValue, error.localizedDescription); ErrorReports.report(.assetLoad, error); return }
            }
            guard !Task.isCancelled, view.real === old else { return }
            let standing = old.isStanding
            place(next, below: old.imageLayer)  // under the old one, which fades out once the new one has drawn
            next.reduced = reduced; next.setMood(mood, duration: 0.01)
            next.setDrifting(workState.isDrift); next.setFlushed(workState == .drifting || workState == .longDrift); next.setAsking(workState == .longDrift)
            next.setLanternBrightness(view.lantern.phase.brightness)
            if standing { next.perform(.standUp) }
            setAttention(attention)
            let fade = reduced ? 0.15 : 0.3  // (Reduce Motion cross-fades too, quicker: a swap at once is a pop)
            // The new companion's frame callback keeps this closure for as long as it lives, so it must not keep the old
            // companion: held strongly, the old one (its renderer, meshes and textures, about 450 MB) stayed in memory
            // after every switch. Only its layer is needed to fade it out.
            let fadingLayer = old.imageLayer
            if keepsBothCompanions { preloaded = old }  // the welcome: the one let go stays loaded, so switching back is at once
            let reveal = { [weak self, weak old] in
                old?.stop(); old?.onFrame = nil
                CATransaction.begin(); CATransaction.setAnimationDuration(fade)
                // Gone once faded, unless it was picked again meanwhile (a quick switch back in the welcome).
                CATransaction.setCompletionBlock { [weak self] in if self?.view.real?.imageLayer !== fadingLayer { fadingLayer.removeFromSuperlayer() } }
                fadingLayer.opacity = 0
                CATransaction.commit()
                self?.updateHit(refreshPointer: true)
            }
            if hidden { reveal(); return }
            var shown = false
            next.onFrame = { [weak self] in
                guard let self else { return }
                if !shown { shown = true; reveal() }
                if let anchor = view.real?.projectedHead { view.manpu.anchor(at: anchor) }
            }
            next.start(); refreshWorkLayers(); installBreakTimer()  // the break timer is the new companion's own
        }
    }
    func useFallback(reason: String) {
        NSLog("Moku procedural fallback: %@", reason)
        if ProcessInfo.processInfo.environment["MOKU_PROCEDURAL"] != "1" { track?("trouble", ["kind": .word("stand_in"), "count": .int(1), "seconds": .int(0)]) }
        readiness = .fallbackReady; view.puppet.body.isHidden = false
        if !hidden { view.puppet.idle(reduced: reduced); presentIfReady() }
    }
    func presentIfReady() {
        guard !hidden, readiness != .loading else { return }
        if firstVisibleSource == nil {
            firstVisibleSource = readiness == .realFrameReady ? "real" : "fallback"
            firstVisibleSeconds = CACurrentMediaTime() - createdAt; firstVisibleProcessAge = processAgeSeconds()
            NSLog("Moku first visible (%@) %.1f s after the stage was made, %.1f s after the process started", firstVisibleSource!, firstVisibleSeconds!, firstVisibleProcessAge!)
            if !rendersOffscreen { track?("launch_speed", ["ms": .int(Int((firstVisibleProcessAge! * 1000).rounded())), "stand_in": .bool(readiness != .realFrameReady)]) }
        }
        guard !rendersOffscreen else { return }
        panel.alphaValue = 0; panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.25; panel.animator().alphaValue = 1 }
    }
    isolated deinit {
        pressureSource?.cancel()
        glanceTask?.cancel(); returnTask?.cancel(); timer?.invalidate(); assetTask?.cancel(); companionTask?.cancel(); fadeTask?.cancel(); speechTask?.cancel(); labelTask?.cancel()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let resetHomeObserver { NotificationCenter.default.removeObserver(resetHomeObserver) }
        if let companionObserver { NotificationCenter.default.removeObserver(companionObserver) }
        if let captionObserver { NotificationCenter.default.removeObserver(captionObserver) }
        if let sizeObserver { NotificationCenter.default.removeObserver(sizeObserver) }
        if let speechObserver { NotificationCenter.default.removeObserver(speechObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
        view.real?.stop(); panel.orderOut(nil); speechPanel.orderOut(nil); labelPanel.orderOut(nil)
    }
    public func show() {
        if let screen = homeScreen() { panel.setFrameOrigin(homeOrigin(on: screen)) }
        setHidden(false)
    }
    public func setHidden(_ hidden: Bool) {
        hiddenByApp = hidden
        refreshHidden()
    }
    /// "Hide Moku" / "Show Moku" (the right-click menu and the popover), or the welcome bringing it out (`by`).
    /// Watching goes on while Moku is hidden.
    func setHiddenByPerson(_ hidden: Bool, by: String = "person") {
        if hidden != hiddenByPerson { trackHiddenByPerson(hidden, by: by) }
        hiddenByPerson = hidden
        homeStore.set(hidden, forKey: MokuPreferences.hiddenKey)
        VisualSessionState.shared.mokuHidden = hidden
        refreshHidden()
    }
    /// `hidden` and `shown` (after how long), by the person. When it was hidden is kept with the rest of its place, so a
    /// Moku put away before a quit counts its hours when it's shown again.
    private func trackHiddenByPerson(_ hidden: Bool, by: String) {
        let key = "MokuVisual.hiddenByPersonAt"
        if hidden {
            homeStore.set(Date().timeIntervalSince1970, forKey: key)
            track?("hidden", ["by": .word("person")])
        } else {
            let since = homeStore.object(forKey: key) as? Double
            homeStore.removeObject(forKey: key)
            var props: [String: UsageValue] = ["by": .word(by)]
            if let since { props["after_seconds"] = .int(max(0, Int(Date().timeIntervalSince1970 - since))) }
            track?("shown", props)
        }
    }
    /// Right-click on the companion: Your day, take (or end) a break, hide it, Settings, or quit. Like the menu bar icon's
    /// right-click menu, so Settings (breaks and water among them) is where Mac people look for it.
    func showMenu(for event: NSEvent) {
        guard let menu = contextMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
    /// The right-click menu; none in the welcome, which holds its companion (Hide took it out of the welcome's window, and
    /// Your day or Settings opened over it).
    func contextMenu() -> NSMenu? {
        guard !inWelcome else { return nil }
        let onBreak = VisualSessionState.shared.workState == .onBreak
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Your day") { NotificationCenter.default.post(name: Notification.Name("MokuVisual.openToday"), object: nil, userInfo: ["from": "menu"]) })
        // A correction that fits the moment (Charles, 2026-10-14): in a drift "This is work", while working "This isn't work".
        if let onCorrectNow {
            if workState.isDrift { menu.addItem(ClosureMenuItem("This is work") { onCorrectNow(true) }) }
            else if workState == .focused { menu.addItem(ClosureMenuItem("This isn’t work") { onCorrectNow(false) }) }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(onBreak ? "End the break" : "Take a break") { [weak self] in self?.onTakeBreak?() })
        menu.addItem(ClosureMenuItem("Hide \(Companion.current.name)") { [weak self] in self?.setHiddenByPerson(true) })
        menu.addItem(ClosureMenuItem("Settings…") { NotificationCenter.default.post(name: Notification.Name("MokuVisual.openSettings"), object: nil) })
        if let onCalibrate { menu.addItem(ClosureMenuItem("Calibrate…") { onCalibrate() }) }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit Moku") { QuitRequest.send() })
        return menu
    }
    func applyHidden(_ hidden: Bool) {
        guard hidden != self.hidden else { return }
        self.hidden = hidden; fadeTask?.cancel(); view.lantern.setHidden(hidden)
        if hidden {
            cancelGrab(); cancelDirectedBeat(); view.manpu.clear(); hoverDwell = HoverDwell(); hover = false; simulatedHover = false; travel.cancel(); moveGeneration += 1; moving = false; dismissSpeech(); fadeCaption(); fadeBreakTimerOut(); view.real?.stop()
            timer?.invalidate(); timer = nil; view.puppet.stop()
            panel.ignoresMouseEvents = true
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.18; panel.animator().alphaValue = 0 }
            fadeTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                self?.panel.orderOut(nil)
            }
            if let localMonitor { NSEvent.removeMonitor(localMonitor) }; if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
            localMonitor = nil; globalMonitor = nil
        } else {
            presentIfReady()
            if let real = view.real { real.start() } else { view.puppet.idle(reduced: reduced) }
            refreshWorkLayers(); view.manpu.mood(mood, reduced: reduced)
            updateHit(refreshPointer: true)
            nextBlink = CACurrentMediaTime() + Double.random(in: 2...5)
            littleMoves = LittleMoveSchedule(nextEar: CACurrentMediaTime() + MokuPreferences.earFlickEvery * Double.random(in: 0.67...1.33),
                                             nextMove: CACurrentMediaTime() + MokuPreferences.fidgetEvery * Double.random(in: 0.67...1.33))
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            timer?.tolerance = 0.05  // nothing in a tick is exact to the millisecond: let the system fire it with the other timers' wakeups
            if localMonitor == nil && !rendersOffscreen {
                localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp]) { [weak self] event in
                    MainActor.assumeIsolated { self?.updateHit(refreshPointer: true) }; return event
                }
                globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in MainActor.assumeIsolated { self?.updateHit(refreshPointer: true) } }
            }
        }
    }
    private var cachedPointer = CGPoint.zero
    func tick() {
        updateHit(); let now = CACurrentMediaTime()
        tickBreakTimer()
        view.lantern.tick(now: now)
        let occupied = hidden || grabbing || moving || speechTask != nil || hoverDwell.active || isGlancing || returning
        let busy = occupied || !(view.real?.acceptsExpression ?? false)
        if let expression = workDirection.claim(now: now, busy: busy, reduced: reduced, choice: Int.random(in: 0...99), jitter: Double.random(in: 0.8...1.2)) { glance(expression) }
        // Fewer of the little moves while dozing, in Low Power Mode, when the Mac runs hot and after ten minutes of unbroken
        // focus (PowerPolicy); long focus slows blinks and darts only a little.
        let power = PowerPolicy.current, focus = focusClock.scale(now: now), calm = power * PowerPolicy.sleepScale(for: mood) * focus.moves
        view.real?.lifeScale = power * focus.moves
        if now >= nextBlink, !isGlancing, !returning { view.real?.blink(); view.puppet.blink(); nextBlink = now + (view.real?.nextBlinkWait(focused: workState == .focused, stretch: focus.eyes) ?? Double.random(in: 3...6)) }
        // A bigger moment (the minute's look-up and smile, a gesture, a line, a hover, a comeback) holds the little moves
        // off: the ear comes about 20 s after it ends and the paw or foot about 40 s after (LittleMoveSchedule).
        let moment = speechTask != nil || returning || !(view.real?.acceptsExpression ?? true)
        if moment && !inMoment { momentJitter = Double.random(in: 0.9...1.1) }
        inMoment = moment
        if moment { littleMoves.moment(at: now, jitter: momentJitter) }
        let flickEvery = MokuPreferences.earFlickEvery * calm
        if flickEvery > 0, now >= littleMoves.nextEar {
            // Due while busy (a glance at the work): try again shortly, so it still comes about as often as set.
            if !busy && !hidden && (view.real?.flickEar() ?? false) { littleMoves.earDone(at: now, every: flickEvery, jitter: Double.random(in: 0.67...1.33)) }
            else { littleMoves.nextEar = now + 2 }
        }
        let fidgetEvery = MokuPreferences.fidgetEvery * calm
        if fidgetEvery > 0, now >= littleMoves.nextMove {
            if !busy && !hidden && (view.real?.fidget() ?? false) { littleMoves.moveDone(at: now, every: fidgetEvery, jitter: Double.random(in: 0.67...1.33)) }
            else { littleMoves.nextMove = now + 2 }
        }
        if now >= nextSaccade, !occupied, workState == .focused { nextSaccade = now + (view.real?.saccade() ?? 2) * power * focus.eyes }
        view.real?.live(occupied: occupied)
    }

    func updateHit(refreshPointer: Bool = false) {
        // Mouse monitors refresh position. Idle ticks only advance dwell timing;
        // avoid querying WindowServer and resending the same window flag at 10 Hz.
        if refreshPointer && !rendersOffscreen { cachedPointer = NSEvent.mouseLocation }
        let p = cachedPointer, frame = panel.frame
        let local = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
        let inside = rendersOffscreen ? simulatedHover : (frame.contains(p) && view.contains(view.stagePoint(local)))
        if !view.dragging && panel.ignoresMouseEvents != !inside { panel.ignoresMouseEvents = !inside }
        hover = inside
        if inside && isGlancing && !caughtDuringGlance && !reduced {
            caughtDuringGlance = true; glanceTask?.cancel(); view.real?.suppressExpressions(); glance(.smile)
        }
        // No hover beam in a drift: a sad or angry Moku doesn't light up because the pointer passed over it.
        let allowed = !hidden && !grabbing && !moving && !isGlancing && !returning && speechTask == nil && !workState.isDrift && (view.real?.acceptsHover ?? true)
        if let reaction = hoverDwell.update(inside: inside, allowed: allowed, now: CACurrentMediaTime()) {
            if reaction { count?(.hover) }
            view.real?.setHover(reaction)
            if reaction { showHoverTask() } else { fadeCaption() }
        }
    }
    public func setMood(_ mood: Mood) {
        guard self.mood != mood else { return }
        // A look-up while you focus: turn to the user first, then the eyes close happily (0.8 s), and open
        // again over 1.2 s as it turns back. Coming back is quicker; sad and cross drift in slowly.
        let lookingUp = mood == .happy && attention == .user && !workState.isDrift && !returning
        let duration = mood == .happy && (workState.isDrift || returning) ? 0.6
            : lookingUp ? 0.8
            : self.mood == .happy && mood == .content ? 1.2
            : (mood == .annoyed || mood == .disappointed ? 3.0 : 2.4)
        self.mood = mood
        if !hidden { view.manpu.mood(mood, reduced: reduced) }
        view.puppet.expression(.mood(mood), reduced: reduced)
        view.real?.setMood(mood, duration: duration, delay: lookingUp ? 0.45 : 0)
    }
    public func setAttention(_ target: AttentionTarget) {
        if case .point(let point) = target { followWork(to: point) }
        if case .point(let point) = target, !workDirection.receive(point: point) { return }
        attention = target
        switch target {
        case .user: cancelGlance(); lookAtUser()
        case .point, .wander: restingGaze()
        }
    }
    /// Moku looks at a point on screen (the menu bar icon, as the welcome ends), the way it watches the centre.
    func look(at point: CGPoint) {
        let eyes = StageGeometry.eyes(panel: panel.frame)
        let screen = (NSScreen.screens.first { $0.frame.contains(eyes) } ?? NSScreen.screens.first)?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        view.real?.look(StageGeometry.gaze(eyes: eyes, at: point, screen: screen))
        let gaze = StageGeometry.gaze(at: point, from: eyes, in: screen)
        view.puppet.look(x: gaze.x, y: gaze.y, reduced: reduced)
    }
    /// Moku watches the centre of the display it sits on, from wherever it is placed.
    func watchScreenCenter() {
        let eyes = StageGeometry.eyes(panel: panel.frame)
        let screen = (NSScreen.screens.first { $0.frame.contains(eyes) } ?? NSScreen.screens.first)?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        view.real?.look(StageGeometry.centerGaze(eyes: eyes, screen: screen))
        let gaze = StageGeometry.gaze(at: CGPoint(x: screen.midX, y: screen.midY), from: eyes, in: screen)
        view.puppet.look(x: gaze.x, y: gaze.y, reduced: reduced)
    }
    public func perform(_ gesture: Gesture) { guard !hidden else { return }
        // A sniff is a little thing laid over whatever Moku is doing: it never interrupts a beat, and skips a busy one.
        if gesture == .sniff {
            guard !returning, !isGlancing, !grabbing, !moving, speechTask == nil else { return }
            count?(.talent(.sniff))
            if let real = view.real { real.perform(.sniff) } else { view.puppet.gesture(.sniff, reduced: reduced) }
            return
        }
        // Compatibility with older mind builds: a drift glance uses the eyes,
        // never the full look_around clip that replaces the mood with neutral.
        if gesture == .glance && mood == .annoyed && workState.isDrift { return }
        if gesture == .wave { makeRoomToWave() }
        if gesture == .patReaction { focusClock.interrupted(now: CACurrentMediaTime()) }
        cancelDirectedBeat(); workDirection.pause(now: CACurrentMediaTime()); if gesture == .patReaction { view.manpu.pat(reduced: reduced) }; if let real = view.real { real.perform(gesture) }  // the real companions celebrate their own way (Moku's petals, Tetsu's hologram): no stand-in confetti over them
        else { view.puppet.gesture(gesture, reduced: reduced) } }
    
    public func capture(to url: URL) throws {
        if let image = view.real?.lastImage {
            try view.real?.diagnostics.write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url); return
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 640, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.scaleBy(x: 4, y: 4); view.puppet.root.render(in: context)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}

public enum MokuVisualFactory {
    /// At launch: Calm or Lively, saved by an older Settings, is cleared, so everyone gets the one behaviour. (The brain clears
    /// its own drift timings when it starts; see ClearRetiredConfig.) Nothing else in the app's settings is touched.
    @MainActor public static func retireBehaviourChoices() { MokuPreferences.retireBehaviourChoices(in: .standard) }
    /// Whether the person has the companion put away ("Hide Moku"), as this launch begins: `app_opened.hidden`.
    @MainActor public static var companionHiddenByPerson: Bool { UserDefaults.standard.bool(forKey: MokuPreferences.hiddenKey) }
    @MainActor public static func makeStage() -> any CharacterStage { MokuCharacterStage() }
    @MainActor public static func makeWorld(model: WorldModel) -> any WorldPresenter { MokuWorldPresenter(model: model) }
    /// A welcome that was under way when Moku quit (macOS's Quit & Reopen for Screen Recording): it picks up where it was.
    public static var welcomeInProgress: Bool { OnboardingProgress.resumable() != nil }
}

/// A menu item that runs a closure.
@MainActor final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { handler() }
}
