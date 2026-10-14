import RealityKit
import QuartzCore

/// Imported multipart USD meshes expose weights but this SDK does not visibly apply
/// them through RealityRenderer. Apply the authored deltas to the same skinned mesh.
/// Updates are quantized and happen only when expression weights change.
/// On macOS 27 the deltas are added on the GPU (FaceMorphsOnGPU) before skinning; before that,
/// each change regenerates the mesh on the CPU.
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
    /// Diagnostics: the weights the mesh shows (quantized), as last sent.
    private(set) var lastSent: [String: Float] = [:]
    /// Diagnostics: how many times the face mesh has been rebuilt (each costs a `MeshResource.generate`).
    private(set) var rebuilds = 0
    /// Diagnostics: seconds per update that changed the face (EnergyCheck).
    private(set) var costs: [Double] = []
    /// On the CPU every face change rebuilds the whole mesh (10.7 ms on the main thread), so there the face changes at most 30
    /// times a second (docs/specs/launch-qa.md, lens 3). A little under 1/30, so a 30 fps ticker's own jitter never costs a
    /// frame; at 60 fps every second frame shows the face, and at 120 every fourth.
    nonisolated static let cpuMinimumInterval = 0.026
    /// Whether a face change `seconds` after the last rebuild waits for a later frame (CPU path, live frames).
    nonisolated static func holdsBack(sinceLastRebuild seconds: Double) -> Bool { seconds < cpuMinimumInterval && !limitSwitchedOff }
    /// Checks only: MOKU_CPU_FACE_UNLIMITED=1 turns the limit off, to measure what it saves in the same build.
    nonisolated static let limitSwitchedOff = ProcessInfo.processInfo.environment["MOKU_CPU_FACE_UNLIMITED"] == "1"
    private var lastRebuildAt = -100.0
    /// The face changed but the CPU path held it back for a later frame (`apply` with `limitingRate`): the character must
    /// keep frames coming until it shows, or the last change of a blink could be lost with the timer stopped.
    private(set) var changeWaiting = false
    /// Diagnostics: changes held back for the 30 Hz limit.
    private(set) var heldBack = 0
    let availableShapes: Set<String>
    /// The shapes that actually move something on this character (a companion may carry a name with no deltas).
    let movingShapes: Set<String>
    private let irisParts: Set<Int>
    private let pupilParts: Set<Int>
    private let toWorld: simd_float4x4
    private let fromWorld: simd_float4x4
    private let pupilCenters: [SIMD3<Float>]
    private let pupilSizes: [SIMD3<Float>]
    var faceCenter: SIMD3<Float> { (pupilCenters[0] + pupilCenters[1]) / 2 }
    /// FaceMorphsOnGPU on macOS 27 (unless MOKU_CPU_MORPHS=1), nil for the CPU path.
    private var gpu: AnyObject?
    private weak var attachedRig: ModelEntity?
    var onGPU: Bool { gpu != nil }
    static var gpuByDefault: Bool { ProcessInfo.processInfo.environment["MOKU_CPU_MORPHS"] != "1" }
    /// `fuzz`: keep the felt's fuzz shell (materials named `*_fuzz`, assets/src/fuzz.py). By default only with the GPU
    /// morphs: on the CPU every face change regenerates the whole mesh, and the shell's third more vertices would cost
    /// macOS 15–26 that much more, so there Moku keeps its plain edge.
    init(mesh source: MeshResource, materials: [any Material], transform: simd_float4x4, materialNames: [String]? = nil, gpu useGPU: Bool = FacialMorphs.gpuByDefault, fuzz: Bool? = nil) throws {
        toWorld = transform; fromWorld = transform.inverse
        let names = materialNames ?? materials.map { ($0 as? PhysicallyBasedMaterial)?.name?.replacingOccurrences(of: " ", with: "_") ?? "" }
        var morphsOnGPU = false
        if #available(macOS 27, *), useGPU { morphsOnGPU = true }
        let shellParts = (fuzz ?? morphsOnGPU) ? [] : Set(names.indices.filter { names[$0].hasSuffix("_fuzz") })
        irisParts = Set(names.indices.filter { names[$0] == "Cocoa_glass_eyes" })
        pupilParts = Set(names.indices.filter { names[$0] == "Deep_cocoa_pupil" || names[$0] == "Softbox_catchlights" })
        let pupilIndex = names.firstIndex(of: "Deep_cocoa_pupil")
        // Reading a mesh's contents costs 250 to 350 ms on the main thread: once, for everything below.
        let imported = source.contents
        let pupilVertices = imported.models.flatMap { $0.parts.flatMap { part in
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
        availableShapes = Set(imported.models.flatMap { $0.parts.flatMap { $0.blendShapeNames } })
        let importedParts = imported.models.flatMap { model in
            model.parts.filter { !shellParts.contains($0.materialIndex) }.map { part in
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
            model.parts = MeshPartCollection(model.parts.filter { !shellParts.contains($0.materialIndex) }.map { part in
                var part = part
                for name in part.blendShapeNames { part.setBlendShapeOffsets(named: name, buffer: nil) }
                return part
            })
            clean.models.update(model)
        }
        movingShapes = Set(importedParts.flatMap { part in part.offsets.filter { !$0.value.isEmpty }.map(\.key) })
        mesh = try MeshResource.generate(from: clean)
        let owned = mesh.contents
        base = owned
        parts = importedParts.map { part in
            Part(modelID: part.modelID, original: owned.models[part.modelID]!.parts[part.original.id]!, positions: part.positions, offsets: part.offsets)
        }
        if #available(macOS 27, *), useGPU {
            gpu = FaceMorphsOnGPU(parts: parts.map { ($0.modelID, $0.original.id, $0.positions.count, pupilParts.contains($0.original.materialIndex), $0.offsets) }, shapes: availableShapes)
        }
    }
    func closureThickness(_ values: [String:Float]) -> [Float] {
        var open = [[SIMD3<Float>]](repeating: [],count: 2),closed = open
        for part in parts where irisParts.contains(part.original.materialIndex) {
            var vertices = part.positions
            for (name,value) in values { let weight = (value*24).rounded()/24; for (index,offset) in part.offsets[name] ?? [] { vertices[index] += offset*weight } }
            for i in vertices.indices {
                let original = (toWorld*SIMD4(part.positions[i],1)).xyz, changed = (toWorld*SIMD4(vertices[i],1)).xyz
                let side = original.x < 0 ? 0 : 1; open[side].append(original); closed[side].append(changed)
            }
        }
        return (0...1).map { side in
            guard !open[side].isEmpty else { return .infinity }
            func height(_ v: [SIMD3<Float>]) -> Float { (v.map(\.y).max() ?? 0)-(v.map(\.y).min() ?? 0) }
            return height(closed[side])/max(0.0001,height(open[side]))
        }
    }
    /// `limitingRate`: live frames only (a review pose wants the exact face now); it matters on the CPU path only.
    func apply(_ values: [String: Float], gaze: SIMD2<Float>, userAttention: Float, to rig: ModelEntity, limitingRate: Bool = false) throws {
        // On the CPU every change rebuilds the mesh, so weights move in 24ths. On the GPU a change costs about 0.01 ms, and
        // 24ths of a big shape (an ear lifting in a pat or a wave) jumped visibly between still frames: 240ths there.
        let steps: Float = gpu != nil ? 240 : 24
        var quantized = values.mapValues { ($0 * steps).rounded() / steps }
        quantized["__gazeX"] = (gaze.x * 12).rounded() / 12
        quantized["__gazeY"] = (gaze.y * 12).rounded() / 12
        quantized["__user"] = (min(1, max(0, userAttention)) * 24).rounded() / 24
        guard quantized != last else { changeWaiting = false; return }
        let started = CACurrentMediaTime()
        if gpu == nil, limitingRate, Self.holdsBack(sinceLastRebuild: started - lastRebuildAt) { changeWaiting = true; heldBack += 1; return }
        changeWaiting = false; last = quantized; lastSent = quantized
        defer { if costs.count < 200_000 { costs.append(CACurrentMediaTime() - started) } }
        if #available(macOS 27, *), let gpu = gpu as? FaceMorphsOnGPU {
            gpu.set(weights: quantized, pupils: pupils(quantized))
            if attachedRig !== rig { rig.components.set(try gpu.component()); attachedRig = rig }
            return
        }
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
                    // v0's full pupils at rest; they widen a touch when Moku looks at you.
                    let scale: Float = 1 + 0.08 * (quantized["__user"] ?? 0)
                    point.x = center.x + (point.x - center.x) * (1 + (scale - 1) * openness)
                    point.y = center.y + (point.y - center.y) * (1 + (scale - 1) * openness)
                    // The eye bones carry the gaze; the pupil only drifts a little for saccades.
                    point.x += size.x * (quantized["__gazeX"] ?? 0) * 0.06 * openness
                    point.y += size.y * (quantized["__gazeY"] ?? 0) * 0.05 * openness
                    // The pupil and specular dots must recede as the lid closes;
                    // stacking their compressed surfaces makes a dark wet smudge.
                    let close = min(1, max(0, (closed - 0.45) / 0.5))
                    point.z -= 0.08 * close * close * (3 - 2 * close)
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
        rebuilds += 1; lastRebuildAt = started
        let joints = rig.jointTransforms
        if var model = rig.model { model.mesh = replacement; rig.model = model; rig.jointTransforms = joints }
    }
}

private extension SIMD4 where Scalar == Float { var xyz: SIMD3<Float> { SIMD3(x, y, z) } }

extension FacialMorphs {
    /// The pupils' move for the GPU pass, per side, with the CPU path's arithmetic (`apply`), operation for operation.
    @available(macOS 27, *)
    fileprivate func pupils(_ quantized: [String: Float]) -> FaceMorphsOnGPU.Pupils {
        var pupils = FaceMorphsOnGPU.Pupils(toWorld: toWorld, fromWorld: fromWorld)
        let sides = [0, 1].map { side -> (SIMD4<Float>, SIMD4<Float>) in
            let closed = max(quantized["eyes_happy"] ?? 0, quantized["eyes_proud"] ?? 0, quantized[side == 0 ? "blink_R" : "blink_L"] ?? 0)
            let openness = max(0, 1 - closed)
            let size = pupilSizes[side], center = pupilCenters[side]
            let scale: Float = 1 + 0.08 * (quantized["__user"] ?? 0)
            let factor = 1 + (scale - 1) * openness
            let driftX = size.x * (quantized["__gazeX"] ?? 0) * 0.06 * openness
            let driftY = size.y * (quantized["__gazeY"] ?? 0) * 0.05 * openness
            let close = min(1, max(0, (closed - 0.45) / 0.5))
            let recede = 0.08 * close * close * (3 - 2 * close)
            return (SIMD4(center, 0), SIMD4(factor, driftX, driftY, recede))
        }
        pupils.center = (sides[0].0, sides[1].0); pupils.shape = (sides[0].1, sides[1].1)
        return pupils
    }
}

extension FacialMorphs {
    /// Diagnostic geometry check, independent of lighting and face pixels.
    /// Antenna deltas identify each ear without depending on USD part ordering.
    func earSpans(_ values: [String: Float]) -> [[Float]] {
        ["ear_antenna_L", "ear_antenna_R"].map { shape in
            var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
            for part in parts {
                let indices = Set((part.offsets[shape] ?? []).map(\.0))
                guard !indices.isEmpty else { continue }
                var vertices = part.positions
                for (name, weight) in values where abs(weight) > 0.001 {
                    for (index, delta) in part.offsets[name] ?? [] { vertices[index] += delta * weight }
                }
                for index in indices {
                    let point = (toWorld * SIMD4(vertices[index], 1)).xyz
                    low = simd_min(low, point); high = simd_max(high, point)
                }
            }
            let span = high - low
            return [span.x, span.y, span.z]
        }
    }
}
