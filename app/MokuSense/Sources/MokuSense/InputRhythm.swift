import AppKit
import MokuKit

/// Typing rhythm, never keys: how many key presses, clicks and scroll gestures happened in the last
/// 60 seconds, and how long since any input. Event contents are dropped on arrival.
///
/// Key presses come from a global keyDown monitor, which macOS only feeds to apps trusted for
/// Accessibility. Without that trust, key and click counts fall back to the window server's
/// system-wide event counters, which need no permission and never see which keys were pressed.
@MainActor
final class InputRhythm {
    private var keys = RollingCounter()
    private var clicks = RollingCounter()
    private var scrolls = RollingCounter()
    private var monitors: [Any] = []
    private var monitorsSeeKeys = false
    private var lastSystemCounts: (keys: UInt32, clicks: UInt32)?

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start(accessibility: Bool) {
        stop()
        monitorsSeeKeys = accessibility
        var mask: NSEvent.EventTypeMask = [.scrollWheel]
        if accessibility { mask.formUnion([.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let type = event.type
            let isGestureStart = Self.isScrollGestureStart(event)
            MainActor.assumeIsolated { self?.record(type, isGestureStart: isGestureStart) }
        }) {
            monitors.append(monitor)
        }
        lastSystemCounts = accessibility ? nil : Self.systemCounts()
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// Restarts the monitors when Accessibility trust changes.
    func update(accessibility: Bool) {
        if accessibility != monitorsSeeKeys { start(accessibility: accessibility) }
    }

    func snapshot() -> InputActivity {
        let now = Self.now
        if !monitorsSeeKeys { recordSystemCounts(at: now) }
        return InputActivity(
            keysPerMinute: keys.count(at: now),
            clicksPerMinute: clicks.count(at: now),
            scrollsPerMinute: scrolls.count(at: now),
            idleSeconds: Self.idleSeconds())
    }

    /// Seconds since the last keyboard, mouse or trackpad input of any kind.
    static func idleSeconds() -> Double {
        let anyInput = CGEventType(rawValue: ~0)!
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    private func record(_ type: NSEvent.EventType, isGestureStart: Bool) {
        switch type {
        case .keyDown: keys.record(at: Self.now)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: clicks.record(at: Self.now)
        case .scrollWheel where isGestureStart: scrolls.record(at: Self.now)
        default: break
        }
    }

    /// A trackpad scroll is dozens of events; count its start, and each notch of a plain mouse wheel.
    nonisolated private static func isScrollGestureStart(_ event: NSEvent) -> Bool {
        guard event.type == .scrollWheel else { return false }
        if event.phase.contains(.began) { return true }
        return event.phase.isEmpty && event.momentumPhase.isEmpty
    }

    private func recordSystemCounts(at now: TimeInterval) {
        let current = Self.systemCounts()
        if let last = lastSystemCounts {
            keys.record(Int(current.keys &- last.keys), at: now)
            clicks.record(Int(current.clicks &- last.clicks), at: now)
        }
        lastSystemCounts = current
    }

    private static func systemCounts() -> (keys: UInt32, clicks: UInt32) {
        func count(_ type: CGEventType) -> UInt32 { CGEventSource.counterForEventType(.combinedSessionState, eventType: type) }
        return (count(.keyDown), count(.leftMouseDown) &+ count(.rightMouseDown) &+ count(.otherMouseDown))
    }
}
