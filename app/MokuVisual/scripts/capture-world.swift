import AppKit
import MokuKit
import MokuVisual

@main struct CaptureWorld {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        try MokuVisualDiagnostics.captureWorld(model: WorldModel(), to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
