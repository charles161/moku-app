import Foundation
import Testing
@testable import MokuVisual

@MainActor @Test func redirectImmediatelyReleasesEarlierMoveFromItsCurrentPosition() async throws {
    let travel = TravelCoordinator()
    var position = CGPoint.zero
    var firstReturned = false
    let first = Task {
        await travel.run {
            position = CGPoint(x: 120, y: 40)
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            position = CGPoint(x: 1000, y: 400)
        }
        firstReturned = true
    }
    while position == .zero { await Task.yield() }
    var redirectedFrom = CGPoint.zero
    let start = ContinuousClock.now
    await travel.run { redirectedFrom = position; position = .zero }
    await first.value
    #expect(firstReturned)
    // Far under the earlier move's 60 s. (It was 2 s against 10: the suite's other tests load companions on the main
    // actor, and on a busy Mac the release took 3.6 s, failing a run that was right.)
    #expect(ContinuousClock.now - start < .seconds(15))
    #expect(redirectedFrom == CGPoint(x: 120, y: 40))
    #expect(position == .zero)
}

@MainActor @Test func redirectReleasesCallerEvenWhileAnImportIgnoresCancellation() async {
    let travel = TravelCoordinator()
    var importer: CheckedContinuation<Void,Never>?
    var earlierReturned = false
    var position = CGPoint(x: 120,y: 40)
    let first = Task {
        await travel.run { await withCheckedContinuation { importer = $0 }; if !Task.isCancelled { position = CGPoint(x: 1000,y: 400) } }
        earlierReturned = true
    }
    while importer == nil { await Task.yield() }
    var redirectedFrom = CGPoint.zero
    await travel.run { redirectedFrom = position; position = .zero }
    await first.value // Must finish while the import continuation is still pending.
    #expect(earlierReturned && importer != nil)
    #expect(redirectedFrom == CGPoint(x: 120,y: 40))
    importer?.resume(); await Task.yield()
    #expect(position == .zero)
}
