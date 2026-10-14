import RealityKit
import Foundation

/// The asset owns the offset, visibility interval and imported coordinate conversion.
@MainActor
final class PropAttachment {
    private struct Configuration: Decodable {
        let holdJointEulerDegrees: [String: [Float]]?
        let file: String
        let joint: String
        let wrapperLocalMatrixColumnMajor: [Float]
        let visibleNormalizedTime: [Double]
    }
    private let wrapper = Entity()
    private let clipID: String
    private var emitters: [(ModelEntity, Int, Float)] = []
    private var intensity: Float = -1
    func setIntensity(_ value: Float) {
        let value = max(0.15, value); guard value != intensity else { return }; intensity = value
        for (entity, index, base) in emitters {
            guard var model = entity.model, var material = model.materials[index] as? PhysicallyBasedMaterial else { continue }
            material.emissiveIntensity = base * value; model.materials[index] = material; entity.model = model
        }
    }
    var holdAngles: [String: [Float]] { configuration.holdJointEulerDegrees ?? [:] }
    private let configuration: Configuration
    private let offset: simd_float4x4

    private init(clip: String, configuration: Configuration, prop: Entity, rig: ModelEntity) {
        self.configuration = configuration; clipID = clip
        let values = configuration.wrapperLocalMatrixColumnMajor
        offset = simd_float4x4(columns: (SIMD4(values[0...3]), SIMD4(values[4...7]), SIMD4(values[8...11]), SIMD4(values[12...15])))
        wrapper.addChild(prop); rig.addChild(wrapper); wrapper.isEnabled = false
    }
    static func load(clip: String, rig: ModelEntity, companion: Companion = .current) async throws -> PropAttachment? {
        guard let url = MokuAssets.file("character/prop_attachments.json", companion: companion) else { return nil }
        // The top-level schemaVersion is metadata, not an attachment record.
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let record = object[clip] else { return nil }
        let config = try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: record))
        guard config.wrapperLocalMatrixColumnMajor.count == 16, config.visibleNormalizedTime.count == 2 else { throw CocoaError(.fileReadCorruptFile) }
        let prop = try await Entity(contentsOf: url.deletingLastPathComponent().appendingPathComponent(config.file).standardizedFileURL)
        let names: [String]
        if clip == "carry_lantern", let manifest = MokuAssets.file("lantern/manifest.json"),
           let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any] {
            names = object["glassMaterialNames"] as? [String] ?? []
        } else { names = [] }
        let emitters = RealityCharacter.descendants(prop).compactMap { $0 as? ModelEntity }.flatMap { entity in
            (entity.model?.materials.enumerated().compactMap { index, material -> (ModelEntity, Int, Float)? in
                guard names.contains(material.name ?? ""), let pbr = material as? PhysicallyBasedMaterial else { return nil }
                return (entity, index, pbr.emissiveIntensity)
            }) ?? []
        }
        try await MaterialConfiguration.apply(to: prop, companion: companion)
        let attachment = PropAttachment(clip: clip, configuration: config, prop: prop, rig: rig)
        attachment.emitters = emitters
        return attachment
    }
    func update(clip: String?, normalizedTime: Double, rig: ModelEntity) {
        let window = configuration.visibleNormalizedTime
        guard clip == clipID else { return update(visible: false, rig: rig) }
        update(visible: normalizedTime >= window[0] && normalizedTime <= window[1], rig: rig,
               scale: Self.growScale(normalizedTime, from: window[0], to: window[1]))
    }
    /// How big the prop is at `t` in its visible window: it grows into the paws over `growFraction` of the clip
    /// at a window that starts inside the clip, and shrinks away the same way at one that ends inside it (a cup
    /// that pops in and out reads as abrupt). A window reaching the clip's start or end (a looped hold) stays full.
    nonisolated static func growScale(_ t: Double, from start: Double, to end: Double, growFraction: Double = 0.025) -> Float {
        let rising = start > 0 ? min(1, max(0, (t - start) / growFraction)) : 1
        let falling = end < 1 ? min(1, max(0, (end - t) / growFraction)) : 1
        let x = min(rising, falling)
        return Float(x * x * (3 - 2 * x))
    }
    func update(visible: Bool, rig: ModelEntity, scale: Float = 1) {
        wrapper.isEnabled = visible && scale > 0.001
        guard wrapper.isEnabled, let hand = Self.jointMatrix(named: configuration.joint, names: rig.jointNames, transforms: rig.jointTransforms) else { return }
        // Scaled about the prop's own anchor (a cup's base), so it grows in the paws rather than toward them.
        wrapper.transform.matrix = hand * offset * simd_float4x4(diagonal: SIMD4(scale, scale, scale, 1))
    }
    static func jointMatrix(named leaf: String, names: [String], transforms: [Transform]) -> simd_float4x4? {
        guard names.count == transforms.count, let name = names.first(where: { $0.split(separator: "/").last == Substring(leaf) }) else { return nil }
        var matrix = matrix_identity_float4x4
        for (index, ancestor) in names.enumerated() where name == ancestor || name.hasPrefix(ancestor + "/") { matrix *= transforms[index].matrix }
        return matrix
    }
}
