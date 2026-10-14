import ApplicationServices
import CoreGraphics
import MokuKit

enum Permissions {
    /// Never prompts.
    static func current() -> PermissionStatus {
        PermissionStatus(accessibility: AXIsProcessTrusted(), screenRecording: CGPreflightScreenCaptureAccess())
    }

    /// Shows the system prompts for anything not yet granted. macOS shows each prompt at most once per
    /// app; after that the user must toggle Moku in System Settings › Privacy & Security.
    static func request() {
        PermissionKind.allCases.forEach(request)
    }

    static func request(_ kind: PermissionKind) {
        switch kind {
        case .accessibility where !AXIsProcessTrusted():
            // The key behind kAXTrustedCheckOptionPrompt, spelled out: that global is not concurrency-safe in Swift 6.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .screenRecording where !CGPreflightScreenCaptureAccess():
            _ = CGRequestScreenCaptureAccess()
        default:
            break
        }
    }
}
