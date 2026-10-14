import AppKit
import MokuKit
import MokuMind

/// Frees what RealityKit keeps after a companion change by quitting and opening Moku again, at a moment nobody can see it
/// (QuietRelaunch decides: you're away, the screen is locked, or the Mac is going to sleep). Asked for when the companion
/// changes; looks again every 30 s and at every lock and sleep until it happens. It is never remembered across a launch:
/// the new Moku starts with nothing pending, so it can't loop.
@MainActor
final class QuietRelauncher {
    private var pending: String?
    private var presence = QuietRelaunch.Presence()
    private var relaunching = false
    private var poll: Timer?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    /// What Moku is doing right now (the app delegate knows the engine, the welcome and manual control).
    private let state: @MainActor () -> QuietRelaunch.State

    init(state: @escaping @MainActor () -> QuietRelaunch.State) { self.state = state }

    /// Asks for a relaunch at the next quiet moment (the reason goes in app.log and in the note for the new Moku).
    func request(because reason: String) {
        guard !relaunching else { return }
        if pending == nil { AppLog.write("relaunch: wanted (\(reason)); will happen when you're away, the screen locks or the Mac sleeps") }
        pending = reason
        watch()
        evaluate()
    }

    private func watch() {
        guard observers.isEmpty else { return }
        func listen(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping @MainActor (inout QuietRelaunch.Presence) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { guard let self else { return }; change(&self.presence); self.evaluate() }
            }
            observers.append((center, token))
        }
        let workspace = NSWorkspace.shared.notificationCenter, distributed = DistributedNotificationCenter.default()
        listen(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true }
        listen(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false }
        listen(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        listen(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        listen(workspace, NSWorkspace.willSleepNotification) { $0.macSleeping = true }
        listen(workspace, NSWorkspace.didWakeNotification) { $0.macSleeping = false; $0.screensAsleep = false }
        poll = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.evaluate() } }
        poll?.tolerance = 10
    }

    private func evaluate() {
        guard let reason = pending, !relaunching else { return }
        presence.idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        var current = state()
        // A titled window of Moku's own (Settings, Your day, the welcome): someone reading with their hands off the Mac isn't away.
        current.windowOpen = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        guard case let .relaunch(moment) = QuietRelaunch.decide(pending: true, presence: presence, state: current) else { return }
        relaunching = true
        poll?.invalidate(); poll = nil
        AppLog.write("relaunch: now (\(reason); \(moment.rawValue)), to free what the renderer kept after the change")
        if !AppLifecycle.relaunch(quietly: reason) {
            // It couldn't start: say so once and stop asking (Moku keeps running as it is).
            relaunching = false; pending = nil
            observers.forEach { $0.center.removeObserver($0.token) }; observers = []
        }
    }
}
