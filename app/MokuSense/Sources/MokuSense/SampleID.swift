import Foundation

/// Time-sortable sample ids in the ULID format: 10 characters of epoch milliseconds, then
/// 16 characters of randomness, Crockford base32. Ids made by one generator sort in creation
/// order even within the same millisecond.
struct SampleIDGenerator: Sendable {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    private var lastMillis: UInt64 = 0
    private var lastRandom: (high: UInt16, low: UInt64) = (0, 0)
    private let random: @Sendable () -> (high: UInt16, low: UInt64)

    init() {
        random = {
            var generator = SystemRandomNumberGenerator()
            return (UInt16.random(in: .min ... .max, using: &generator), UInt64.random(in: .min ... .max, using: &generator))
        }
    }

    /// For tests: a fixed source of randomness.
    init(random: @escaping @Sendable () -> (high: UInt16, low: UInt64)) {
        self.random = random
    }

    mutating func next(at date: Date) -> String {
        let millis = UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded()))
        if millis <= lastMillis {
            // Same (or an earlier) millisecond: keep the last time and count up, so order is preserved.
            let (low, overflow) = lastRandom.low.addingReportingOverflow(1)
            lastRandom = (overflow ? lastRandom.high &+ 1 : lastRandom.high, low)
        } else {
            lastMillis = millis
            lastRandom = random()
        }
        // 48 bits of time (50 bits, the top two zero), then 80 bits of randomness as four 20-bit groups.
        let (high, low) = lastRandom
        let groups = [(UInt64(high) << 4) | (low >> 60), (low >> 40) & 0xFFFFF, (low >> 20) & 0xFFFFF, low & 0xFFFFF]
        return Self.encode(lastMillis, bits: 50) + groups.map { Self.encode($0, bits: 20) }.joined()
    }

    /// Big-endian base32 of the low `bits` bits of `value` (bits is a multiple of 5).
    private static func encode(_ value: UInt64, bits: Int) -> String {
        var characters: [Character] = []
        characters.reserveCapacity(bits / 5)
        var shift = bits - 5
        while shift >= 0 {
            characters.append(alphabet[Int((value >> UInt64(shift)) & 0x1F)])
            shift -= 5
        }
        return String(characters)
    }
}
