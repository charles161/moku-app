import AppKit
import SwiftUI
import Observation
import MokuKit

@MainActor @Observable final class ForestPresentation {
    var points = 0.0
    var celebration: ForestStage?
    var celebrating = false
    var manualControl = false
    var onBreak = false
    var thinking: ThinkingStatus = .fine
    /// Read each time the popover opens; nil before the app says.
    var permissions: PermissionStatus?
    func queueCelebration(_ stage: ForestStage) { guard !manualControl else { return }; ingest(stage.threshold); celebration = max(celebration ?? .seed,stage) }
    func ingest(_ value: Double) { if value.isFinite { points = max(points,value) } }
}

/// What the popover's controls and the menu bar icon's right-click menu do: one list, so the two never drift apart.
/// The raw value is the word `popover_action` sends (UsageEvents.schema and the relay's events.js list the same words).
enum HomeAction: String, CaseIterable {
    case takeBreak = "break", hide, show, putBack = "put_back", settings, hi, feedback, quit
    /// Under "···" in the popover, and after the three controls in the right-click menu, in groups.
    static let more: [[HomeAction]] = [[.hi, .putBack], [.feedback], [.quit]]
    /// The menu item's title (the popover's three controls use shorter labels).
    func title(onBreak: Bool, name: String) -> String {
        switch self {
        case .takeBreak: onBreak ? "End the break" : "Take a break"
        case .hide: "Hide \(name)"
        case .show: "Show \(name)"
        case .putBack: "Put \(name) back in the corner"
        case .settings: "Settings…"
        case .hi: "Say hi again"
        case .feedback: "Send feedback…"
        case .quit: "Quit Moku"
        }
    }
}

@MainActor final class MokuWorldPresenter: NSObject, WorldPresenter, NSPopoverDelegate, NSMenuDelegate {
    var onManualControl: (@MainActor (Bool)->Void)?
    var onTakeBreak: (@MainActor ()->Void)?
    var onSayHiAgain: (@MainActor ()->Void)?
    var onOpen: (@MainActor ()->Void)?
    var todayProvider: (@MainActor (Date?) async -> TodaySummary?)?
    var daysProvider: (@MainActor (_ from: Date, _ to: Date) async -> DaysResponse?)?
    var onCorrection: (@MainActor ([String],Bool)->Void)?
    var loadConfig: (@MainActor () async -> CompanionConfig?)?
    var saveConfig: (@MainActor (CompanionConfigPatch) async -> CompanionConfig?)?
    var loadAccess: (@MainActor () async -> AccessStatus?)?
    var redeemInvite: (@MainActor (String) async -> Result<AccessStatus, InviteError>)?
    var startCheckout: (@MainActor (String) async -> Result<Void, InviteError>)?
    var deleteData: (@MainActor () async -> Bool)?
    var checkForUpdates: (@MainActor () -> Void)?
    var updateStatus: String? { didSet { settings?.model.updateStatus = updateStatus } }
    var permissionStatus: (@MainActor () -> PermissionStatus)?
    var requestPermission: (@MainActor (PermissionKind) -> Void)?
    var track: UsageTracker? { didSet { dayCounted.track = track; today?.track = track; settings?.model.track = track } }
    var count: UsageCounter?
    func setManualControl(_ on: Bool) {
        state.manualControl = on; if on { state.celebration = nil }; updateIcon()
    }
    func setOnBreak(_ on: Bool) { state.onBreak = on }
    func setThinking(_ status: ThinkingStatus) { if state.thinking != status { state.thinking = status } }
    let model: WorldModel
    let state = ForestPresentation()
    let scene = HomeScene()
    let item: NSStatusItem
    let popover = NSPopover()
    var screenObserver: NSObjectProtocol?
    var settingsObserver: NSObjectProtocol?
    var todayObserver: NSObjectProtocol?
    var homeObserver: NSObjectProtocol?
    var companionObserver: NSObjectProtocol?
    /// Escape, and a click outside, while the popover is open.
    var dismissMonitors: [Any] = []
    /// Switching to another app closes the popover too, once it has been open a moment.
    var resignObserver: NSObjectProtocol?
    var openedAt = Date.distantPast
    /// The screens changed while it was open: it opens again, placed afresh, once it has closed.
    var reopenOnClose = false
    var today: TodayPresenter?
    var settings: SettingsPresenter?
    /// "Today counted": the day's card beside the companion (DayCounted.swift).
    let dayCounted = DayCountedPresenter()
    init(model: WorldModel) {
        self.model = model; item = NSStatusBar.system.statusItem(withLength: 26); super.init()
        item.button?.target = self; item.button?.action = #selector(toggle); item.button?.setAccessibilityLabel("Moku, today’s house")
        // A right-click (or a control-click) opens the menu, the Mac convention. The left click keeps the mask it had.
        if let button = item.button {
            let left = NSEvent.EventTypeMask(rawValue: UInt64(button.sendAction(on: .leftMouseUp)))
            button.sendAction(on: left.union(.rightMouseUp))
        }
        // Moku closes the popover itself (openWorld). With AppKit's transient rules it could vanish the moment it opened,
        // before Moku was active (a friend's Mac, 2026-10-03).
        popover.behavior = .applicationDefined; popover.animates = true; popover.delegate = self
        popover.contentSize = CGSize(width: 370,height: HomeView.height)
        popover.contentViewController = NSHostingController(rootView: HomeView(model: model,state: state,scene: scene,onManualControl: { [weak self] in self?.onManualControl?($0) },onToday: { [weak self] in self?.openToday(from: $0) },onAction: { [weak self] in self?.perform($0,from: "popover") },onMore: { [weak self] in self?.showMore(under: $0) },onPermissions: { [weak self] in self?.openSettings(.privacy) },onSettings: { [weak self] in self?.openSettings(.general) }))
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,object: nil,queue: .main) { [weak self] _ in Task { @MainActor in
            guard let self, self.popover.isShown else { return }; self.reopenOnClose = true; self.closeWorld()
        } }
        // A moku://invite link redeemed: Settings shows that it took.
        settingsObserver = NotificationCenter.default.addObserver(forName: Notification.Name("MokuVisual.openSettings"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.openSettings() } }
        // Moku opened a second time (the running one is told): the popover opens, so the double-click shows something.
        homeObserver = NotificationCenter.default.addObserver(forName: Notification.Name("MokuVisual.openHome"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showWorld() }
        }
        // moku://day (a link from Shortcuts or Raycast), or the companion's right-click menu ("menu").
        todayObserver = NotificationCenter.default.addObserver(forName: Notification.Name("MokuVisual.openToday"), object: nil, queue: .main) { [weak self] note in
            let from = note.userInfo?["from"] as? String == "menu" ? "menu" : "link"
            Task { @MainActor in self?.openToday(from: from) }
        }
        // The day's home is the companion's: its name, its stages and its pieces (CompanionChoice.choose renames it on a
        // switch; the scenes load the home themselves).
        DayHouse.useNames(of: .current)
        // The card's click: Your day at its day, counted as `day_opened` from "card".
        dayCounted.onOpenDay = { [weak self] day in self?.showToday(day: day); self?.track?("day_opened", ["from": .word("card")]) }
        companionObserver = NotificationCenter.default.addObserver(forName: .mokuCompanionChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIcon() }
        }
        observe()
    }
    isolated deinit { scene.close(); if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }; if let todayObserver { NotificationCenter.default.removeObserver(todayObserver) }; if let homeObserver { NotificationCenter.default.removeObserver(homeObserver) }; if let companionObserver { NotificationCenter.default.removeObserver(companionObserver) }; if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; NSStatusBar.system.removeStatusItem(item) }
    func observe() {
        withObservationTracking { state.ingest(model.snapshot.growthPoints); scene.setPoints(Double(model.snapshot.todayFocusMinutes)); updateIcon(); noticePieces() } onChange: { [weak self] in Task { @MainActor in self?.observe() } }
    }
    /// Today's pieces as last seen: a new one is announced (Tetsu projects a hologram of its rocket). The first
    /// snapshot is only the baseline, and a new day starts again from none.
    private var builtPieces: Int?
    private func noticePieces() {
        let built = DayHouse.built(Double(model.snapshot.todayFocusMinutes))
        defer { builtPieces = built }
        if let before = builtPieces, built > before { NotificationCenter.default.post(name: .mokuHousePieceLanded, object: nil, userInfo: ["units": built]) }
    }
    /// The menu bar icon: a house that fills up as today's house is built, with a dot when there's something to see.
    func updateIcon() {
        let minutes = Double(model.snapshot.todayFocusMinutes)
        let base = MenuBarHouse.symbol
        let line = MenuBarHouse.fillLine(Double(DayHouse.percent(minutes)) / 100)  // the popover's percent, of the house's shape
        let dot = state.celebration != nil && !state.manualControl
        let image = NSImage(size: MenuBarHouse.size,flipped: false) { rect in
            base?.draw(in: rect,from: .zero,operation: .sourceOver,fraction: 0.3)
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: CGRect(x: 0,y: 0,width: rect.width,height: line)).addClip(); base?.draw(in: rect); NSGraphicsContext.restoreGraphicsState()
            if dot { NSColor.black.setFill(); NSBezierPath(ovalIn: CGRect(x: 14,y: 14,width: 3,height: 3)).fill() }
            return true
        }
        image.isTemplate = true; item.button?.image = image
        item.button?.toolTip = "Moku · \(DayHouse.names.home.lowercased()) \(DayHouse.percent(minutes))% built"
        item.button?.setAccessibilityValue("\(DayHouse.percent(minutes)) percent built")
    }
    /// The menu bar icon: Moku's home opens, or closes when it's already open. A right-click or a control-click opens
    /// the menu instead.
    @objc func toggle() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp || event.modifierFlags.contains(.control) { showMenu(); return }
        toggleWorld(from: "menubar")
    }
    /// The right-click menu on the menu bar icon, under it like any menu bar app's: Your day, the popover's three
    /// controls, then the rest (what "···" holds), with Quit last.
    func showMenu() {
        closeWorld()
        rightClickMenu = controlsMenu(); item.menu = rightClickMenu
        item.button?.performClick(nil)  // AppKit shows the item's menu, with the icon highlighted; menuDidClose lets it go
    }
    /// The last right-click menu, kept until the next one, so the item picked outlives the menu closing.
    var rightClickMenu: NSMenu?
    func controlsMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        let onBreak = state.onBreak, name = Companion.current.name
        menu.addItem(ClosureMenuItem("Your day") { [weak self] in self?.openToday(from: "menu") })
        menu.addItem(.separator())
        let controls: [HomeAction] = [.takeBreak, VisualSessionState.shared.mokuHidden ? .show : .hide, .settings]
        for group in [controls] + HomeAction.more {
            if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
            for action in group { menu.addItem(ClosureMenuItem(action.title(onBreak: onBreak,name: name)) { [weak self] in self?.perform(action,from: "menu") }) }
        }
        return menu
    }
    func menuDidClose(_ menu: NSMenu) { if item.menu === menu { item.menu = nil } }
    /// What "···" holds, in its groups: say hi again and put it back, feedback, quit.
    static func moreMenu(onBreak: Bool, name: String, perform: @escaping @MainActor (HomeAction) -> Void) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for (i, group) in HomeAction.more.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            for action in group { menu.addItem(ClosureMenuItem(action.title(onBreak: onBreak, name: name)) { perform(action) }) }
        }
        return menu
    }
    /// "···" in the popover: its menu, just under the button (`frame`, in the popover's flipped content view).
    private var moreMenu: NSMenu?
    func showMore(under frame: CGRect) {
        guard let view = popover.contentViewController?.view else { return }
        let menu = Self.moreMenu(onBreak: state.onBreak, name: Companion.current.name) { [weak self] in self?.perform($0, from: "popover") }
        moreMenu = menu  // kept while it's up, so the item picked outlives the menu closing
        menu.popUp(positioning: nil, at: CGPoint(x: frame.minX, y: view.isFlipped ? frame.maxY + 4 : view.bounds.height - frame.maxY - 4), in: view)
    }
    /// One of the popover's controls or a right-click menu item: counted as `popover_action` (which, and where from),
    /// then done.
    func perform(_ action: HomeAction,from place: String) {
        track?("popover_action", ["action": .word(action.rawValue), "from": .word(place)])
        switch action {
        case .takeBreak: onTakeBreak?()
        case .hide, .show: NotificationCenter.default.post(name: .mokuVisibility,object: nil,userInfo: ["hidden": action == .hide])
        case .putBack: NotificationCenter.default.post(name: .mokuResetHome,object: nil)
        case .settings: openSettings()
        case .hi: closeWorld(); onSayHiAgain?()
        case .feedback: Feedback.compose()
        case .quit: closeWorld(); QuitRequest.send()  // the event goes with the last batch, as Moku quits (after the day's goodbye, if any)
        }
    }
    /// A click on Moku: the same.
    func openWorld() { toggleWorld(from: "moku") }
    /// Opening counts as `popover_opened` (where from, and the milliseconds from the click until it's shown); the reopen
    /// after the screens change doesn't.
    private func toggleWorld(from place: String) {
        if popover.isShown { closeWorld(); return }
        let clickedAt = NSApp.currentEvent?.timestamp ?? ProcessInfo.processInfo.systemUptime
        showWorld()
        if popover.isShown { pendingOpen = (place, clickedAt) }
    }
    /// The popover asked to open (where from, and when the click was), counted once it's shown.
    private var pendingOpen: (from: String, clickedAt: TimeInterval)?
    func popoverDidShow(_ notification: Notification) {
        guard let open = pendingOpen else { return }
        pendingOpen = nil
        let ms = Int(((ProcessInfo.processInfo.systemUptime - open.clickedAt) * 1000).rounded())
        track?("popover_opened", ["from": .word(open.from), "ms": .int(max(0, ms))])
    }
    func showWorld() {
        guard !popover.isShown, let button = item.button else { return }
        // Everything built since you last looked lands piece by piece; a new day's house starts from the empty plot.
        let seen = UserDefaults.standard.string(forKey: Self.houseSeen)?.split(separator: "|")
        let previous = seen?.count == 2 && String(seen![0]) == TodayModel.key(Date()) ? Double(seen![1]) : 0
        scene.open(points: Double(model.snapshot.todayFocusMinutes),from: previous)
        state.permissions = permissionStatus?()
        onOpen?()  // fresh numbers: when they differ, the new pieces land as they arrive
        if state.celebration != nil && !state.manualControl { scene.celebrate(for: 3) }
        popover.contentSize.height = min(HomeView.height,(button.window?.screen?.visibleFrame.height ?? 800)-40)
        // Moku becomes active first, so the popover opens in front and takes Escape; the icon opens the popover and nothing
        // else (ActivateOnly).
        let anchor = anchor(for: button)
        ActivateOnly.activate(keeping: [button.window]) {
            popover.show(relativeTo: anchor.rect,of: anchor.view,preferredEdge: anchor.edge)
            popover.contentViewController?.view.window?.makeKey()
        }
        openedAt = Date()
        dismissMonitors = [
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }  // Escape
                MainActor.assumeIsolated { self?.closeWorld() }
                return nil
            },
            // A click in another of Moku's windows (Your day, Settings). The menu bar icon and Moku itself open and
            // close it on their own.
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown,.rightMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let window = event.window, window !== self.popover.contentViewController?.view.window,
                          window !== self.item.button?.window, !(window is OverlayPanel) else { return }
                    self.closeWorld()
                }
                return event
            },
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown,.rightMouseDown]) { [weak self] _ in MainActor.assumeIsolated { self?.closeWorld() } },
        ].compactMap { $0 }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,object: nil,queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, Date().timeIntervalSince(self.openedAt) > 1 { self.closeWorld() } }
        }
    }
    /// What a window is, for `keepsBehind`.
    struct WindowFacts: Equatable { var visible: Bool; var companion: Bool; var level: Int; var excepted: Bool }
    /// Whether a window of Moku's would be pulled forward by the activation the popover needs: only when Moku isn't
    /// active (it's behind another app), only a visible window, never the companion's panels (they float on their own)
    /// or the menu bar icon, and nothing above the alert level (the popover, menus).
    static func keepsBehind(_ window: WindowFacts, appActive: Bool) -> Bool {
        !appActive && window.visible && !window.companion && !window.excepted && window.level <= NSWindow.Level.modalPanel.rawValue
    }
    static func windowsToKeepBehind(_ windows: [NSWindow], appActive: Bool, except: [NSWindow?]) -> [NSWindow] {
        windows.filter { window in
            keepsBehind(WindowFacts(visible: window.isVisible, companion: window is OverlayPanel, level: window.level.rawValue,
                                    excepted: except.contains { $0 === window }), appActive: appActive)
        }
    }
    /// The menu bar icon, or Moku itself when the icon can't be seen (a menu bar that hides, an icon behind the notch):
    /// a popover tied to a hidden icon has nowhere to show. Only a Moku on this desktop, though: over a full-screen app
    /// it isn't (OverlayPanel), and a popover tied to it would show on another desktop.
    private func anchor(for button: NSStatusBarButton) -> (view: NSView, rect: CGRect, edge: NSRectEdge) {
        if iconFrame != nil { return (button, button.bounds, .minY) }
        if let moku = VisualSessionState.shared.character, moku.window?.occlusionState.contains(.visible) == true, !VisualSessionState.shared.mokuHidden {
            return (moku, moku.characterRect, .minX)
        }
        return (button, button.bounds, .minY)
    }
    /// The menu bar icon on screen, or nil while it can't be seen (a full menu bar hides some icons behind the notch;
    /// a hidden menu bar). The welcome folds into it.
    var iconFrame: CGRect? {
        guard let window = item.button?.window, NSMenu.menuBarVisible(), window.occlusionState.contains(.visible),
              NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else { return nil }
        return window.frame
    }
    /// The menu bar icon as it's drawn now, in the menu bar's own ink, at four times its size: the welcome's spotlight
    /// pulses a copy of it in place, over the real one.
    var iconPicture: CGImage? {
        guard let button = item.button, let image = button.image else { return nil }
        var ink = NSColor.black
        button.effectiveAppearance.performAsCurrentDrawingAppearance { ink = NSColor.labelColor.usingColorSpace(.sRGB) ?? .black }
        let side = 72, rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        context.setBlendMode(.sourceIn); context.setFillColor(ink.cgColor); context.fill(rect)
        return context.makeImage()
    }
    /// Where the house itself is drawn on screen: the button's image, centred in a button wider than it (26 points, and
    /// as tall as the menu bar, which is taller beside a notch). The spotlight centres on this, not on the button.
    var iconImageFrame: CGRect? {
        guard iconFrame != nil, let button = item.button, let window = button.window, let cell = button.cell else { return nil }
        return window.convertToScreen(button.convert(cell.imageRect(forBounds: button.bounds), to: nil))
    }
    /// Hides the real icon while the spotlight's copy of it pulses (one house, not two), and shows it again.
    func setIconShown(_ shown: Bool) { item.button?.alphaValue = shown ? 1 : 0 }
    func closeWorld() { popover.performClose(nil); scene.close() }
    func celebrate(_ stage: ForestStage) { state.queueCelebration(stage); updateIcon() }
    /// What you've seen built ("YYYY-MM-DD|minutes"), so the popover lands only what's new.
    static let houseSeen = "MokuVisual.houseSeen"
    func popoverDidClose(_ notification: Notification) {
        if pendingOpen != nil { pendingOpen = nil }
        if Date().timeIntervalSince(openedAt) < 1 { count?(.popoverBlink) }  // opened and shut at once
        dismissMonitors.forEach(NSEvent.removeMonitor); dismissMonitors = []
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        defer { if reopenOnClose { reopenOnClose = false; showWorld() } }
        UserDefaults.standard.set("\(TodayModel.key(Date()))|\(scene.displayedPoints)",forKey: Self.houseSeen)
        scene.close(); state.celebrating = false; state.celebration = nil; updateIcon()
    }
    /// Your day, counted as `day_opened` with where from: "popover" (its button), "popover_house" or "popover_numbers"
    /// (the house, or today's three numbers under it), "menu" (a right-click menu: the menu bar icon's or the companion's) or
    /// "link" (moku://day).
    func openToday(from place: String) {
        showToday()
        track?("day_opened", ["from": .word(place)])
    }
    /// Your day, at `day` (nil: today).
    func showToday(day: Date? = nil) {
        closeWorld()
        if today == nil { today = TodayPresenter(world: model,provider: { [weak self] date in await self?.todayProvider?(date) },days: { [weak self] from,to in await self?.daysProvider?(from,to) },correction: { [weak self] ids,work in self?.onCorrection?(ids,work) }); today?.track = track }
        today?.open()
        if let day { today?.select(day) }
    }
    func openSettings(_ tab: SettingsTab? = nil) {
        closeWorld()
        if settings == nil { settings = SettingsPresenter() }
        settings?.model.permissionStatus = permissionStatus
        settings?.model.requestPermission = requestPermission
        settings?.model.loadConfig = { [weak self] in await self?.loadConfig?() }
        settings?.model.saveConfig = { [weak self] patch in await self?.saveConfig?(patch) }
        settings?.model.loadAccess = { [weak self] in await self?.loadAccess?() }
        settings?.model.redeemInvite = { [weak self] code in await self?.redeemInvite?(code) ?? .failure(InviteError("Moku isn’t ready yet. Try again in a moment?")) }
        settings?.model.startCheckout = { [weak self] plan in await self?.startCheckout?(plan) ?? .failure(InviteError("Moku isn’t ready yet. Try again in a moment?")) }
        settings?.model.deleteData = { [weak self] in
            let done = await self?.deleteData?() ?? false
            if done { self?.today?.forgetShownDays() }  // Your day, if it's open, shows the fresh start too
            return done
        }
        settings?.model.checkForUpdates = checkForUpdates
        settings?.model.updateStatus = updateStatus
        settings?.model.track = track
        settings?.open(tab)
    }
}

extension ForestStage { var title: String { homeTitle } }
let paper = Color(red: 0.975,green: 0.963,blue: 0.934)
let ink = Color(red: 0.23,green: 0.29,blue: 0.23)
let sage = Color(red: 0.54,green: 0.62,blue: 0.47)
let oat = Color(red: 0.85,green: 0.80,blue: 0.71)
func minutesText(_ minutes: Int) -> String { minutes < 60 ? "\(minutes)m" : "\(minutes/60)h"+(minutes%60 == 0 ? "" : " \(minutes%60)m") }
func stoneText(_ stone: StoneMemory) -> String {
    let away = stone.driftSeconds < 60 ? "\(max(1, stone.driftSeconds)) s" : "\(stone.driftSeconds / 60) min"  // a 4 s glance isn't "1 min"
    return "\(stone.ts.formatted(date: .omitted,time: .shortened)) · back from \(stone.from) after \(away) · then \(stone.followingFocusMinutes) min"+(stone.threadTitle.map { " on \($0)" } ?? "")
}

/// The popover: a glance at the day. Today's house and how much is built, today in three numbers (the house and the
/// numbers open Your day), "Your day →", then three controls (Break · Hide · Settings) with the rest under "···".
struct HomeView: View {
    let model: WorldModel; let state: ForestPresentation; let scene: HomeScene
    var onManualControl: (Bool)->Void = { _ in }
    /// Your day, and where from: "popover" (the button), "popover_house" or "popover_numbers".
    var onToday: (String)->Void = { _ in }
    /// The three controls, and what "···" holds.
    var onAction: (HomeAction)->Void = { _ in }
    var onMore: (CGRect)->Void = { _ in }
    var onPermissions: ()->Void = {}
    /// Opens Settings (General, where the brain's access and the invite code are).
    var onSettings: ()->Void = {}
    var snapshot: WorldSnapshot { model.snapshot }
    /// The popover's fixed height: everything fits, nothing scrolls (the house takes what the rest leaves).
    static let height: CGFloat = 620
    var body: some View {
        VStack(spacing: 0) {
            HomeSceneView(scene: scene)
                .frame(maxWidth: .infinity,minHeight: 180,maxHeight: .infinity).clipped()
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading,spacing: 2) {
                        HStack(spacing: 8) {
                            Text(DayHouse.names.home.uppercased()).font(.system(size: 10,weight: .semibold)).tracking(2).opacity(0.85)
                            // Moku is in beta. Beside the label, over open sky (the corner has the sun or the moon).
                            Text("BETA").font(.system(size: 8,weight: .bold)).tracking(1.4)
                                .padding(.horizontal,6).padding(.vertical,2).overlay(Capsule().stroke(.white.opacity(0.7),lineWidth: 0.8))
                        }
                        Text(DayHouse.stages[DayHouse.stage(scene.displayedPoints)].name).font(.system(size: 22,weight: .medium,design: .serif))
                    }.foregroundStyle(.white).shadow(color: .black.opacity(0.3),radius: 6).padding(16).allowsHitTesting(false)
                }
                // The house opens Your day ("Skip", while pieces land, is a button of its own and keeps its click).
                .contentShape(Rectangle()).onTapGesture { onToday("popover_house") }
                .pointerStyle(.link).help("Open Your day")
                .accessibilityAction(named: "Open Your day") { onToday("popover_house") }
            VStack(alignment: .leading,spacing: 12) {
                HouseProgress(minutes: scene.displayedPoints)
                DayGlance(focused: snapshot.todayFocusMinutes,returns: snapshot.todayReturns,longest: snapshot.longestFocusMinutesToday) { onToday("popover_numbers") }
                if let line = state.thinking.line {
                    HStack(alignment: .firstTextBaseline,spacing: 6) {
                        Label(line,systemImage: "cloud").lineLimit(2)
                        // A trial that has ended is the one status with something to do: the invite code is in Settings.
                        if state.thinking == .accessRefused { Spacer(minLength: 4); Button("Settings",action: onSettings).buttonStyle(.plain).underline() }
                    }.font(.system(size: 11)).quiet()
                }
                // Without Accessibility Moku is nearly blind: one quiet line, never a prompt (it asks only in the welcome).
                if state.permissions?.accessibility == false {
                    HStack(spacing: 6) {
                        Label("Moku can’t see much of what you’re doing.",systemImage: "eye.slash").lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Turn on…",action: onPermissions).buttonStyle(.plain).underline()
                    }.font(.system(size: 11)).quiet()
                }
                RecentActivities(threads: snapshot.threads)
                Button { onToday("popover") } label: {
                    HStack(spacing: 8) { Text("Your day").font(.system(size: 15,weight: .semibold,design: .serif)); Image(systemName: "arrow.right").font(.system(size: 12,weight: .semibold)) }
                        .foregroundStyle(.white).padding(.horizontal,16).padding(.vertical,9).frame(maxWidth: .infinity)
                        .background(LinearGradient(colors: [sage,Color(red: 0.43,green: 0.52,blue: 0.37)],startPoint: .top,endPoint: .bottom),in: RoundedRectangle(cornerRadius: 10))
                        .shadow(color: sage.opacity(0.35),radius: 6,y: 2)
                }.buttonStyle(.plain).keyboardShortcut(.defaultAction)
                HomeControls(onBreak: state.onBreak,hidden: VisualSessionState.shared.mokuHidden,name: Companion.current.name,onAction: onAction,onMore: onMore)
            }
            .padding(.horizontal,18).padding(.top,14).padding(.bottom,12)
        }
        .frame(width: 370,height: Self.height).background(paper).foregroundStyle(ink).preferredColorScheme(.light)
    }
}

/// Today in three numbers, as Your day has them: focused · returns · longest. A click opens Your day.
struct DayGlance: View {
    let focused: Int; let returns: Int; let longest: Int
    var onOpen: ()->Void = {}
    @State private var hovering = false
    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline,spacing: 0) {
                figure(minutesText(focused),"focused")
                separator
                figure("\(returns)",returns == 1 ? "return" : "returns")
                separator
                figure(minutesText(longest),"longest")
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.system(size: 10,weight: .semibold)).quiet()
            }
            .padding(.horizontal,12).padding(.vertical,7)
            .background(sage.opacity(hovering ? 0.2 : 0.12),in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).pointerStyle(.link).help("Open Your day")
        .onHover { hovering = $0 }.animation(.easeOut(duration: 0.12),value: hovering)
        .accessibilityLabel("Today: \(minutesText(focused)) focused, \(returns) \(returns == 1 ? "return" : "returns"), longest stretch \(minutesText(longest)). Open Your day")
    }
    func figure(_ value: String,_ label: String) -> some View {
        HStack(alignment: .firstTextBaseline,spacing: 4) {
            Text(value).font(.system(size: 15,weight: .medium,design: .serif)).monospacedDigit()
            Text(label).font(.system(size: 11)).quiet()
        }
    }
    var separator: some View { Text("·").font(.system(size: 13)).quiet().padding(.horizontal,7) }
}

/// The popover's controls: Break, Hide (or Show) and Settings, labelled, with the rest under "···" (the same list
/// as the right-click menu on the menu bar icon). "···" asks the presenter for an AppKit menu under it (`onMore`, with its
/// frame in the window): a SwiftUI Menu here closed at once the first time (2026-10-08), when Moku became active a moment
/// after the popover opened or the popover redrew with its fresh numbers.
struct HomeControls: View {
    let onBreak: Bool; let hidden: Bool; let name: String
    var onAction: (HomeAction)->Void = { _ in }
    var onMore: (CGRect)->Void = { _ in }
    @State private var moreFrame = CGRect.zero
    var body: some View {
        HStack(spacing: 6) {
            control(.takeBreak,onBreak ? "End break" : "Break",icon: onBreak ? "sun.max" : "cup.and.saucer")
            control(hidden ? .show : .hide,"\(hidden ? "Show" : "Hide") \(name)",icon: hidden ? "eye" : "eye.slash")
            control(.settings,"Settings",icon: "gearshape")
            Button { onMore(moreFrame) } label: { Image(systemName: "ellipsis").font(.system(size: 12,weight: .medium)).frame(width: 34,height: 30)
                .background(oat.opacity(0.35),in: RoundedRectangle(cornerRadius: 9)).contentShape(RoundedRectangle(cornerRadius: 9)) }
                .buttonStyle(.plain).help("More: say hi again, put \(name) back, feedback, quit").accessibilityLabel("More")
                .background(GeometryReader { proxy in Color.clear.onAppear { moreFrame = proxy.frame(in: .global) }.onChange(of: proxy.frame(in: .global)) { moreFrame = $1 } })
        }
    }
    func control(_ action: HomeAction,_ label: String,icon: String) -> some View {
        Button { onAction(action) } label: {
            HStack(spacing: 5) { Image(systemName: icon).font(.system(size: 11,weight: .medium)); Text(label).lineLimit(1) }
                .font(.system(size: 12,weight: .medium)).frame(maxWidth: .infinity).frame(height: 30)
                .background(oat.opacity(0.35),in: RoundedRectangle(cornerRadius: 9)).contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
}

/// How much of the day's house is built: the percentage, a bar with a notch per piece and a mark per stage, the
/// stages, and the next piece.
struct HouseProgress: View {
    /// The minutes the house is shown at (it climbs as pieces land).
    let minutes: Double
    /// The day's real focused minutes, for "2h 29m of 4h".
    var focusedMinutes: Int? = nil
    var body: some View {
        let pct = DayHouse.percent(minutes), fraction = DayHouse.fraction(minutes), stage = DayHouse.stage(minutes)
        VStack(alignment: .leading,spacing: 6) {
            HStack(alignment: .firstTextBaseline,spacing: 6) {
                Text("\(pct)%").font(.system(size: 26,weight: .semibold,design: .serif)).monospacedDigit().contentTransition(MotionPreference.reduced ? .identity : .numericText()).animation(MotionPreference.reduced ? nil : .snappy,value: pct)
                Text(pct >= 100 ? "built · finished for today" : "built").font(.system(size: 13,design: .serif)).quiet()
                Spacer()
                if let focusedMinutes { Text("\(minutesText(focusedMinutes)) of \(minutesText(Int(DayHouse.goalMinutes)))").font(.system(size: 11)).quiet().monospacedDigit() }
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.opacity(0.08))
                    Capsule().fill(LinearGradient(colors: [Color(red: 0.62,green: 0.74,blue: 0.50),Color(red: 0.42,green: 0.64,blue: 0.62)],startPoint: .leading,endPoint: .trailing))
                        .frame(width: fraction > 0 ? max(10,width * fraction) : 0)
                        .shadow(color: Color(red: 0.45,green: 0.68,blue: 0.60).opacity(0.55),radius: 5)
                        .animation(MotionPreference.reduced ? .easeOut(duration: 0.2) : .spring(response: 0.45,dampingFraction: 0.8),value: fraction)  // (Reduce Motion: no overshoot)
                    ForEach(1..<DayHouse.pieces,id: \.self) { i in
                        let stageMark = DayHouse.stages.contains { $0.first == i }
                        Rectangle().fill(Color.white.opacity(stageMark ? 0.9 : 0.45)).frame(width: stageMark ? 1.5 : 1,height: stageMark ? 10 : 4)
                            .offset(x: width * CGFloat(i) / CGFloat(DayHouse.pieces))
                    }
                }
            }.frame(height: 10).accessibilityHidden(true)
            GeometryReader { geometry in
                ForEach(DayHouse.stages.indices,id: \.self) { i in
                    let from = CGFloat(DayHouse.stages[i].first), to = CGFloat(i + 1 < DayHouse.stages.count ? DayHouse.stages[i + 1].first : DayHouse.pieces)
                    Text(DayHouse.stages[i].name.replacingOccurrences(of: "The ",with: "").capitalized)
                        .font(.system(size: 10,weight: i == stage ? .semibold : .regular)).quiet(.dimmed, unless: i <= stage)
                        .position(x: geometry.size.width * (from + to) / 2 / CGFloat(DayHouse.pieces),y: 6)
                }
            }.frame(height: 12)
            Text(DayHouse.next(minutes).map { "Next: \($0.name), in \($0.minutes) focused min" } ?? DayHouse.names.finished ?? "Moku’s home is finished for today. Come see it in Your day.")
                .font(.system(size: 11)).quiet().lineLimit(1)
        }
        .accessibilityElement(children: .combine).accessibilityLabel("\(DayHouse.names.home): \(pct) percent built")
    }
}

/// The last three things worked on (the most recent threads), each with when and today's focus on it.
struct RecentActivities: View {
    let threads: [ThreadSummary]
    var body: some View {
        let recent = Array(threads.sorted { $0.lastActiveAt > $1.lastActiveAt }.prefix(3))
        if !recent.isEmpty {
            VStack(alignment: .leading,spacing: 6) {
                Text("RECENTLY").font(.system(size: 10,weight: .semibold)).tracking(1.5).quiet()
                ForEach(recent,id: \.id) { thread in
                    HStack(alignment: .firstTextBaseline,spacing: 8) {
                        Circle().fill(sage.opacity(0.7)).frame(width: 5,height: 5)
                        Text(thread.title).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(thread.focusMinutesToday > 0 ? minutesText(thread.focusMinutesToday) : thread.lastActiveAt.formatted(.relative(presentation: .numeric,unitsStyle: .abbreviated)))
                            .font(.system(size: 11)).quiet().monospacedDigit()
                    }
                }
            }
        }
    }
}
@MainActor public enum MokuVisualDiagnostics {
    /// Look development: the popover with today's house at several points in the day (popover-<minutes>.png); at 150
    /// minutes also without Accessibility, on a break with Moku hidden, and on a Mac in dark mode (the popover stays
    /// light); the break timer pill (break-timer.png).
    public static func popoverLook(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let now = Date()
        let threads = [ThreadSummary(id: "a",title: "Building Moku app",summary: "",focusMinutesToday: 82,focusMinutesTotal: 600,lastActiveAt: now.addingTimeInterval(-120)),
                       ThreadSummary(id: "b",title: "Designing the landing page",summary: "",focusMinutesToday: 25,focusMinutesTotal: 90,lastActiveAt: now.addingTimeInterval(-3600)),
                       ThreadSummary(id: "c",title: "Writing the onboarding doc",summary: "",focusMinutesToday: 0,focusMinutesTotal: 40,lastActiveAt: now.addingTimeInterval(-86_400))]
        VisualSessionState.shared.workState = .focused
        for minutes in [25, 150, 245] {
            var world = sampleWorld(hours: 20,today: minutes,returns: 4); world.threads = threads
            let scene = HomeScene(); scene.open(points: Double(minutes))
            while !scene.hasFrame && scene.error == nil { try await Task.sleep(for: .milliseconds(100)) }
            try await Task.sleep(for: .milliseconds(600))
            let view = NSHostingView(rootView: HomeView(model: WorldModel(snapshot: world),state: ForestPresentation(),scene: scene)); view.frame = CGRect(x: 0,y: 0,width: 370,height: HomeView.height)
            try NSBitmapImageRep(cgImage: ReviewCapture.view(view)).representation(using: .png,properties: [:])!.write(to: directory.appendingPathComponent("popover-\(minutes).png"))
            if minutes == 150 {  // and the quiet line when Accessibility is off
                let blind = ForestPresentation(); blind.permissions = PermissionStatus(accessibility: false,screenRecording: false)
                let line = NSHostingView(rootView: HomeView(model: WorldModel(snapshot: world),state: blind,scene: scene)); line.frame = view.frame
                try NSBitmapImageRep(cgImage: ReviewCapture.view(line)).representation(using: .png,properties: [:])!.write(to: directory.appendingPathComponent("popover-no-accessibility.png"))
                // and the controls' other labels: on a break, with Moku hidden
                let resting = ForestPresentation(); resting.onBreak = true; VisualSessionState.shared.mokuHidden = true
                let rest = NSHostingView(rootView: HomeView(model: WorldModel(snapshot: world),state: resting,scene: scene)); rest.frame = view.frame
                try NSBitmapImageRep(cgImage: ReviewCapture.view(rest)).representation(using: .png,properties: [:])!.write(to: directory.appendingPathComponent("popover-break-hidden.png"))
                VisualSessionState.shared.mokuHidden = false
                // and on a Mac in dark mode
                let dark = NSHostingView(rootView: HomeView(model: WorldModel(snapshot: world),state: ForestPresentation(),scene: scene)); dark.frame = view.frame
                dark.appearance = NSAppearance(named: .darkAqua)
                try NSBitmapImageRep(cgImage: ReviewCapture.view(dark)).representation(using: .png,properties: [:])!.write(to: directory.appendingPathComponent("popover-dark.png"))
            }
            scene.close()
        }
        let timer = BreakTimerModel(); timer.total = 1200; timer.now = Date(); timer.until = timer.now.addingTimeInterval(1122)
        let pill = NSHostingView(rootView: BreakTimerView(model: timer).padding(20).background(Color(red: 0.36,green: 0.45,blue: 0.55)))
        pill.frame = CGRect(origin: .zero,size: pill.fittingSize)
        try NSBitmapImageRep(cgImage: ReviewCapture.view(pill)).representation(using: .png,properties: [:])!.write(to: directory.appendingPathComponent("break-timer.png"))
        // Tetsu's: the time in dots on its display glass, the row under it going out, amber for the last minute (break-timer-led-<left>.png).
        for (left, name) in [(1122.0, "18-42"), (190.0, "3-10"), (45.0, "0-45")] {
            let led = BreakTimerModel(); led.total = 1200; led.now = Date(); led.until = led.now.addingTimeInterval(left)
            for dark in [false, true] {
                let view = NSHostingView(rootView: LEDBreakTimerView(model: led).padding(20).background(Color(red: dark ? 0.12 : 0.36,green: dark ? 0.13 : 0.45,blue: dark ? 0.15 : 0.55)))
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                view.frame = CGRect(origin: .zero,size: view.fittingSize)
                try NSBitmapImageRep(cgImage: ReviewCapture.view(view)).representation(using: .png,properties: [:])!.write(to: directory.appendingPathComponent("break-timer-led-\(name)\(dark ? "-dark" : "").png"))
            }
        }
    }
    /// Opens the real popover from the menu bar while the app can't become active (the demo runs with activation
    /// prohibited), the way it opens on a Mac that won't let Moku come forward. For AppKit's transient behavior (the old
    /// one) and Moku's own, whether it's still open after 0.1, 0.5 and 1.5 s; then a second click (it closes), a
    /// screen change while open (it opens again), and the right-click menu (it opens, then lets the left click have the
    /// popover again). Writes popover-open.json.
    public static func popoverOpenCheck(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        var world = sampleWorld(hours: 20,today: 150,returns: 4); world.threads = []
        let presenter = MokuWorldPresenter(model: WorldModel(snapshot: world))
        func openFor(_ behavior: NSPopover.Behavior) async throws -> [Bool] {
            presenter.popover.behavior = behavior
            presenter.openWorld()
            var shown: [Bool] = []
            for wait in [100, 400, 1000] { try await Task.sleep(for: .milliseconds(wait)); shown.append(presenter.popover.isShown) }
            presenter.closeWorld(); try await Task.sleep(for: .milliseconds(600))
            return shown
        }
        let transient = try await openFor(.transient)
        let own = try await openFor(.applicationDefined)
        presenter.openWorld(); try await Task.sleep(for: .milliseconds(500))
        presenter.openWorld(); try await Task.sleep(for: .milliseconds(600))
        let secondClickCloses = !presenter.popover.isShown
        presenter.openWorld(); try await Task.sleep(for: .milliseconds(500))
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification,object: nil)
        try await Task.sleep(for: .milliseconds(1500))
        let reopensAfterScreenChange = presenter.popover.isShown
        presenter.closeWorld(); try await Task.sleep(for: .milliseconds(600))
        // The right-click menu on the icon: it opens under the icon (closed again here after a moment), and lets go of the
        // icon once it closes, so the next left click opens the popover again.
        let probe = MenuProbe()
        let close = Timer(timeInterval: 0.8,repeats: false) { _ in MainActor.assumeIsolated {
            probe.trackedAfter08s = !probe.returned && presenter.item.menu != nil
            presenter.item.menu?.cancelTracking()
        } }
        RunLoop.main.add(close,forMode: .common)
        presenter.showMenu()
        probe.returned = true; close.invalidate()
        try await Task.sleep(for: .milliseconds(300))
        let menuLetsGo = presenter.item.menu == nil
        presenter.item.button?.performClick(nil); try await Task.sleep(for: .milliseconds(500))
        let leftClickOpensAfterMenu = presenter.popover.isShown
        presenter.closeWorld(); try await Task.sleep(for: .milliseconds(600))
        // What the menu holds, and what "···" holds; and what an item sends (say hi, which only closes the popover here).
        let menu = presenter.controlsMenu().items.map { $0.isSeparatorItem ? "—" : $0.title }
        let more = HomeAction.more.map { $0.map { $0.title(onBreak: false,name: Companion.current.name) } }
        var sent: [String] = []
        presenter.track = { name,props in sent.append(([name]+props.keys.sorted().map { key in if case let .word(word)? = props[key] { "\(key)=\(word)" } else { "\(key)=?" } }).joined(separator: " ")) }
        presenter.perform(.hi,from: "menu")
        let report: [String: Any] = ["appActive": NSApp.isActive, "transientShownAt_0.1_0.5_1.5s": transient, "ownShownAt_0.1_0.5_1.5s": own,
                                     "secondClickCloses": secondClickCloses, "reopensAfterScreenChange": reopensAfterScreenChange,
                                     "rightClickMenuOpens": probe.trackedAfter08s, "rightClickMenuLetsGo": menuLetsGo,
                                     "leftClickOpensAfterMenu": leftClickOpensAfterMenu,
                                     "rightClickMenu": menu, "moreMenu": more, "sayHiSends": sent]
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("popover-open.json"))
    }
    public static func captureWorld(model: WorldModel,to url: URL) throws {
        let state = ForestPresentation(); state.ingest(model.snapshot.growthPoints)
        let view = NSHostingView(rootView: HomeView(model: model,state: state,scene: HomeScene())); view.frame = CGRect(x: 0,y: 0,width: 370,height: HomeView.height)
        try NSBitmapImageRep(cgImage: ReviewCapture.view(view)).representation(using: .png,properties: [:])!.write(to: url)
    }
}

/// What popoverOpenCheck saw of the right-click menu: whether it was still open, under the icon, after 0.8 s.
@MainActor private final class MenuProbe { var returned = false; var trackedAfter08s = false }

/// Feedback, questions or complaints: an email to hello@hellomoku.com, which reaches Charles, with the version filled in.
enum Feedback {
    static let address = "hello@hellomoku.com"
    static func compose() {
        var mail = URLComponents(); mail.scheme = "mailto"; mail.path = address
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        mail.queryItems = [URLQueryItem(name: "subject", value: "Moku feedback"),
                           URLQueryItem(name: "body", value: "\n\n—\nMoku \(version) beta · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")]
        if let url = mail.url { NSWorkspace.shared.open(url) }
    }
}
