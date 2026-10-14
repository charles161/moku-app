import Foundation
import Metal
import RealityKit

/// Moku's face morphs as a GPU pass (macOS 27's mesh deformers), instead of a new MeshResource whenever the face
/// changes. Each frame RealityKit hands every mesh part's resting positions to `FaceMorphDeformer`, which adds the
/// authored deltas at today's weights and moves the pupils exactly as `FacialMorphs.apply` does on the CPU; skinning
/// runs after it, as before. (RealityKit's own blend shapes, through BlendShapeWeightsComponent or BlendShapeDeformer,
/// still don't deform this mesh in the RealityRenderer path: measured 2026-10-04, not one pixel changes.)
@available(macOS 27, *)
final class FaceMorphsOnGPU: @unchecked Sendable {
    /// What one frame needs besides the weights: the pupils, per side (0: the character's right, x < 0).
    struct Pupils {
        var toWorld = matrix_identity_float4x4
        var fromWorld = matrix_identity_float4x4
        var center: (SIMD4<Float>, SIMD4<Float>) = (.zero, .zero)
        /// x: the scale about the centre, y and z: the gaze drift, w: how far the pupil recedes.
        var shape: (SIMD4<Float>, SIMD4<Float>) = (SIMD4(1, 0, 0, 0), SIMD4(1, 0, 0, 0))
    }
    struct Part {
        let modelID: String
        let partID: String
        let vertexCount: Int
        let isPupil: Bool
        /// Per vertex, where its deltas start in `entries` (vertexCount + 1 values).
        let rows: any MTLBuffer
        /// (shape index, delta) pairs, 16 bytes each.
        let entries: any MTLBuffer
    }
    let shapeNames: [String]
    let parts: [Part]
    private let shapeIndex: [String: Int]
    private let lock = NSLock()
    private var weights: [Float]
    private var pupils = Pupils()
    private let id: Int

    init?(parts source: [(modelID: String, partID: String, vertexCount: Int, isPupil: Bool, offsets: [String: [(Int, SIMD3<Float>)]])], shapes: Set<String>) {
        guard let device = MTLCreateSystemDefaultDevice(), Self.pipeline(device) != nil else { return nil }
        shapeNames = shapes.sorted()
        shapeIndex = Dictionary(uniqueKeysWithValues: shapeNames.enumerated().map { ($1, $0) })
        weights = [Float](repeating: 0, count: max(1, shapeNames.count))
        var built: [Part] = []
        for part in source {
            var perVertex = [[(UInt32, SIMD3<Float>)]](repeating: [], count: part.vertexCount)
            for name in shapeNames {
                for (index, delta) in part.offsets[name] ?? [] where index < part.vertexCount { perVertex[index].append((UInt32(shapeIndex[name]!), delta)) }
            }
            var rows = [UInt32](repeating: 0, count: part.vertexCount + 1)
            var entries: [SIMD4<Float>] = []  // (delta.xyz, shape index as bits)
            for vertex in 0..<part.vertexCount {
                for (shape, delta) in perVertex[vertex] { entries.append(SIMD4(delta.x, delta.y, delta.z, Float(bitPattern: shape))) }
                rows[vertex + 1] = UInt32(entries.count)
            }
            if entries.isEmpty { entries.append(.zero) }
            guard let rowBuffer = device.makeBuffer(bytes: rows, length: rows.count * 4, options: .storageModeShared),
                  let entryBuffer = device.makeBuffer(bytes: entries, length: entries.count * 16, options: .storageModeShared) else { return nil }
            built.append(Part(modelID: part.modelID, partID: part.partID, vertexCount: part.vertexCount, isPupil: part.isPupil, rows: rowBuffer, entries: entryBuffer))
        }
        parts = built
        id = Self.register(nil)
        Self.register(self, as: id)
    }
    deinit { Self.unregister(id) }

    /// One stack per mesh part: the morphs, then skinning, as the CPU path's regenerated mesh was skinned. Skinning
    /// must carry the normals and tangents too (without it a turned head is lit as if it hadn't turned).
    func component() throws -> MeshDeformerComponent {
        try MeshDeformerComponent(from: parts.indices.map { index in
            MeshDeformationStack(deformers: [FaceMorphDeformer(morphs: id, part: index), SkinningDeformer(skinsTangentFrame: true)],
                                 targets: [.model(name: parts[index].modelID, part: parts[index].partID)])
        })
    }

    /// The face for the next frames drawn (already quantized, as on the CPU).
    func set(weights values: [String: Float], pupils: Pupils) {
        var next = [Float](repeating: 0, count: weights.count)
        for (name, value) in values { if let index = shapeIndex[name] { next[index] = value } }
        lock.lock(); weights = next; self.pupils = pupils; lock.unlock()
    }

    fileprivate func encode(part index: Int, parameter: MeshDeformParameterGPU, encoder: any MTLComputeCommandEncoder) {
        guard let input = parameter.inputBuffers.positions, let output = parameter.outputBuffers.positions,
              let pipeline = Self.pipeline(encoder.device), index < parts.count else { return }
        let part = parts[index], count = parameter.inputBuffers.count
        lock.lock(); var weights = self.weights; var pupils = self.pupils; lock.unlock()
        // A part that isn't the one these deltas were made for is copied through untouched.
        let matches: UInt32 = part.vertexCount == count ? 1 : 0
        var layout = (SIMD4<UInt32>(UInt32(count), UInt32(input.offset), UInt32(input.stride), UInt32(output.offset)),
                      SIMD4<UInt32>(UInt32(output.stride), part.isPupil ? matches : 0, matches, UInt32(weights.count)))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input.buffer, offset: 0, index: 0)
        encoder.setBuffer(output.buffer, offset: 0, index: 1)
        encoder.setBytes(&layout, length: 32, index: 2)
        encoder.setBuffer(part.rows, offset: 0, index: 3)
        encoder.setBuffer(part.entries, offset: 0, index: 4)
        weights.withUnsafeMutableBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 5) }
        encoder.setBytes(&pupils, length: MemoryLayout<Pupils>.size, index: 6)
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 64)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }

    // MARK: The kernel. It mirrors FacialMorphs.apply line for line; safe math keeps it to the CPU's arithmetic.

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Pupils { float4x4 toWorld; float4x4 fromWorld; float4 center[2]; float4 shape[2]; };
    kernel void faceMorphs(device const uchar* src [[buffer(0)]], device uchar* dst [[buffer(1)]],
                           constant uint4* layout [[buffer(2)]], device const uint* rows [[buffer(3)]],
                           device const float4* entries [[buffer(4)]], constant float* weights [[buffer(5)]],
                           constant Pupils& pupils [[buffer(6)]], uint id [[thread_position_in_grid]]) {
        uint4 a = layout[0], b = layout[1];
        if (id >= a.x) return;
        float3 p = float3(*(device const packed_float3*)(src + a.y + id * a.z));
        if (b.z != 0) {
            for (uint e = rows[id]; e < rows[id + 1]; e++) {
                float4 entry = entries[e];
                uint shape = as_type<uint>(entry.w);
                float w = shape < b.w ? weights[shape] : 0.0f;
                if (fabs(w) > 0.001f) { p = p + entry.xyz * w; }
            }
        }
        if (b.y != 0) {
            float4 world4 = pupils.toWorld * float4(p, 1.0f);
            float3 point = world4.xyz;
            uint side = point.x < 0.0f ? 0 : 1;
            float4 center = pupils.center[side], shape = pupils.shape[side];
            point.x = center.x + (point.x - center.x) * shape.x;
            point.y = center.y + (point.y - center.y) * shape.x;
            point.x += shape.y;
            point.y += shape.z;
            point.z -= shape.w;
            p = (pupils.fromWorld * float4(point, 1.0f)).xyz;
        }
        *(device packed_float3*)(dst + a.w + id * b.x) = packed_float3(p);
    }
    """
    private static let pipelineLock = NSLock()
    nonisolated(unsafe) private static var pipelines: [ObjectIdentifier: any MTLComputePipelineState] = [:]
    private static func pipeline(_ device: any MTLDevice) -> (any MTLComputePipelineState)? {
        pipelineLock.lock(); defer { pipelineLock.unlock() }
        if let ready = pipelines[ObjectIdentifier(device)] { return ready }
        let options = MTLCompileOptions(); options.mathMode = .safe; options.mathFloatingPointFunctions = .precise
        guard let library = try? device.makeLibrary(source: source, options: options), let function = library.makeFunction(name: "faceMorphs"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        pipelines[ObjectIdentifier(device)] = pipeline
        return pipeline
    }

    // MARK: Deformers are Codable values, so they find their morphs by number.

    private final class Weak: @unchecked Sendable { weak var value: FaceMorphsOnGPU?; init(_ value: FaceMorphsOnGPU?) { self.value = value } }
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [Int: Weak] = [:]
    nonisolated(unsafe) private static var nextID = 1
    @discardableResult private static func register(_ morphs: FaceMorphsOnGPU?, as id: Int? = nil) -> Int {
        registryLock.lock(); defer { registryLock.unlock() }
        let key = id ?? { defer { nextID += 1 }; return nextID }()
        if let morphs { registry[key] = Weak(morphs) }
        return key
    }
    private static func unregister(_ id: Int) { registryLock.lock(); registry[id] = nil; registryLock.unlock() }
    fileprivate static func morphs(_ id: Int) -> FaceMorphsOnGPU? { registryLock.lock(); defer { registryLock.unlock() }; return registry[id]?.value }
}

@available(macOS 27, *)
struct FaceMorphDeformer: MeshDeformer {
    let morphs: Int
    let part: Int
    static var mode: MeshDeformerExecutionMode { .gpu }
    static var type: String { "ai.lightslips.moku.face-morphs" }
    var options: MeshDeformerOptions { MeshDeformerOptions(cadence: .everyFrame, inputSpec: .positions, outputSpec: .positions) }
    func isDeformerEqual(other: any MeshDeformer) -> Bool { (other as? FaceMorphDeformer) == self }
    func deform(parameter: MeshDeformParameterGPU, encoder: any MTLComputeCommandEncoder) {
        FaceMorphsOnGPU.morphs(morphs)?.encode(part: part, parameter: parameter, encoder: encoder)
    }
}
