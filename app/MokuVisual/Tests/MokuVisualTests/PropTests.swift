import Testing
import RealityKit
@testable import MokuVisual

@MainActor @Test func attachmentComposesOnlyItsJointAncestors() {
    let names = ["root", "root/chest", "root/chest/hand_R", "root/foot_L"]
    let poses = [SIMD3<Float>(1,0,0), SIMD3<Float>(0,2,0), SIMD3<Float>(0,0,3), SIMD3<Float>(50,50,50)].map { Transform(translation: $0) }
    let matrix = PropAttachment.jointMatrix(named: "hand_R", names: names, transforms: poses)
    #expect(matrix?.columns.3 == SIMD4<Float>(1,2,3,1))
    #expect(PropAttachment.jointMatrix(named: "absent", names: names, transforms: poses) == nil)
}
