import AppKit
import RealityKit

/// Apply after USDZ load. USD Preview Surface preserves PBR textures and roughness,
/// but does not encode RealityKit's optional fabric sheen extension.
@MainActor public enum MokuMaterials {
    public static func applyPlushSheen(to entity: Entity) {
        if let model = entity as? ModelEntity, var component = model.model {
            component.materials = component.materials.map { original in
                guard var material = original as? PhysicallyBasedMaterial else { return original }
                let name = material.name ?? ""
                let isPlush = name.localizedCaseInsensitiveContains("plush")
                    || name.localizedCaseInsensitiveContains("velour")
                    || name.localizedCaseInsensitiveContains("ivory")
                guard isPlush else { return original }
                material.roughness = .init(floatLiteral: 0.93)
                material.sheen = .init(tint: NSColor(deviceRed: 0.86, green: 0.74, blue: 0.57, alpha: 1))
                return material
            }
            model.model = component
        }
        for child in entity.children { applyPlushSheen(to: child) }
    }
}
