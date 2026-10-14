import Foundation
import RealityKit
@main struct Inspect {
 @MainActor static func main() async throws {
 let root = try await Entity(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
 func walk(_ e: Entity) {
 if let r=e as? ModelEntity, !r.jointNames.isEmpty {
 print("MATRIX", r.transformMatrix(relativeTo: nil))
 for (i,n) in r.jointNames.enumerated() { print(n, r.jointTransforms[i]) }
 for m in r.model!.materials { print("MATERIAL", (m as? PhysicallyBasedMaterial)?.name ?? "nil") }
 for m in r.model!.mesh.contents.models { for p in m.parts { let v=p.positions.elements;print("PART",p.id,p.materialIndex, v.reduce(SIMD3<Float>(repeating: .infinity),simd_min),v.reduce(SIMD3<Float>(repeating: -.infinity),simd_max)) } }
 }
 for c in e.children { walk(c) }
 }
 walk(root)
 }
}
