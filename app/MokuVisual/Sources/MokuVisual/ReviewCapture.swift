import AppKit
import AVFoundation
import SwiftUI
import MokuKit

@MainActor enum ReviewCapture {
    static func view(_ view: NSView) throws -> CGImage {
        // Bubbles and labels are drawn in layers, which `cacheDisplay` misses.
        if let drawn = view as? LayerSnapshot, let image = drawn.snapshot(scale: 2) { return image }
        var temporary: NSPanel?
        if view.window == nil {
            let panel = NSPanel(contentRect: view.frame,styleMask: .borderless,backing: .buffered,defer: false)
            panel.isReleasedWhenClosed = false; panel.contentView = view; temporary = panel
        }
        defer { temporary?.contentView = nil; temporary?.close() }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw CocoaError(.fileWriteUnknown) }
        return image
    }
    /// The desktop as the person would see it: a plain backdrop with a menu bar, the companion, and its speech.
    static func desktop(stage: MokuCharacterStage) throws -> CGImage {
        let screen = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let width = Int(screen.width / 2) * 2, height = Int(screen.height / 2) * 2
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor(calibratedRed: 0.90, green: 0.91, blue: 0.88, alpha: 1).cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: -screen.minX, y: -screen.minY)
        context.setFillColor(NSColor(calibratedWhite: 0.97, alpha: 1).cgColor); context.fill(CGRect(x: screen.minX, y: screen.maxY - 24, width: screen.width, height: 24))
        context.draw(try MokuVisualDiagnostics.stageImage(stage: stage), in: stage.panel.frame)
        if stage.speechTask != nil, let content = stage.speechPanel.contentView { context.draw(try view(content), in: stage.speechPanel.frame) }
        return context.makeImage()!
    }
}
