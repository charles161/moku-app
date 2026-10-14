import AppKit
import Metal
import RealityKit

/// `--morph-probe <dir>`: which ways of deforming the face show in the RealityRenderer path (RealityKit's own blend
/// shapes, macOS 27's deformers), and the GPU morphs against the CPU's, posed, for every shape and mood, as image
/// diffs (gpu-vs-cpu.tsv). MOKU_COMPANION picks the mesh.
extension MokuVisualDiagnostics { public static func morphProbe(directory: URL) async throws { try await MorphProbe.run(directory: directory) } }
@MainActor enum MorphProbe {
    static var log: [String] = []
    static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let companion = Companion.current  // MOKU_COMPANION=tetsu checks another companion's mesh
        guard let url = MokuAssets.file(companion.modelPath) else { return }
        log.append("companion: \(companion.rawValue)")
        let character = try await Entity(contentsOf: url)
        let rig = RealityCharacter.descendants(character).compactMap { $0 as? ModelEntity }.first { !$0.jointNames.isEmpty }!
        let names = rig.model!.materials.map { $0.name?.replacingOccurrences(of: " ", with: "_") ?? "" }
        try await MaterialConfiguration.apply(to: character, companion: companion)
        // Without the fuzz shell on both paths: its see-through parts are drawn in an order that follows the mesh's
        // bounds, which the CPU path regenerates and the GPU path keeps at rest, so a few overlapping fringe pixels
        // would differ though every vertex is the same. The shell's vertices take the same kernel as the felt's.
        let morphs = try FacialMorphs(mesh: rig.model!.mesh, materials: rig.model!.materials, transform: rig.transformMatrix(relativeTo: nil), materialNames: names, gpu: false, fuzz: false)
        let weights: [String: Float] = ["blink_L": 1, "smile": 1, "brows_angry": 1, "ear_antenna_L": 1]

        let device = MTLCreateSystemDefaultDevice()!
        let renderer = try RealityRenderer()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 640, height: 640, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        let output = try RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        renderer.cameraSettings.colorBackground = .color(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        let studio = try JSONDecoder().decode(Studio.self, from: Data(contentsOf: MokuAssets.file("runtime/studio.json")!))
        let camera = PerspectiveCamera(); camera.camera.fieldOfViewInDegrees = 2 * atan(tan(studio.camera.fieldOfView * .pi / 360) * Float(StageGeometry.renderPoints / 160) / (studio.camera.safeAreaFraction ?? 1)) * 180 / .pi
        camera.look(at: Studio.vector(studio.camera.target), from: Studio.vector(studio.camera.position), relativeTo: nil)
        let light = DirectionalLight(); light.light.intensity = 3000; light.look(at: .zero, from: [1, 2, 3], relativeTo: nil)
        let holder = Entity()
        renderer.entities.append(contentsOf: [holder, camera, light]); renderer.activeCamera = camera

        func render(_ entity: Entity, _ name: String) async throws -> [UInt8] {
            holder.children.removeAll(); holder.addChild(entity)
            for _ in 0..<3 {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    do { try renderer.updateAndRender(deltaTime: 1 / 60, cameraOutput: output, onComplete: { _ in c.resume() }) } catch { c.resume(throwing: error) }
                }
            }
            var pixels = [UInt8](repeating: 0, count: 640 * 640 * 4)
            texture.getBytes(&pixels, bytesPerRow: 640 * 4, from: MTLRegionMake2D(0, 0, 640, 640), mipmapLevel: 0)
            let image = CGImage(width: 640, height: 640, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 640 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little), provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
            return pixels
        }
        func diff(_ a: [UInt8], _ b: [UInt8]) -> String {
            var maxD = 0, sum = 0, changed = 0
            for i in a.indices { let d = abs(Int(a[i]) - Int(b[i])); maxD = max(maxD, d); sum += d; if d > 0 { changed += 1 } }
            return "max \(maxD) mean \(String(format: "%.4f", Double(sum) / Double(a.count))) changedBytes \(changed)"
        }
        func runtimeRig() -> ModelEntity {
            let entity = ModelEntity(mesh: morphs.mesh, materials: rig.model!.materials)
            entity.transform.matrix = rig.transformMatrix(relativeTo: nil); entity.jointTransforms = rig.jointTransforms
            entity.components.remove(BlendShapeWeightsComponent.self)
            return entity
        }
        // N: neutral. A: today's CPU morphs.
        let neutral = try await render(runtimeRig(), "N-neutral")
        let cpuRig = runtimeRig()
        try morphs.apply(weights, gaze: .zero, userAttention: 0, to: cpuRig)
        let cpu = try await render(cpuRig, "A-cpu")
        log.append("A cpu vs neutral: \(diff(cpu, neutral))")
        // B: the imported mesh with its own blend shapes, weights through BlendShapeWeightsComponent.
        let imported = rig.clone(recursive: false)
        imported.transform.matrix = rig.transformMatrix(relativeTo: nil)
        var component = BlendShapeWeightsComponent(weightsMapping: BlendShapeWeightsMapping(meshResource: imported.model!.mesh))
        log.append("B weight sets: \(component.weightSet.map { "\($0.id) \($0.weightNames.count)" })")
        let neutralImported = try await render(imported.clone(recursive: false), "B0-imported-neutral")
        log.append("B0 imported neutral vs N: \(diff(neutralImported, neutral))")
        for data in component.weightSet {
            var data = data
            for (index, name) in data.weightNames.enumerated() { if let w = weights[name] { data.weights[index] = w } }
            component.weightSet.set(data)
        }
        imported.components.set(component)
        let native = try await render(imported, "B-native")
        log.append("B native vs neutral: \(diff(native, neutralImported)); vs A: \(diff(native, cpu))")
        if #available(macOS 27, *), CommandLine.arguments.contains("--probe-deformers") {
            let stacked = rig.clone(recursive: false)
            stacked.transform.matrix = rig.transformMatrix(relativeTo: nil)
            stacked.components.set(component)
            stacked.components.set(try MeshDeformerComponent(from: [MeshDeformationStack(deformers: [BlendShapeDeformer(), SkinningDeformer()], targets: [.all])]))
            let deformed = try await render(stacked, "C-deformer-blendshapes")
            log.append("C builtin deformer vs neutral: \(diff(deformed, neutralImported)); vs A: \(diff(deformed, cpu))")
        }
        // G: the GPU morphs against the CPU's, posed (so skinning after the morphs is checked too), for every shape
        // alone and for whole faces with the gaze, the user's attention and blinks.
        let gpuMorphs = try FacialMorphs(mesh: rig.model!.mesh, materials: rig.model!.materials, transform: rig.transformMatrix(relativeTo: nil), materialNames: names, gpu: true, fuzz: false)
        log.append("gpu available: \(gpuMorphs.onGPU)")
        var posed = rig.jointTransforms
        for (i, name) in rig.jointNames.enumerated() {
            let leaf = name.split(separator: "/").last ?? ""
            if leaf == "head" { posed[i].rotation = posed[i].rotation * simd_quatf(angle: 0.25, axis: [0, 1, 0]) * simd_quatf(angle: 0.15, axis: [1, 0, 0]) }
            if leaf == "ear_L_01" { posed[i].rotation = posed[i].rotation * simd_quatf(angle: 0.5, axis: [0, 0, 1]) }
            if leaf == "chest" { posed[i].rotation = posed[i].rotation * simd_quatf(angle: -0.12, axis: [0, 1, 0]) }
        }
        func gpuRig() -> ModelEntity {
            let entity = ModelEntity(mesh: gpuMorphs.mesh, materials: rig.model!.materials)
            entity.transform.matrix = rig.transformMatrix(relativeTo: nil); entity.components.remove(BlendShapeWeightsComponent.self)
            return entity
        }
        let moods = (try? JSONSerialization.jsonObject(with: Data(contentsOf: MokuAssets.file("character/moods.json", companion: companion)!)) as? [String: Any])?["moods"] as? [String: [String: Any]] ?? [:]
        var cases: [(String, [String: Float], SIMD2<Float>, Float)] = morphs.availableShapes.sorted().map { ("shape-" + $0, [$0: 1], .zero, 0) }
        for (mood, pose) in moods.sorted(by: { $0.key < $1.key }) {
            let shapes = (pose["blendShapes"] as? [String: Double] ?? [:]).mapValues { Float($0) }
            cases.append(("mood-" + mood, shapes, SIMD2(0.4, -0.3), 1))
            cases.append(("mood-" + mood + "-blinkhalf", shapes.merging(["blink_L": 0.5, "blink_R": 0.6]) { max($0, $1) }, SIMD2(-0.7, 0.5), 0.5))
        }
        cases.append(("neutral", [:], .zero, 0))
        cases.append(("eyes-closed", ["blink_L": 1, "blink_R": 1], SIMD2(0.9, 0.9), 1))
        var worst = (name: "", max: 0, mean: 0.0)
        var rows: [String] = []
        for (name, shapes, gaze, user) in cases {
            let a = runtimeRig(); a.jointTransforms = posed
            try morphs.apply(shapes, gaze: gaze, userAttention: user, to: a)
            let b = gpuRig(); b.jointTransforms = posed
            try gpuMorphs.apply(shapes, gaze: gaze, userAttention: user, to: b)
            let ca = try await render(a, "G-\(name)-cpu"), cb = try await render(b, "G-\(name)-gpu")
            if name == "neutral" || name == "shape-smile" {
                try Data(ca).write(to: directory.appendingPathComponent("G-\(name)-cpu.bgra")); try Data(cb).write(to: directory.appendingPathComponent("G-\(name)-gpu.bgra"))
                let again = try await render(a, "G-\(name)-cpu-again"); try Data(again).write(to: directory.appendingPathComponent("G-\(name)-cpu-again.bgra"))
            }
            var maxD = 0, sum = 0
            for i in ca.indices { let d = abs(Int(ca[i]) - Int(cb[i])); maxD = max(maxD, d); sum += d }
            let mean = Double(sum) / Double(ca.count)
            rows.append("\(name)\t\(maxD)\t\(String(format: "%.5f", mean))")
            if maxD > worst.max || (maxD == worst.max && mean > worst.mean) { worst = (name, maxD, mean) }
            if maxD == 0 { try? FileManager.default.removeItem(at: directory.appendingPathComponent("G-\(name)-cpu.png")); try? FileManager.default.removeItem(at: directory.appendingPathComponent("G-\(name)-gpu.png")) }
        }
        try (["case\tmaxDiff\tmeanDiff"] + rows).joined(separator: "\n").write(to: directory.appendingPathComponent("gpu-vs-cpu.tsv"), atomically: true, encoding: .utf8)
        log.append("G gpu vs cpu over \(cases.count) faces: worst \(worst)")
        try log.joined(separator: "\n").write(to: directory.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)
        print(log.joined(separator: "\n"))
    }
}

@available(macOS 27, *)
struct ProbeDeformer: MeshDeformer {
    nonisolated(unsafe) static var calls: [String] = []
    nonisolated(unsafe) static var pipeline: (any MTLComputePipelineState)?
    var lift: Float
    static var mode: MeshDeformerExecutionMode { .gpu }
    static var type: String { "MokuProbeDeformer" }
    var options: MeshDeformerOptions { MeshDeformerOptions(cadence: .everyFrame, inputSpec: .positions, outputSpec: .positions) }
    func isDeformerEqual(other: any MeshDeformer) -> Bool { (other as? ProbeDeformer)?.lift == lift }
    func deform(parameter: MeshDeformParameterGPU, encoder: any MTLComputeCommandEncoder) {
        let input = parameter.inputBuffers.positions, output = parameter.outputBuffers.positions
        Self.calls.append("count \(parameter.inputBuffers.count) in \(input.map { "\($0.format.rawValue)/\($0.stride)/\($0.offset)/\($0.buffer.length)" } ?? "nil") out \(output.map { "\($0.format.rawValue)/\($0.stride)/\($0.offset)/\($0.buffer.length)" } ?? "nil") normals \(parameter.inputBuffers.normals != nil)/\(parameter.outputBuffers.normals != nil) thread \(Thread.isMainThread)")
        guard let input, let output else { return }
        if Self.pipeline == nil {
            let source = """
            #include <metal_stdlib>
            using namespace metal;
            kernel void lift(device const uchar* src [[buffer(0)]], device uchar* dst [[buffer(1)]], constant uint4& layout [[buffer(2)]], constant float& amount [[buffer(3)]], uint id [[thread_position_in_grid]]) {
                if (id >= layout.x) return;
                packed_float3 p = *(device const packed_float3*)(src + layout.y + id * layout.z);
                p.y += amount;
                *(device packed_float3*)(dst + layout.w + id * layout.z) = p;
            }
            """
            let device = encoder.device
            let library = try! device.makeLibrary(source: source, options: nil)
            Self.pipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "lift")!)
        }
        var layout = SIMD4<UInt32>(UInt32(parameter.inputBuffers.count), UInt32(input.offset), UInt32(input.stride), UInt32(output.offset))
        var amount = lift
        encoder.setComputePipelineState(Self.pipeline!)
        encoder.setBuffer(input.buffer, offset: 0, index: 0); encoder.setBuffer(output.buffer, offset: 0, index: 1)
        encoder.setBytes(&layout, length: 16, index: 2); encoder.setBytes(&amount, length: 4, index: 3)
        encoder.dispatchThreads(MTLSize(width: parameter.inputBuffers.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    }
}
