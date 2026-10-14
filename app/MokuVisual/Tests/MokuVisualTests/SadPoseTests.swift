import Testing
import MokuKit
@testable import MokuVisual

/// Charles, 2026-10-14: "its doing a two pass sad display, one sad down lookdown - the first one is fine, the second is
/// actually being sad and folding hand - that isnt good, we can remove the latter". The sad face held a pose with folded
/// arms after the sigh; now only the sigh shows the sadness.
@Test func theSadFaceFoldsNoArms() {
    #expect(!RealityCharacter.foldsArms(for: .disappointed))
    #expect(!RealityCharacter.foldsArms(for: .content) && !RealityCharacter.foldsArms(for: .happy))
}
