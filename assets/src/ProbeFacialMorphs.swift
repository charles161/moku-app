import RealityKit

/// Imported multipart USD meshes expose weights but this SDK does not visibly apply
/// them through RealityRenderer. Apply the authored deltas to the same skinned mesh.
/// Updates are quantized and happen only when expression weights change.
@MainActor
final class FacialMorphs {
    private struct Part {
        let modelID: String
        let original: MeshResource.Part
        let positions: [SIMD3<Float>]
        let offsets: [String: [(Int, SIMD3<Float>)]]
    }
    let mesh: MeshResource
    private let base: MeshResource.Contents
    private let parts: [Part]
    private var last: [String: Float] = [:]
    let availableShapes: Set<String>
    private let pupilParts: Set<Int>
    private let toWorld: simd_float4x4
    private let fromWorld: simd_float4x4
    private let pupilCenters: [SIMD3<Float>]
    private let pupilSizes: [SIMD3<Float>]
    init(mesh source: MeshResource, materials: [any Material], transform: simd_float4x4) throws {
        toWorld = transform; fromWorld = transform.inverse
        let names = materials.map { ($0 as? PhysicallyBasedMaterial)?.name?.replacingOccurrences(of: " ", with: "_") ?? "" }
        pupilParts = Set(names.indices.filter { names[$0] == "Deep_cocoa_pupil" || names[$0] == "Softbox_catchlights" })
        let pupilIndex = names.firstIndex(of: "Deep_cocoa_pupil")
        let pupilVertices = source.contents.models.flatMap { $0.parts.flatMap { part in
            part.materialIndex == pupilIndex ? part.positions.elements.map { (transform * SIMD4($0, 1)).xyz } : []
        } }
        var centers = [SIMD3<Float>](), sizes = [SIMD3<Float>]()
        for side in [-1.0 as Float, 1] {
            let vertices = pupilVertices.filter { $0.x * side > 0 }
            let low = vertices.reduce(SIMD3<Float>(repeating: .infinity), simd_min)
            let high = vertices.reduce(SIMD3<Float>(repeating: -.infinity), simd_max)
            centers.append(vertices.isEmpty ? .zero : (low + high) / 2)
            sizes.append(vertices.isEmpty ? .zero : high - low)
        }
        pupilCenters = centers; pupilSizes = sizes
        let imported = source.contents
        availableShapes = Set(imported.models.flatMap { $0.parts.flatMap { $0.blendShapeNames } })
        let importedParts = imported.models.flatMap { model in
            model.parts.map { part in
                let offsets = Dictionary(uniqueKeysWithValues: part.blendShapeNames.map { name in
                    let sparse = (part.blendShapeOffsets(named: name)?.elements ?? []).enumerated().compactMap { index, value in simd_length_squared(value) > 0.000000001 ? (index, value) : nil }
                    return (name, sparse)
                })
                return Part(modelID: model.id, original: part, positions: part.positions.elements, offsets: offsets)
            }
        }
        // Keep only a clean, independently generated source alive. Sparse authored
        // deltas above are copied values; the large imported morph buffers can go.
        var clean = imported
        for var model in clean.models {
            for var part in model.parts {
                for name in part.blendShapeNames { part.setBlendShapeOffsets(named: name, buffer: nil) }
                model.parts.update(part)
            }
            clean.models.update(model)
        }
        mesh = try MeshResource.generate(from: clean)
        let owned = mesh.contents
        base = owned
        parts = importedParts.map { part in
            Part(modelID: part.modelID, original: owned.models[part.modelID]!.parts[part.original.id]!, positions: part.positions, offsets: part.offsets)
        }
    }
    func apply(_ values: [String: Float], gaze: SIMD2<Float>, noticesUser: Bool, to rig: ModelEntity) throws {
        var quantized = values.mapValues { ($0 * 24).rounded() / 24 }
        quantized["__gazeX"] = (gaze.x * 12).rounded() / 12
        quantized["__gazeY"] = (gaze.y * 12).rounded() / 12
        quantized["__user"] = noticesUser ? 1 : 0
        guard quantized != last else { return }; last = quantized
        var content = base
        for entry in parts {
            var vertices = entry.positions
            for (name, weight) in quantized where abs(weight) > 0.001 {
                for (index, offset) in entry.offsets[name] ?? [] where index < vertices.count { vertices[index] += offset * weight }
            }
            if pupilParts.contains(entry.original.materialIndex) {
                for i in vertices.indices {
                    var point = (toWorld * SIMD4(vertices[i], 1)).xyz
                    let side = point.x < 0 ? 0 : 1
                    let closed = max(quantized["eyes_happy"] ?? 0, quantized["eyes_proud"] ?? 0, quantized[side == 0 ? "blink_R" : "blink_L"] ?? 0)
                    let openness = max(0, 1 - closed)
                    let size = pupilSizes[side], center = pupilCenters[side]
                    let scale: Float = noticesUser ? 1.08 : 0.84
                    point.x = center.x + (point.x - center.x) * (1 + (scale - 1) * openness)
                    point.y = center.y + (point.y - center.y) * (1 + (scale - 1) * openness)
                    point.x += size.x * (quantized["__gazeX"] ?? 0) * 0.20 * openness
                    point.y += size.y * (quantized["__gazeY"] ?? 0) * 0.17 * openness
                    vertices[i] = (fromWorld * SIMD4(point, 1)).xyz
                }
            }
            var part = entry.original
            part.positions = MeshBuffers.Positions(vertices)
            guard var model = content.models[entry.modelID] else { continue }
            model.parts.update(part); content.models.update(model)
        }
        // Never replace the source resource: saved buffers in `base` reference it.
        // Mutating it would invalidate those buffers on the next expression update.
        let replacement = try MeshResource.generate(from: content)
        let joints = rig.jointTransforms
        if var model = rig.model { model.mesh = replacement; rig.model = model; rig.jointTransforms = joints }
    }
}

private extension SIMD4 where Scalar == Float { var xyz: SIMD3<Float> { SIMD3(x, y, z) } }
