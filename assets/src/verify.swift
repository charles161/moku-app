import Foundation
import RealityKit

@main struct Verify {
 @MainActor static func main() async {
  let args = Array(CommandLine.arguments.dropFirst())
  var reports: [[String: Any]] = []
  for path in args {
   do {
    let entity = try await Entity(contentsOf: URL(fileURLWithPath: path))
    var models:[[String:Any]]=[]
    var animations:[String]=[]
    var animationDetails:[[String:Any]]=[]
    func visit(_ e:Entity) {
     animations += e.availableAnimations.map { $0.name ?? "unnamed" }
     animationDetails += e.availableAnimations.map { animation in
      ["name":animation.name ?? "unnamed","duration":animation.definition.duration,"kind":animation.definition is SampledAnimation<JointTransforms> ? "joints" : animation.definition is SampledAnimation<BlendShapeWeights> ? "face" : "other"]
     }
     if let m = e as? ModelEntity {
      var entry:[String:Any] = ["name":e.name,"joints":m.jointNames,"jointCount":m.jointTransforms.count]
      let importedMaterials: [any Material] = m.model?.materials ?? []
      entry["materials"] = importedMaterials.map { material -> [String:Any] in
       if let p = material as? PhysicallyBasedMaterial {
        return ["name":p.name ?? "", "roughness":p.roughness.scale, "hasNormalTexture":p.normal.texture != nil, "hasBaseTexture":p.baseColor.texture != nil, "hasSheen":p.sheen != nil]
       }
       return ["type":String(describing:type(of:material))]
      }
      if let b = m.components[BlendShapeWeightsComponent.self] {
       entry["blendShapeDescription"] = String(describing:b)
      }
      models.append(entry)
     }
     for c in e.children {visit(c)}
    }
    visit(entity)
    reports.append(["file":path,"loaded":true,"models":models,"animations":animations,"animationDetails":animationDetails])
    fputs("PASS \(path)\n",stderr)
   } catch {
    reports.append(["file":path,"loaded":false,"error":String(describing:error)])
    fputs("FAIL \(path): \(error)\n",stderr)
   }
  }
  let data=try! JSONSerialization.data(withJSONObject:reports,options:[.prettyPrinted,.sortedKeys])
  print(String(data:data,encoding:.utf8)!)
  if reports.contains(where:{($0["loaded"] as? Bool)==false}) {exit(1)}
 }
}
