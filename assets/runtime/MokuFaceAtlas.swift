import Foundation
import RealityKit

/// Opt-in adapter matching the native proof in assets/src/face_probe.swift.
/// Construct immediately after import, before another adapter mutates material names.
/// The caller applies returned weights through its authored-morph driver.
@MainActor public final class MokuFaceAtlas {
    private struct Manifest: Decodable {
        struct Cell: Decodable {
            let name: String
            let uvScale: [Float]
            let uvOffset: [Float]
            let morphs: [String: Float]
        }
        let atlasPath: String
        let opacityAtlasPath: String
        let alphaCutoff: Float
        let cells: [Cell]
    }
    private let manifest: Manifest
    private let color: TextureResource
    private let opacity: TextureResource
    private let materialIndex: Int
    private let original: PhysicallyBasedMaterial

    public init(rig: ModelEntity, assetRoot: URL) async throws {
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: assetRoot.appendingPathComponent("character/face_atlas.json")))
        guard let materials = rig.model?.materials,
              let index = materials.firstIndex(where: { ($0 as? PhysicallyBasedMaterial)?.name?.replacingOccurrences(of: " ", with: "_") == "Face_decals" }),
              let material = materials[index] as? PhysicallyBasedMaterial else {
            throw NSError(domain: "MokuFaceAtlas", code: 1, userInfo: [NSLocalizedDescriptionKey: "Face_decals material must be resolved before imported names are lost during mutation."])
        }
        materialIndex = index; original = material
        color = try await TextureResource(contentsOf: assetRoot.appendingPathComponent(manifest.atlasPath), options: .init(semantic: .color))
        opacity = try await TextureResource(contentsOf: assetRoot.appendingPathComponent(manifest.opacityAtlasPath), options: .init(semantic: .scalar))
    }

    @discardableResult public func apply(_ name: String, to rig: ModelEntity, mirrorU: Bool = false) throws -> [String: Float] {
        guard let cell = manifest.cells.first(where: { $0.name == name }),
              var model = rig.model, model.materials.indices.contains(materialIndex) else {
            throw NSError(domain: "MokuFaceAtlas", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown face cell or incompatible model."])
        }
        var material = original
        material.baseColor = .init(tint: .white, texture: .init(color))
        material.blending = .transparent(opacity: .init(scale: 1, texture: .init(opacity)))
        material.opacityThreshold = manifest.alphaCutoff
        material.textureCoordinateTransform.scale = [mirrorU ? -cell.uvScale[0] : cell.uvScale[0], cell.uvScale[1]]
        material.textureCoordinateTransform.offset = [cell.uvOffset[0] + (mirrorU ? cell.uvScale[0] : 0), cell.uvOffset[1]]
        model.materials[materialIndex] = material; rig.model = model
        var weights: [String: Float] = ["face_decals": 0, "eye_hidden_L": 0, "eye_hidden_R": 0]
        weights.merge(cell.morphs) { _, new in new }
        return weights
    }

    @discardableResult public func disable(on rig: ModelEntity) -> [String: Float] {
        if var model = rig.model, model.materials.indices.contains(materialIndex) {
            model.materials[materialIndex] = original; rig.model = model
        }
        return ["face_decals": 0, "eye_hidden_L": 0, "eye_hidden_R": 0]
    }
}
