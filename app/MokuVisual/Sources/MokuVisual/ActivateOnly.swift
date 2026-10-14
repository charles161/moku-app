import AppKit

/// Moku lives in the menu bar and isn't active on its own. Opening one of its windows (the popover, Your day, Settings)
/// makes it active, and activating an app brings all its windows forward. So Moku's others that sat behind your apps
/// (Settings, Your day, an alert) step aside while it activates and go back behind once it has: what you opened comes
/// forward, and nothing else (Charles, 2026-10-06: "sometimes it opens all windows like settings, dialog and the popover").
@MainActor
enum ActivateOnly {
    /// Activates Moku, then `show` brings forward what was asked for (one of `keep`); Moku's other windows stay where
    /// they were.
    static func activate(keeping keep: [NSWindow?], show: () -> Void) {
        let behind = MokuWorldPresenter.windowsToKeepBehind(NSApp.windows, appActive: NSApp.isActive, except: keep)
        behind.forEach { $0.orderOut(nil) }
        NSApp.activate()
        show()
        putBehind(behind)
    }

    /// Back behind your apps once Moku is active (activation can land a moment after it's asked for).
    private static func putBehind(_ windows: [NSWindow]) {
        guard !windows.isEmpty else { return }
        if NSApp.isActive { windows.forEach { $0.orderBack(nil) }; return }
        pendingBehind += windows
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { finishPutBehind() }
            }
        }
        Task { @MainActor in  // activation refused: they come back all the same
            try? await Task.sleep(for: .seconds(1))
            finishPutBehind()
        }
    }
    private static var pendingBehind: [NSWindow] = []
    private static var activationObserver: NSObjectProtocol?
    private static func finishPutBehind() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver); self.activationObserver = nil }
        pendingBehind.forEach { if !$0.isVisible { $0.orderBack(nil) } }
        pendingBehind = []
    }
}
