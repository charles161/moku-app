/// The engine's only source of chance (when Moku looks up at you, and how). Seeded, so the engine stays
/// deterministic under test and in the simulator; the app seeds it from the system. SplitMix64.
public struct MokuRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    /// Seeded from the system: different every launch.
    public init() {
        self.init(seed: UInt64.random(in: .min ... .max))
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
