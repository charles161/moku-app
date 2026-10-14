import AppKit

/// Whether the person asked macOS for Reduce Motion (System Settings › Accessibility › Display). Every calm version of a
/// move reads it from here. The app never sets it: only the demo's checks pin it (`MOKU_REDUCE_MOTION=1` or `=0` in the
/// environment) to see the calm versions offscreen without touching the system's setting.
enum MotionPreference {
    nonisolated(unsafe) static var override: Bool? = ProcessInfo.processInfo.environment["MOKU_REDUCE_MOTION"].map { $0 == "1" }
    static var reduced: Bool { override ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Whether the person asked macOS for Increase Contrast (System Settings › Accessibility › Display). The companion's own
/// windows (the bubble, the label) are drawn once, so they read it when they're made. The demo's checks can pin it
/// (`MOKU_INCREASE_CONTRAST=1` or `=0`) to see both offscreen.
enum ContrastPreference {
    nonisolated(unsafe) static var override: Bool? = ProcessInfo.processInfo.environment["MOKU_INCREASE_CONTRAST"].map { $0 == "1" }
    static var increased: Bool { override ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
}
