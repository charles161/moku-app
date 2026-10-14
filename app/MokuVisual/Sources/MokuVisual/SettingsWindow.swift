import AppKit
import SwiftUI
import Observation
import ServiceManagement
import MokuKit

/// Moku's settings in UserDefaults, with their defaults.
enum MokuPreferences {
    /// The person chose "Hide Moku" (the right-click menu); "Show Moku" in the popover brings it back.
    static let hiddenKey = "MokuVisual.hiddenByPerson"
    static let captionGapKey = "MokuVisual.captionGap"
    static let defaultCaptionGap: CGFloat = 6
    /// How far above Moku's head the caption sits, in points.
    static func captionGap(in store: UserDefaults) -> CGFloat {
        store.object(forKey: captionGapKey) == nil ? defaultCaptionGap : CGFloat(store.double(forKey: captionGapKey))
    }
    static let speechGapKey = "MokuVisual.speechGap"
    static let defaultSpeechGap: CGFloat = 6
    /// How far above Moku's head its speech bubble sits, in points.
    static func speechGap(in store: UserDefaults) -> CGFloat {
        store.object(forKey: speechGapKey) == nil ? defaultSpeechGap : CGFloat(store.double(forKey: speechGapKey))
    }
    /// One behaviour for everyone (Charles, 2026-10-04: "there should be just one behaviour"): about how often, in seconds,
    /// an ear flicks and a paw, a foot, the head or the body moves a little while it sits quietly. Each wait varies by a
    /// third either way. These were Settings' "While it sits quietly" (Calm, Normal, Lively): Normal is what's left.
    static let earFlickEvery: Double = 20
    static let fidgetEvery: Double = 25
    /// What the Calm / Lively choice and its sliders saved in UserDefaults. Cleared at launch (`retireBehaviourChoices`).
    static let retiredKeys = ["MokuVisual.earFlickEvery", "MokuVisual.fidgetEvery"]
    /// Removes the saved liveliness, so someone who had chosen Calm or Lively gets the one behaviour. Nothing else in the
    /// store is touched (the size, the companion, hiding, the login offer and every other setting stay).
    static func retireBehaviourChoices(in store: UserDefaults) { retiredKeys.forEach(store.removeObject(forKey:)) }
    static let sizeKey = "MokuVisual.size"
    static let defaultSize: CGFloat = 1
    /// What Settings calls 1× is drawn at this much of the companion's full size (the friends, 2026-10-14: "cuteness
    /// wins"; it was 1 before).
    static let standardScale: CGFloat = 0.87
    /// Settings › Size as chosen: 1 is the standard, from 0.25 up to 1.25 times.
    static func setting(in store: UserDefaults) -> CGFloat {
        let size = store.object(forKey: sizeKey) == nil ? defaultSize : CGFloat(store.double(forKey: sizeKey))
        return min(max(size, StageGeometry.scales.lowerBound), StageGeometry.scales.upperBound)
    }
    /// The scale the companion is drawn at: the setting times `standardScale`.
    static func size(in store: UserDefaults) -> CGFloat { setting(in: store) * standardScale }
}

extension Notification.Name {
    static let mokuCaptionMoved = Notification.Name("MokuVisual.captionMoved")
    static let mokuResized = Notification.Name("MokuVisual.resized")
    static let mokuSpeechMoved = Notification.Name("MokuVisual.speechMoved")
    /// "Hide Moku" / "Show Moku": userInfo["hidden"] is a Bool.
    static let mokuVisibility = Notification.Name("MokuVisual.visibility")
}

/// What Settings shows and changes. Timings and the name live in the brain's config: edits show at once and are saved
/// a moment later, one save at a time, the newest edit winning. Size and sharing are local preferences.
@MainActor @Observable final class SettingsModel {
    var config: CompanionConfig?
    /// Who keeps the person company: Settings says its name wherever it means the companion (not the app).
    var companion = Companion.current
    /// As typed, saved when you press Return or leave the field.
    var name = ""
    /// Water and breaks can be turned off (0 in the config); the minutes are kept for when they're turned back on.
    var drinkOn = true
    var drinkMinutes = 30
    var breakOn = true
    var breakAfterMinutes = 50
    var breakMinutes = 20
    static let drinkRange = 10...120, breakAfterRange = 15...180, breakRange = 5...60
    var saveProblem: String?
    var access: AccessStatus?
    var inviteMessage = ""
    var redeeming = false
    /// Moku Pro's checkout, and then the wait for the payment to land (docs/specs/payments.md).
    var proMessage = ""
    var deleting = false
    var dataMessage = ""
    var loginMessage: String?
    /// The apps Moku never watches (Privacy). Kept in `preferences`; the senses read the same list.
    var ignoredApps = IgnoredApps.load().apps
    @ObservationIgnored var preferences: UserDefaults = .standard
    /// Sparkle's "Check for updates…"; nil in development builds (no update feed).
    var checkForUpdates: (@MainActor () -> Void)?
    /// How the last update check went ("Up to date (checked at 10:17).", or why it failed and when Moku tries again).
    var updateStatus: String?
    var permissions: PermissionStatus?
    @ObservationIgnored var permissionStatus: (@MainActor () -> PermissionStatus)?
    @ObservationIgnored var requestPermission: (@MainActor (PermissionKind) -> Void)?
    /// Records usage events: a setting changed (its name only), a permission turned on from here.
    @ObservationIgnored var track: UsageTracker?
    /// When each permission was last asked for here ("Turn on…"): `permission_answered` says how many seconds it took.
    @ObservationIgnored private var askedAt: [String: Date] = [:]
    /// "Turn on…": macOS's prompt the first time, then the right page of System Settings.
    func ask(_ kind: PermissionKind) {
        askedAt[kind == .accessibility ? "accessibility" : "screen"] = Date()
        requestPermission?(kind)
    }
    /// Reads the permissions again. One that turned on while Settings was open (back from System Settings after
    /// "Turn on…") is a `permission_answered`, with the seconds since it was asked for.
    func refreshPermissions(whileOpen: Bool = false) {
        guard let status = permissionStatus?(), status != permissions else { return }
        if whileOpen, let before = permissions {
            for (kind, was, now) in [("accessibility", before.accessibility, status.accessibility), ("screen", before.screenRecording, status.screenRecording)] where !was && now {
                var props: [String: UsageValue] = ["kind": .word(kind), "granted": .bool(true), "where": .word("settings")]
                if let asked = askedAt.removeValue(forKey: kind) { props["seconds"] = .int(max(0, Int(Date().timeIntervalSince(asked)))) }
                track?("permission_answered", props)
            }
        }
        permissions = status
    }
    /// A setting changed: its name only, never its value; for a switch, whether it went on or off. With the values before
    /// and after (kept here, never sent), whether it stays changed for 5 minutes or is changed back (`setting_outcome`).
    func settingChanged(_ key: String, turned on: Bool? = nil, from old: String? = nil, to new: String? = nil) {
        var props: [String: UsageValue] = ["key": .word(key)]
        if let on { props["turned"] = .word(on ? "on" : "off") }
        track?("setting_changed", props)
        if let old, let new { outcomes.changed(key, from: old, to: new) }
    }
    /// Kept or changed back within 5 minutes, for each setting changed here.
    @ObservationIgnored lazy var outcomes = SettingOutcomes { [weak self] key, outcome, seconds in
        self?.track?("setting_outcome", ["key": .word(key), "outcome": .word(outcome), "seconds": .int(seconds)])
    }
    /// How long screen text is kept: an hour, or 14 days in Charles's calibration build (BrainSupervisor.calibrating).
    var screenTextKept: String {
        Bundle.main.object(forInfoDictionaryKey: "MokuCalibrate") as? Bool == true
            ? "This calibration build keeps screen text 14 days, so your ratings can be replayed."
            : "Screen text is deleted within an hour."
    }
    /// What Moku can and can't do with the permissions it has, said plainly.
    var permissionsNote: String {
        switch (permissions?.accessibility, permissions?.screenRecording) {
        case (true, true): "Moku never asks by itself. Either one can be turned off in System Settings › Privacy & Security."
        case (true, false): "Without Screen Recording, Moku goes by the app, the window’s name and the web address. That’s enough most of the time. After you turn it on, macOS asks to quit and reopen Moku."
        case (false, true): "Without Accessibility, Moku can’t see web addresses or how busy your typing is, so it’s less sure what’s work."
        case (false, false): "Moku can see only which app you’re in, so it can’t tell work from a detour very well."
        default: ""
        }
    }
    @ObservationIgnored var loadConfig: (@MainActor () async -> CompanionConfig?)?
    @ObservationIgnored var saveConfig: (@MainActor (CompanionConfigPatch) async -> CompanionConfig?)?
    @ObservationIgnored var loadAccess: (@MainActor () async -> AccessStatus?)?
    @ObservationIgnored var redeemInvite: (@MainActor (String) async -> Result<AccessStatus, InviteError>)?
    /// Opens Dodo's checkout for a plan (`monthly` or `yearly`) in the browser; the app then renews until Pro arrives.
    @ObservationIgnored var startCheckout: (@MainActor (String) async -> Result<Void, InviteError>)?
    /// How often Settings looks for Pro after a checkout opened (30 times).
    @ObservationIgnored var proCheckEvery: Duration = .seconds(30)
    @ObservationIgnored private var proWait: Task<Void, Never>?
    @ObservationIgnored var deleteData: (@MainActor () async -> Bool)?
    @ObservationIgnored private var pending: CompanionConfigPatch?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var saving = false
    /// Bumps on every edit: a load or a save that answers after a newer edit doesn't overwrite it.
    @ObservationIgnored private var edits = 0
    /// The name the field last showed from the brain: a field that differs is being typed in (it saves on Return or on
    /// leaving it), and a reload (Settings opened again) leaves it alone.
    @ObservationIgnored private var shownName = ""

    /// The plan and the config side by side; the config once more if the brain was still starting.
    func load() async {
        let before = edits
        async let plan = loadAccess?()
        async let loaded = loadConfig?()
        let (status, first) = await (plan, loaded)
        access = status
        var config = first
        if config == nil { try? await Task.sleep(for: .seconds(2)); config = await loadConfig?() }
        guard let config else { saveProblem = "Moku’s brain isn’t answering yet, so these can’t be changed right now."; return }
        saveProblem = nil
        if edits == before { show(config) }
    }

    private func show(_ config: CompanionConfig) {
        self.config = config
        func minutes(_ seconds: Double, _ range: ClosedRange<Int>) -> Int { min(max(Int((seconds / 60).rounded()), range.lowerBound), range.upperBound) }
        let served = config.userName.lowercased() == "friend" ? "" : config.userName
        if name == shownName { name = served }
        shownName = served
        drinkOn = config.drinkEverySec > 0
        if drinkOn { drinkMinutes = minutes(config.drinkEverySec, Self.drinkRange) }
        breakOn = config.breakAfterSec > 0
        if breakOn { breakAfterMinutes = minutes(config.breakAfterSec, Self.breakAfterRange) }
        breakMinutes = minutes(config.teaBreakMaxSec, Self.breakRange)
    }

    /// The name is made safe for the brain (one line, 60 UTF-16 units at most, never half an emoji; it refused the rest, and
    /// Settings said "the brain isn't answering"). The field shows what was kept. An empty field means no name: "friend".
    func commitName() {
        if let kept = PersonName.clean(name), kept != name { name = kept }
        let cleaned = PersonName.clean(name) ?? PersonName.fallback
        guard cleaned != config?.userName else { return }
        change(CompanionConfigPatch(userName: cleaned))
    }
    func setDrink(_ minutes: Int) { drinkMinutes = minutes; drinkOn = true; change(CompanionConfigPatch(drinkEverySec: Double(minutes * 60))) }
    /// Off is 0: MokuMind never drinks then, and leaves water out of its break suggestions.
    func setDrinkOn(_ on: Bool) { drinkOn = on; change(CompanionConfigPatch(drinkEverySec: on ? Double(drinkMinutes * 60) : 0)) }
    func setBreakAfter(_ minutes: Int) { breakAfterMinutes = minutes; breakOn = true; change(CompanionConfigPatch(breakAfterSec: Double(minutes * 60))) }
    /// Off is 0: no break is suggested (one can still be taken from the menu bar or the companion's menu).
    func setBreakOn(_ on: Bool) { breakOn = on; change(CompanionConfigPatch(breakAfterSec: on ? Double(breakAfterMinutes * 60) : 0)) }
    func setBreak(_ minutes: Int) { breakMinutes = minutes; change(CompanionConfigPatch(teaBreakMaxSec: Double(minutes * 60))) }

    /// Queues an edit: merged with any waiting, saved after a short pause (holding a stepper sends one save).
    private func change(_ patch: CompanionConfigPatch) {
        edits += 1
        pending = pending.map { $0.merged(with: patch) } ?? patch
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() async {
        guard !saving, let patch = pending else { return }
        saving = true; pending = nil
        let edit = edits, before = config
        let saved = await saveConfig?(patch)
        saving = false
        if let saved {
            saveProblem = nil
            for key in patch.changedKeys(from: before) {
                let values = patch.values(key, from: before)
                settingChanged(key, turned: patch.turned(key, from: before), from: values?.old, to: values?.new)
            }
            if edits == edit { config = saved }
        } else {
            saveProblem = "Couldn’t save: Moku’s brain isn’t answering. Try again in a moment?"
        }
        if pending != nil { await flush() }  // edits made while that one was saving
    }

    func redeem(_ code: String) async {
        redeeming = true; defer { redeeming = false }
        switch await redeemInvite?(code) ?? .failure(InviteError("Moku isn’t ready yet. Try again in a moment?")) {
        case let .success(status): access = status; inviteMessage = "Welcome in. Moku’s cloud brain is on."
        case let .failure(error): inviteMessage = error.message
        }
    }

    /// "Get Moku Pro": the checkout opens in the browser, and Settings shows Pro as soon as the payment has landed.
    func getPro(plan: String) async {
        proMessage = ""
        switch await startCheckout?(plan) ?? .failure(InviteError("Moku isn’t ready yet. Try again in a moment?")) {
        case let .failure(error): proMessage = error.message
        case .success:
            proMessage = "The checkout opened in your browser. Moku Pro turns on here by itself once it’s paid."
            proWait?.cancel()
            proWait = Task { [weak self] in
                for _ in 0..<30 {
                    guard let every = self?.proCheckEvery else { return }
                    try? await Task.sleep(for: every)
                    guard !Task.isCancelled, let self else { return }
                    if let status = await loadAccess?() {
                        access = status
                        if status.plan == .pro { proMessage = "Moku Pro is on. Thank you!"; return }
                    }
                }
            }
        }
    }

    func deleteEverything() async {
        track?("frustration", ["signal": .word("delete_data")])
        deleting = true; dataMessage = ""
        let done = await deleteData?() == true
        deleting = false
        dataMessage = done ? "Done. Moku starts fresh from here." : "Moku’s brain isn’t answering. Try again in a moment?"
    }

    /// Opening Moku when you log in to your Mac (a login item).
    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    func setOpensAtLogin(_ on: Bool) {
        settingChanged("open_at_login", turned: on, from: String(!on), to: String(on))
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginMessage = SMAppService.mainApp.status == .requiresApproval ? "Allow Moku in System Settings › General › Login Items." : nil
        } catch {
            loginMessage = "macOS didn’t allow that: \(error.localizedDescription)"
        }
    }
}

extension CompanionConfigPatch {
    /// This patch with `other`'s fields on top.
    func merged(with other: CompanionConfigPatch) -> CompanionConfigPatch {
        var merged = self
        merged.drinkEverySec = other.drinkEverySec ?? drinkEverySec
        merged.teaBreakMaxSec = other.teaBreakMaxSec ?? teaBreakMaxSec
        merged.userName = other.userName ?? userName
        merged.breakAfterSec = other.breakAfterSec ?? breakAfterSec
        merged.companion = other.companion ?? companion
        return merged
    }

    /// The settings this patch changes from `config`, by their snake_case names (for `setting_changed`).
    func changedKeys(from config: CompanionConfig?) -> [String] {
        func changed<T: Equatable>(_ new: T?, _ old: T?) -> Bool { new != nil && new != old }
        let fields: [(String, Bool)] = [
            ("user_name", changed(userName, config?.userName)),
            ("drink_every_sec", changed(drinkEverySec, config?.drinkEverySec)),
            ("tea_break_max_sec", changed(teaBreakMaxSec, config?.teaBreakMaxSec)),
            ("break_after_sec", changed(breakAfterSec, config?.breakAfterSec)),
        ]
        return fields.filter(\.1).map(\.0)
    }

    /// A changed setting's value before and after, as text kept on the Mac to tell a change kept from one undone. Never sent.
    func values(_ key: String, from config: CompanionConfig?) -> (old: String, new: String)? {
        let pair: (String?, String?) = switch key {
        case "user_name": (config?.userName, userName)
        case "drink_every_sec": (config.map { "\($0.drinkEverySec)" }, drinkEverySec.map { "\($0)" })
        case "tea_break_max_sec": (config.map { "\($0.teaBreakMaxSec)" }, teaBreakMaxSec.map { "\($0)" })
        case "break_after_sec": (config.map { "\($0.breakAfterSec)" }, breakAfterSec.map { "\($0)" })
        default: (nil, nil)
        }
        guard let old = pair.0, let new = pair.1 else { return nil }
        return (old, new)
    }

    /// Whether this patch turns water or breaks on or off (0 is off); nil for any other change.
    func turned(_ key: String, from config: CompanionConfig?) -> Bool? {
        let (new, old): (Double?, Double?) = switch key {
        case "drink_every_sec": (drinkEverySec, config?.drinkEverySec)
        case "break_after_sec": (breakAfterSec, config?.breakAfterSec)
        default: (nil, nil)
        }
        guard let new, let old, (new == 0) != (old == 0) else { return nil }
        return new > 0
    }
}

/// Settings' tabs: short pages, each exactly as tall as what's on it (the window grows and shrinks between them).
/// Breaks and water have a tab of their own, where people look for them (Charles didn't find them under Focus).
enum SettingsTab: CaseIterable {
    case general, breaks, privacy
    /// Its word in `settings_opened`.
    var usageWord: String { switch self { case .general: "general"; case .breaks: "breaks"; case .privacy: "privacy" } }
    var title: String { switch self { case .general: "General"; case .breaks: "Breaks & Water"; case .privacy: "Privacy" } }
    /// General's icon is the companion's (a hare for Moku, a chip for Tetsu: there's no robot symbol).
    func symbol(for companion: Companion) -> String {
        switch self { case .general: companion == .tetsu ? "cpu" : "hare"; case .breaks: "cup.and.saucer"; case .privacy: "hand.raised" }
    }
    @MainActor func view(_ model: SettingsModel) -> AnyView {
        switch self {
        case .general: AnyView(GeneralSettings(model: model))
        case .breaks: AnyView(BreakSettings(model: model))
        case .privacy: AnyView(PrivacySettings(model: model))
        }
    }
}

/// The words that differ between companions: Tetsu sips from a battery cell rather than a cup.
extension Companion {
    var sipsWater: String { self == .tetsu ? "tops up from its battery cell" : "has a sip of water" }
}

@MainActor final class SettingsPresenter: NSObject {
    let model = SettingsModel()
    let window: NSWindow
    let tabs = NSTabViewController()
    /// Back from System Settings with a switch flipped: the permissions are read again.
    private var keyObserver: NSObjectProtocol?
    /// Another companion chosen (here or in the welcome): its name and its icon.
    private var companionObserver: NSObjectProtocol?
    /// A tab chosen while the window is open: `settings_opened` (switched).
    private var tabObserver: NSKeyValueObservation?
    private var opening = false
    override init() {
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let host = NSHostingController(rootView: tab.view(model))
            host.sizingOptions = [.preferredContentSize]
            host.title = tab.title  // the window's title is the tab's, as in System Settings
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title; item.image = NSImage(systemSymbolName: tab.symbol(for: model.companion), accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        window = MokuWindow(contentViewController: tabs)
        super.init()
        window.styleMask = [.titled, .closable]; window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false; window.isRestorable = false
        window.center()
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshPermissions(whileOpen: true) }
        }
        companionObserver = NotificationCenter.default.addObserver(forName: .mokuCompanionChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followCompanion() }
        }
        tabObserver = tabs.observe(\.selectedTabViewItemIndex, options: [.new]) { [weak self] _, change in
            guard let index = change.newValue else { return }
            MainActor.assumeIsolated { self?.tabShown(index, how: "switched") }
        }
    }
    /// Which page people reach for: the tab shown when Settings opens, and each one chosen while it's open.
    private func tabShown(_ index: Int, how: String) {
        guard !opening, window.isVisible, SettingsTab.allCases.indices.contains(index) else { return }
        model.track?("settings_opened", ["tab": .word(SettingsTab.allCases[index].usageWord), "how": .word(how)])
    }
    isolated deinit {
        tabObserver?.invalidate()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        if let companionObserver { NotificationCenter.default.removeObserver(companionObserver) }
    }
    private func followCompanion() {
        model.companion = .current
        for (tab, item) in zip(SettingsTab.allCases, tabs.tabViewItems) {
            item.image = NSImage(systemSymbolName: tab.symbol(for: model.companion), accessibilityDescription: tab.title)
        }
    }
    func open(_ tab: SettingsTab? = nil) {
        let wasOpen = window.isVisible
        opening = true
        if let tab, let index = SettingsTab.allCases.firstIndex(of: tab) { tabs.selectedTabViewItemIndex = index }
        opening = false
        model.refreshPermissions(whileOpen: window.isVisible)
        Task { await model.load() }
        ActivateOnly.activate(keeping: [window]) { window.makeKeyAndOrderFront(nil) }  // Settings, and none of Moku's others
        if !wasOpen { tabShown(tabs.selectedTabViewItemIndex, how: "opened") }
    }
}

/// Moku's own windows (Settings, Your day) close with Escape or ⌘W, like any Mac window. Caught here, before any
/// view: Moku lives in the menu bar, and a view or the hidden menu mustn't get in the way.
final class MokuWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            if event.keyCode == 53 || (command && event.charactersIgnoringModifiers?.lowercased() == "w") {
                performClose(nil)
                return
            }
        }
        super.sendEvent(event)
    }
}

private func note(_ text: String) -> some View {
    Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
}

/// A settings page: a grouped form at a fixed width, as tall as its content.
private struct Page<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Form { content }.formStyle(.grouped).scrollDisabled(true).frame(width: 480).fixedSize(horizontal: false, vertical: true)
    }
}

/// A timing on a stepper, in minutes (or seconds), with its words beside it.
private struct MinutesRow: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    var step = 1
    var words: (Int) -> String = { "\($0) min" }
    let set: (Int) -> Void
    var body: some View {
        LabeledContent(title) {
            Stepper(value: Binding(get: { value }, set: set), in: range, step: step) { Text(words(value)).monospacedDigit() }
                .accessibilityLabel(title).accessibilityValue(words(value))
        }
    }
}

struct GeneralSettings: View {
    @Bindable var model: SettingsModel
    @State private var invite = ""
    @State private var opensAtLogin = false
    @AppStorage(MokuPreferences.sizeKey) private var size = Double(MokuPreferences.defaultSize)
    /// The slider's value while you drag it; the companion changes size when you let go.
    @State private var sizeDraft: Double?
    @FocusState private var editingName: Bool
    private var name: String { model.companion.name }

    var body: some View {
        Page {
            // Only when this build has more than one companion: with Moku alone, General looks as it always has.
            if Companion.hasChoice {
                Section {
                    Picker("Who keeps you company", selection: Binding(get: { model.companion }, set: { choose($0) })) {
                        ForEach(Companion.available) { Text($0.name).tag($0) }
                    }.pickerStyle(.segmented)
                } header: {
                    Text("Companion")
                } footer: {
                    note("\(name) is a \(model.companion.kind). Switching keeps your days, your name and today’s progress.")
                }
            }
            Section {
                LabeledContent("Your name") {
                    TextField("", text: $model.name, prompt: Text("What \(name) calls you"))
                        .accessibilityLabel("Your name").multilineTextAlignment(.trailing).focused($editingName)
                        .onSubmit { model.commitName() }
                        .disabled(model.config == nil)
                }
                LabeledContent("Size") {
                    HStack(spacing: 8) {
                        Slider(value: Binding(get: { sizeDraft ?? size }, set: { sizeDraft = ($0 / 0.05).rounded() * 0.05 }),
                               in: Double(StageGeometry.scales.lowerBound)...Double(StageGeometry.scales.upperBound)) { editing in
                            if !editing, let sizeDraft {
                                let before = size
                                size = sizeDraft; self.sizeDraft = nil; NotificationCenter.default.post(name: .mokuResized, object: nil)
                                if sizeDraft != before { model.settingChanged("size", from: "\(before)", to: "\(sizeDraft)") }
                            }
                        }
                        .accessibilityLabel("Size").accessibilityValue("\((sizeDraft ?? size).formatted(.number.precision(.fractionLength(0...2)))) times")
                        Text("\((sizeDraft ?? size).formatted(.number.precision(.fractionLength(0...2))))×").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }.frame(width: 230)
                }
                if let problem = model.saveProblem { note(problem) }
            } header: {
                Text(name)
            } footer: {
                note(motionNote)
            }
            Section {
                Text(model.access?.line() ?? "Checking…").fixedSize(horizontal: false, vertical: true)
                if model.access != nil && model.access?.plan != .tester && model.access?.plan != .pro {
                    HStack {
                        TextField("", text: $invite, prompt: Text("Invite code")).accessibilityLabel("Invite code").textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).onSubmit { Task { await model.redeem(invite) } }
                        Button(model.redeeming ? "Checking…" : "Use code") { Task { await model.redeem(invite) } }
                            .disabled(model.redeeming || invite.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if !model.inviteMessage.isEmpty { note(model.inviteMessage) }
                if model.access?.offersPro == true {
                    HStack {
                        Text("Moku Pro")
                        Spacer()
                        Button("$6 a month") { Task { await model.getPro(plan: "monthly") } }
                        Button("$48 a year") { Task { await model.getPro(plan: "yearly") } }
                    }
                    note("Moku’s cloud brain after the trial: sharper judging and notes on your day. Sold by Dodo Payments. Cancel any time; Pro stays until the end of what you’ve paid for.")
                }
                if !model.proMessage.isEmpty { note(model.proMessage) }
            } header: {
                Text("Moku’s brain")
            } footer: {
                note(LocalBrain.isBundled ? "Without the cloud, \(name) still keeps you company and thinks on your Mac." : "If the cloud brain can’t be reached, \(name) keeps you company and waits for it. It won’t guess what you’re doing.")
            }
            Section {
                Toggle("Open Moku when you log in", isOn: Binding(get: { opensAtLogin }, set: { model.setOpensAtLogin($0); opensAtLogin = model.opensAtLogin }))
                if let message = model.loginMessage {
                    HStack { note(message); Spacer(); Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() } }
                }
                HStack {
                    Text("Moku \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") beta").foregroundStyle(.secondary)
                        .help("Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")")
                    Spacer()
                    Button("Check for updates…") { model.checkForUpdates?() }.disabled(model.checkForUpdates == nil)
                }
            } header: {
                Text("App")
            } footer: {
                note(model.checkForUpdates == nil ? "This is a development build: it doesn’t update itself." : "Moku updates itself: it downloads new versions quietly and installs them while you’re away from your Mac." + (model.updateStatus.map { "\n\($0)" } ?? ""))
            }
        }
        .onChange(of: editingName) { if !editingName { model.commitName() } }
        .onAppear { opensAtLogin = model.opensAtLogin; model.companion = Companion.current }
    }
    /// Reduce Motion is the system's (System Settings › Accessibility › Display); here it's said what it changes.
    private var motionNote: String {
        guard MotionPreference.reduced else { return "\(name) follows Reduce Motion in System Settings › Accessibility › Display." }
        return "Reduce Motion is on, so \(name) keeps its moves small: no petals, and " + (model.companion == .tetsu ? "its lines appear at once instead of typing on." : "its bubbles fade in without the little pop.")
    }
    private func choose(_ next: Companion) {
        guard next != model.companion else { return }
        model.track?("companion_changed", ["from": .word(model.companion.rawValue), "to": .word(next.rawValue), "where": .word("settings")])
        let previous = model.companion
        model.companion = next; CompanionChoice.choose(next); model.settingChanged("companion", from: previous.rawValue, to: next.rawValue)
    }
}

/// Water and breaks, each with a switch (they couldn't be turned off before) and plain words.
struct BreakSettings: View {
    @Bindable var model: SettingsModel
    private var name: String { model.companion.name }
    var body: some View {
        Page {
            Section {
                Toggle("Remind me to drink water", isOn: Binding(get: { model.drinkOn }, set: model.setDrinkOn))
                if model.drinkOn {
                    MinutesRow(title: "How often", value: model.drinkMinutes, range: SettingsModel.drinkRange, step: 5, words: { "every \($0) min" }, set: model.setDrink)
                }
            } header: {
                Text("Water")
            } footer: {
                note(model.drinkOn ? "While you focus, \(name) \(model.companion.sipsWater) every \(model.drinkMinutes) minutes: a reminder by example, without a word."
                                   : "\(name) won’t drink or suggest water. Breaks can still be suggested below.")
            }
            .disabled(model.config == nil)
            Section {
                Toggle("Suggest a break", isOn: Binding(get: { model.breakOn }, set: model.setBreakOn))
                if model.breakOn {
                    MinutesRow(title: "After you’ve focused for", value: model.breakAfterMinutes, range: SettingsModel.breakAfterRange, step: 5, set: model.setBreakAfter)
                }
                MinutesRow(title: "A break lasts", value: model.breakMinutes, range: SettingsModel.breakRange, step: 5, set: model.setBreak)
                if let problem = model.saveProblem { note(problem) }
            } header: {
                Text("Breaks")
            } footer: {
                note((model.breakOn ? "After \(model.breakAfterMinutes) minutes of focus, \(name) suggests \(model.drinkOn ? "a glass of water, " : "")a stretch, a look away or a short walk. " : "\(name) won’t suggest breaks. ")
                     + "On a break it stops watching, has a cup of tea and dozes, with a countdown over its head. Take one any time from the menu bar, or by right-clicking \(name).")
            }
            .disabled(model.config == nil)
        }
    }
}

/// A title with a line under it: a permission (what it lets Moku see, and "Allowed" or a button to turn it on), or a fact.
private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool?
    let turnOn: () -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch granted {
            case true?: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            case false?: Button("Turn on…", action: turnOn)
            case nil: EmptyView()
            }
        }
    }
}

struct PrivacySettings: View {
    @Bindable var model: SettingsModel
    @State private var confirmingDelete = false
    @AppStorage(DailyCounts.shareKey) private var shareDailyCounts = false
    var body: some View {
        Page {
            Section {
                PermissionRow(title: "Accessibility", detail: "Which app, window and web page you’re on, and how busy your typing is (counts only, never keys).",
                              granted: model.permissions?.accessibility) { model.ask(.accessibility) }
                PermissionRow(title: "Screen Recording", detail: "A few words from the window you’re on, read on your Mac. The picture never leaves it.",
                              granted: model.permissions?.screenRecording) { model.ask(.screenRecording) }
            } header: {
                Text("What Moku can see")
            } footer: {
                note(model.permissionsNote)
            }
            Section {
                IgnoredAppsList(model: model)
            } header: {
                Text("Apps where Moku steps aside")
            } footer: {
                note("Moku hides while one of these is in front. “Hide Moku” still counts the work you do there. “Hide, don’t watch” reads nothing from the app: no window, address or text, and nothing is judged or sent. Pick as many as you like. The list stays on this Mac.")
            }
            Section {
                Toggle("Share daily counts", isOn: Binding(get: { shareDailyCounts }, set: { shareDailyCounts = $0; model.settingChanged("share_daily_counts", turned: $0, from: String(!$0), to: String($0)) }))
            } header: {
                Text("Help make Moku better")
            } footer: {
                note("Once a day: how long Moku watched, how it decided, its nudges and your corrections, and whether its brain answered. Numbers only, never what’s on your screen or the names of your apps, sites and work. Separately, Moku always says how it’s used (the popover opened, a break, a setting changed) in code words and counts, never anything from your screen or anything you type. hellomoku.com/privacy lists every one.")
            }
            Section {
                PermissionRow(title: "Kept on this Mac", detail: "Your days, activities and houses, until you delete them. \(model.screenTextKept) Pictures of your screen are never saved.", granted: nil) {}
                PermissionRow(title: "Sent to the AI", detail: "To tell work from a detour: the app, the window’s name, the address and a short excerpt of its text. Every request asks it to keep nothing.", granted: nil) {}
                HStack {
                    Button("Delete my data…", role: .destructive) { confirmingDelete = true }.disabled(model.deleting)
                    if model.deleting { ProgressView().controlSize(.small); Text("Deleting…").foregroundStyle(.secondary) }
                }
                .confirmationDialog("Delete everything Moku has seen and learned?", isPresented: $confirmingDelete) {
                    Button("Delete everything", role: .destructive) { Task { await model.deleteEverything() } }
                } message: {
                    Text("Your days, activities, what Moku learned about your work, and your houses. Your name and settings stay.")
                }
                if !model.dataMessage.isEmpty { note(model.dataMessage) }
            } header: {
                Text("Your data")
            } footer: {
                note("Nothing is sold, shared with advertisers or used to train AI. hellomoku.com/privacy says exactly what leaves your Mac.")
            }
        }
    }
}

/// A setting changed in Settings: kept for 5 minutes, or changed back before then (`setting_outcome`, with the seconds).
/// Only the first value is remembered, on the Mac, to see whether it came back; a change that goes on to a third value
/// keeps waiting. Nothing is polled: one wait per setting changed.
@MainActor final class SettingOutcomes {
    static let keptAfter: Duration = .seconds(300)
    private let report: @MainActor (_ key: String, _ outcome: String, _ seconds: Int) -> Void
    private let keptAfter: Duration
    private var watching: [String: (original: String, at: Date, wait: Task<Void, Never>)] = [:]

    init(keptAfter: Duration = SettingOutcomes.keptAfter, report: @escaping @MainActor (_ key: String, _ outcome: String, _ seconds: Int) -> Void) {
        self.keptAfter = keptAfter; self.report = report
    }

    func changed(_ key: String, from old: String, to new: String, now: Date = Date()) {
        guard old != new else { return }
        if let watch = watching[key] {
            guard new == watch.original else { return }
            watch.wait.cancel(); watching[key] = nil
            report(key, "changed_back", max(0, Int(now.timeIntervalSince(watch.at).rounded())))
            return
        }
        let wait = Task { [weak self, keptAfter] in
            do { try await Task.sleep(for: keptAfter) } catch { return }
            guard let self, let watch = self.watching.removeValue(forKey: key) else { return }
            self.report(key, "kept", max(0, Int(Date().timeIntervalSince(watch.at).rounded())))
        }
        watching[key] = (old, now, wait)
    }
}
