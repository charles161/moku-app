// UpdateProbe: Sparkle exactly as Moku runs it, with every step written down. scripts/check-update-live.sh builds it into
// a "Moku.app" (so Sparkle's installer finds Moku.app in the update, as it does for Moku) with its own bundle id
// (ai.lightslips.moku.updateprobe, so its own defaults, caches and installer), Moku's update key, and an old version.
// It has no windows and no Dock icon: its user driver answers Sparkle itself and logs what Moku's would have shown.
//
//   UpdateProbe --mode scheduled|background|user --install quit|now|none --timeout <seconds>
//     scheduled   Moku at launch: the last check two days ago, so Sparkle's own timer checks at once (SPUUpdater.start).
//     background  checkForUpdatesInBackground(), as Moku's remote flags ask when a build is below minVersion.
//     user        checkForUpdates(), as Settings › Check for updates (the standard driver's flow, answered "Install").
//     --install quit  the update installs when the probe quits (Moku's install when you step away, without the wait);
//               now   the immediate installation block (or "Install and Relaunch");
//               none  stop once the update is downloaded and checked: the installer is stopped before it replaces anything.
//   Never relaunches: the installed app may be the real Moku, and only one Moku runs at a time.
import AppKit
import Sparkle

// MARK: - Options and the log

struct Options {
    var mode = "scheduled"
    var install = "quit"
    var timeout: TimeInterval = 900

    init(_ arguments: [String]) {
        var rest = arguments.dropFirst().makeIterator()
        while let flag = rest.next() {
            let value = rest.next() ?? ""
            switch flag {
            case "--mode": mode = value
            case "--install": install = value
            case "--timeout": timeout = TimeInterval(value) ?? timeout
            default: Log.line("unknown option \(flag)")
            }
        }
    }
}

enum Log {
    static let started = Date()
    private static let clock: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func line(_ text: String) {
        let elapsed = String(format: "%7.2f", Date().timeIntervalSince(started))
        print("\(clock.string(from: Date())) +\(elapsed)s \(text)")
        fflush(stdout)
    }

    /// Every layer of an error: domain, code, Sparkle's name for the code, the message, the userInfo, and each underlying error.
    static func describe(_ error: Error, depth: Int = 0) -> String {
        let error = error as NSError
        let pad = String(repeating: "    ", count: depth + 1)
        var text = "\(error.domain) \(error.code)\(codeName(error).map { " (\($0))" } ?? ""): \(error.localizedDescription)"
        let skipped: Set<String> = [NSUnderlyingErrorKey, NSMultipleUnderlyingErrorsKey, NSLocalizedDescriptionKey]
        for (key, value) in error.userInfo.sorted(by: { $0.key < $1.key }) where !skipped.contains(key) {
            text += "\n\(pad)\(key) = \(String(String(describing: value).replacingOccurrences(of: "\n", with: " ").prefix(400)))"
        }
        for underlying in error.underlyingErrors {
            text += "\n\(pad)underlying: " + describe(underlying, depth: depth + 1)
        }
        return text
    }

    private static func codeName(_ error: NSError) -> String? {
        switch error.domain {
        case SUSparkleErrorDomain:
            let names: [Int: String] = [
                1: "SUNoPublicDSAFoundError", 2: "SUInsufficientSigningError", 3: "SUInsecureFeedURLError", 4: "SUInvalidFeedURLError",
                5: "SUInvalidUpdaterError", 6: "SUInvalidHostBundleIdentifierError", 7: "SUInvalidHostVersionError",
                1000: "SUAppcastParseError", 1001: "SUNoUpdateError", 1002: "SUAppcastError", 1003: "SURunningFromDiskImageError",
                1004: "SUResumeAppcastError", 1005: "SURunningTranslocated", 1007: "SUReleaseNotesError",
                2000: "SUTemporaryDirectoryError", 2001: "SUDownloadError",
                3000: "SUUnarchivingError", 3001: "SUSignatureError", 3002: "SUValidationError",
                4000: "SUFileCopyFailure", 4001: "SUAuthenticationFailure", 4002: "SUMissingUpdateError",
                4003: "SUMissingInstallerToolError", 4004: "SURelaunchError", 4005: "SUInstallationError", 4006: "SUDowngradeError",
                4007: "SUInstallationCanceledError", 4008: "SUInstallationAuthorizeLaterError", 4009: "SUNotValidUpdateError",
                4010: "SUAgentInvalidationError", 4012: "SUInstallationWriteNoPermissionError", 5000: "SUIncorrectAPIUsageError",
            ]
            return names[error.code]
        case NSURLErrorDomain, "kCFErrorDomainCFNetwork":
            let names: [Int: String] = [
                -1001: "timed out", -1003: "cannot find host", -1004: "cannot connect to host", -1005: "network connection lost",
                -1009: "not connected to the internet", -1011: "bad server response", -1200: "secure connection failed (TLS)",
                -1202: "server certificate untrusted", -1206: "client certificate required", -999: "cancelled",
            ]
            return names[error.code]
        default:
            return nil
        }
    }

    static func describe(_ item: SUAppcastItem) -> String {
        var parts = ["\(item.displayVersionString) (build \(item.versionString))",
                     item.isDeltaUpdate ? "DELTA" : "full",
                     "url \(item.fileURL?.absoluteString ?? "none")", "length \(item.contentLength)"]
        if let minimum = item.minimumSystemVersion { parts.append("minimumSystemVersion \(minimum) (ok \(item.minimumOperatingSystemVersionIsOK))") }
        if !item.hardwareRequirements.isEmpty { parts.append("hardware \(item.hardwareRequirements.sorted().joined(separator: ",")) (ok \(item.arm64HardwareRequirementIsOK))") }
        if let minimum = item.minimumAutoupdateVersion { parts.append("minimumAutoupdateVersion \(minimum)") }
        if let interval = item.phasedRolloutInterval { parts.append("phasedRolloutInterval \(interval)") }
        if let channel = item.channel { parts.append("channel \(channel)") }
        if item.isCriticalUpdate { parts.append("critical") }
        if item.isInformationOnlyUpdate { parts.append("information only") }
        if let size = item.deltaFromSparkleExecutableSize { parts.append("deltaFromSparkleExecutableSize \(size)") }
        if let deltas = item.deltaUpdates, !deltas.isEmpty {
            parts.append("deltas from builds " + deltas.keys.sorted().joined(separator: ", "))
        }
        parts.append("installationType \(item.installationType)")
        return parts.joined(separator: " · ")
    }
}

// MARK: - What Sparkle tells the app (SPUUpdaterDelegate). Explicit selectors: an optional method with a misspelled Swift
// name would silently never be called.

@MainActor
final class ProbeDelegate: NSObject, SPUUpdaterDelegate {
    let options: Options
    /// Called when the run is over (with what to do next: quit to install, or stop the installer).
    var finish: (_ reason: String) -> Void = { _ in }
    private var downloadStarted: Date?

    init(options: Options) { self.options = options }

    private var hostBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }

    @objc(updater:mayPerformUpdateCheck:error:)
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        Log.line("delegate mayPerformUpdateCheck: \(name(updateCheck)) (feed \(updater.feedURL?.absoluteString ?? "none"))")
    }

    @objc(updater:didFinishLoadingAppcast:)
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Log.line("delegate didFinishLoadingAppcast: \(appcast.items.count) items")
        // What Sparkle weighs for each item, from this app's side: is it newer, does it run here, is there a delta from us.
        let comparator = SUStandardVersionComparator()
        for item in appcast.items {
            let newer = comparator.compareVersion(hostBuild, toVersion: item.versionString) == .orderedAscending
            var verdict = newer ? "newer than this build \(hostBuild)" : "not newer than this build \(hostBuild): skipped"
            if newer && !item.minimumOperatingSystemVersionIsOK { verdict += "; this macOS is too old: skipped" }
            if newer && !item.arm64HardwareRequirementIsOK { verdict += "; needs arm64: skipped" }
            if let delta = item.deltaUpdates?[hostBuild] {
                verdict += "; has a delta from this build (\(delta.fileURL?.lastPathComponent ?? "?"), \(delta.contentLength) bytes)"
            } else if newer {
                verdict += "; no delta from this build: the full archive"
            }
            Log.line("  item \(Log.describe(item))\n      → \(verdict)")
        }
    }

    @objc(updater:didFindValidUpdate:)
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Log.line("delegate didFindValidUpdate: \(Log.describe(item))")
    }

    @objc(updaterDidNotFindUpdate:error:)
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let info = (error as NSError).userInfo
        let reasons = ["unknown", "on the latest version", "newer than the latest", "macOS too old", "macOS too new", "not arm64"]
        let reason = (info[SPUNoUpdateFoundReasonKey] as? NSNumber).map { $0.intValue < reasons.count ? reasons[$0.intValue] : "\($0)" } ?? "?"
        let latest = (info[SPULatestAppcastItemFoundKey] as? SUAppcastItem).map(Log.describe) ?? "none"
        Log.line("delegate updaterDidNotFindUpdate: \(reason); latest in the feed: \(latest)\n    \(Log.describe(error))")
    }

    @objc(updater:shouldProceedWithUpdate:updateCheck:error:)
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        Log.line("delegate shouldProceedWithUpdate: \(updateItem.displayVersionString) (\(name(updateCheck))): yes")
    }

    @objc(updater:userDidMakeChoice:forUpdate:state:)
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        Log.line("delegate userDidMakeChoice: \(name(choice)) for \(updateItem.displayVersionString) at stage \(name(state.stage))")
    }

    @objc(updater:shouldDownloadReleaseNotesForUpdate:)
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { true }

    @objc(updater:willDownloadUpdate:withRequest:)
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        downloadStarted = Date()
        let service = request.networkServiceType == .background ? "BACKGROUND (the system may throttle it)" : "default (\(request.networkServiceType.rawValue))"
        let headers = (request.allHTTPHeaderFields ?? [:]).map { "\($0.key): \($0.value)" }.sorted().joined(separator: "; ")
        Log.line("delegate willDownloadUpdate: GET \(request.url?.absoluteString ?? "?") · \(item.isDeltaUpdate ? "delta" : "full") \(item.contentLength) bytes · network service \(service) · timeout \(Int(request.timeoutInterval)) s · headers \(headers)")
    }

    @objc(updater:didDownloadUpdate:)
    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        let seconds = downloadStarted.map { Date().timeIntervalSince($0) } ?? 0
        let rate = seconds > 0 ? Double(item.contentLength) / seconds / 1_000_000 : 0
        Log.line(String(format: "delegate didDownloadUpdate: %@ (%@) in %.1f s, %.2f MB/s", item.displayVersionString, item.isDeltaUpdate ? "delta" : "full", seconds, rate))
    }

    @objc(updater:failedToDownloadUpdate:error:)
    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        let seconds = downloadStarted.map { Date().timeIntervalSince($0) } ?? 0
        Log.line(String(format: "delegate failedToDownloadUpdate: %@ after %.1f s\n    ", item.displayVersionString, seconds) + Log.describe(error))
    }

    @objc(userDidCancelDownload:)
    func userDidCancelDownload(_ updater: SPUUpdater) { Log.line("delegate userDidCancelDownload") }

    @objc(updater:willExtractUpdate:)
    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        Log.line("delegate willExtractUpdate: \(item.displayVersionString) (\(item.isDeltaUpdate ? "delta" : "full"))")
    }

    @objc(updater:didExtractUpdate:)
    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        Log.line("delegate didExtractUpdate: \(item.displayVersionString) (\(item.isDeltaUpdate ? "delta" : "full")): handed to the installer, which unpacks it and checks its signatures (its own log says how that went)")
    }

    @objc(updater:willInstallUpdate:)
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Log.line("delegate willInstallUpdate: \(item.displayVersionString)")
    }

    @objc(updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        Log.line("delegate shouldPostponeRelaunchForUpdate: no")
        return false
    }

    @objc(updaterShouldRelaunchApplication:)
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        Log.line("delegate updaterShouldRelaunchApplication: NO (the installed app may be the real Moku)")
        return false
    }

    @objc(updaterWillRelaunchApplication:)
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { Log.line("delegate updaterWillRelaunchApplication") }

    @objc(updater:willScheduleUpdateCheckAfterDelay:)
    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        Log.line(String(format: "delegate willScheduleUpdateCheckAfterDelay: %.0f s (%.1f h)", delay, delay / 3600))
    }

    @objc(updaterWillNotScheduleUpdateCheck:)
    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) { Log.line("delegate updaterWillNotScheduleUpdateCheck") }

    @objc(updater:willInstallUpdateOnQuit:immediateInstallationBlock:)
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        Log.line("delegate willInstallUpdateOnQuit: \(item.displayVersionString) is downloaded, checked and waiting (Moku logs \"is ready\" here)")
        switch options.install {
        case "now":
            Log.line("probe: calling the immediate installation block")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { immediateInstallHandler() }
        default:
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.finish("update ready") }
        }
        return true
    }

    @objc(updater:didAbortWithError:)
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Log.line("delegate didAbortWithError:\n    \(Log.describe(error))")
    }

    @objc(updater:didFinishUpdateCycleForUpdateCheck:error:)
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            Log.line("delegate didFinishUpdateCycle (\(name(updateCheck))) with error:\n    \(Log.describe(error))")
        } else {
            Log.line("delegate didFinishUpdateCycle (\(name(updateCheck))): no error")
        }
        Log.line("  next: lastUpdateCheckDate \(updater.lastUpdateCheckDate.map { "\($0)" } ?? "none"), sessionInProgress \(updater.sessionInProgress)")
        // A cycle that ends without an update waiting (no update, or an error) is the end of the run.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !updater.sessionInProgress, self.options.install != "now" || error != nil else { return }
            self.finish(error == nil ? "cycle finished" : "cycle failed")
        }
    }
}

// MARK: - What Moku's standard user driver would have shown (SPUUserDriver): logged, and answered as a person would.

@MainActor
final class ProbeUserDriver: NSObject, SPUUserDriver {
    let options: Options
    private var expected: UInt64 = 0
    private var received: UInt64 = 0
    private var lastProgressLog = Date.distantPast

    init(options: Options) { self.options = options }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        Log.line("driver showUpdatePermissionRequest (Moku's Info.plist sets SUEnableAutomaticChecks, so this should not appear): answering yes")
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, automaticUpdateDownloading: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        Log.line("driver showUserInitiatedUpdateCheck (the \"Checking for updates…\" window)")
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        Log.line("driver showUpdateFound: \(Log.describe(appcastItem)) · stage \(name(state.stage)) · userInitiated \(state.userInitiated): answering Install")
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        Log.line("driver showUpdateReleaseNotes: \(downloadData.data.count) bytes from \(downloadData.url.absoluteString)")
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        Log.line("driver showUpdateReleaseNotesFailedToDownload:\n    \(Log.describe(error))")
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        Log.line("driver showUpdateNotFound (the \"You're up to date!\" alert):\n    \(Log.describe(error))")
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        Log.line("driver showUpdaterError (the \"Update Error!\" alert):\n    \(Log.describe(error))")
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expected = 0; received = 0
        Log.line("driver showDownloadInitiated")
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
        Log.line("driver showDownloadDidReceiveExpectedContentLength: \(expectedContentLength) bytes")
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        if Date().timeIntervalSince(lastProgressLog) >= 5 || received == expected {
            lastProgressLog = Date()
            let percent = expected > 0 ? Double(received) / Double(expected) * 100 : 0
            Log.line(String(format: "driver download progress: %llu of %llu bytes (%.0f%%)", received, expected, percent))
        }
    }

    func showDownloadDidStartExtractingUpdate() { Log.line("driver showDownloadDidStartExtractingUpdate") }

    func showExtractionReceivedProgress(_ progress: Double) {
        if progress == 0 || progress >= 1 { Log.line(String(format: "driver extraction progress %.0f%%", progress * 100)) }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let choice: SPUUserUpdateChoice = options.install == "now" ? .install : .dismiss
        Log.line("driver showReadyToInstallAndRelaunch: answering \(name(choice)) (--install \(options.install))")
        reply(choice)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        Log.line("driver showInstallingUpdate: applicationTerminated \(applicationTerminated)")
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        Log.line("driver showUpdateInstalledAndRelaunched: relaunched \(relaunched)")
        acknowledgement()
    }

    func showUpdateInFocus() { Log.line("driver showUpdateInFocus") }

    func dismissUpdateInstallation() { Log.line("driver dismissUpdateInstallation") }
}

// MARK: - Names for Sparkle's enums

func name(_ check: SPUUpdateCheck) -> String {
    switch check {
    case .updates: "user-initiated check"
    case .updatesInBackground: "background check"
    case .updateInformation: "information check"
    @unknown default: "check \(check.rawValue)"
    }
}

func name(_ choice: SPUUserUpdateChoice) -> String {
    switch choice {
    case .skip: "skip"
    case .install: "install"
    case .dismiss: "dismiss (install on quit)"
    @unknown default: "choice \(choice.rawValue)"
    }
}

func name(_ stage: SPUUserUpdateStage) -> String {
    switch stage {
    case .notDownloaded: "not downloaded"
    case .downloaded: "downloaded"
    case .installing: "installing"
    @unknown default: "stage \(stage.rawValue)"
    }
}

// MARK: - The app

@MainActor
final class Probe: NSObject, NSApplicationDelegate {
    let options = Options(CommandLine.arguments)
    lazy var delegate = ProbeDelegate(options: options)
    lazy var driver = ProbeUserDriver(options: options)
    lazy var updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: delegate)
    private var finished = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let info = Bundle.main.infoDictionary ?? [:]
        Log.line("probe: \(Bundle.main.bundlePath) · \(info["CFBundleIdentifier"] ?? "?") \(info["CFBundleShortVersionString"] ?? "?") (build \(info["CFBundleVersion"] ?? "?")) · mode \(options.mode) · install \(options.install) · pid \(getpid())")
        Log.line("probe: SUFeedURL \(info["SUFeedURL"] ?? "none") · SUPublicEDKey \(info["SUPublicEDKey"] ?? "none")")
        if let sparkle = Bundle(for: SPUUpdater.self).executableURL?.resolvingSymlinksInPath(),
           let size = try? FileManager.default.attributesOfItem(atPath: sparkle.path)[.size] {
            Log.line("probe: Sparkle \(Bundle(for: SPUUpdater.self).infoDictionary?["CFBundleShortVersionString"] ?? "?") executable \(size) bytes (deltas name the size they were made against)")
        }
        delegate.finish = { [weak self] reason in self?.finish(reason) }
        do {
            try updater.start()
        } catch {
            Log.line("probe: SPUUpdater.start failed:\n    \(Log.describe(error))")
            exit(2)
        }
        Log.line("probe: started · automaticallyChecksForUpdates \(updater.automaticallyChecksForUpdates) · automaticallyDownloadsUpdates \(updater.automaticallyDownloadsUpdates) · updateCheckInterval \(Int(updater.updateCheckInterval)) s · lastUpdateCheckDate \(updater.lastUpdateCheckDate.map { "\($0)" } ?? "none") · userAgent \(updater.userAgentString)")
        switch options.mode {
        case "background": updater.checkForUpdatesInBackground()
        case "user": updater.checkForUpdates()
        default: break  // "scheduled": Sparkle's own timer, which fires at once because the last check was two days ago
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + options.timeout) { [weak self] in
            self?.finish("TIMEOUT after \(Int(self?.options.timeout ?? 0)) s, still in a session: \(self?.updater.sessionInProgress ?? false)")
        }
    }

    func finish(_ reason: String) {
        guard !finished else { return }
        finished = true
        Log.line("probe: done (\(reason))")
        if options.install == "none" || reason.hasPrefix("TIMEOUT") {
            // Stop the installer this probe started, before it replaces anything when the probe quits.
            let stop = Process()
            stop.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            stop.arguments = ["-f", "Autoupdate.* \(Bundle.main.bundleIdentifier ?? "-")( |$)"]
            try? stop.run(); stop.waitUntilExit()
            Log.line("probe: stopped this probe's installer (if one was waiting); nothing is installed")
            exit(0)
        }
        Log.line("probe: quitting (a waiting update installs now, never relaunched)")
        NSApp.terminate(nil)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)  // no Dock icon, no menu bar, never in front
    let probe = Probe()
    app.delegate = probe
    app.run()
}
