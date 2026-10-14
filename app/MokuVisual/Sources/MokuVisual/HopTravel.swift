import Foundation

struct HopTravel: Decodable {
    let duration: Double
    let strideLength: Double
    let travelPhase: [Double]
    static func load(companion: Companion = .current) -> Self {
        struct Manifest: Decodable { struct Clip: Decodable { let name: String; let duration: Double; let strideLength: Double?; let travelPhase: [Double]? }; let clips: [Clip] }
        if let url = MokuAssets.file("character/animations.json", companion: companion),let data = try? Data(contentsOf: url),let manifest = try? JSONDecoder().decode(Manifest.self,from: data),let clip = manifest.clips.first(where: { $0.name == "hop_cycle" }),let stride = clip.strideLength,let phase = clip.travelPhase,phase.count == 2 { return Self(duration: clip.duration,strideLength: stride,travelPhase: phase) }
        return Self(duration: 13/24,strideLength: 0.26,travelPhase: [0.29,0.72])
    }
    func flight(_ phase: Double) -> Double { let p = min(1,max(0,(phase-travelPhase[0])/(travelPhase[1]-travelPhase[0]))); return p*p*(3-2*p) }
    func position(elapsed: Double,distance: Double,stridePoints: Double) -> Double {
        let cycle = max(0,elapsed)/duration, completed = floor(cycle)
        let remaining = max(0,distance-completed*stridePoints)
        return min(distance,completed*stridePoints+min(stridePoints,remaining)*flight(cycle-completed))
    }
    func travelDuration(distance: Double,stridePoints: Double) -> Double { ceil(distance/max(1,stridePoints))*duration }
}
