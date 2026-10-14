import ApplicationServices
import CoreGraphics
import Foundation
import MokuKit
import os

/// What Moku can see of the target app's focused window.
struct WindowReading: Sendable {
    var windowID: CGWindowID?
    /// Normalized; nil when neither Accessibility nor the window server gave one.
    var title: String?
    var url: String?
    /// Quartz global coordinates.
    var frame: CGRect?
    /// A browser window whose address was not in the cache; a read with `searchURL` will find it.
    var urlPending = false

    var info: WindowInfo? {
        guard title != nil || url != nil else { return nil }
        return WindowInfo(title: title ?? "", url: url)
    }
}

/// Everything a sample needs that costs a system call.
struct SampleReading: Sendable {
    var permissions: PermissionStatus
    var window: WindowReading
    /// Visible text of the focused text view when Accessibility offers a large one.
    var accessibilityText: String?
    var windows: [WindowEntry]
    var micInUse: Bool
    var cameraInUse: Bool
}

/// Reads windows through Accessibility and the window server. Those calls block on IPC with other
/// apps, so the actor runs on its own utility queue: never on the main thread, never on the
/// cooperative pool.
actor WindowReader {
    /// Accessibility text shorter than this is a field, not the window's content; OCR does better.
    static let minAccessibilityTextLength = 200
    /// Beyond this, reading a text view's whole value is no longer cheap.
    static let maxAccessibilityValueLength = 100_000
    /// The Screen Recording check is a synchronous round trip to tccd, and a new grant only takes
    /// effect after a relaunch anyway, so it is repeated at most this often.
    static let screenRecordingCheckInterval: TimeInterval = 30

    private let queue = DispatchSerialQueue(label: "ai.lightslips.moku.sense.windows", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// The web area last found, valid while the same window shows the same title (a tab switch or a
    /// navigation changes the title; a background tab's web area would report the wrong address).
    private var webAreaCache: (pid: pid_t, window: AXUIElement, title: String?, webArea: AXUIElement)?
    private var chromiumAccessibilityEnabled: Set<pid_t> = []
    /// When each browser's address search last logged how it went (at most once a minute per browser).
    private var searchLoggedAt: [String: Date] = [:]
    private static let log = Logger(subsystem: "ai.lightslips.moku", category: "sense")
    private var screenRecording: (granted: Bool, checkedAt: TimeInterval)?

    init() {
        AX.boundTimeouts()
    }

    /// A quick read for focus changes. With `searchURL` false a browser address comes only from the
    /// cache, and `urlPending` says whether a second read with `searchURL` is worth it.
    func focus(pid: pid_t, bundleId: String, searchURL: Bool) -> WindowReading {
        read(pid: pid, bundleId: bundleId, accessibility: AXIsProcessTrusted(), searchURL: searchURL,
             windows: WindowList.onScreen()).window
    }

    /// What a call check needs while an ignored app is in front: nothing read from that app (not its windows' titles,
    /// not its focused window), only the microphone, the camera and the other apps' windows.
    func sampleSkipping(pid: pid_t) -> SampleReading {
        let permissions = PermissionStatus(accessibility: AXIsProcessTrusted(), screenRecording: screenRecordingGranted())
        let others = WindowList.onScreen().filter { $0.pid != pid }
        return SampleReading(permissions: permissions, window: WindowReading(), accessibilityText: nil, windows: others,
                             micInUse: MediaDevices.microphoneInUse(), cameraInUse: MediaDevices.cameraInUse())
    }

    func sample(pid: pid_t, bundleId: String) -> SampleReading {
        let permissions = PermissionStatus(accessibility: AXIsProcessTrusted(), screenRecording: screenRecordingGranted())
        let windows = WindowList.onScreen()
        let (window, focusedWindow) = read(pid: pid, bundleId: bundleId, accessibility: permissions.accessibility,
                                           searchURL: true, windows: windows)
        let text = focusedWindow != nil ? focusedText(pid: pid) : nil
        return SampleReading(permissions: permissions, window: window, accessibilityText: text, windows: windows,
                             micInUse: MediaDevices.microphoneInUse(), cameraInUse: MediaDevices.cameraInUse())
    }

    private func screenRecordingGranted() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let screenRecording, now - screenRecording.checkedAt < Self.screenRecordingCheckInterval {
            return screenRecording.granted
        }
        let granted = CGPreflightScreenCaptureAccess()
        screenRecording = (granted, now)
        return granted
    }

    private func read(pid: pid_t, bundleId: String, accessibility: Bool, searchURL: Bool,
                      windows: [WindowEntry]) -> (window: WindowReading, element: AXUIElement?) {
        var reading = WindowReading()
        var element: AXUIElement?
        if accessibility {
            let app = AXUIElementCreateApplication(pid)
            element = AX.element(app, kAXFocusedWindowAttribute) ?? AX.element(app, kAXMainWindowAttribute)
            if let element {
                reading.title = AX.string(element, kAXTitleAttribute).map(Normalize.title)
                reading.frame = AX.frame(element)
                if Browsers.all.contains(bundleId) {
                    let url = browserURL(pid: pid, bundleId: bundleId, app: app, window: element,
                                         title: reading.title, search: searchURL)
                    reading.url = Normalize.url(url)
                    reading.urlPending = url == nil && !searchURL
                }
            }
        }
        if let entry = WindowList.focusedWindow(of: pid, in: windows, accessibilityFrame: reading.frame) {
            reading.windowID = entry.id
            reading.frame = reading.frame ?? entry.bounds
            if reading.title?.isEmpty ?? true, !entry.title.isEmpty {
                reading.title = Normalize.title(entry.title)
            }
        }
        return (reading, element)
    }

    // MARK: Browser address

    /// The focused tab's address from the AXWebArea's AXURL, found by a bounded search (when `search`
    /// is true) and cached per window and title.
    private func browserURL(pid: pid_t, bundleId: String, app: AXUIElement, window: AXUIElement,
                            title: String?, search: Bool) -> String? {
        if let cache = webAreaCache, cache.pid == pid, cache.title == title, CFEqual(cache.window, window),
           let url = AX.url(cache.webArea) {
            return url
        }
        guard search else { return nil }
        webAreaCache = nil
        var manual: Bool?
        if Browsers.chromium.contains(bundleId), !chromiumAccessibilityEnabled.contains(pid) {
            // Chromium builds the web page's accessibility tree only once a client asks for it: AXManualAccessibility
            // (Chrome, Edge), or the attribute VoiceOver sets, AXEnhancedUserInterface (Brave refuses the first).
            // A refusal of both is asked again next time.
            manual = AX.set(app, "AXManualAccessibility", kCFBooleanTrue) || AX.set(app, "AXEnhancedUserInterface", kCFBooleanTrue)
            if manual == true { chromiumAccessibilityEnabled.insert(pid) }
        }
        var stats = SearchStats()
        let webArea = Self.findWebArea(in: window, stats: &stats)
        let url = webArea.flatMap { AX.url($0) }
        logSearch(bundleId: bundleId, found: webArea != nil, url: url != nil, manual: manual, stats: stats)
        guard let webArea else { return nil }
        webAreaCache = (pid, window, title, webArea)
        return url
    }

    /// How an address search went, for diagnosing a browser that never gives one: counts and roles only, never a
    /// title or an address. At most once a minute per browser.
    private func logSearch(bundleId: String, found: Bool, url: Bool, manual: Bool?, stats: SearchStats) {
        let now = Date()
        if let last = searchLoggedAt[bundleId], now.timeIntervalSince(last) < 60 { return }
        searchLoggedAt[bundleId] = now
        let roles = stats.roles.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        Self.log.notice("address search \(bundleId, privacy: .public): webArea \(found) url \(url) manual \(manual.map(String.init) ?? "-", privacy: .public) nodes \(stats.nodes) depth \(stats.maxDepth) timedOut \(stats.timedOut) ms \(Int(stats.seconds * 1000)) roles \(roles, privacy: .public)")
    }

    /// Roles whose subtrees never hold the page, so the search skips them.
    private static let leafRoles: Set<String> = [
        "AXButton", "AXStaticText", "AXImage", "AXTextField", "AXRadioButton", "AXCheckBox", "AXPopUpButton",
        "AXMenuBar", "AXMenuButton", "AXToolbar", "AXMenu", "AXSlider", "AXIncrementor",
    ]

    struct SearchStats {
        var nodes = 0, maxDepth = 0, timedOut = false, seconds = 0.0
        var roles: [String: Int] = [:]
    }

    /// Breadth-first, bounded in depth, node count and time: a slow or huge tree gives nil, not a stall.
    static func findWebArea(in window: AXUIElement, maxDepth: Int = 12, maxNodes: Int = 500,
                            budget: TimeInterval = 0.15) -> AXUIElement? {
        var stats = SearchStats()
        return findWebArea(in: window, maxDepth: maxDepth, maxNodes: maxNodes, budget: budget, stats: &stats)
    }

    static func findWebArea(in window: AXUIElement, maxDepth: Int = 12, maxNodes: Int = 500,
                            budget: TimeInterval = 0.15, stats: inout SearchStats) -> AXUIElement? {
        let started = Date(), deadline = started.addingTimeInterval(budget)
        defer { stats.seconds = Date().timeIntervalSince(started) }
        var frontier: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var index = 0
        while index < frontier.count, index < maxNodes {
            guard Date() < deadline else { stats.timedOut = true; return nil }
            let (element, depth) = frontier[index]
            index += 1
            stats.nodes = index; stats.maxDepth = max(stats.maxDepth, depth)
            let (role, children) = AX.roleAndChildren(element)
            stats.roles[role ?? "?", default: 0] += 1
            if role == "AXWebArea" { return element }
            if let role, leafRoles.contains(role) { continue }
            if depth < maxDepth {
                frontier.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return nil
    }

    // MARK: Accessibility text

    /// The visible text of the focused text view (editors, terminals, notes) when it is large enough
    /// to describe the window. Secure fields are never text areas, so passwords are never read.
    private func focusedText(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        guard let focused = AX.element(app, kAXFocusedUIElementAttribute),
              AX.string(focused, kAXRoleAttribute) == kAXTextAreaRole
        else { return nil }
        var text: String?
        if let visible = AX.range(focused, kAXVisibleCharacterRangeAttribute), visible.length > 0 {
            text = AX.string(focused, forRange: visible)
        } else if let count = AX.int(focused, kAXNumberOfCharactersAttribute), count <= Self.maxAccessibilityValueLength {
            text = AX.string(focused, kAXValueAttribute)
        }
        guard let text, text.count >= Self.minAccessibilityTextLength else { return nil }
        return text
    }
}
