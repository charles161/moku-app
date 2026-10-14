import Testing
@testable import MokuSense

@Suite struct RollingCounterTests {
    @Test func countsEventsInsideTheWindow() {
        var counter = RollingCounter()
        counter.record(at: 100.2)
        counter.record(at: 100.9)
        counter.record(3, at: 130)
        #expect(counter.count(at: 130) == 5)
        #expect(counter.count(at: 159.9) == 5)
    }

    @Test func forgetsEventsOlderThanSixtySeconds() {
        var counter = RollingCounter()
        counter.record(at: 100)
        counter.record(at: 150)
        #expect(counter.count(at: 159) == 2)
        #expect(counter.count(at: 160) == 1)
        #expect(counter.count(at: 210) == 0)
    }

    @Test func reusesBucketsAfterLongGaps() {
        var counter = RollingCounter()
        counter.record(5, at: 10)
        // 10 and 70 share a bucket; the old count must not leak into the new second.
        counter.record(at: 70)
        #expect(counter.count(at: 70) == 1)
        counter.record(at: 10_000)
        #expect(counter.count(at: 10_000) == 1)
    }

    @Test func ignoresEmptyBatchesAndFutureEvents() {
        var counter = RollingCounter()
        counter.record(0, at: 5)
        counter.record(-3, at: 5)
        counter.record(at: 50)
        #expect(counter.count(at: 20) == 0)
        #expect(counter.count(at: 50) == 1)
    }
}
