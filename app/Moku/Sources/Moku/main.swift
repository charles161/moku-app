import AppKit
import MokuKit
import MokuMind
import MokuSense
import MokuVisual
import ServiceManagement
import Sparkle

/// One line per lifecycle event in ~/.moku/app.log. A launch with no matching "terminate" before the
/// next launch means Moku disappeared without quitting (a crash or a kill).
enum AppLog {
    /// A log past `maxBytes` becomes `<name>.1` (replacing the older one), so logs never grow without end.
    static func rotate(_ url: URL, maxBytes: Int) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes else { return }
        let older = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: older)
        try? FileManager.default.moveItem(at: url, to: older)
    }

    /// For a log another process holds open (the brain's, opened with O_APPEND): the lines so far are copied to
    /// `<name>.1` and the file is emptied, so the other process goes on writing to it. A brain that runs for weeks
    /// writes a line per judgment; rotating only when it starts let brain.log grow by more than a megabyte a day.
    static func rotateInPlace(_ url: URL, maxBytes: Int) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes else { return }
        let older = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: older)
        guard (try? FileManager.default.copyItem(at: url, to: older)) != nil, let handle = try? FileHandle(forWritingTo: url) else { return }
        try? handle.truncate(atOffset: 0)
        try? handle.close()
    }

    static func write(_ event: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".moku/app.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) pid \(ProcessInfo.processInfo.processIdentifier) \(event)\n"
        // Owner-only, like everything in ~/.moku: the logs name apps and goals.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
        }
    }
}

/// Builds the sensors, the brain client, the character and its world, and hands them to the runtime.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let sense = SenseHub()
    private let stepAsideApps = IgnoredAppsCache()
    /// The secret only Moku and its brain share (BrainToken): without it the brain answers nothing but /health, so no
    /// other user or app on this Mac can read Your day or delete it.
    private static let brainToken = BrainToken.loadOrCreate(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".moku"))
    private let brain = BrainSupervisor(token: AppDelegate.brainToken)
    private let brainClient = BrainClient(token: AppDelegate.brainToken)
    /// This Mac's access to the cloud brain: a quiet trial on first launch, invites from Settings or moku:// links.
    private lazy var access = RelayAccess(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".moku"), relay: relayURL)
    private let relayURL = (Bundle.main.object(forInfoDictionaryKey: "MokuRelayURL") as? String).flatMap(URL.init(string:)) ?? RelayAccess.defaultRelay
    /// The opt-in daily counts (Settings › Share daily counts), checked at launch and every hour.
    private lazy var heartbeat = DailyHeartbeat(relay: relayURL, counts: { [brainClient] date in try await brainClient.counts(date: date) },
                                                facts: { [weak self] in await self?.appFacts() ?? [:] })
    private let launchedAt = Date()
    /// Usage events, always on (docs/specs/usage-analytics.md): code words and counts through the relay, never what's on
    /// the screen. They wait in ~/.moku/usage-queue.json until they go.
    private lazy var usage = UsageEvents(file: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".moku/usage-queue.json"),
                                         relay: relayURL, appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                                         token: { [weak self] in self?.access.currentToken() },
                                         common: { ["companion": .word(Companion.current.rawValue)] }, installedAt: UsageEvents.installedAt())
    /// What breaks (`trouble`): the brain, the relay, the stand-in, a permission lost, the store set aside.
    private lazy var trouble = TroubleLog(track: { [weak self] name, props in self?.usage.track(name, props) })
    /// Errors Moku carries on from (`app_error`, a PostHog `$exception` with level error), from anywhere in the app
    /// (`ErrorReports`) and from the brain's /health.
    private lazy var errors = ErrorLog(track: { [weak self] name, props in self?.usage.track(name, props) })
    /// Memory and CPU, sampled every 10 minutes into the day's summary (ResourceSamples).
    private let resources = ResourceSamples()
    /// The main thread busy for more than a quarter of a second (`day_summary` stalls).
    private let stalls = MainThreadStalls()
    private var resourceTimer: Timer?
    /// The permissions at the last look: one turned off since is `trouble` (permission_lost).
    private var lastPermissions: PermissionStatus?
    /// Auto-update (Sparkle 2): on only in builds that carry an update feed and its public key (scripts/release.sh):
    /// a daily check, a quiet download, and the install when Moku quits or the person steps away (QuietUpdates).
    private let quietUpdates = QuietUpdates()
    private lazy var updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: quietUpdates, userDriverDelegate: nil)
    private var updatesEnabled: Bool {
        ["SUFeedURL", "SUPublicEDKey"].allSatisfy { (Bundle.main.object(forInfoDictionaryKey: $0) as? String).map { !$0.isEmpty } ?? false }
    }
    private var heartbeatTimer: Timer?
    /// The relay's remote switches (RemoteFlags): asked at launch and every 10 minutes; the last answer is kept.
    private lazy var remoteFlags = RemoteFlagsClient(relay: relayURL, appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                                                     token: { [weak self] in self?.access.currentToken() })
    /// What the brain last said about its models, before the remote switches have their say.
    private var brainThinking = ThinkingStatus.fine
    private let worldModel = WorldModel()
    private var runtime: CompanionRuntime?
    private var world: (any WorldPresenter)?
    private var manualPanel: (any ManualControlPanel)?
    private var onboarding: (any OnboardingPresenter)?
    private var manualControl = false
    private var onboardingRunning = false
    private var stateLog: Timer?
    /// After a companion change RealityKit keeps ~200 MB of the old one until the process ends: Moku opens itself again when
    /// nobody can see it (QuietRelaunch).
    private lazy var quietRelauncher = QuietRelauncher { [weak self] in
        guard let self, let status = runtime?.status else { return QuietRelaunch.State(phase: .settling, mood: .content, atHome: true, manualControl: true) }
        return QuietRelaunch.State(phase: status.phase, mood: status.mood, atHome: status.atHome, welcomeOpen: onboardingRunning, manualControl: manualControl)
    }
    private var companionObserver: NSObjectProtocol?
    private var reopenObserver: NSObjectProtocol?
    private var lastState = ""
    /// Quitting from Moku's own menu, while the day's card says goodbye.
    private var quitting = false
    /// An invite redeemed during the welcome: Settings shows it once the welcome is over.
    private var settingsAfterWelcome = false

    private func appFacts() async -> [String: Any] {
        AppFacts.collect(launchedAt: launchedAt, plan: access.status(brainModels: await brain.models()).plan,
                         localModel: await brain.localModel(), brainExits: brain.unexpectedExits)
    }

    /// A Mac with no model access gets its 21-day trial, quietly: at launch, then hourly until one takes (it was
    /// offline, or new trials were full for the day).
    private func ensureAccess() async {
        if let status = await access.ensureTrial(brainModels: await brain.models()) { AppLog.write("access: \(status.plan.rawValue) until \(status.expiresAt.map { "\($0)" } ?? "-")") }
    }

    /// Once a day (checked at launch and hourly): a fresh token from the relay. A payment reaches this Mac this way, and a
    /// tester's token gets another month.
    private var lastRenewal: Date?
    private func renewAccessDaily() async {
        if let lastRenewal, Date().timeIntervalSince(lastRenewal) < 20 * 3600 { return }
        lastRenewal = Date()
        if let status = await access.renew() { AppLog.write("access: renewed, \(status.plan.rawValue)") }
    }

    /// Settings › Get Moku Pro: Dodo's checkout in the browser, then a renewal every 30 s for 15 minutes until the payment
    /// has landed and the relay answers with Pro (docs/specs/payments.md).
    private func startCheckout(_ plan: String) async -> Result<Void, InviteError> {
        do {
            let page = try await access.checkout(plan: plan)
            NSWorkspace.shared.open(page)
            AppLog.write("pro: checkout opened (\(plan))")
            Task { [weak self] in
                for _ in 0..<30 {
                    try? await Task.sleep(for: .seconds(30))
                    guard let self else { return }
                    if let status = await access.renew(), status.plan == .pro {
                        lastRenewal = Date()
                        AppLog.write("pro: on")
                        return
                    }
                }
            }
            return .success(())
        } catch RelayAccess.AccessError.refused(503) {
            return .failure(InviteError("Moku Pro isn’t open yet. Soon!"))
        } catch let error as RelayAccess.AccessError {
            return .failure(InviteError(error.description))
        } catch { return .failure(InviteError("Something went wrong. Try again?")) }
    }

    /// A first launch with no network (or a full day of new trials): the trial is asked for again after 30 s, 2 minutes and
    /// 10 minutes, and then hourly as ever, so someone who opens Moku on flaky wifi isn't left with a calm Moku for an hour.
    private func askForAccessSoonIfMissing() async {
        for seconds in [30, 120, 600] {
            guard access.status(brainModels: await brain.models()).plan == .none else { return }
            try? await Task.sleep(for: .seconds(seconds))
            await ensureAccess()
        }
    }

    /// The relay's switches, applied: forceCalm to Moku, and cloudJudging to the popover's line. (The relay refuses
    /// whatever is switched off itself, and `remoteFlags` asks Sparkle when this build is below minVersion.)
    private func useRemoteFlags(_ flags: RemoteFlags) {
        AppLog.write("flags: \(flags)")
        runtime?.setForceCalm(flags.forceCalm)
        showThinking()
    }

    private func showThinking() { world?.setThinking(remoteFlags.current.thinkingStatus(from: brainThinking)) }

    private func sendDailyCounts() async {
        let days = await heartbeat.tick()
        if !days.isEmpty { AppLog.write("heartbeat: sent \(days.joined(separator: ", "))") }
    }

    /// An invite code, from Settings or a moku://invite/CODE link.
    private func redeem(_ code: String) async -> Result<AccessStatus, InviteError> {
        do {
            let status = try await access.install(invite: code)
            AppLog.write("access: invite redeemed, \(status.plan.rawValue)")
            return .success(status)
        } catch let error as RelayAccess.AccessError {
            return .failure(InviteError(error.description))
        } catch { return .failure(InviteError("Something went wrong. Try again?")) }
    }

    /// moku:// links: invite/CODE (an invite email or the website), and break, day and settings (Shortcuts, Raycast). A link
    /// that opens Moku arrives before launch has finished: the inbox keeps it until then (MokuLinks.swift).
    private lazy var links = LinkInbox { [weak self] link in self?.follow(link) }

    func application(_ application: NSApplication, open urls: [URL]) {
        links.receive(urls)
    }

    /// An invite is redeemed, then Settings opens to show it took; break takes a break or ends it; day opens Your day;
    /// settings opens Settings.
    private func follow(_ link: MokuLink) {
        switch link {
        case let .invite(code):
            Task { [weak self] in
                guard let self else { return }
                _ = await self.redeem(code)
                // Settings shows that it took; over the welcome (an invite link that opened Moku the first time), once the
                // welcome is over.
                if self.onboardingRunning { self.settingsAfterWelcome = true; return }
                NotificationCenter.default.post(name: Notification.Name("MokuVisual.openSettings"), object: nil)
            }
        case .toggleBreak: runtime?.toggleBreak(from: .link)
        case .openDay: NotificationCenter.default.post(name: Notification.Name("MokuVisual.openToday"), object: nil)
        case .openSettings: NotificationCenter.default.post(name: Notification.Name("MokuVisual.openSettings"), object: nil)
        }
    }

    /// Opening Moku again while it runs (the Applications folder, Spotlight, Launchpad): macOS sends this copy a reopen
    /// event rather than starting another one (checked with a bare accessory app opened twice: one process, one reopen).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openedAgain()
        return false
    }

    /// Opened again: Moku says it's here. The popover opens (the welcome comes forward instead while it's open).
    private func openedAgain() {
        if onboardingRunning { NSApp.activate() } else { NotificationCenter.default.post(name: Notification.Name("MokuVisual.openHome"), object: nil) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let loginItem = Self.openedAtLogin()  // only readable now, while the launch's Apple Event is current
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        AppLog.rotate(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".moku/app.log"), maxBytes: 2_000_000)
        AppLog.write("launch build \(version), allocator \(ProcessInfo.processInfo.environment["MallocSpaceEfficient"] == "1" ? "space-efficient" : "default")")
        // Opened again by a quiet relaunch: the same Moku, so no welcome, no offer to move, and no new "opening" in the usage events.
        let quietRelaunch = QuietRelaunch.takeNote(at: AppLifecycle.relaunchNote)
        if let quietRelaunch { AppLog.write("launch: quiet relaunch (\(quietRelaunch.reason)); the same Moku, no welcome") }
        if quietRelaunch == nil, MoveToApplications.offerIfNeeded() { return }  // quitting: the copy in Applications takes over
        MokuVisualFactory.retireBehaviourChoices()  // one behaviour for everyone: a saved Calm or Lively is cleared
        // Opening another copy of Moku while this one runs (the disk image's, a build): that one hands over and quits.
        reopenObserver = DistributedNotificationCenter.default().addObserver(forName: AppLifecycle.reopenedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openedAgain() }
        }
        ErrorReports.sink = { [weak self] report in self?.errors.note(report) }
        MokuNetwork.forgetSharedCache()  // brain answers and the relay's token, saved there before 0.1.12
        CrashReports.sendNew()
        // Again soon: macOS writes a crash report a moment after the crash, and a quick relaunch can beat it.
        Task { try? await Task.sleep(for: .seconds(60)); CrashReports.sendNew() }
        let launch = quietRelaunch == nil ? trackLaunch(loginItem: loginItem) : nil
        if quietRelaunch != nil { UsageEvents.recordQuietRelaunch() }  // so a crash after it still reads "unclean"
        AppMenu.install()
        // Opening at login is registered by the welcome's Start, with its switch on (LoginItemConsent): never here, before
        // the person has seen the switch. A copy that registered at first launch before this keeps its login item.
        brain.onPort = { [brainClient] port in brainClient.use(port: port) }  // 8020 unless something else holds it
        brain.onStatus = { [weak self] status in self?.brainThinking = status; self?.showThinking() }
        brain.onHealth = { [weak self] answering, judge, lastError in self?.noticeTrouble(answering: answering, judge: judge, lastError: lastError) }
        brain.onUnexpectedExit = { [weak self] in self?.trouble.happened("brain_restarted") }
        brain.onErrors = { [weak self] counts in self?.errors.brainCounts(counts) }
        Task { [weak self] in
            guard let self else { return }
            await brain.start()
            await ensureAccess()
            await renewAccessDaily()
            Task { [weak self] in await self?.askForAccessSoonIfMissing() }
            remoteFlags.start()
            await tellBrainTheCompanion()
            await sendDailyCounts()
        }
        companionObserver = NotificationCenter.default.addObserver(forName: .mokuCompanionChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Task { await self?.tellBrainTheCompanion() }
                self?.quietRelauncher.request(because: "companion changed")
            }
        }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { CrashReports.sendNew(); Task { await self?.ensureAccess(); await self?.renewAccessDaily(); await self?.sendDailyCounts(); await self?.usage.flush() } }
        }
        resourceTimer = Timer.scheduledTimer(withTimeInterval: ResourceSamples.every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self, let sample = self.resources.take() { self.usage.count(sample) } }
        }
        resourceTimer?.tolerance = 60  // with the other timers' wakeups
        stalls.start { [weak self] in self?.usage.count(.stall) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppLifecycle.quitReason = AppLifecycle.quitReason ?? "logout" }
        }

        let stage = MokuVisualFactory.makeStage()
        let world = MokuVisualFactory.makeWorld(model: worldModel)
        // Apps Moku steps aside for (Settings › Privacy): it hides while one is in front, and reads nothing from the ones
        // the person also asked it not to watch.
        sense.ignoresApp = { [stepAsideApps] in stepAsideApps.list.ignores(bundleId: $0) }
        sense.stepsAsideFor = { [stepAsideApps] in stepAsideApps.list.stepsAside(bundleId: $0) }
        sense.onStepAsideChange = { [weak stage] aside in (stage as? MokuCharacterStage)?.setSteppingAsideForApp(aside) }
        // A video full screen on Moku's display: Moku steps aside until it leaves full screen.
        sense.onFullScreenChange = { [weak stage] displays in (stage as? MokuCharacterStage)?.setFullScreenDisplays(displays) }
        let runtime = CompanionRuntime(senses: sense.events, brain: brainClient, stage: stage,
                                       world: world, worldModel: worldModel)
        let manualPanel = MokuVisualFactory.makeManualControl(stage: stage, world: worldModel, presenter: world,
                                                              scenes: runtime.manualScenes())
        world.onManualControl = { [weak self] on in self?.setManualControl(on) }
        manualPanel.onClose = { [weak self] in self?.setManualControl(false) }
        world.onSayHiAgain = { [weak self] in self?.runOnboarding() }
        // Charles's calibration build (MOKU_CALIBRATE=1 at build time): "Calibrate…" opens the brain's local dashboard.
        if BrainSupervisor.calibrating {
            (stage as? MokuCharacterStage)?.onCalibrate = { [weak self] in
                if let port = self?.brain.port, let dashboard = URL(string: "http://127.0.0.1:\(port)/calibrate") { NSWorkspace.shared.open(dashboard) }
            }
        }
        world.loadConfig = { [weak self] in try? await self?.brainClient.config() }
        world.saveConfig = { [weak self] patch in
            guard let self, let config = try? await self.brainClient.updateConfig(patch) else { return nil }
            self.runtime?.useConfig(config)
            return config
        }
        world.loadAccess = { [weak self] in guard let self else { return nil }; return self.access.status(brainModels: await self.brain.models()) }
        world.redeemInvite = { [weak self] code in await self?.redeem(code) ?? .failure(InviteError("Moku isn’t ready yet.")) }
        world.startCheckout = { [weak self] plan in await self?.startCheckout(plan) ?? .failure(InviteError("Moku isn’t ready yet.")) }
        quietUpdates.track = { [weak self] name, props in self?.usage.track(name, props) }
        quietUpdates.checkInBackground = { [weak self] in self?.updater.updater.checkForUpdatesInBackground() }
        quietUpdates.onOutcome = { [weak world] outcome in world?.updateStatus = outcome.sentence() }
        if updatesEnabled {
            updater.startUpdater()
            // A Mac that can't update itself, said once a launch: Moku outside Applications, or automatic checks off.
            if !UpdateFacts.inApplications() { usage.track("update_stuck", ["why": .word("not_in_applications")]) }
            if !updater.updater.automaticallyChecksForUpdates { usage.track("update_stuck", ["why": .word("sparkle_off")]) }
            world.checkForUpdates = { [weak self] in self?.updater.checkForUpdates(nil) }
            remoteFlags.checkForUpdates = { [weak self] in self?.updater.updater.checkForUpdatesInBackground() }
            AppLog.write("updates: checking \(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "")")
        }
        world.permissionStatus = { SenseHub.permissionStatus() }
        world.requestPermission = { Onboarding.requestPermission($0) }
        runtime.usage = { [weak self] name, props in self?.usage.track(name, props) }
        runtime.count = { [weak self] count in self?.usage.count(count) }
        stage.track = { [weak self] name, props in self?.usage.track(name, props) }
        stage.count = { [weak self] count in self?.usage.count(count) }
        runtime.installedAt = UsageEvents.installedAt()
        // "Today counted" (docs/specs/next-three.md §3): the day's card, once a day as work winds down. Its memory (the
        // day followed, and the days that have had their card) is kept in the app's defaults.
        let dayCounted = DayCountedSchedule(memory: .load(from: .standard),
                                            idleSeconds: { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) },
                                            save: { $0.save(to: .standard) })
        dayCounted.onShown = { card, summary in
            AppLog.write("day counted: \(card.yesterday ? "yesterday's" : "today's") card (\(card.reason.rawValue)), \(summary.focusedMinutes) focused minutes")
        }
        runtime.dayCounted = dayCounted
        QuitRequest.handler = { [weak self] in self?.quitFromMenu(nil) }
        // "What's new" after an update (WhatsNew.swift): once per version, at the first calm moment; a click opens the changelog.
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        runtime.whatsNew = WhatsNew.pending(version: shortVersion, updated: launch?.updated ?? false)
        runtime.onWhatsNewTold = { version in
            WhatsNew.told(version)
            AppLog.write("what's new: \(version) seen")
        }
        runtime.openLink = { NSWorkspace.shared.open($0) }
        world.track = { [weak self] name, props in self?.usage.track(name, props) }
        world.count = { [weak self] count in self?.usage.count(count) }
        world.deleteData = { [weak self] in
            guard let self else { return false }
            let done = (try? await brainClient.deleteEverything()) != nil
            // The logs name apps and goals: they go too.
            if done {
                HistoryLogs.forget(in: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".moku"))
                self.runtime?.forgetWork()  // and the window "Where was I?" was keeping
            }
            AppLog.write(done ? "data: deleted everything" : "data: delete failed (brain not answering)")
            return done
        }

        // A break: Moku stops watching (nothing sensed, judged or recorded) until it ends.
        runtime.onBreakChanged = { [weak self] on in
            guard let self else { return }
            AppLog.write(on ? "break: started, not watching" : "break: over, watching again")
            if on { sense.stop(keepWatchingFullScreen: true) } else if !manualControl && !onboardingRunning { sense.start() }
        }
        self.runtime = runtime
        self.world = world
        self.manualPanel = manualPanel
        onboarding = MokuVisualFactory.makeOnboarding(stage: stage, world: world)  // Start folds the welcome into the menu bar icon
        runtime.start()
        remoteFlags.onChange = { [weak self] flags in self?.useRemoteFlags(flags) }
        useRemoteFlags(remoteFlags.current)  // the last answer, until the relay gives a new one
        logStateChanges()
        if !Onboarding.shouldOffer || quietRelaunch != nil {
            // Moku asks only in the welcome. Asking at every launch brought macOS's prompts back each time for someone
            // who had said no (friend 1, 2026-10-02); Settings and the popover say what's missing instead.
            let permissions = SenseHub.permissionStatus()
            AppLog.write("permissions: accessibility \(permissions.accessibility ? "on" : "off"), screen recording \(permissions.screenRecording ? "on" : "off")")
            sense.start()
        } else {
            runOnboarding()
        }
        links.open()  // a link that opened Moku: now there's a companion, a popover and Settings to follow it
    }

    /// The brain names the day's home and its pieces in its notes ("I put up the nose cone"): it's told who's on show,
    /// at launch and on every switch.
    private func tellBrainTheCompanion() async {
        let companion = Companion.current.rawValue
        guard let config = try? await brainClient.config(), (config.companion ?? "moku") != companion else { return }
        if let saved = try? await brainClient.updateConfig(CompanionConfigPatch(companion: companion)) {
            runtime?.useConfig(saved)
            AppLog.write("brain: companion \(companion)")
        }
    }

    /// Every 30 s, with the brain's health check: what's wrong with the brain or the cloud (`trouble`), a permission turned
    /// off since the last look, and a store the brain set aside as damaged.
    private func noticeTrouble(answering: Bool, judge: String?, lastError: String?) {
        trouble.observe(TroubleLog.brainKind(answering: answering, judgeState: judge, lastError: lastError), among: TroubleLog.brainKinds)
        let permissions = SenseHub.permissionStatus()
        if let before = lastPermissions, (before.accessibility && !permissions.accessibility) || (before.screenRecording && !permissions.screenRecording) {
            trouble.happened("permission_lost")
        }
        lastPermissions = permissions
        if StoreSetAside.isNew(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".moku")) { trouble.happened("store_set_aside") }
    }

    /// Whether macOS opened Moku at login: the launch's open-application Apple Event says so.
    private static func openedAtLogin() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    /// `app_opened`, and `update_installed` on the first launch of a new version. Returns what this launch is.
    @discardableResult private func trackLaunch(loginItem: Bool) -> UsageEvents.Launch {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let launch = UsageEvents.recordLaunch(version: version, onboarded: Onboarding.isCompleted, loginItem: loginItem)
        let permissions = SenseHub.permissionStatus()
        var opened: [String: UsageValue] = [
            "first_launch": .bool(launch.firstLaunch),
            "macos": .int(ProcessInfo.processInfo.operatingSystemVersion.majorVersion),
            "ram_gb": .int(UsageEvents.ramBucket(bytes: ProcessInfo.processInfo.physicalMemory)),
            "launched_by": .word(launch.launchedBy),
            "screen_recording": .bool(permissions.screenRecording),
            "accessibility": .bool(permissions.accessibility),
            "companion": .word(Companion.current.rawValue),  // to compare retention across companions
            "displays": .int(max(1, NSScreen.screens.count)),
            "reduce_motion": .bool(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion),
            "low_power": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled),
            "hidden": .bool(MokuVisualFactory.companionHiddenByPerson),
        ]
        if let previousExit = launch.previousExit { opened["previous_exit"] = .word(previousExit.rawValue) }
        usage.track("app_opened", opened)
        if launch.updated {
            var props: [String: UsageValue] = ["to": .word(version)]
            if let from = launch.previousVersion { props["from"] = .word(from) }
            if let hours = UpdateFacts.hoursSinceRelease(of: version) { props["hours_since_release"] = .int(hours) }
            usage.track("update_installed", props)
        }
        AppLog.write("usage: opened by \(launch.launchedBy)\(launch.firstLaunch ? ", first launch" : "")\(launch.updated ? ", updated from \(launch.previousVersion ?? "an older version")" : "")")
        return launch
    }

    /// One app.log line whenever Moku's phase, mood or work state changes, so a report like "Moku
    /// never fell asleep" can be checked against what the engine actually did.
    private func logStateChanges() {
        stateLog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let status = self.runtime?.status else { return }
                let state = "\(status.phase.rawValue) \(status.mood) \(status.workState)"
                guard state != self.lastState else { return }
                self.lastState = state
                AppLog.write("state: \(state)")
            }
        }
    }

    /// Moku stops watching while it says hi (nothing sensed, judged or recorded), then carries on
    /// as if it had just appeared.
    private func runOnboarding() {
        if manualControl { setManualControl(false) }  // "Say hi again" mid-test ends the test first
        guard !onboardingRunning, !manualControl, let onboarding, let runtime else { return }
        onboardingRunning = true
        AppLog.write("onboarding: started")
        sense.stop()
        runtime.setManualControl(true)
        Task {
            // Saying hi again prefills the name Moku already uses; the first time, the Mac account's.
            let knownName = Onboarding.isCompleted ? try? await brainClient.config().userName : nil
            var context = Onboarding.context()
            context.suggestedName = knownName ?? context.suggestedName
            context.track = { [weak self] name, props in self?.usage.track(name, props) }
            let result = await onboarding.run(context)
            AppLog.write("onboarding: \(result.completed ? "finished" : "closed early")")
            if result.completed { Onboarding.isCompleted = true } else if !Onboarding.isCompleted { Onboarding.recordEarlyExit() }
            await Onboarding.saveName(result.name, to: brainClient)
            onboardingRunning = false
            runtime.setManualControl(false)
            sense.start()
            if settingsAfterWelcome {
                settingsAfterWelcome = false
                NotificationCenter.default.post(name: Notification.Name("MokuVisual.openSettings"), object: nil)
            }
        }
    }

    /// While manual control is on, Moku stops watching entirely: no sensing, no judging, nothing
    /// recorded. The panel drives the character by hand until it's closed or switched off.
    private func setManualControl(_ on: Bool) {
        guard on != manualControl, !onboardingRunning, let runtime, let world, let manualPanel else { return }
        manualControl = on
        if on {
            sense.stop()
            runtime.setManualControl(true)
            manualPanel.open()
        } else {
            manualPanel.close()
            runtime.setManualControl(false)
            sense.start()
        }
        world.setManualControl(on)
    }

    /// "Quit Moku" from Moku's own menus (QuitRequest, ⌘Q): after 4 pm on a day that counted, the day's card says goodbye
    /// first, for a few seconds or until it's clicked; then Moku quits. Asked again meanwhile, it quits at once.
    @objc func quitFromMenu(_ sender: Any?) {
        guard !quitting, let runtime else { NSApp.terminate(nil); return }
        quitting = true
        world?.closeWorld()  // ⌘Q with the popover open: it goes first, so the goodbye card is the one thing showing
        Task {
            await runtime.sayGoodbye()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.write("terminate")
        // How Moku was quit, and after how long: its own menus, a logout, an update, a relaunch or a signal.
        usage.track("app_quit", ["uptime_minutes": .int(max(0, Int(Date().timeIntervalSince(launchedAt) / 60))),
                                 "how": .word(quitting ? "menu" : AppLifecycle.quitReason ?? "other")])
        trouble.sendAll()
        errors.sendAll()
        runtime?.stop()
        sense.stop()
        brain.stop()
        usage.sendBeforeQuit(within: 2)  // the last usage events, 2 s at most; what doesn't go waits for the next launch
        UsageEvents.recordQuit()  // last: a crash in any step above still reads "unclean" at the next launch
    }
}

// One Moku at a time: the lock decides (two copies started in the same instant), the look at who's running backs it up.
if !InstanceLock.acquire(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".moku/moku.lock")) || AppLifecycle.isAnotherInstanceRunning() {
    AppLog.write("launch skipped: Moku is already running")
    AppLifecycle.tellRunningMoku()
    exit(0)
}
AppLifecycle.quitCleanlyOnSignals()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
