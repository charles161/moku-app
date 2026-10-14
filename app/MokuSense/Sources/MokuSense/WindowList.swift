import CoreGraphics
import Foundation

/// One on-screen window as the window server reports it.
struct WindowEntry: Sendable, Equatable {
    var id: CGWindowID
    var pid: pid_t
    var layer: Int
    /// Quartz global coordinates.
    var bounds: CGRect
    /// Empty unless the window is ours or Screen Recording is granted.
    var title: String
}

enum WindowList {
    /// On-screen windows, front to back. Cheap (about a millisecond) and needs no permission,
    /// except that other apps' titles come back empty without Screen Recording.
    static func onScreen() -> [WindowEntry] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }
        return info.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsInfo = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo)
            else { return nil }
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0 else { return nil }
            return WindowEntry(id: id, pid: pid, layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                               bounds: bounds, title: entry[kCGWindowName as String] as? String ?? "")
        }
    }

    /// The app's focused window: the one matching the Accessibility frame when known,
    /// otherwise its frontmost normal-level window of a real size.
    static func focusedWindow(of pid: pid_t, in windows: [WindowEntry], accessibilityFrame: CGRect?) -> WindowEntry? {
        let candidates = windows.filter { $0.pid == pid && $0.layer == 0 && $0.bounds.width >= 40 && $0.bounds.height >= 40 }
        if let frame = accessibilityFrame,
           let match = candidates.first(where: { framesMatch($0.bounds, frame) }) {
            return match
        }
        return candidates.first
    }

    static func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

/// Browsers whose focused tab address Moku reads from the Accessibility tree.
enum Browsers {
    static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    static let all: Set<String> = chromium.union([
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox",
    ])
}
