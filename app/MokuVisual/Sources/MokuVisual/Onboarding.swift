import AppKit
import SwiftUI
import Observation
import MokuKit

/// The welcome (docs/specs/welcome-wow.md; Charles picked "A + C" on 2026-10-04). The companion is the welcome: it's in
/// the window, life-size and live, its eyes on your pointer from the first frame, and it says hello by name. Two
/// pages: hello (with who you'd like to work with, as two names: hover one and it leans in), and what it reads, where
/// it's kept and how it's processed, each permission's Allow under the line that says why, while it shows you on a
/// drawn window what each one lets it read. Start ends it the companion's way: Moku's window lets go around it, and
/// Moku fades into its corner and settles there; Tetsu's switches off like an old screen and Tetsu appears in its
/// corner. (A seated glide home was tried and read as floating.) Then it looks up at the menu bar icon, "Your house
/// lives up here.", while that display dims round a spotlight on the icon and the house pulses in place. Skip and the
/// close button end it too, and say the same.
/// Nothing is asked that it can work out: the name is the Mac account's first name (Settings can change it). Starting
/// with the Mac is on unless switched off here, and it's registered only on Start: the switch is the consent.
@MainActor @Observable final class OnboardingModel {
    enum Page: String { case hello, read }
    var page = Page.hello
    var name = ""
    var suggestedName = ""
    /// Who says hello: the chosen companion. With more than one in this build the window offers the other (`choosing`).
    var companion = Companion.current
    var choosing = false
    /// The other companion, leaning in while its name is hovered.
    var peeking: Companion?
    var permissions = PermissionStatus(accessibility: false, screenRecording: false)
    /// The permissions whose Allow was pressed, here or before a relaunch.
    var asked: Set<PermissionKind> = []
    /// Starting with the Mac: on unless switched off here, applied on Start.
    var startWithMac = true
    /// Picked up again after a relaunch (macOS's Quit & Reopen for Screen Recording): it opens at what it reads.
    var resumed = false
    /// Start, Skip or the close button was pressed: the welcome is ending.
    var starting = false
    /// Reduce Motion: fades only, nothing typing on or sweeping, the companion still.
    var reduced = MotionPreference.reduced
    /// When the companion's hello began (the words rising in, Tetsu's dots typing on).
    var greetedAt: Date?
    /// The read page: when it opened (Tetsu's self-test types on from then), and which of the four things on the drawn
    /// window the companion is showing (1…4; 0 before it starts).
    var readStartedAt: Date?
    var readStep = 0
    /// Tetsu's last sweep of its scan beam across the drawn window.
    var scanAt: Date?
    var choose: (Companion) -> Void = { _ in }
    var hover: (Companion?) -> Void = { _ in }
    var next: () -> Void = {}
    var start: () -> Void = {}
    var skip: () -> Void = {}
    var request: (PermissionKind) -> Void = { _ in }
    var relaunch: () -> Void = {}
    /// The name the companion will use: the one given, else the Mac's, else "friend", always one line and short enough for
    /// the brain (PersonName: it refuses a name past 60 UTF-16 units, and the welcome used to allow 80 characters).
    var resultName: String { PersonName.clean(name) ?? PersonName.clean(suggestedName) ?? PersonName.fallback }
    var greeting: String {
        // A name ending in a full stop ("Dr.") doesn't get a second one.
        resultName == PersonName.fallback ? "Hi! I’m \(companion.name)." : "Hi, \(resultName)\(resultName.hasSuffix(".") ? " " : ". ")I’m \(companion.name)."
    }
    /// The hello's first words, large: "Hi, Charles." (Moku) or HELLO, CHARLES in Tetsu's dots.
    var hello: String {
        let named = resultName == PersonName.fallback ? nil : resultName
        if machine { return named.map { "HELLO, \($0.uppercased())" } ?? "HELLO" }
        return named.map { "Hi, \($0)\($0.hasSuffix(".") ? "" : ".")" } ?? "Hi!"
    }
    /// What it does, under the hello.
    var introduction: String { "I’m \(companion.name). " + Self.whatItDoes }
    static let whatItDoes = "I’ll sit in the corner of your screen while you work, notice when you drift, and be glad when you’re back."
    /// Tetsu's window is a dark screen and it speaks in dots; Moku's is paper.
    var machine: Bool { companion.isMachine }
    /// Screen Recording was asked for and isn't on yet. macOS turns it on for Moku only after Moku reopens, so the window
    /// offers its own Quit & Reopen.
    var waitingForReopen: Bool { asked.contains(.screenRecording) && !permissions.screenRecording }
}

/// What Moku reads, where it's kept and how it's processed, word for word as the welcome has said it since the one-window
/// welcome (and as hellomoku.com/privacy says it). Both companions' pages show exactly these.
enum PlainAccount {
    static let accessibility = (title: "Accessibility", why: "Which app, window and web page you’re on, and your typing pace.",
                                without: "Without it, I can’t see web addresses or your typing, so I’m less sure what’s work.")
    static let screenRecording = (title: "Screen Recording", why: "A few words from that window, read on this Mac.",
                                  without: "Without it, I go by the app, the window’s name and the address.")
    /// The welcome doesn't ask for Screen Recording (the friends, 2026-10-14: they "dont like to give screen recording
    /// permissions"): it says what it would add, and where to turn it on.
    static let screenRecordingOptional = "Optional, and off. Turn it on in Settings, and I read a few words from that window, on this Mac."
    static let never = "Never the keys you press, never sound, never password managers."
    static let kept = (title: "Where it’s kept", text: "On this Mac: your days, your houses, your name. Pictures of your screen are read here, then let go: never saved, never sent.")
    static let processed = (title: "How it’s processed", text: "To tell work from a detour, a short excerpt, with the app, the window’s name and the address, goes to an AI that’s asked to keep nothing. We don’t keep it either.")
    static let more = "Everything, in detail: hellomoku.com/privacy"
    static let reopen = "Switched it on? macOS needs me to quit and reopen. I’ll pick up right here."
    static func permission(_ kind: PermissionKind) -> (title: String, why: String, without: String) { kind == .accessibility ? accessibility : screenRecording }
    /// The four things on the drawn window, in the order the companion shows them.
    static let marks = ["the app", "the window’s name", "the address", "a few words, if you allow it"]
}

/// Where things sit in the welcome window, for a window `size` big. Shared by the view (which draws the floor, the drawn
/// window and the leaning-in companion) and the presenter (which puts the live companion there and points its eyes).
/// Points from the window's top-left, as SwiftUI lays them out; `feet` converts to the window's bottom-left.
struct WelcomeLayout: Equatable {
    var size: CGSize
    static let width: CGFloat = 620
    static let footer: CGFloat = 64
    /// The hello's words and names, under the companion.
    static let words: CGFloat = 214
    static func height(visible: CGFloat) -> CGFloat { min(700, max(480, visible - 24)) }
    /// The hello page: the stage over the words, and the companion's feet on its floor (from the top).
    var stageHeight: CGFloat { size.height - Self.footer - Self.words }
    var helloFloor: CGFloat { stageHeight - 18 }
    var helloScale: CGFloat { min(1.6, max(0.9, (stageHeight - 64) / 176)) }
    /// The read page: a band at the top with the companion on the left and the drawn window beside it.
    var readBand: CGFloat { min(236, max(196, stageHeight * 0.62)) }
    var readFloor: CGFloat { readBand - 14 }
    var readScale: CGFloat { min(1.1, helloScale, (readBand - 54) / 176) }
    var readX: CGFloat { 124 }
    var sample: CGRect { CGRect(x: 242, y: 40, width: size.width - 242 - 28, height: readBand - 40 - 14) }
    /// The four marks on the drawn window, in its own coordinates (from its top-left).
    func mark(_ index: Int) -> CGRect {
        let w = sample.width
        switch index {
        case 1: return CGRect(x: 46, y: 4, width: 54, height: 20)
        case 2: return CGRect(x: w / 2 - 54, y: 4, width: 108, height: 20)
        case 3: return CGRect(x: 7, y: 31, width: w - 14, height: 28)
        default: return CGRect(x: 8, y: 61, width: w - 16, height: max(36, sample.height - 69))
        }
    }
    /// The other companion leaning in from the window's right edge: its picture's frame (the picture is 240 × 253.5
    /// points with the feet 246 down), in and out.
    func peek(in leaning: Bool) -> CGRect {
        let floor = helloFloor + 4, scale = min(1, helloScale / 1.35)
        let size = CGSize(width: 240 * scale, height: 253.5 * scale)
        return CGRect(x: leaning ? self.size.width - size.width * 0.62 : self.size.width + 8, y: floor - 246 * scale, width: size.width, height: size.height)
    }
    /// A point in the window (from its top-left) on screen, for a window at `frame`.
    func screen(_ point: CGPoint, in frame: CGRect) -> CGPoint { CGPoint(x: frame.minX + point.x, y: frame.maxY - point.y) }
}

@MainActor final class MokuOnboardingPresenter: NSObject, OnboardingPresenter, NSWindowDelegate {
    let stage: any CharacterStage
    let state = OnboardingModel()
    /// Checks and tests: the window is never shown, and nothing flies on screen.
    let offscreen: Bool
    /// Whether this welcome may keep where it got to and the login offer in UserDefaults. The demo shares Moku's defaults
    /// domain, so its checks never do.
    let remembers: Bool
    var panel: NSPanel?
    /// Where the menu bar icon is on screen (the app's world presenter), or nil while macOS doesn't show it; its picture
    /// as drawn; and hiding or showing the real one (while the spotlight's copy pulses over it).
    var menuBarIcon: @MainActor () -> CGRect? = { nil }
    var iconPicture: @MainActor () -> CGImage? = { nil }
    /// Where the house itself is drawn in the menu bar (the button's image; nil: the middle of `menuBarIcon`).
    var iconImage: @MainActor () -> CGRect? = { nil }
    var showIcon: @MainActor (Bool) -> Void = { _ in }
    /// Where System Settings' window is (the companion goes and sits on it), and whether the welcome is in front again.
    var settingsWindow: @MainActor () -> CGRect? = { SettingsWindowLocator.frame() }
    var welcomeInFront: @MainActor () -> Bool = { NSApp.isActive }
    /// The pointer (the film moves a pretend one).
    var pointer: @MainActor () -> CGPoint = { NSEvent.mouseLocation }
    /// How long the companion points at the icon before the welcome finishes.
    var pointSeconds = 4.5
    /// Where the companion pointed, and the line it said there.
    private(set) var pointedAt: CGRect?
    private(set) var pointLine: String?
    /// The spotlight on the icon while it's on: the screen's overlay, or offscreen just its clock (the film draws it).
    private(set) var spotlight: (model: IconSpotlight, began: CFTimeInterval, icon: CGRect, dismissedAt: Double?)?
    private(set) var spotlightOverlay: IconSpotlightOverlay?
    /// The window's exit on its way (the film draws it from here), when it began, and where it was.
    private(set) var exit: (kind: WindowExit, at: CFTimeInterval, frame: CGRect, picture: CGImage)?
    /// System Settings' window while the companion sits on it (the film draws a stand-in there).
    private(set) var visiting: CGRect?
    private var exitOverlay: WindowExitOverlay?
    private var context: OnboardingContext?
    private var continuation: CheckedContinuation<OnboardingResult, Never>?
    private var permissionTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    /// Where the window sits once it's in (it rises into it): the companion is placed by this, not the frame mid-rise.
    private var windowFrame: CGRect?
    private var reactionTask: Task<Void, Never>?
    private var greetTask: Task<Void, Never>?
    private var followTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    private var savedClick: (@MainActor () -> Void)?
    /// For welcome_finished's seconds, and so a permission that turns on is counted once.
    private var startedAt = Date()
    private var counted: PermissionStatus?
    /// The last step the welcome reached, for `welcome_left`.
    private var lastStep = "opened"
    /// When each permission's Allow was pressed: `permission_answered` says how many seconds the answer took.
    private var askedAt: [String: Date] = [:]
    /// The "Start with your Mac" switch as the window opened.
    private var startWithMacAtOpen = true
    /// The companion is busy showing something (the drawn window, System Settings): its eyes aren't the pointer's.
    private var showing = false
    init(stage: any CharacterStage, offscreen: Bool = false, remembers: Bool? = nil) {
        self.stage = stage; self.offscreen = offscreen; self.remembers = remembers ?? !offscreen; super.init()
    }
    private var real: MokuCharacterStage? { stage as? MokuCharacterStage }
    var layout: WelcomeLayout { WelcomeLayout(size: panel?.frame.size ?? CGSize(width: WelcomeLayout.width, height: 700)) }

    func run(_ context: OnboardingContext) async -> OnboardingResult {
        finish(completed: false)
        if Task.isCancelled { return OnboardingResult(name: PersonName.clean(context.suggestedName ?? "") ?? PersonName.fallback, completed: false) }
        VisualSessionState.shared.onboarding = true
        self.context = context
        state.suggestedName = context.suggestedName ?? ""; state.name = state.suggestedName
        state.resumed = false; state.asked = []; state.starting = false; state.peeking = nil; askedAt = [:]
        state.greetedAt = nil; state.readStartedAt = nil; state.readStep = 0; state.scanAt = nil; state.page = .hello
        state.reduced = MotionPreference.reduced
        pointedAt = nil; pointLine = nil; spotlight = nil; exit = nil; visiting = nil; showing = false; windowFrame = nil
        if remembers, let resumed = OnboardingProgress.resumable() { state.resumed = true; state.name = resumed.name; state.asked = resumed.asked; state.page = .read }
        state.permissions = context.permissions()
        // Chosen for you the first time (a companion that isn't there when you start isn't much company); after that, as it is.
        state.startWithMac = remembers && UserDefaults.standard.bool(forKey: Self.loginOfferedKey) ? context.launchAtLogin() : true
        startWithMacAtOpen = state.startWithMac
        state.companion = Companion.current; state.choosing = Companion.hasChoice
        state.choose = { [weak self] companion in self?.choose(companion) }
        state.hover = { [weak self] companion in self?.hover(companion) }
        state.next = { [weak self] in self?.showWhatItReads() }
        state.start = { [weak self] in self?.end(.start) }
        state.skip = { [weak self] in self?.end(.skip) }
        state.request = { [weak self] kind in self?.request(kind) }
        state.relaunch = { [weak self] in
            guard let self else { return }
            self.step("relaunch")
            if remembers { OnboardingProgress.save(name: state.name, asked: state.asked) }
            self.context?.relaunch()
        }
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = Self.size(for: state, visible: screen)
        let view = NSHostingView(rootView: OnboardingView(model: state, size: size))
        view.sizingOptions = []  // the window keeps its measured size (the hosting view would add the title bar's inset)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false  // stays up while System Settings is in front for the permissions
        panel.title = "Hello, \(state.companion.name)"; panel.titlebarAppearsTransparent = true; panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false; panel.delegate = self; panel.contentView = view
        panel.level = .floating; panel.backgroundColor = Self.windowColor(state.companion)
        panel.standardWindowButton(.zoomButton)?.isHidden = true; panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.setFrame(CGRect(origin: .zero, size: size), display: false)  // the title bar is inside it, not on top
        // In the middle of the screen, a little above: the companion is in it, not beside it.
        panel.setFrameOrigin(CGPoint(x: (screen.midX - size.width / 2).rounded(), y: (screen.midY - size.height / 2 + min(30, (screen.height - size.height) / 4)).rounded()))
        panel.isMovable = false  // the companion sits in it: a window dragged away would leave it behind
        self.panel = panel; windowFrame = panel.frame
        screenObserver = DisplayRecovery.observe(panel)
        // A display change can still move it: the companion goes with it (unless it's away on System Settings).
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, let frame = self.windowFrame, panel.frame.size == frame.size,
                      hypot(panel.frame.minX - frame.minX, panel.frame.minY - frame.minY) > 12 else { return }
                self.windowFrame = panel.frame
                if !self.state.starting, self.visiting == nil, let real = self.real, let spot = self.spot(self.state.page) { real.place(feet: spot.feet, scale: spot.scale) }
            }
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.state.starting == false { self?.panel?.level = .floating } }
        }
        // Both companions loaded before the window shows: a switch is then a cross-fade at once, and no load runs while
        // you watch (a load holds the main thread about half a second). The one not picked is freed when it ends.
        if state.choosing, !offscreen, let real, let other = Companion.available.first(where: { $0 != Companion.current }) {
            real.keepsBothCompanions = true
            real.preloadCompanion(other)
            let asked = CACurrentMediaTime()
            while real.hasPreloaded != other, CACurrentMediaTime() - asked < 4 {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                if !offscreen { appear(panel) }
                react()
                startedAt = Date(); counted = state.permissions
                step(state.resumed ? "resumed" : "opened")
                permissionTask = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self, let context = self.context else { return }
                        let before = state.permissions
                        state.permissions = context.permissions()
                        if !state.starting, settingsTask == nil, (!before.accessibility && state.permissions.accessibility) || (!before.screenRecording && state.permissions.screenRecording) {
                            stage.perform(.nod)  // glad you allowed it
                        }
                        answered(granted: true)
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(completed: false) } }
    }
    static let loginOfferedKey = "MokuVisual.loginOffered"
    static func windowColor(_ companion: Companion) -> NSColor {
        companion.isMachine ? NSColor(srgbRed: 0.071, green: 0.094, blue: 0.078, alpha: 1) : NSColor(calibratedRed: 0.975, green: 0.963, blue: 0.934, alpha: 1)
    }
    /// The window's size: 620 points wide, as tall as the screen allows up to 700 (at least 480; a short screen scrolls
    /// what's under the drawn window, never Start).
    static func size(for model: OnboardingModel, visible: CGRect? = nil) -> CGSize {
        CGSize(width: WelcomeLayout.width, height: WelcomeLayout.height(visible: visible?.height ?? 900))
    }
    /// The window rises a little as it fades in (just fades with Reduce Motion).
    private func appear(_ panel: NSPanel) {
        let frame = panel.frame
        panel.alphaValue = 0
        if !state.reduced { panel.setFrameOrigin(CGPoint(x: frame.minX, y: frame.minY - 8)) }
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4; context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1)
            panel.animator().alphaValue = 1
            if !state.reduced { panel.animator().setFrame(frame, display: true) }
        }
    }

    // MARK: Usage events (usage-analytics.md): the window opening or picking up again, each permission's answer, the
    // Quit & Reopen, and how the welcome ended.

    /// Counts each permission once: when it turns on, or (granted false) when the welcome is left without it.
    private func answered(granted: Bool) {
        guard let before = counted else { return }
        let now = state.permissions
        for (kind, was, isOn) in [("accessibility", before.accessibility, now.accessibility), ("screen", before.screenRecording, now.screenRecording)]
            where !was && (granted ? isOn : !isOn) {
            var props: [String: UsageValue] = ["kind": .word(kind), "granted": .bool(isOn), "where": .word("welcome")]
            if let asked = askedAt[kind] { props["seconds"] = .int(max(0, Int(Date().timeIntervalSince(asked)))) }
            context?.track("permission_answered", props)
        }
        counted = granted ? now : PermissionStatus(accessibility: true, screenRecording: true)
    }
    /// `welcome_step`: how far the welcome got (the companion on show goes with every event).
    private func step(_ word: String) {
        lastStep = word
        context?.track("welcome_step", ["step": .word(word)])
    }
    private func finished(how: String) {
        context?.track("welcome_finished", ["how": .word(how), "seconds": .int(max(0, Int(Date().timeIntervalSince(startedAt))))])
    }

    // MARK: The companion

    /// Where the companion sits for a page, on screen, and at what size.
    private func spot(_ page: OnboardingModel.Page) -> (feet: CGPoint, scale: CGFloat)? {
        guard let frame = windowFrame ?? panel?.frame else { return nil }
        let layout = self.layout
        switch page {
        case .hello: return (layout.screen(CGPoint(x: layout.size.width / 2, y: layout.helloFloor), in: frame), layout.helloScale)
        case .read: return (layout.screen(CGPoint(x: layout.readX, y: layout.readFloor), in: frame), layout.readScale)
        }
    }
    private func react() {
        reactionTask?.cancel()
        reactionTask = Task { [weak self] in
            guard let self else { return }
            if let real, let spot = spot(state.page) {
                savedClick = real.onClick
                real.onClick = { [weak self] in self?.stage.perform(.wave) }  // a click in the welcome says hi, it doesn't open the house
                // Already out ("Say hi again"): it fades from its corner into the window. Otherwise it appears there.
                if real.hidden { real.enterWelcome(feet: spot.feet, scale: spot.scale) }
                else { await real.fade(toFeet: spot.feet, scale: spot.scale); real.enterWelcome(feet: spot.feet, scale: spot.scale) }
                while real.view.real == nil && real.rendererError == nil {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
            } else {
                stage.show()
            }
            stage.setMood(.content); stage.setAttention(.user)
            guard !Task.isCancelled else { return }
            if state.resumed {
                // Back after a relaunch: a word, and it carries on where it was.
                stage.perform(.wave)
                stage.say(SpeechLine(text: state.permissions.screenRecording ? "Thanks! Now I can read a few words too." : "I’m back. Let’s carry on.", tone: .warm, duration: 3))
                state.readStartedAt = .distantPast; state.readStep = 4
            } else {
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }  // the window is in, then it says hi
                greet()
                step("hello")
            }
            followPointer()
        }
    }
    /// It waves (Tetsu's display boots as it does) and the hello arrives with it.
    private func greet() {
        stage.perform(.wave)
        state.greetedAt = Date()
        if state.machine, let real = real?.view.real {
            // Its antennae twitch once it's up, like sensors coming on.
            Task { try? await Task.sleep(for: .seconds(1.6)); _ = real.flickEar() }
        }
    }
    /// Its eyes follow your pointer while the window is in front (30 times a second at most, and only when the pointer
    /// moves). A pointer left still for a few seconds, and it looks at you instead. Not with Reduce Motion: it stays still.
    private func followPointer() {
        followTask?.cancel()
        guard !state.reduced, let real else { return }
        followTask = Task { [weak self] in
            var last: CGPoint?, stillSince = CACurrentMediaTime(), atYou = true
            while !Task.isCancelled {
                guard let self else { return }
                let inFront = offscreen || panel?.isKeyWindow == true
                if inFront && !showing && !state.starting && state.peeking == nil {
                    let p = pointer(), now = CACurrentMediaTime()
                    if let last, hypot(p.x - last.x, p.y - last.y) < 3 {
                        if !atYou && now - stillSince > 3.5 { atYou = true; real.setAttention(.user) }
                    } else {
                        if last != nil { atYou = false; real.look(at: p) }  // the first sample only notes where it is
                        last = p; stillSince = now
                    }
                } else { last = nil }
                do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
            }
        }
    }
    /// "Or work with": the other companion takes over. Its window, its words and its character, by fade, where it sits.
    private func choose(_ companion: Companion) {
        guard !state.starting else { return }
        state.peeking = nil
        guard companion != state.companion else { return }
        withAnimation(state.reduced ? nil : .easeInOut(duration: 0.5)) { state.companion = companion }
        panel?.title = "Hello, \(companion.name)"  // what VoiceOver and Mission Control call the window
        panel?.backgroundColor = Self.windowColor(companion)
        context?.track("companion_changed", ["from": .word(CompanionChoice.chosen.rawValue), "to": .word(companion.rawValue), "where": .word("welcome")])
        CompanionChoice.choose(companion)
        context?.track("setting_changed", ["key": .word("companion")])
        step("picked")
        state.greetedAt = nil
        greetTask?.cancel()
        greetTask = Task { [weak self] in
            guard let self else { return }
            if let real {
                let asked = CACurrentMediaTime()
                while real.companion != companion {
                    guard CACurrentMediaTime() - asked < 15 else { return }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
                real.view.real?.frameCap = 30  // the new character draws life-size too
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            }
            guard !state.starting, state.companion == companion else { return }
            if state.page == .hello { greet() } else { stage.perform(.wave); state.readStartedAt = Date() }
        }
    }
    /// Hovering the other one's name: it leans in from the window's edge, and the one in the window turns to look.
    private func hover(_ companion: Companion?) {
        guard !state.starting else { return }
        let peeking = companion == state.companion ? nil : companion
        guard peeking != state.peeking else { return }
        withAnimation(state.reduced ? .easeInOut(duration: 0.2) : peeking?.isMachine == true ? .interpolatingSpring(stiffness: 260, damping: 20) : .easeOut(duration: 0.32)) {
            state.peeking = peeking
        }
        if peeking != nil, let frame = windowFrame ?? panel?.frame, let real {
            let peek = layout.peek(in: true)
            real.look(at: layout.screen(CGPoint(x: peek.minX + peek.width * 0.45, y: peek.minY + peek.height * 0.4), in: frame))
        }
    }
    /// Next: the companion moves over (the seated move: out and in) for the drawn window, and shows what it reads on it.
    private func showWhatItReads() {
        guard !state.starting, state.page == .hello else { return }
        step("reads")
        withAnimation(state.reduced ? .easeInOut(duration: 0.25) : .easeInOut(duration: 0.45)) { state.page = .read; state.peeking = nil }
        readTask?.cancel()
        readTask = Task { [weak self] in
            guard let self else { return }
            showing = true; defer { showing = false }
            if let real, let spot = spot(.read) { await real.fade(toFeet: spot.feet, scale: spot.scale) }  // the seated move, as the page changes
            guard !Task.isCancelled else { return }
            await showMarks()
        }
    }
    /// The four things it reads on the drawn window, one after another, its eyes on each (and Tetsu's beam across it).
    private func showMarks() async {
        state.readStartedAt = Date()
        if state.reduced { state.readStep = 4; return }
        stage.setMood(.curious)
        for step in 1...4 {
            guard !Task.isCancelled, !state.starting else { return }
            state.readStep = step
            if let frame = windowFrame ?? panel?.frame, let real {
                let sample = layout.sample, mark = layout.mark(step)
                real.look(at: layout.screen(CGPoint(x: sample.minX + mark.midX, y: sample.minY + mark.midY), in: frame))
                if step == 1, state.machine { real.view.real?.playDisplayMoment("px_scan"); state.scanAt = Date() }
            }
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
        }
        stage.setMood(.content); stage.setAttention(.user)
    }
    /// Allow: macOS's prompt or System Settings, which comes to the front (the welcome steps back to let it). The
    /// companion goes and sits on System Settings' window, over its switch, and waits; it's back in the welcome once
    /// the switch is on or the welcome is in front again.
    private func request(_ kind: PermissionKind) {
        panel?.level = .normal
        step(kind == .accessibility ? "allow_accessibility" : "allow_screen")
        askedAt[kind == .accessibility ? "accessibility" : "screen"] = askedAt[kind == .accessibility ? "accessibility" : "screen"] ?? Date()
        state.asked.insert(kind)
        if remembers { OnboardingProgress.save(name: state.name, asked: state.asked) }  // kept first: macOS may quit Moku to apply Screen Recording
        context?.requestPermission(kind)
        guard let real else { return }
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            guard let self else { return }
            showing = true
            defer { showing = false; settingsTask = nil }
            var window: CGRect?
            for _ in 0..<16 where window == nil {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                window = settingsWindow()
            }
            guard !state.starting else { return }
            if let window {
                visiting = window
                await real.fade(toFeet: SettingsWindowLocator.perch(on: window), scale: real.chosenScale)  // the seated move
                real.look(at: CGPoint(x: window.maxX - min(150, window.width * 0.2), y: window.midY + window.height * 0.12))
                stage.say(SpeechLine(text: state.machine ? "That switch is mine. Standing by." : "That one’s me. I’ll wait.", tone: .warm, duration: SpeechLine.untilDismissed))
            } else if let screen = NSScreen.main?.visibleFrame {
                real.look(at: CGPoint(x: screen.midX, y: screen.midY))  // it can't see where it went: it turns to look
            }
            let began = CACurrentMediaTime()
            let granted: @MainActor () -> Bool = { [state] in kind == .accessibility ? state.permissions.accessibility : state.permissions.screenRecording }
            while !Task.isCancelled, !state.starting, !granted(), CACurrentMediaTime() - began < 90, !(welcomeInFront() && CACurrentMediaTime() - began > 1.5) {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            guard !state.starting else { return }
            if granted() { stage.perform(.nod) }
            stage.dismissSpeech()
            if visiting != nil, let spot = spot(state.page) {
                await real.fade(toFeet: spot.feet, scale: spot.scale)
                visiting = nil
            }
            stage.setAttention(.user)
        }
    }

    // MARK: The end

    enum Ending { case start, skip, closed }
    /// Start, Skip or the close button. Start applies "Start with your Mac" (registering the login item when it's on: the
    /// switch is the consent); Skip and the close button keep only a switch the person flipped. Each ends the companion's
    /// way and then shows where the icon is.
    func end(_ ending: Ending) {
        guard !state.starting, continuation != nil else { return }
        state.starting = true
        followTask?.cancel(); readTask?.cancel(); settingsTask?.cancel(); greetTask?.cancel(); reactionTask?.cancel()
        if remembers { OnboardingProgress.clear() }
        switch ending {
        case .start:
            answered(granted: false)  // left with a permission still off
            if let context {
                if remembers { UserDefaults.standard.set(true, forKey: Self.loginOfferedKey) }
                if let change = LoginItemConsent.atStart(switchOn: state.startWithMac, registered: context.launchAtLogin()) { context.setLaunchAtLogin(change) }
            }
            step("start"); finished(how: "completed")
        case .skip:
            applyLoginChoice(); step("skip"); finished(how: "skipped")
        case .closed:
            applyLoginChoice()
            context?.track("welcome_left", ["last_step": .word(lastStep), "seconds": .int(max(0, Int(Date().timeIntervalSince(startedAt))))])
        }
        exitTask = Task { [weak self] in
            await self?.leave(ending)
            self?.finish(completed: ending == .start)
        }
    }
    /// The window goes (lets go, powers off, or fades), the companion goes home, and it points at the icon.
    private func leave(_ ending: Ending) async {
        stage.dismissSpeech()
        let reduced = state.reduced, machine = state.machine, start = ending == .start
        let kind = Self.exit(for: ending, reduced: reduced, machine: machine, centre: companionCentre ?? .zero)
        if let panel, ending != .closed, let content = panel.contentView, let picture = try? ReviewCapture.view(content) {
            exit = (kind, CACurrentMediaTime(), panel.frame, picture)
            if !offscreen { exitOverlay = WindowExitOverlay(picture: picture, frame: panel.frame, exit: kind, scale: panel.backingScaleFactor) }
        }
        panel?.orderOut(nil)
        let icon = menuBarIcon()
        if let real {
            let home = real.homeFeet(scale: real.chosenScale)
            if start && !reduced && !machine {
                // Moku: a beat on your desk with the window gone, then out of sight and into its corner, where it settles.
                do { try await Task.sleep(for: .seconds(kind.duration + 0.25)) } catch { return }
                closeExit()
                await real.fade(toFeet: home, scale: real.chosenScale)
                await real.settle()
            } else if start && !reduced && machine {
                // Tetsu: it goes with the screen, and is in its corner a moment later.
                await NSAnimationContext.runAnimationGroup { context in context.duration = 0.16; real.panel.animator().alphaValue = 0 }
                do { try await Task.sleep(for: .seconds(max(0, kind.duration - 0.16) + 0.05)) } catch { return }
                real.place(feet: home, scale: real.chosenScale)
                await NSAnimationContext.runAnimationGroup { context in context.duration = 0.45; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); real.panel.animator().alphaValue = 1 }
            } else {
                await real.fade(toFeet: home, scale: real.chosenScale)  // the seated move, the app's own
            }
            real.leaveWelcome()
        } else {
            do { try await Task.sleep(for: .seconds(kind.duration)) } catch { return }
        }
        closeExit()
        await point(at: icon)
    }
    private func closeExit() { exitOverlay?.close(); exitOverlay = nil; exit = nil }
    /// How the window goes: on Start, Moku's lets go and Tetsu's powers off; Skip, the close button and Reduce Motion
    /// fade it where it is.
    static func exit(for ending: Ending, reduced: Bool, machine: Bool, centre: CGPoint) -> WindowExit {
        ending != .start || reduced ? .fade : machine ? .powerOff : .letGo(center: centre)
    }
    /// Where the companion's body is on screen (the window lets go around it).
    private var companionCentre: CGPoint? {
        guard let real else { return nil }
        let body = real.view.characterRect
        return CGPoint(x: real.panel.frame.minX + body.midX, y: real.panel.frame.minY + body.midY)
    }
    /// It looks up at the icon and says where its house lives, and the icon's display dims at once round a spotlight on
    /// it while the house pulses in place (IconSpotlight). With the icon out of sight (a full menu bar hides some behind
    /// the notch), no dim: it says to click it instead.
    private func point(at icon: CGRect?) async {
        let line = icon == nil ? "Click me to see your house." : state.machine ? "HOME ↑" : "Your house lives up here."
        pointedAt = icon; pointLine = line
        if let icon { lightUp(icon) }
        if !state.machine && !state.reduced { stage.perform(.wave) }  // Tetsu's wave boots its display: it just looks up (Reduce Motion: one wave in all)
        stage.say(SpeechLine(text: line, tone: .warm, duration: pointSeconds))
        if let icon { look(at: icon) } else { stage.setMood(.happy); stage.setAttention(.user) }
        let until = CACurrentMediaTime() + pointSeconds
        var wait = min(1.6, pointSeconds)
        while CACurrentMediaTime() < until {
            do { try await Task.sleep(for: .seconds(min(wait, max(0, until - CACurrentMediaTime())))) } catch { return }
            if let icon { look(at: icon) }
            if let spotlight, spotlight.model.isOver(at: CACurrentMediaTime() - spotlight.began, dismissedAt: spotlightOverlay?.dismissedAt ?? spotlight.dismissedAt) { self.spotlight = nil }
            wait = 0.8
        }
    }
    /// The spotlight: only the display the icon is on dims, and the companion and its line stay over the dim.
    private func lightUp(_ icon: CGRect) {
        // On the house itself: the button's image, centred in the wider button (the same centre when it isn't known).
        let house = iconImage() ?? CGRect(x: icon.midX - 9, y: icon.midY - 9, width: 18, height: 18)
        spotlight = (IconSpotlight(reduced: state.reduced), CACurrentMediaTime(), house, nil)
        guard !offscreen, let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: house.midX, y: house.midY)) }) else { return }
        let above = real.map { [$0.panel, $0.speechPanel, $0.labelPanel] } ?? []
        let overlay = IconSpotlightOverlay(icon: house, screen: screen.frame, house: iconPicture(), reduced: state.reduced, above: above, showIcon: showIcon, listens: true, shows: true)  // the app only: never in a check
        overlay.onEnd = { [weak self, weak overlay] in
            guard let self, self.spotlightOverlay === overlay else { return }
            self.spotlightOverlay = nil; self.spotlight = nil
        }
        spotlightOverlay = overlay
    }
    /// A click or a key ends the spotlight at once (the film presses one; on screen the overlay hears them itself).
    func dismissSpotlight() {
        if let overlay = spotlightOverlay { overlay.handle(.leftMouseDown); return }
        guard var spotlight, spotlight.dismissedAt == nil else { return }
        spotlight.dismissedAt = CACurrentMediaTime() - spotlight.began; self.spotlight = spotlight
    }
    /// The companion looks at the icon.
    private func look(at target: CGRect) {
        let point = CGPoint(x: target.midX, y: target.midY)
        guard let real else { stage.setAttention(.point(point)); return }
        if real.attention == .user { real.setAttention(.wander) }  // off you, without restarting a look already on its way
        real.look(at: point)
    }
    func finish(completed: Bool) {
        guard let continuation else { return }
        real?.dropPreloaded()  // the one not picked is freed
        self.continuation = nil; VisualSessionState.shared.onboarding = false
        // Only finishing clears where the welcome had got to (Skip clears it too). Quitting closes the window as
        // well, and macOS quits Moku to apply Screen Recording: the reopened Moku carries on from what it reads.
        if completed && remembers { OnboardingProgress.clear() }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver); self.activationObserver = nil }
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver); self.moveObserver = nil }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver); self.screenObserver = nil }
        for task in [permissionTask, reactionTask, greetTask, followTask, readTask, settingsTask] { task?.cancel() }
        permissionTask = nil; reactionTask = nil; greetTask = nil; followTask = nil; readTask = nil; settingsTask = nil
        if !completed && !state.starting { exitTask?.cancel() }
        exitTask = nil
        exitOverlay?.close(); exitOverlay = nil; spotlightOverlay?.end(); spotlightOverlay = nil; spotlight = nil; exit = nil
        context = nil; panel?.delegate = nil; panel?.orderOut(nil); panel?.close(); panel = nil
        if let real { real.leaveWelcome(); real.onClick = savedClick; savedClick = nil }
        stage.dismissSpeech(); stage.setMood(.content); stage.setAttention(.wander)
        continuation.resume(returning: OnboardingResult(name: state.resultName, completed: completed))
    }
    func windowWillClose(_ notification: Notification) { if !state.starting { end(.closed) } }
    /// "Start with your Mac" is the person's, whichever way the welcome ends: Skip and the close button used to ignore it, so
    /// someone who switched it off and skipped was still opened at every login.
    /// Only a switch the person flipped counts: a welcome left untouched changes nothing (and never adds a development
    /// build to the login items).
    private func applyLoginChoice() {
        guard let context, let change = LoginItemConsent.atEarlyExit(switchOn: state.startWithMac, switchAtOpen: startWithMacAtOpen) else { return }
        context.setLaunchAtLogin(change)
    }
    isolated deinit { for task in [permissionTask, reactionTask, greetTask, followTask, readTask, settingsTask, exitTask] { task?.cancel() } }
}

extension MokuVisualFactory {
    @MainActor public static func makeOnboarding(stage: any CharacterStage) -> any OnboardingPresenter { MokuOnboardingPresenter(stage: stage) }
    /// The welcome, with the menu bar icon to point at as it ends.
    @MainActor public static func makeOnboarding(stage: any CharacterStage, world: any WorldPresenter) -> any OnboardingPresenter {
        let presenter = MokuOnboardingPresenter(stage: stage)
        presenter.menuBarIcon = { [weak world] in (world as? MokuWorldPresenter)?.iconFrame }
        presenter.iconPicture = { [weak world] in (world as? MokuWorldPresenter)?.iconPicture }
        presenter.iconImage = { [weak world] in (world as? MokuWorldPresenter)?.iconImageFrame }
        presenter.showIcon = { [weak world] shown in (world as? MokuWorldPresenter)?.setIconShown(shown) }
        return presenter
    }
}

/// Where the welcome had got to. Allowing Screen Recording makes macOS quit and reopen Moku (and the window's own
/// Quit & Reopen does the same): without this the welcome started again from the top. Saved when a permission's Allow is
/// pressed, kept for half an hour.
enum OnboardingProgress {
    static let key = "MokuVisual.onboardingProgress.v3"
    /// How long a saved place is picked up again: macOS's Quit & Reopen takes seconds; half an hour covers stepping away.
    static let keptFor: TimeInterval = 1800
    static func save(name: String, asked: Set<PermissionKind>, in store: UserDefaults = .standard, now: Date = Date()) {
        store.set(["name": name, "asked": asked.map(\.rawValue).sorted(), "at": now.timeIntervalSince1970], forKey: key)
    }
    static func resumable(in store: UserDefaults = .standard, now: Date = Date()) -> (name: String, asked: Set<PermissionKind>)? {
        guard let saved = store.dictionary(forKey: key), let at = saved["at"] as? Double,
              now.timeIntervalSince1970 - at >= 0, now.timeIntervalSince1970 - at < keptFor else { return nil }
        return (saved["name"] as? String ?? "", Set((saved["asked"] as? [String] ?? []).compactMap(PermissionKind.init(rawValue:))))
    }
    static func clear(in store: UserDefaults = .standard) { store.removeObject(forKey: key) }
}
