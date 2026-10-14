import AppKit
import MokuKit

extension MokuVisualDiagnostics {
    public static func auditTransitions(stage: MokuCharacterStage, directory: URL) async throws {
        stage.setHidden(true)
        while stage.view.real == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let renderer = stage.view.real else { throw CocoaError(.fileReadUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var rows = [[String: Any]]()
        let moods = CommandLine.arguments.contains("--blink-only") ? [] : Mood.allCases
        for from in moods { for to in moods where from != to {
            var images = [CGImage](), spans = [[[Float]]]()
            for frame in 0...180 {
                let (image, ears) = try await renderer.auditTransition(from: from, to: to, progress: Double(frame) / 180)
                images.append(image); spans.append(ears)
            }
            let key = from.rawValue + "-" + to.rawValue
            let movie = try ReviewMovie(url: directory.appendingPathComponent(key + ".mp4"), width: 640, height: 640, fps: 60)
            var failures = [[String: Any]](), horizontalRun = 0, longestHorizontalRun = 0
            for index in images.indices {
                let ears = spans[index]
                // Relative to the shorter endpoint: an in-between may curve, but
                // cannot lose most of its vertical reach or become a flat wing.
                let horizontal = ears.indices.contains { ear in
                    let minimumHeight = min(spans.first![ear][1],spans.last![ear][1])
                    return ears[ear][1] < minimumHeight*0.70 || ears[ear][1] < ears[ear][0]*0.35
                }
                horizontalRun = horizontal ? horizontalRun+1 : 0; longestHorizontalRun = max(longestHorizontalRun,horizontalRun)
                let intact = ears.indices.allSatisfy { ear in
                    func reach(_ values: [Float]) -> Float { sqrt(values.reduce(0) { $0+$1*$1 }) }
                    return reach(ears[ear]) >= 0.65*min(reach(spans.first![ear]),reach(spans.last![ear]))
                }
                let silhouette = SilhouetteResult.analyze(images[index])
                if !intact || !silhouette.passes || horizontalRun > 5 || ((index == 0 || index == images.count-1) && horizontal) { failures.append(["frame": index,"ears": ears,"earShape": intact,"horizontalRun": horizontalRun,"silhouette": silhouette.passes]) }
                try await movie.append(images[index])
            }
            try await movie.finish()
            rows.append(["from": from.rawValue, "to": to.rawValue, "frames": images.count, "pass": failures.isEmpty, "fps": 60, "longestHorizontalRun": longestHorizontalRun, "failures": failures])
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("transitions.json"))
        } }
        let (closed,thickness) = try await renderer.auditBlink()
        try NSBitmapImageRep(cgImage: closed).representation(using: .png,properties: [:])!.write(to: directory.appendingPathComponent("blink-closed.png"))
        let blinkPass = thickness.allSatisfy { $0.isFinite && $0 <= 0.28 }
        try JSONSerialization.data(withJSONObject: ["closedToOpenIrisHeight":thickness.map { $0.isFinite ? Double($0) : -1 },"pass":blinkPass],options: .prettyPrinted).write(to: directory.appendingPathComponent("blink.json"))
        renderer.stop()
        guard blinkPass else { throw CocoaError(.validationMissingMandatoryProperty) }
        guard rows.allSatisfy({ $0["pass"] as? Bool == true }) else { throw CocoaError(.validationMissingMandatoryProperty) }
    }
}
