import AppKit
import MokuKit
import MokuMind
import Sparkle

/// Lets an update actually land in an app that never quits. Sparkle downloads an update quietly and would install it
/// the next time Moku quits, which could be weeks away. So once an update is waiting, Moku installs it (and is back
/// about two seconds later) the first time the person has been away from the Mac for five minutes.
///
/// It also tells the usage events (docs/specs/next-0-1-9.md §2) how updates go, from Sparkle's own delegate calls: each
/// check (up to date, found, or an error's kind), a download, and why a Mac is stuck (a download or a signature that
/// failed, no permission to replace the app, waiting a day for the person to step away). Versions and fixed words only.
///
/// And it writes every step to the app's log, with every layer of an error (2026-10-06: Charles's 0.1.8 said only "An
/// error occurred while downloading the update"; under it, the delta didn't apply and then the network reset the full
/// download). A check that failed for the network is tried again soon (UpdateRetry), not a day later. Settings shows
/// how the last check went (`onOutcome`). scripts/check-update-live.sh runs the same Sparkle with the same steps logged.
@MainActor
final class QuietUpdates: NSObject, SPUUpdaterDelegate {
    static let awaySeconds: TimeInterval = 300
    /// Waiting this long for the person to step away is `update_stuck` (waiting_for_away), once.
    static let stuckWaitingAfter: TimeInterval = 86_400
    private var installNow: (() -> Void)?
    private var watch: Timer?
    private var waitingSince: Date?
    private var reportedWaiting = false
    /// Set by the app: records `update_check`, `update_downloaded` and `update_stuck`.
    var track: UsageTracker?
    /// Set by the app: a background check, for trying again after the network failed.
    var checkInBackground: (() -> Void)?
    /// Set by the app: how the last check went, for Settings.
    var onOutcome: ((UpdateOutcome) -> Void)?
    private var retry = UpdateRetry()
    private var retryTimer: Timer?
    private var download: (item: SUAppcastItem, started: Date)?

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        AppLog.write("updates: \(item.displayVersionString) is ready; installing when the Mac has been idle \(Int(Self.awaySeconds / 60)) minutes")
        onOutcome?(.ready(version: item.displayVersionString))
        installNow = immediateInstallationBlock
        waitingSince = waitingSince ?? Date()
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installIfAway() }
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        AppLog.write("updates: found \(item.displayVersionString) (build \(item.versionString)), \(Self.describe(item))")
        UpdateFacts.noteRelease(version: item.displayVersionString, date: item.date)
        track?("update_check", ["result": .word("found")])
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        let reasons = ["unknown reason", "on the latest version", "newer than the latest", "macOS too old", "macOS too new", "not arm64"]
        let reason = ((error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber).map { reasons.indices.contains($0.intValue) ? reasons[$0.intValue] : "\($0)" }
        AppLog.write("updates: up to date (\(reason ?? "no reason given"))")
        onOutcome?(.upToDate(at: Date()))
        track?("update_check", ["result": .word("up_to_date")])
    }

    @objc(updater:willDownloadUpdate:withRequest:)  // explicit: a misspelled optional delegate method is never called, silently
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        // A full download right after a delta is Sparkle falling back: the delta didn't apply to this Mac's copy.
        let fallback = download.map { $0.item.isDeltaUpdate && !item.isDeltaUpdate } ?? false
        download = (item, Date())
        AppLog.write("updates: downloading \(item.displayVersionString), \(Self.describe(item))\(fallback ? ", because the delta didn't apply to this copy" : "") from \(request.url?.absoluteString ?? "?")\(request.networkServiceType == .background ? " (background priority)" : "")")
        onOutcome?(.downloading(version: item.displayVersionString))
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        let seconds = download.map { Date().timeIntervalSince($0.started) } ?? 0
        AppLog.write(String(format: "updates: downloaded %@ in %.0f s (%.2f MB/s)", item.displayVersionString, seconds, seconds > 0 ? Double(item.contentLength) / seconds / 1_000_000 : 0))
        track?("update_downloaded", ["to": .word(item.displayVersionString)])
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        let seconds = download.map { Date().timeIntervalSince($0.started) } ?? 0
        AppLog.write("updates: download of \(item.displayVersionString) failed after \(Int(seconds)) s: \(UpdateFacts.describe(error as NSError))")
        track?("update_stuck", ["why": .word("download_failed")].merging(UpdateFacts.facts(of: error as NSError)) { a, _ in a })
        ErrorReports.report(.sparkle, error)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let kind = UpdateFacts.kind(of: error as NSError)
        guard kind != "none" else { return }  // "no update" arrives here too
        AppLog.write("updates: stopped (\(kind)): \(UpdateFacts.describe(error as NSError))")
        let facts = UpdateFacts.facts(of: error as NSError)
        track?("update_check", ["result": .word("error"), "error": .word(kind)].merging(facts) { a, _ in a })
        ErrorReports.report(.sparkle, error)
        if let why = UpdateFacts.stuck(kind) { track?("update_stuck", ["why": .word(why)].merging(facts) { a, _ in a }) }
    }

    /// The end of every check: when it failed for the network or a server's passing refusal, the next try is soon, not in a day.
    @objc(updater:didFinishUpdateCycleForUpdateCheck:error:)
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        download = nil
        let error = error.map { $0 as NSError }
        guard error.map({ UpdateFacts.kind(of: $0) != "none" }) ?? false, let error else {
            _ = retry.next(after: nil)
            return
        }
        retryTimer?.invalidate()
        let delay = retry.next(after: error)
        if let delay {
            AppLog.write("updates: trying again in \(Int(delay / 60)) minutes (the network or the server failed for now)")
            retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkInBackground?() }
            }
            retryTimer?.tolerance = 60
        }
        onOutcome?(.failed(at: Date(), network: UpdateFacts.isNetwork(error), reason: UpdateOutcome.reason(of: error),
                           retryAt: delay.map { Date().addingTimeInterval($0) }))
    }

    @objc(updater:willScheduleUpdateCheckAfterDelay:)
    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        AppLog.write(String(format: "updates: next scheduled check in %.1f hours", delay / 3600))
    }

    private static func describe(_ item: SUAppcastItem) -> String {
        String(format: "%@ %.1f MB", item.isDeltaUpdate ? "a delta of" : "the full update,", Double(item.contentLength) / 1_000_000)
    }

    private func installIfAway() {
        if let waitingSince, !reportedWaiting, Date().timeIntervalSince(waitingSince) >= Self.stuckWaitingAfter {
            reportedWaiting = true
            track?("update_stuck", ["why": .word("waiting_for_away")])
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= Self.awaySeconds, let installNow else { return }
        watch?.invalidate()
        self.installNow = nil
        AppLog.write("updates: installing now (idle \(Int(idle)) s)")
        AppLifecycle.quitReason = "update"
        installNow()
    }
}
