import AppKit
import SwiftUI
import MokuKit

@MainActor
final class MokuManualControlPanel: NSObject, ManualControlPanel, NSWindowDelegate {
    var onClose: (@MainActor () -> Void)?
    let model: ManualControlModel
    private let window: NSWindow
    private var screenObserver: NSObjectProtocol?
    private var closesProgrammatically = false
    init(stage: any CharacterStage, world: WorldModel, presenter: any WorldPresenter, scenes: [ManualScene]) {
        model = ManualControlModel(stage: stage, world: world, presenter: presenter, scenes: scenes)
        window = NSWindow(contentRect: CGRect(x: 160, y: 120, width: 740, height: 850), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Moku · Manual control"; window.level = .floating
        window.isReleasedWhenClosed = false; window.isRestorable = false
        window.contentView = NSHostingView(rootView: ManualControls(model: model)); window.delegate = self
        screenObserver = DisplayRecovery.observe(window)
    }
    func open() { model.startMonitoring(); window.makeKeyAndOrderFront(nil); NSApp.activate() }
    func close() {
        closesProgrammatically = true; model.stopMonitoring(); window.close(); closesProgrammatically = false
    }
    func windowWillClose(_ notification: Notification) {
        model.stopMonitoring()
        if !closesProgrammatically { onClose?() }
    }
    isolated deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; model.stopMonitoring(); window.delegate = nil; window.close() }
}

extension MokuVisualFactory {
    @MainActor public static func makeManualControl(stage: any CharacterStage, world: WorldModel, presenter: any WorldPresenter, scenes: [ManualScene]) -> any ManualControlPanel {
        MokuManualControlPanel(stage: stage, world: world, presenter: presenter, scenes: scenes)
    }
}

extension MokuVisualDiagnostics {
    public static func captureManualControl(stage: any CharacterStage, world: WorldModel, presenter: any WorldPresenter, scenes: [ManualScene], to url: URL) throws {
        let model = ManualControlModel(stage: stage, world: world, presenter: presenter, scenes: scenes)
        model.playback.steps = [ManualStep(action: .move(.center), wait: 0), ManualStep(action: .speech("There you are.", .warm), wait: 0), ManualStep(action: .mood(.happy), wait: 2)]
        let view = NSHostingView(rootView: ManualControls(model: model))
        view.frame = CGRect(x: 0, y: 0, width: 740, height: 1650)
        let panel = NSPanel(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.contentView = nil; panel.close() }
        panel.contentView = view; view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
