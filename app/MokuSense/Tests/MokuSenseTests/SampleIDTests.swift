import Foundation
import Testing
@testable import MokuSense

@Suite struct SampleIDTests {
    static let crockford = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    @Test func idsLookLikeULIDs() {
        var generator = SampleIDGenerator()
        let id = generator.next(at: Date(timeIntervalSince1970: 1_790_000_000.123))
        #expect(id.count == 26)
        #expect(id.allSatisfy { Self.crockford.contains($0) })
    }

    @Test func timePrefixEncodesEpochMilliseconds() {
        var generator = SampleIDGenerator(random: { (0, 0) })
        #expect(generator.next(at: Date(timeIntervalSince1970: 0.001)) == "0000000001" + String(repeating: "0", count: 16))
        // The ULID spec's example: 1469918176385 ms → "01ARYZ6S41".
        var other = SampleIDGenerator(random: { (0, 0) })
        #expect(other.next(at: Date(timeIntervalSince1970: 1_469_918_176.385)).hasPrefix("01ARYZ6S41"))
    }

    @Test func idsSortInTimeOrder() {
        var generator = SampleIDGenerator()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let ids = (0..<200).map { generator.next(at: start.addingTimeInterval(Double($0) * 0.003)) }
        #expect(ids == ids.sorted())
    }

    @Test func idsWithinOneMillisecondStayOrderedAndUnique() {
        var generator = SampleIDGenerator(random: { (0, UInt64.max - 1) })
        let now = Date(timeIntervalSince1970: 1_790_000_000.5)
        let ids = (0..<5).map { _ in generator.next(at: now) }
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
    }
}
