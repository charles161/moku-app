import Foundation
import simd

struct EarPose {
    var weights: [String: Float] = [:]
    var angles: [String: SIMD3<Float>] = [:]
    var isRest: Bool { weights.values.allSatisfy { abs($0) < 0.0001 } && angles.values.allSatisfy { simd_length($0) < 0.0001 } }
    static func blend(_ a: Self, _ b: Self, _ t: Float) -> Self {
        var result = Self()
        for key in Set(a.weights.keys).union(b.weights.keys) { result.weights[key] = (a.weights[key] ?? 0) * (1-t) + (b.weights[key] ?? 0) * t }
        for key in Set(a.angles.keys).union(b.angles.keys) { result.angles[key] = (a.angles[key] ?? .zero) * (1-t) + (b.angles[key] ?? .zero) * t }
        return result
    }
}

struct EarTransitions: Decodable {
    struct Keypose: Decodable { let phase: Float; let blendShapes: [String: Float]; let jointEulerDegrees: [String: [Float]] }
    struct Path: Decodable { let target: String; let keyposes: [Keypose] }
    let clearControls: [String]
    let paths: [Path]
    static func load(companion: Companion = .current) -> Self? { MokuAssets.file("character/ear_transitions.json", companion: companion).flatMap { try? JSONDecoder().decode(Self.self, from: Data(contentsOf: $0)) } }
    var requiredShapes: Set<String> { Set(paths.flatMap { $0.keyposes.flatMap { $0.blendShapes.keys } }) }
    private func path(_ pose: EarPose) -> String? { paths.first { (pose.weights[$0.target] ?? 0) > 0.0001 }?.target }
    func interpolate(from: EarPose, to: EarPose, progress: Float) -> EarPose {
        let p = min(1, max(0, progress))
        let a = path(from), b = path(to)
        if (a != nil || b != nil) && a != b && !from.isRest && !to.isRest {
            return p < 0.5 ? .blend(from, EarPose(), EarTiming.phase(p*2,rising: false)) : .blend(EarPose(), to, EarTiming.phase((p-0.5)*2,rising: true))
        }
        return .blend(from, to, EarTiming.phase(p,rising: (to.weights.values.max() ?? 0) > (from.weights.values.max() ?? 0)))
    }
    func duration(from: EarPose,to: EarPose) -> Double {
        let a = path(from),b = path(to)
        return (a != nil || b != nil) && a != b && !from.isRest && !to.isRest ? 0.76 : 0.38
    }
    func usesPath(from: EarPose,to: EarPose) -> Bool { path(from) != nil || path(to) != nil }
    func resolve(_ pose: EarPose) -> EarPose {
        var result = pose
        for path in paths {
            let phase = min(1, max(0, pose.weights[path.target] ?? 0))
            result.weights[path.target] = 0
            guard phase > 0, let upper = path.keyposes.firstIndex(where: { $0.phase >= phase }) else { continue }
            let a = path.keyposes[max(0, upper-1)], b = path.keyposes[upper]
            let t = (phase-a.phase) / max(0.0001, b.phase-a.phase)
            for key in Set(a.blendShapes.keys).union(b.blendShapes.keys) { result.weights[key] = (a.blendShapes[key] ?? 0)*(1-t) + (b.blendShapes[key] ?? 0)*t }
            // Authored lift/antenna paths own the ear skeleton as well as the mesh.
            for key in ["ear_L_01", "ear_L_02", "ear_R_01", "ear_R_02"] {
                let x = a.jointEulerDegrees[key] ?? [0,0,0], y = b.jointEulerDegrees[key] ?? [0,0,0]
                result.angles[key] = (SIMD3(x[0],x[1],x[2])*(1-t) + SIMD3(y[0],y[1],y[2])*t) * (.pi/180)
            }
        }
        let excess = max(0,(pose.weights.values.max() ?? 0)-1)
        if excess > 0 {
            result.angles["ear_L_01",default: .zero].z -= excess*0.6
            result.angles["ear_R_01",default: .zero].z += excess*0.6
        }
        return result
    }
}

/// The ear leads a slow facial mood blend with a brief, living pop.
/// The steep middle crosses the horizontal region in under 5 samples at 60 Hz.
enum EarTiming {
    static func phase(_ t: Float, rising: Bool) -> Float {
        let t = min(1,max(0,t))
        let knots: [(Float,Float)] = rising ? [(0,0),(0.22,0.08),(0.38,0.24),(0.58,0.84),(0.76,1.08),(1,1)] : [(0,0),(0.22,0.08),(0.38,0.24),(0.58,0.84),(0.82,1),(0.9,0.98),(1,1)]
        for i in 1..<knots.count where t <= knots[i].0 { let a = knots[i-1],b = knots[i]; let p = (t-a.0)/(b.0-a.0); return a.1+(b.1-a.1)*p*p*(3-2*p) }
        return 1
    }
}
