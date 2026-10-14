import AppKit
import SwiftUI
import MokuKit

extension MokuVisualDiagnostics {
    /// Both companions' bubbles in every tone (gentle, warm, cheerful, the ask, cross) and thinking, with long, emoji,
    /// accented, right-to-left and CJK lines, at 1× and 2×, light and dark (speech-<1x|2x>-<light|dark>.png); Tetsu's
    /// typing on, step by step (speech-typing.png); the thread labels (speech-labels-<light|dark>.png); and how long
    /// each bubble takes to make (speech-look.json). Nothing here touches the stage or any setting.
    public static func speechLook(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines: [(String, SpeechLine.Tone, String)] = [
            ("Welcome back! Let's do it.", .warm, "warm"),
            ("That's your 20-minute break. Ready when you are.", .gentle, "gentle"),
            ("Nice! 47 minutes on the settings window.", .cheerful, "cheerful"),
            ("Charles, can we focus? I want my rocket built.", .calling, "ask"),
            ("Still here. Still waiting.", .firm, "cross"),
            ("Élodie, ça va? Un verre d'eau 💧 et on repart 🚀", .warm, "accents, emoji"),
            ("مرحبا! لنعد إلى العمل معًا الآن.", .warm, "right to left"),
            ("你好，我们继续工作吧！", .warm, "CJK"),
            ("A long one: you've been on that tab for a while now, and the house is still waiting for its roof, its chimney, its porch lamp and the little garden out front, so shall we?", .gentle, "long"),
        ]
        var timings: [[String: Any]] = []
        for scale in [1, 2] as [CGFloat] {
            for dark in [false, true] {
                var cells: [(String, CGImage)] = []
                for (style, name) in [(SpeechStyle.paper, "Moku"), (.led, "Tetsu")] {
                    for (text, tone, label) in lines {
                        let started = CACurrentMediaTime()
                        let bubble = SpeechBubbleView(content: .line(SpeechLine(text: text, tone: tone)), style: style, name: name, dark: dark, scale: scale, reduced: false)
                        let made = (CACurrentMediaTime() - started) * 1000
                        if let image = bubble.snapshot(scale: scale) { cells.append(("\(name) · \(label)", image)) }
                        if scale == 2 && !dark { timings.append(["companion": name, "line": label, "ms": made, "size": [bubble.frame.width, bubble.frame.height]]) }
                    }
                    let thinking = SpeechBubbleView(content: .thinking, style: style, name: name, dark: dark, scale: scale, reduced: false)
                    if let image = thinking.snapshot(scale: scale) { cells.append(("\(name) · thinking", image)) }
                }
                try sheet(cells, columns: 5, scale: scale, dark: dark, to: directory.appendingPathComponent("speech-\(Int(scale))x-\(dark ? "dark" : "light").png"))
            }
        }
        // Typing on: the ask at a few steps, then done (">" and the cursor).
        let ask = SpeechBubbleView(content: .line(SpeechLine(text: "Charles, can we focus? I want my rocket built.", tone: .calling)), style: .led, name: "Tetsu", dark: false, scale: 2, reduced: false)
        let warm = SpeechBubbleView(content: .line(SpeechLine(text: "Welcome back! Let's do it.", tone: .warm)), style: .led, name: "Tetsu", dark: true, scale: 2, reduced: false)
        var frames: [(String, CGImage)] = []
        for typed in [0, 1, 8, 16, 24, 32, 40, 49] { if let image = ask.snapshot(scale: 2, typed: typed) { frames.append(("ask, \(typed) typed", image)) } }
        for typed in [3, 10, 18, 26] { if let image = warm.snapshot(scale: 2, typed: typed) { frames.append(("warm, \(typed) typed", image)) } }
        try sheet(frames, columns: 4, scale: 2, dark: false, to: directory.appendingPathComponent("speech-typing.png"))
        // The labels over the head, both companions, light and dark.
        for dark in [false, true] {
            var labels: [(String, CGImage)] = []
            for title in ["practicing system design", "Moku · Settings: breaks and water", "Ünïcødé façade 🚀", "مراجعة التقرير", "整理笔记"] {
                if let strip = LEDLabelView(title: title, dark: dark, scale: 2).snapshot(scale: 2) { labels.append(("Tetsu · \(title)", strip)) }
                // In a clear panel like the app's label panel (a plain window's background shows at the edges).
                let paper = NSHostingView(rootView: PaperLabel(title: title, dark: dark))
                let panel = OverlayPanel(size: CGSize(width: min(260, max(100, paper.fittingSize.width)), height: 38))
                panel.contentView = paper
                labels.append(("Moku · \(title)", try ReviewCapture.view(paper)))
            }
            try sheet(labels, columns: 2, scale: 2, dark: dark, to: directory.appendingPathComponent("speech-labels-\(dark ? "dark" : "light").png"))
        }
        try JSONSerialization.data(withJSONObject: ["bubbles": timings], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("speech-look.json"))
    }

    /// "What's new" after an update in both companions' bubbles (docs/specs/next-0-1-9.md §1): at rest, the link under the
    /// pointer and the ✕ under the pointer, at 1× and 2×, light and dark (whats-new-<1x|2x>-<light|dark>.png), and Tetsu typing
    /// it on (whats-new-typing.png). Every bubble is drawn straight to a picture: no window, no stage, no setting.
    public static func whatsNewLook(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let line = SpeechLine(text: "I updated! See what’s new", tone: .cheerful, duration: 15, whatsNew: "0.1.9")
        for scale in [1, 2] as [CGFloat] {
            for dark in [false, true] {
                var cells: [(String, CGImage)] = []
                for (style, name) in [(SpeechStyle.paper, "Moku"), (.led, "Tetsu")] {
                    for state in ["at rest", "link under the pointer", "✕ under the pointer"] {
                        let bubble = SpeechBubbleView(content: .line(line), style: style, name: name, dark: dark, scale: scale, reduced: false)
                        if state == "link under the pointer" { bubble.light(true) }
                        if state == "✕ under the pointer" { bubble.lightClose(true) }
                        if let image = bubble.snapshot(scale: scale) { cells.append(("\(name) · \(state)", image)) }
                    }
                }
                try sheet(cells, columns: 3, scale: scale, dark: dark, to: directory.appendingPathComponent("whats-new-\(Int(scale))x-\(dark ? "dark" : "light").png"))
            }
        }
        var frames: [(String, CGImage)] = []
        for dark in [false, true] {
            let tetsu = SpeechBubbleView(content: .line(line), style: .led, name: "Tetsu", dark: dark, scale: 2, reduced: false)
            for typed in [3, 11, 18, 25] { if let image = tetsu.snapshot(scale: 2, typed: typed) { frames.append(("\(dark ? "dark" : "light"), \(typed) typed", image)) } }
        }
        try sheet(frames, columns: 4, scale: 2, dark: true, to: directory.appendingPathComponent("whats-new-typing.png"))
    }

    /// Pictures in a grid on a desktop-ish background, each with its caption above it.
    private static func sheet(_ cells: [(String, CGImage)], columns: Int, scale: CGFloat, dark: Bool, to url: URL) throws {
        guard !cells.isEmpty else { return }
        let pad = 14 * scale, caption = 16 * scale
        let cellWidth = cells.map { CGFloat($0.1.width) }.max()! + pad, cellHeight = cells.map { CGFloat($0.1.height) }.max()! + pad + caption
        let rows = (cells.count + columns - 1) / columns
        let width = Int(cellWidth * CGFloat(min(columns, cells.count)) + pad), height = Int(cellHeight * CGFloat(rows) + pad)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(dark ? CGColor(srgbRed: 0.13, green: 0.14, blue: 0.15, alpha: 1) : CGColor(srgbRed: 0.86, green: 0.87, blue: 0.84, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (index, (label, image)) in cells.enumerated() {
            let x = pad + CGFloat(index % columns) * cellWidth, top = CGFloat(height) - pad - CGFloat(index / columns) * cellHeight
            NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 10 * scale), .foregroundColor: dark ? NSColor(white: 0.6, alpha: 1) : NSColor(white: 0.4, alpha: 1)])
                .draw(at: CGPoint(x: x, y: top - 13 * scale))
            context.draw(image, in: CGRect(x: x, y: top - caption - CGFloat(image.height), width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        NSGraphicsContext.current = previous
        guard let image = context.makeImage() else { return }
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
}
