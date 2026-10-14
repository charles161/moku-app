import Foundation

/// Concurrent gestures and redirected walks share one unfold, then honor their own cancellation.
@MainActor final class ArmUnfoldGate {
    private(set) var folded = false
    private var task: Task<Void, Never>?
    private var generation = 0
    var isUnfolding: Bool { task != nil }
    func foldedPoseBegan() { folded = true }
    func reset() { generation += 1; task?.cancel(); task = nil; folded = false }
    func unfold(using operation: @escaping @MainActor @Sendable () async -> Void) async {
        if let task { await task.value; return }
        guard folded else { return }
        folded = false
        let token = generation
        let work = Task { await operation() }; task = work
        await work.value
        if generation == token { task = nil }
    }
    isolated deinit { task?.cancel() }
}
