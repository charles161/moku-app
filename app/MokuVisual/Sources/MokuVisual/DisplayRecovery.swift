import AppKit
import Observation
import MokuKit

struct DisplayRegion: Equatable {
    let id: String
    let visible: CGRect
}
struct HomePlacement {
    static func resolve(savedDisplay: String?, savedHome: SavedHome?, displays: [DisplayRegion], scale: CGFloat) -> CGPoint? {
        guard let main = displays.first else { return nil }
        guard let savedDisplay, let display = displays.first(where: { $0.id == savedDisplay }) else {
            return StageGeometry.clamped(StageGeometry.home(in: main.visible, scale: scale), to: main.visible, scale: scale)
        }
        return savedHome?.origin(in: display.visible, scale: scale)
            ?? StageGeometry.clamped(StageGeometry.home(in: display.visible, scale: scale), to: display.visible, scale: scale)
    }
    static func panel(_ frame: CGRect, displays: [DisplayRegion]) -> CGRect {
        guard let display = displays.first(where: { $0.visible.contains(CGPoint(x: frame.midX, y: frame.midY)) }) ?? displays.first else { return frame }
        let visible = display.visible.insetBy(dx: 12, dy: 12)
        let size = CGSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
        return CGRect(x: min(max(frame.minX, visible.minX), visible.maxX-size.width), y: min(max(frame.minY, visible.minY), visible.maxY-size.height), width: size.width, height: size.height)
    }
}
@MainActor @Observable final class VisualSessionState {
    static let shared = VisualSessionState()
    var onboarding = false
    var workState = WorkState.idle
    /// The person chose "Hide Moku": the popover offers "Show Moku".
    var mokuHidden = false
    /// Moku on screen, for a popover that points at Moku when the menu bar icon can't be seen.
    @ObservationIgnored weak var character: CharacterView?
}
@MainActor enum DisplayRecovery {
    static func observe(_ window: NSWindow) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak window] _ in
            Task { @MainActor in
                guard let window else { return }
                let displays = NSScreen.screens.enumerated().map { DisplayRegion(id: String($0.offset), visible: $0.element.visibleFrame) }
                window.setFrame(HomePlacement.panel(window.frame, displays: displays), display: false)
            }
        }
    }
}
