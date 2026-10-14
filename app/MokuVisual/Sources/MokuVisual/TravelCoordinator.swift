import Foundation

/// The caller is released on redirect even if an import does not cooperate with
/// cancellation. The old operation still observes cancellation before touching
/// the stage; its eventual completion cannot finish the newer journey.
@MainActor final class TravelCoordinator {
    private var task: Task<Void,Never>?
    private var waiter: CheckedContinuation<Void,Never>?
    private var activeID: UUID?
    func run(_ operation: @escaping @MainActor () async -> Void) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(); return }
                cancel(); activeID = id; waiter = continuation
                task = Task { [weak self] in await operation(); self?.finish(id) }
            }
        } onCancel: { Task { @MainActor [weak self] in if self?.activeID == id { self?.cancel() } } }
    }
    private func finish(_ id: UUID) {
        guard activeID == id else { return }
        activeID = nil; task = nil; let continuation = waiter; waiter = nil; continuation?.resume()
    }
    func cancel() {
        task?.cancel(); task = nil; activeID = nil
        let continuation = waiter; waiter = nil; continuation?.resume()
    }
    isolated deinit { task?.cancel(); waiter?.resume() }
}
