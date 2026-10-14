import AppKit
import MokuKit

/// Running apps by pid, kept current by NSWorkspace launch and quit notifications. Every
/// `NSRunningApplication` property read is an XPC round trip to LaunchServices, so each app is
/// described once, when it launches, and samples only read this table.
@MainActor
final class RunningApps {
    private(set) var apps: [pid_t: AppInfo] = [:]
    private var observers: [NSObjectProtocol] = []

    var bundleIds: Set<String> { Set(apps.values.map(\.bundleId)) }

    func start() {
        stop()
        for app in NSWorkspace.shared.runningApplications {
            remember(app)
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { _ = self?.remember(app) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { _ = self?.apps.removeValue(forKey: pid) }
        })
    }

    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        apps = [:]
    }

    /// The app's description, remembering it if it was not seen launching.
    func info(for app: NSRunningApplication) -> AppInfo {
        apps[app.processIdentifier] ?? remember(app)
    }

    @discardableResult
    private func remember(_ app: NSRunningApplication) -> AppInfo {
        let bundleId = app.bundleIdentifier
        let name = app.localizedName
        let fallback = bundleId == nil || name == nil ? app.executableURL?.lastPathComponent ?? "pid \(app.processIdentifier)" : ""
        let info = AppInfo(bundleId: bundleId ?? fallback, name: Normalize.name(name ?? fallback))
        apps[app.processIdentifier] = info
        return info
    }
}
