import AppKit
import MokuKit

/// Counters for measuring the sensors themselves.
public struct SenseDiagnostics: Sendable, Equatable {
    public var samples = 0
    public var focusChanges = 0
    public var accessibilityTextReads = 0
    public var ocrRuns = 0
    public var ocrMilliseconds = 0.0
}

/// Moku's senses. Turns what the user is doing into `SenseEvent`s, exactly as MokuKit describes them:
/// - `.permissions` on start and whenever a permission changes;
/// - `.focusChanged` as soon as the frontmost app or its focused window changes;
/// - `.attention` when the pointer moves, at most ~15 per second;
/// - `.meeting` on start and whenever call or screen-share state changes;
/// - `.sample` every `sampleInterval` seconds.
///
/// Moku's own windows (bundle id `ai.lightslips.moku`) are never read: while Moku is frontmost, the
/// sensors keep describing the app the user was in before.
///
/// Apps the person chose to ignore (`ignoresApp`) are never read either: while one is in front, nothing about it is
/// read and no sample or focus change is sent. Calls and screen sharing are still noticed, from the microphone, the
/// camera and the other apps' windows. `onStepAsideChange` says when an app Moku steps aside for (`stepsAsideFor`,
/// ignored or not) comes to the front or leaves it, so the character can hide.
///
/// `onFullScreenChange` tells which displays have something full screen on them (`FullScreenRules`), so the character
/// can step aside. It's worked out from the window list, which needs no permission, and reads no content.
///
/// Without Accessibility, samples carry the app, a window title only if Screen Recording is granted,
/// no browser address, and system-wide input counts. Without Screen Recording there is no OCR.
/// Call `stop()` before releasing the hub.
@MainActor
public final class SenseHub {
    public static let mokuBundleId = "ai.lightslips.moku"

    public let sampleInterval: TimeInterval
    public let ocrEnabled: Bool
    /// Single consumer. Keeps the newest 512 events if the consumer falls behind.
    public let events: AsyncStream<SenseEvent>
    /// Frame of the focused window being read, in AppKit global coordinates.
    public private(set) var focusedWindowFrame: CGRect?
    /// True for an app the person asked Moku not to watch (by bundle id). Asked at every focus read and sample, so a
    /// change in Settings counts within seconds.
    public var ignoresApp: @MainActor (String) -> Bool = { _ in false }
    /// True for an app Moku hides for while it's in front (ignored or still watched).
    public var stepsAsideFor: @MainActor (String) -> Bool = { _ in false }
    /// Called when the front app starts or stops being one Moku steps aside for, and with false when the senses stop.
    public var onStepAsideChange: (@MainActor (Bool) -> Void)?
    public private(set) var steppingAside = false
    /// The displays with a full-screen window on them (`CGDirectDisplayID`s), called when that set changes, and with an
    /// empty set when the senses stop.
    public var onFullScreenChange: (@MainActor (Set<UInt32>) -> Void)?
    public private(set) var fullScreenDisplays: Set<UInt32> = []

    private let continuation: AsyncStream<SenseEvent>.Continuation
    private let windowReader = WindowReader()
    private let screenText = ScreenTextReader()
    private let input = InputRhythm()
    private let attention = AttentionTracker()
    private let runningApps = RunningApps()
    private var focusWatcher: FocusWatcher?
    private var ids = SampleIDGenerator()
    private var stats = SenseDiagnostics()

    private var running = false
    private var permissions = PermissionStatus(accessibility: false, screenRecording: false)
    /// The app being read: the frontmost app, or the one before it while Moku is frontmost.
    private var target: Target?
    private var lastFocus: FocusedContext?
    private var meeting: MeetingContext?
    private var lastSentTextHash: String?
    private var sampleTask: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?
    private var focusReadPending = false
    private var fullScreenRecheck: Task<Void, Never>?
    /// Full-screen windows seen playing: they keep Moku away until they leave full screen (`FullScreenMedia`).
    private var mediaWindows: Set<CGWindowID> = []
    /// The full-screen check alone, while the senses are stopped for a break (`stop(keepWatchingFullScreen:)`).
    private var fullScreenWatch: Task<Void, Never>?

    public init(sampleInterval: TimeInterval = 3, ocrEnabled: Bool = true) {
        self.sampleInterval = max(0.5, sampleInterval)
        self.ocrEnabled = ocrEnabled
        (events, continuation) = AsyncStream.makeStream(of: SenseEvent.self, bufferingPolicy: .bufferingNewest(512))
    }

    deinit {
        continuation.finish()
    }

    public static func permissionStatus() -> PermissionStatus {
        Permissions.current()
    }

    /// Shows the system prompts for Accessibility and Screen Recording, for whichever is missing.
    public static func requestPermissions() {
        Permissions.request()
    }

    /// Shows the system prompt for one permission, if it isn't granted yet.
    public static func requestPermission(_ kind: PermissionKind) {
        Permissions.request(kind)
    }

    public func start() {
        guard !running else { return }
        running = true
        fullScreenWatch?.cancel()
        fullScreenWatch = nil
        permissions = Permissions.current()
        continuation.yield(.permissions(permissions))

        runningApps.start()
        input.start(accessibility: permissions.accessibility)
        attention.start { [weak self] point in self?.continuation.yield(.attention(point)) }
        let watcher = FocusWatcher { [weak self] change in self?.focusMayHaveChanged(change) }
        watcher.start()
        focusWatcher = watcher
        focusMayHaveChanged(.appSwitched)

        sampleTask = Task { [weak self] in
            let clock = ContinuousClock()
            var next = clock.now
            while !Task.isCancelled {
                guard let interval = await self?.takeSample() else { return }
                next = max(next.advanced(by: .seconds(interval)), clock.now)
                try? await Task.sleep(until: next, tolerance: .milliseconds(250), clock: clock)
            }
        }
    }

    /// `keepWatchingFullScreen`: a break stops the senses, but a film may play through it (that's when people watch
    /// one), so the full-screen check alone goes on every few seconds and Moku doesn't doze over the film.
    public func stop(keepWatchingFullScreen: Bool = false) {
        guard running else { return }
        running = false
        sampleTask?.cancel()
        sampleTask = nil
        focusTask?.cancel()
        focusTask = nil
        attention.stop()
        input.stop()
        focusWatcher?.stop()
        focusWatcher = nil
        runningApps.stop()
        target = nil
        lastFocus = nil
        meeting = nil
        lastSentTextHash = nil
        updateSteppingAside()  // false: stopped
        fullScreenRecheck?.cancel()
        fullScreenRecheck = nil
        if keepWatchingFullScreen {
            fullScreenWatch = Task { [weak self, sampleInterval] in
                while !Task.isCancelled {
                    self?.refreshFullScreen(evenStopped: true)
                    try? await Task.sleep(for: .seconds(sampleInterval), tolerance: .seconds(1))
                }
            }
        } else {
            mediaWindows = []
            setFullScreen([])
        }
        let screenText = screenText
        Task { await screenText.reset() }
    }

    public func diagnostics() async -> SenseDiagnostics {
        var diagnostics = stats
        diagnostics.ocrRuns = await screenText.ocrRuns
        diagnostics.ocrMilliseconds = await screenText.ocrMilliseconds
        return diagnostics
    }

    // MARK: Focus

    private func focusMayHaveChanged(_ change: FocusWatcher.Change) {
        guard running else { return }
        if change == .appSwitched {
            retarget()
            refreshFullScreen()
            recheckFullScreenWhenSettled()
        }
        guard focusTask == nil else {
            focusReadPending = true
            return
        }
        focusTask = Task { [weak self] in
            // Title changes arrive in bursts (a page loading); let them settle.
            if change == .title { try? await Task.sleep(for: .milliseconds(150)) }
            await self?.readFocusUntilSettled()
        }
    }

    /// Emits at once with what is cheap to read. A browser address that needs the bounded tree search
    /// follows in a second `.focusChanged` for the same window.
    private func readFocusUntilSettled() async {
        defer { focusTask = nil }
        repeat {
            focusReadPending = false
            guard running, let target, !ignoresApp(target.info.bundleId) else { return }
            let quick = await windowReader.focus(pid: target.pid, bundleId: target.info.bundleId, searchURL: false)
            guard running else { return }
            publishFocus(app: target.info, window: quick)
            if quick.urlPending, !focusReadPending {
                let full = await windowReader.focus(pid: target.pid, bundleId: target.info.bundleId, searchURL: true)
                guard running, !focusReadPending else { continue }
                publishFocus(app: target.info, window: full)
            }
        } while focusReadPending
    }

    /// Follows the frontmost app, except Moku itself. When Moku is frontmost with no earlier app (it was
    /// just launched and activated), or the app being read quit, it takes the owner of the frontmost window.
    private func retarget() {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            let info = runningApps.info(for: front)
            if info.bundleId != Self.mokuBundleId {
                target = Target(pid: front.processIdentifier, info: info)
            }
        }
        if let current = target, runningApps.apps[current.pid] == nil {
            target = nil
        }
        if target == nil {
            target = ownerOfFrontmostWindow()
        }
        observeFocus()
    }

    /// The window and title watch follows the app being read, and nothing at all while that app is ignored.
    private func updateSteppingAside() {
        let aside = running && target.map { stepsAsideFor($0.info.bundleId) } == true
        guard aside != steppingAside else { return }
        steppingAside = aside
        onStepAsideChange?(aside)
    }

    private func observeFocus() {
        updateSteppingAside()
        let watched = target.flatMap { ignoresApp($0.info.bundleId) ? nil : $0 }
        focusWatcher?.observe(pid: watched?.pid, accessibility: permissions.accessibility)
    }

    private func ownerOfFrontmostWindow() -> Target? {
        for window in WindowList.onScreen() where window.layer == 0 && window.pid != getpid() {
            if let info = runningApps.apps[window.pid], info.bundleId != Self.mokuBundleId {
                return Target(pid: window.pid, info: info)
            }
        }
        return nil
    }

    private func publishFocus(app: AppInfo, window: WindowReading) {
        focusedWindowFrame = window.frame.map {
            ScreenGeometry.appKitRect(fromQuartz: $0, primaryDisplayHeight: ScreenGeometry.primaryDisplayHeight)
        }
        let info = shared(window, app: app)
        let context = FocusedContext(app: app, window: info)
        guard context != lastFocus else { return }
        lastFocus = context
        stats.focusChanges += 1
        continuation.yield(.focusChanged(app, info))
        // A new page may be a reel, or work after one: the full-screen answer follows at once, not at the next sample.
        refreshFullScreen()
    }

    /// The window as Moku may pass it on: a sensitive screen's title is blanked (it can name a vault item).
    private func shared(_ window: WindowReading, app: AppInfo) -> WindowInfo? {
        guard var info = window.info else { return nil }
        if SensitiveScreens.contains(bundleId: app.bundleId, url: info.url) { info.title = "" }
        return info
    }

    // MARK: Samples

    /// Returns the interval until the next sample, or nil once stopped.
    private func takeSample() async -> TimeInterval? {
        guard running else { return nil }
        if target.map({ runningApps.apps[$0.pid] == nil }) ?? true { retarget() }
        refreshFullScreen()
        guard let target else { return sampleInterval }
        // An ignored app: nothing read, nothing sent, and its windows aren't watched. (Settings may have just added it.)
        observeFocus()
        updateSteppingAside()
        guard !ignoresApp(target.info.bundleId) else {
            // Nothing read from the app, but a call or a shared screen must still hide Moku.
            let reading = await windowReader.sampleSkipping(pid: target.pid)
            guard running else { return nil }
            update(permissions: reading.permissions)
            updateMeeting(from: reading, focusedApp: target.info)
            return sampleInterval
        }
        let now = Date()
        let reading = await windowReader.sample(pid: target.pid, bundleId: target.info.bundleId)
        guard running else { return nil }
        update(permissions: reading.permissions)
        updateMeeting(from: reading, focusedApp: target.info)
        let text = await readText(pid: target.pid, bundleId: target.info.bundleId, reading: reading)
        guard running else { return nil }
        publishFocus(app: target.info, window: reading.window)

        stats.samples += 1
        continuation.yield(.sample(ActivitySample(
            id: ids.next(at: now), ts: now, app: target.info, window: shared(reading.window, app: target.info),
            text: text.text, textSource: text.source, textHash: text.hash,
            activity: input.snapshot(), context: meeting ?? .none)))
        return sampleInterval
    }

    /// Accessibility text when the focused view offers a large one, else OCR (never for media players). The text itself
    /// is sent only when it differs from the last text sent; the hash is sent whenever text was read.
    private func readText(pid: pid_t, bundleId: String, reading: SampleReading) async -> (text: String?, source: TextSource?, hash: String?) {
        if SensitiveScreens.contains(bundleId: bundleId, url: reading.window.url) { return (nil, nil, nil) }
        var full: String?
        var source: TextSource?
        if let text = reading.accessibilityText {
            full = text
            source = .accessibility
            stats.accessibilityTextReads += 1
        } else if ocrEnabled, OCRPolicy.reads(bundleId: bundleId), reading.permissions.screenRecording, let windowID = reading.window.windowID {
            let key = WindowKey(pid: pid, windowID: windowID)
            let now = ProcessInfo.processInfo.systemUptime
            if let screen = await screenText.read(key, frame: reading.window.frame, now: now) {
                full = screen.text
                source = .ocr
            }
        }
        guard let full, !full.allSatisfy(\.isWhitespace) else { return (nil, nil, nil) }
        let hash = TextDigest.sha256(full)
        defer { lastSentTextHash = hash }
        return (hash == lastSentTextHash ? nil : TextDigest.capped(full), source, hash)
    }

    private func updateMeeting(from reading: SampleReading, focusedApp: AppInfo) {
        var windows = reading.windows.compactMap { entry -> TitledWindow? in
            guard let bundleId = runningApps.apps[entry.pid]?.bundleId, bundleId != Self.mokuBundleId else { return nil }
            return TitledWindow(bundleId: bundleId, title: entry.title)
        }
        if let title = reading.window.title {
            windows.append(TitledWindow(bundleId: focusedApp.bundleId, title: title))
        }
        let evidence = MeetingEvidence(
            micInUse: reading.micInUse, cameraInUse: reading.cameraInUse,
            runningBundleIds: runningApps.bundleIds.subtracting([Self.mokuBundleId]),
            windows: windows, focusedURL: reading.window.url, focusedBundleId: focusedApp.bundleId)
        let context = MeetingRules.context(from: evidence, previous: meeting ?? .none)
        guard context != meeting else { return }
        meeting = context
        continuation.yield(.meeting(context))
    }

    private func update(permissions current: PermissionStatus) {
        guard current != permissions else { return }
        permissions = current
        input.update(accessibility: current.accessibility)
        observeFocus()
        continuation.yield(.permissions(current))
    }

    // MARK: Full screen

    private func refreshFullScreen(evenStopped: Bool = false) {
        guard running || evenStopped else { return }
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let displays = ids.prefix(Int(count)).map { FullScreenRules.Display(id: $0, bounds: CGDisplayBounds($0)) }
        let covering = FullScreenRules.coveringWindows(windows: WindowList.onScreen(), displays: displays, ownPID: getpid())
        // The power manager is asked only while something is full screen: most samples skip it.
        let playing = covering.isEmpty ? [] : MediaPlayback.playingPIDs(MediaPlayback.displayAwakeAssertions())
        // The page in front, when it's known: a browser on a site for watching counts with no keep-awake lock (a muted
        // reel takes none), and one moved to a page of work stops counting. The address is the one read for judging
        // anyway; an ignored app's is never read.
        let front = frontPage()
        let media = FullScreenMedia.displays(covering: covering, playing: playing, isWatchingApp: { pid in
            if front?.pid == pid, front?.isMedia == true { return true }
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map(MediaPlayback.watchingApps.contains) ?? false
        }, isOnWorkPage: { pid in front?.pid == pid && front?.isMedia == false }, remembered: mediaWindows)
        mediaWindows = media.remembered
        setFullScreen(media.displays)
    }

    /// The app in front and whether its page is on a site for watching; nil when no page address is known.
    private func frontPage() -> (pid: pid_t, isMedia: Bool)? {
        guard let target, let focus = lastFocus, focus.app.bundleId == target.info.bundleId,
              let address = focus.window?.url else { return nil }
        return (target.pid, MediaPlayback.isMediaPage(address))
    }

    private func setFullScreen(_ displays: Set<UInt32>) {
        guard displays != fullScreenDisplays else { return }
        fullScreenDisplays = displays
        onFullScreenChange?(displays)
    }

    /// A full-screen switch takes most of a second to settle (the window grows, the menu bar slides away): look again
    /// once it has, so the answer doesn't wait for the next sample.
    private func recheckFullScreenWhenSettled() {
        fullScreenRecheck?.cancel()
        fullScreenRecheck = Task { [weak self] in
            for wait in [Duration.milliseconds(900), .milliseconds(1500)] {
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
                self?.refreshFullScreen()
            }
        }
    }

}

private struct Target: Equatable {
    var pid: pid_t
    var info: AppInfo
}

/// What `.focusChanged` reports, for spotting real changes.
private struct FocusedContext: Equatable {
    var app: AppInfo
    var window: WindowInfo?
}
