import AppKit
import MokuKit

extension MokuVisualDiagnostics {
    /// Whether the welcome's spotlight sits exactly on the menu bar icon, measured without a screenshot and without
    /// putting anything over the screen: a real status item like the app's (a house in a 26-point button) is added for
    /// a moment, the spotlight is built on it as the app builds it but never shown, and its layers are drawn offscreen
    /// to find where the dim's clear hole is. Measures, against the centre of the button's image (and its window): the
    /// hole's centre, the house panel's centre, and the house picture's rect; which way up a radial gradient's unit
    /// space is on a layer-hosting view; and the displays (which has the menu bar, a notch's safe area, the menu bar's
    /// height). spotlight-geometry.json; throws when anything is 1 point or more off.
    public static func spotlightGeometry(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        // The app's icon: a 26-point status item with an 18-point template house (WorldPresenter.updateIcon).
        let item = NSStatusBar.system.statusItem(withLength: 26)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let image = NSImage(size: CGSize(width: 18, height: 18), flipped: false) { rect in
            NSImage(systemSymbolName: "house.fill", accessibilityDescription: nil)?.draw(in: rect); return true
        }
        image.isTemplate = true; item.button?.image = image
        var window = CGRect.zero
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(50))
            if let frame = item.button?.window?.frame, frame.width > 0, NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) { window = frame; break }
        }
        guard window != .zero, let button = item.button, let cell = button.cell, let buttonWindow = button.window else { throw NSError(domain: "Spotlight geometry", code: 1, userInfo: [NSLocalizedDescriptionKey: "the status item never showed"]) }
        let imageRect = buttonWindow.convertToScreen(button.convert(cell.imageRect(forBounds: button.bounds), to: nil))
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: imageRect.midX, y: imageRect.midY)) }) else { throw NSError(domain: "Spotlight geometry", code: 2) }
        // The spotlight as the app builds it (IconSpotlightOverlay on the image's rect), never shown.
        let picture = CGContext(data: nil, width: 72, height: 72, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()
        let overlay = IconSpotlightOverlay(icon: imageRect, screen: screen.frame, house: picture, reduced: false, listens: false, shows: false)
        defer { overlay.end() }
        let measured = overlay.measure
        // Where the hole is: the dim's layers drawn offscreen at one pixel a point; the clear pixels' centre.
        func clearCentre(_ layer: CALayer, size: CGSize) -> (CGPoint, Int)? {
            let w = Int(size.width), h = Int(size.height)
            guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else { return nil }
            layer.render(in: context)
            let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
            var sx = 0.0, n = 0, opaque = 0
            var widths = [Int](repeating: 0, count: h)
            for y in 0..<h { for x in 0..<w {
                let alpha = pixels[(y * w + x) * 4 + 3]
                if alpha < 8 { sx += Double(x) + 0.5; n += 1; widths[y] += 1 } else if alpha > 100 { opaque += 1 }
            } }
            guard n > 0, opaque > 0 else { return nil }  // nothing clear, or nothing drawn: not a hole
            // Across, the clear pixels' centre. Up and down, the widest row: the hole round a menu bar icon runs past the
            // screen's top, and the clear pixels left below the edge have their centre lower than the hole's (6.8 points
            // for an icon 16.5 points down); the widest row is the centre's while the centre is on the screen.
            let widest = widths.max() ?? 0
            let rows = widths.indices.filter { widths[$0] >= widest - 1 }
            let middle = Double(rows.reduce(0, +)) / Double(rows.count) + 0.5
            // The bitmap's rows run from the top in memory; CoreGraphics draws with y up, so row 0 in memory is the top.
            return (CGPoint(x: sx / Double(n), y: Double(h) - middle), n)
        }
        var holeSource = "the dim with its mask"
        var hole = clearCentre(measured.dim, size: measured.dimPanel.size)
        if hole == nil, let mask = measured.dim.sublayers?.first?.mask {  // a renderer that ignores masks: the mask alone
            holeSource = "the mask alone"
            hole = clearCentre(mask, size: measured.dimPanel.size)
        }
        guard let (holePoint, holePixels) = hole else { throw NSError(domain: "Spotlight geometry", code: 3, userInfo: [NSLocalizedDescriptionKey: "no hole drawn"]) }
        let holeOnScreen = CGPoint(x: measured.dimPanel.minX + holePoint.x, y: measured.dimPanel.minY + holePoint.y)
        // Which way up a radial gradient's unit space is on a layer-hosting view: a gradient started at (0.25, 0.8).
        let probeView = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300)); probeView.layer = CALayer(); probeView.wantsLayer = true
        let probe = CAGradientLayer(); probe.type = .radial; probe.frame = probeView.bounds
        probe.startPoint = CGPoint(x: 0.25, y: 0.8); probe.endPoint = CGPoint(x: 0.25 + 40.0 / 400, y: 0.8 + 40.0 / 300)
        probe.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.black.cgColor]; probe.locations = [0, 0.5, 1]
        probeView.layer?.addSublayer(probe)
        let probeCentre = clearCentre(probeView.layer!, size: probeView.bounds.size)?.0 ?? .zero
        let yUp = abs(probeCentre.y - 0.8 * 300) < abs(probeCentre.y - 0.2 * 300)

        let centre = CGPoint(x: imageRect.midX, y: imageRect.midY)
        func off(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) }
        let houseCentre = CGPoint(x: measured.house.midX, y: measured.house.midY)
        let panelCentre = CGPoint(x: measured.housePanel.midX, y: measured.housePanel.midY)
        let report: [String: Any] = [
            "statusItemWindow": [window.minX, window.minY, window.width, window.height],
            "buttonImageRect": [imageRect.minX, imageRect.minY, imageRect.width, imageRect.height],
            "imageCentreFromWindowCentre": off(centre, CGPoint(x: window.midX, y: window.midY)),
            "holeCentre": [holeOnScreen.x, holeOnScreen.y], "holeOffPoints": off(holeOnScreen, centre), "holeClearPixels": holePixels, "holeMeasuredFrom": holeSource,
            "housePanelOffPoints": off(panelCentre, centre), "housePictureOffPoints": off(houseCentre, centre),
            "housePictureSize": [measured.house.width, measured.house.height], "housePictureSizeOffPoints": Double(abs(measured.house.width - imageRect.width) + abs(measured.house.height - imageRect.height)),
            "dimCoversTheIconsDisplay": measured.dimPanel == screen.frame,
            "gradientUnitSpace": yUp ? "y up (0 at the bottom)" : "flipped (0 at the top)", "gradientProbeCentre": [probeCentre.x, probeCentre.y],
            "displays": NSScreen.screens.map { s -> [String: Any] in
                ["frame": [s.frame.minX, s.frame.minY, s.frame.width, s.frame.height], "hasTheIcon": s == screen, "notchSafeAreaTop": s.safeAreaInsets.top,
                 "menuBarHeight": s.frame.maxY - s.visibleFrame.maxY, "scale": s.backingScaleFactor, "name": s.localizedName]
            },
            "nothingShown": measured.dimPanel != .zero && !overlay.windows.contains { $0.isVisible },
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("spotlight-geometry.json"))
        let worst = [off(holeOnScreen, centre), off(panelCentre, centre), off(houseCentre, centre), Double(abs(measured.house.width - imageRect.width) + abs(measured.house.height - imageRect.height))].max() ?? 0
        guard worst < 1, yUp, measured.dimPanel == screen.frame, !overlay.windows.contains(where: { $0.isVisible }) else {
            throw NSError(domain: "Spotlight geometry", code: 4, userInfo: [NSLocalizedDescriptionKey: "\(report)"])
        }
    }
}
