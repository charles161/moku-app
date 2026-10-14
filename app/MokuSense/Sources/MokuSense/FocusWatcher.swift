import AppKit
import ApplicationServices

/// Notices, without polling, when the frontmost app or its focused window may have changed:
/// NSWorkspace for app switches and Space changes, and an Accessibility observer on the frontmost
/// app for window focus and title changes (a new browser tab, a new document).
@MainActor
final class FocusWatcher {
    enum Change {
        /// Another app may be frontmost (an app or Space switch): read right away.
        case appSwitched
        /// The frontmost app focused another window: read right away.
        case window
        /// A title changed; these come in bursts, so the reader coalesces them.
        case title
    }

    private let onChange: @MainActor (Change) -> Void
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Nonisolated so `deinit` can invalidate it: a live observer holds an unretained pointer to self.
    nonisolated(unsafe) private var axObserver: AXObserver?
    private var observedPid: pid_t?
    private var observedApp: AXUIElement?
    private var observedWindow: AXUIElement?

    init(onChange: @escaping @MainActor (Change) -> Void) {
        self.onChange = onChange
    }

    deinit {
        if let axObserver { CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(axObserver)) }
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange(.appSwitched) }
            })
        }
    }

    func stop() {
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
        detach()
    }

    /// Watches window changes inside `pid`. Needs Accessibility; without it only app switches are seen.
    func observe(pid: pid_t?, accessibility: Bool) {
        guard accessibility, let pid else { return detach() }
        guard pid != observedPid else { return }
        detach()
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &created) == .success, let observer = created else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(observer, app, notification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
        observedPid = pid
        observedApp = app
        watchFocusedWindowTitle()
    }

    private func detach() {
        if let axObserver { CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(axObserver)) }
        axObserver = nil
        observedPid = nil
        observedApp = nil
        observedWindow = nil
    }

    /// Some apps post title changes only to the window itself, so the focused window is watched too.
    private func watchFocusedWindowTitle() {
        guard let axObserver, let observedApp else { return }
        let title = kAXTitleChangedNotification as CFString
        if let observedWindow { AXObserverRemoveNotification(axObserver, observedWindow, title) }
        observedWindow = AX.element(observedApp, kAXFocusedWindowAttribute)
        if let observedWindow {
            AXObserverAddNotification(axObserver, observedWindow, title, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private func handle(_ notification: String) {
        if notification == kAXTitleChangedNotification {
            onChange(.title)
        } else {
            watchFocusedWindowTitle()
            onChange(.window)
        }
    }

    /// Runs on the main run loop, where the observer's source was added.
    private static let callback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let watcher = Unmanaged<FocusWatcher>.fromOpaque(refcon).takeUnretainedValue()
        let name = notification as String
        MainActor.assumeIsolated { watcher.handle(name) }
    }
}
