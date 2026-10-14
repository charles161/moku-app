import AppKit
import RealityKit

struct MaterialConfiguration: Decodable {
    struct Rule: Decodable {
        let name: String
        let aliases: [String]
        let baseTint: [CGFloat]
        let baseColorTexturePath: String?
        let roughness: Float
        let metallic: Float
        let specular: Float
        let sheenColor: [CGFloat]
        let normalMapPath: String?
        let normalScale: Float
        let normalTiling: [Float]
        let uvOffset: [Float]
        let doubleSided: Bool
        /// Lamps, windows and stars glow: an emissive colour (linear) and its strength. Absent for everything else.
        let emissive: [CGFloat]?
        let emissiveIntensity: Float?
        /// Warms with the angry flush (a companion's own rules; Moku's plush is listed in RealityCharacter).
        let flush: Bool?
        /// Where a flushed material goes instead of warming (linear RGB): Tetsu's cyan status LEDs turn amber.
        let flushColor: [CGFloat]?
        func matches(_ name: String) -> Bool { self.name == name || aliases.contains(name) }
    }
    let materials: [Rule]

    /// The rules for `companion`: its own (`character/<id>/materials.json`) first, so they win for a shared name (the
    /// eyes keep Moku's material names so the face code is shared), then the shared `runtime/materials.json`.
    static func load(companion: Companion = .moku) throws -> Self? {
        let files = (companion == .moku ? [] : ["character/\(companion.rawValue)/materials.json"]) + ["runtime/materials.json"]
        let rules = try files.compactMap { MokuAssets.file($0, companion: .moku) }.flatMap { try JSONDecoder().decode(Self.self, from: Data(contentsOf: $0)).materials }
        return rules.isEmpty ? nil : Self(materials: rules)
    }
    /// The material names that warm with the angry flush, for a companion with its own rules (nil for Moku).
    static func flushedNames(companion: Companion) -> Set<String>? {
        guard companion != .moku, let url = MokuAssets.file("character/\(companion.rawValue)/materials.json", companion: .moku),
              let rules = try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url)).materials else { return nil }
        return Set(rules.filter { $0.flush == true }.flatMap { [$0.name] + $0.aliases })
    }
    /// The flushed materials that change to a colour of their own (by name and alias), for a companion with its own rules.
    static func flushColors(companion: Companion) -> [String: [CGFloat]] {
        guard companion != .moku, let url = MokuAssets.file("character/\(companion.rawValue)/materials.json", companion: .moku),
              let rules = try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url)).materials else { return [:] }
        var colors: [String: [CGFloat]] = [:]
        for rule in rules where rule.flush == true { if let color = rule.flushColor { for name in [rule.name] + rule.aliases { colors[name] = color } } }
        return colors
    }
    @MainActor static func apply(to root: Entity, companion: Companion = .moku) async throws {
        guard let config = try load(companion: companion) else { return }
        var textures: [String: TextureResource] = [:]
        for entity in RealityCharacter.descendants(root) {
            guard let model = entity as? ModelEntity, var component = model.model else { continue }
            for index in component.materials.indices {
                guard var material = component.materials[index] as? PhysicallyBasedMaterial,
                      let rule = config.materials.first(where: { $0.matches(material.name ?? "") }) else { continue }
                material.baseColor.tint = linearColor(rule.baseTint)
                material.roughness = .init(floatLiteral: rule.roughness)
                material.metallic = .init(floatLiteral: rule.metallic)
                material.specular = .init(floatLiteral: rule.specular)
                material.sheen = .init(tint: linearColor(rule.sheenColor))
                // Without a clearcoat block, RealityKit's lit shader turns a few single pixels black (NaN) where a
                // surface faces a directional light's half-vector: about 11 specks per frame at 1280 px, on the head,
                // the body and the ears. They don't depend on the textures, normal map, roughness, sheen or light
                // strength. An explicit zero clearcoat selects the shader that doesn't; every other pixel is unchanged.
                material.clearcoat = .init(floatLiteral: 0)
                material.faceCulling = rule.doubleSided ? .none : .back
                if let emissive = rule.emissive {
                    material.emissiveColor = .init(color: linearColor(emissive))
                    material.emissiveIntensity = rule.emissiveIntensity ?? 1
                }
                if let path = rule.baseColorTexturePath, let url = MokuAssets.file(path, companion: .moku) {  // exact paths
                    let texture: TextureResource
                    if let cached = textures[path] { texture = cached } else { texture = try await TextureResource(contentsOf: url, options: .init(semantic: .color)); textures[path] = texture }
                    material.baseColor.texture = .init(texture)
                }
                if let path = rule.normalMapPath, let url = MokuAssets.file(path, companion: .moku) {
                    let key = "\(path):\(rule.normalScale)"
                    let texture: TextureResource
                    if let cached = textures[key] { texture = cached }
                    else {
                        let image = try scaledNormal(url: url, scale: rule.normalScale)
                        texture = try await TextureResource(image: image, options: .init(semantic: .normal)); textures[key] = texture
                    }
                    material.normal.texture = .init(texture)
                    // Current contract is 1×1 / zero offset, preserving all imported UV bindings.
                    if rule.normalTiling.count == 2 && rule.uvOffset.count == 2 {
                        material.textureCoordinateTransform.scale *= SIMD2(rule.normalTiling[0], rule.normalTiling[1])
                        material.textureCoordinateTransform.offset += SIMD2(rule.uvOffset[0], rule.uvOffset[1])
                    }
                }
                component.materials[index] = material
            }
            model.model = component
        }
    }
    @MainActor private static func linearColor(_ values: [CGFloat]) -> NSColor {
        let color = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, components: [values[0], values[1], values[2], values.count > 3 ? values[3] : 1])!
        return NSColor(cgColor: color)!
    }
    @MainActor private static func scaledNormal(url: URL, scale: Float) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
        if scale == 1 { return image }
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileReadCorruptFile) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let x = (Float(bytes[i]) / 127.5 - 1) * scale, y = (Float(bytes[i+1]) / 127.5 - 1) * scale, z = Float(bytes[i+2]) / 127.5 - 1
            let length = max(0.001, sqrt(x*x + y*y + z*z))
            for (j, value) in [x,y,z].enumerated() { bytes[i+j] = UInt8(clamping: Int((value / length + 1) * 127.5)) }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}
