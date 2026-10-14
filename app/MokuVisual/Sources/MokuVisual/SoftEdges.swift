import Foundation

/// RealityKit blends in linear light into Moku's sRGB render target, so a pixel the character only partly covers holds
/// the sRGB encoding of its colour premultiplied *in linear light*. Core Graphics and Core Animation read a frame as
/// premultiplied in sRGB, which lifts every soft pixel toward white: a pale rim round the antialiased silhouette, and a
/// light halo round the felt's fuzz (moku-look-v2.md step 4). This re-premultiplies those pixels in sRGB, so the edge
/// keeps the felt's own colour on any wallpaper. Opaque and empty pixels (nearly all of them) are left alone.
enum SoftEdges {
    /// [alpha << 8 | stored value] → the value premultiplied in sRGB.
    private static let table: [UInt8] = {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func encoded(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        var table = [UInt8](repeating: 0, count: 256 * 256)
        for alpha in 1..<255 {
            let a = Double(alpha) / 255
            for value in 0..<256 {
                let straight = min(1, linear(Double(value) / 255) / a)
                table[alpha << 8 | value] = UInt8(min(Double(alpha), (encoded(straight) * a * 255).rounded()))
            }
        }
        return table
    }()

    /// `bytes`: `pixelCount` BGRA pixels (little-endian ARGB words: alpha in each word's top byte), premultiplied. About
    /// 0.1 ms a frame at 640 px, measured; a word at a time is faster here than SIMD loads.
    static func correct(_ bytes: UnsafeMutableRawPointer, pixelCount: Int) {
        table.withUnsafeBufferPointer { table in
            let words = bytes.bindMemory(to: UInt32.self, capacity: pixelCount)
            for index in 0..<pixelCount {
                let word = words[index], alpha = word >> 24
                guard alpha &- 1 < 254 else { continue }  // alpha 1...254: a soft pixel
                let row = Int(alpha) << 8
                let blue = UInt32(table[row | Int(word & 0xff)]), green = UInt32(table[row | Int((word >> 8) & 0xff)]), red = UInt32(table[row | Int((word >> 16) & 0xff)])
                words[index] = alpha << 24 | red << 16 | green << 8 | blue
            }
        }
    }
}
