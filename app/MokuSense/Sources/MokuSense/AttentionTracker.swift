import AppKit

/// Where the user is working: the mouse location, in AppKit global coordinates. Polled at 15 Hz while
/// the pointer moves and at 4 Hz while it rests, and reported only when it moved.
@MainActor
final class AttentionTracker {
    static let movingInterval: Duration = .milliseconds(66)
    static let restingInterval: Duration = .milliseconds(250)
    /// How long after the last movement polling stays fast.
    static let settleSeconds: TimeInterval = 1

    private var task: Task<Void, Never>?

    func start(onMove: @escaping @MainActor (CGPoint) -> Void) {
        stop()
        task = Task { @MainActor in
            var last: CGPoint?
            var lastMove = -TimeInterval.infinity
            while !Task.isCancelled {
                let location = NSEvent.mouseLocation
                let now = ProcessInfo.processInfo.systemUptime
                if location != last {
                    last = location
                    lastMove = now
                    onMove(location)
                }
                let moving = now - lastMove < Self.settleSeconds
                try? await Task.sleep(for: moving ? Self.movingInterval : Self.restingInterval,
                                      tolerance: .milliseconds(moving ? 10 : 50))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
