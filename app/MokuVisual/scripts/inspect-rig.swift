import Foundation
import RealityKit
@main struct Inspect {
    @MainActor static func main() async throws {
        let entity = try await Entity(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        func walk(_ e: Entity, _ depth: Int) {
            print(String(repeating: " ", count: depth), e.name, String(describing: type(of: e)), "animations:", e.availableAnimations.map { $0.name ?? "nil" })
            for a in e.availableAnimations { print("ANIM", a.name ?? "", String(describing: type(of:a.definition)), a.definition.bindTarget, a.definition.duration) }
            if let m = e as? ModelEntity, let mesh = m.model?.mesh { for model in mesh.contents.models { for part in model.parts { print("PART", model.id, part.id, part.materialIndex, part.positions.count, part.blendShapeOffsets(named: "blink_L")?.elements.map { simd_length($0) }.max() ?? -1) } } }
            if let m = e as? ModelEntity { print("JOINTS",m.jointNames.count, "WEIGHTS",String(describing:m.components[BlendShapeWeightsComponent.self])) }
            for child in e.children { walk(child, depth+1) }
        }
        walk(entity,0)
    }
}
