import AppKit
import SwiftUI
import MokuKit

extension MokuCharacterStage {
    public func showThreadLabel(_ title: String) {
        labelTask?.cancel(); lastCaption = title
        // One already up fades out (0.12 s) before the next fades in. It used to vanish at once under the new one.
        if captionShowing, labelPanel.alphaValue > 0.05, !hidden {
            labelTask = Task { [weak self] in
                guard let self else { return }
                await NSAnimationContext.runAnimationGroup { context in context.duration = 0.12; labelPanel.animator().alphaValue = 0 }
                guard !Task.isCancelled else { return }
                presentThreadLabel(title)
            }
            return
        }
        presentThreadLabel(title)
    }
    /// While the pointer rests on the companion: the task and its minutes today ("building Moku · 1h 24m"), up until the
    /// pointer leaves. Nothing when there's no named task.
    func showHoverTask() {
        guard let task = currentTask?(), !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = task.minutesToday > 0 ? "\(task.title) · \(minutesText(task.minutesToday))" : task.title
        labelTask?.cancel(); lastCaption = text
        presentThreadLabel(text, staysUp: true)
    }
    private func presentThreadLabel(_ title: String, staysUp: Bool = false) {
        hideCaption()
        guard !hidden, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        captionShowing = true
        // In the companion's own voice: a leaf on soft paper for Moku, a line on a little LED strip for Tetsu.
        let content: NSView, width: CGFloat
        switch SpeechStyle(companion ?? .current) {
        case .led:
            let strip = LEDLabelView(title: title, dark: appearsDark, scale: backingScale)
            content = strip; width = strip.frame.width
        case .paper:
            let paper = NSHostingView(rootView: PaperLabel(title: title, dark: appearsDark))
            content = paper; width = min(260, max(100, paper.fittingSize.width))
        }
        labelPanel.setContentSize(CGSize(width: width, height: 38))
        labelPanel.contentView = content; labelPanel.ignoresMouseEvents = true
        labelPanel.alphaValue = 0; positionLabel(); if !rendersOffscreen { labelPanel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.25; labelPanel.animator().alphaValue = 1 }
        guard !staysUp else { return }
        labelTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3.2)) } catch { return }
            guard let self else { return }
            await NSAnimationContext.runAnimationGroup { context in context.duration = 0.35; labelPanel.animator().alphaValue = 0 }
            do { try await Task.sleep(for: .seconds(0.4)) } catch { return }
            hideCaption()
        }
    }
    func hideCaption() { labelPanel.orderOut(nil); captionShowing = false }
    /// Takes the label down with a short fade (a grab used to take it away at once).
    func fadeCaption() {
        labelTask?.cancel()
        guard captionShowing, labelPanel.alphaValue > 0.05 else { hideCaption(); return }
        labelTask = Task { [weak self] in
            guard let self else { return }
            await NSAnimationContext.runAnimationGroup { context in context.duration = 0.15; labelPanel.animator().alphaValue = 0 }
            guard !Task.isCancelled else { return }
            hideCaption()
        }
    }
    func positionLabel() {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: panel.frame.midX, y: panel.frame.midY)) } ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? panel.frame
        labelPanel.setFrameOrigin(StageGeometry.captionOrigin(panel: panel.frame, caption: labelPanel.frame.size, visible: visible, gap: MokuPreferences.captionGap(in: homeStore)))
        if speechTask != nil { positionSpeech() }  // a bubble showing moves up above the caption
    }
    /// Shows the caption where it now sits, so a placement change in Settings can be seen.
    func previewCaption() { showThreadLabel(lastCaption ?? "What you’re working on") }
    /// Shows a bubble where Moku's lines now sit, so a placement change in Settings can be seen.
    func previewSpeech() { say(SpeechLine(text: "This is where I talk to you.", tone: .gentle, duration: 3)) }
}

/// Moku's label: what you're working on, by a leaf, on a little pill of the same paper as its bubble.
struct PaperLabel: View {
    let title: String
    let dark: Bool
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "leaf.fill").font(.system(size: 11)).foregroundStyle(Color(nsColor: SpeechInk.paper(.cheerful, dark: dark)))
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 13).padding(.vertical, 8).foregroundStyle(Color(nsColor: SpeechInk.paperText(dark: dark)))
        .background(Capsule().fill(Color(nsColor: SpeechInk.paperFill(dark: dark))))
        .overlay(Capsule().strokeBorder(Color(nsColor: SpeechInk.sage).opacity(ContrastPreference.increased ? 0.9 : dark ? 0.4 : 0.35), lineWidth: ContrastPreference.increased ? 1.5 : 1))
        .padding(3)
    }
}

/// Tetsu's label: a ">" and what you're working on, lit in dots on a strip of its display glass, in its white shell.
/// Drawn once; one line, ending in "…" if it's long.
@MainActor final class LEDLabelView: NSView, LayerSnapshot {
    private let picture: CGImage?
    private let scale: CGFloat
    static let maxWidth: CGFloat = 300

    init(title: String, dark: Bool, scale: CGFloat) {
        self.scale = scale
        let (size, image) = Self.draw(title: title, dark: dark, scale: scale)
        picture = image
        super.init(frame: CGRect(origin: .zero, size: size))
        layer = CALayer(); wantsLayer = true
        layer?.contents = image; layer?.contentsScale = scale; layer?.contentsGravity = .resize; layer?.magnificationFilter = .nearest
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { nil }
    func snapshot(scale: CGFloat) -> CGImage? { picture }

    private static func draw(title: String, dark: Bool, scale: CGFloat) -> (CGSize, CGImage?) {
        let pitch: CGFloat = 2, margin = DotPainter.glowMargin, color = SpeechInk.cyan
        let height: CGFloat = 38, card = CGRect(x: 3, y: 4, width: 0, height: 30)
        let shell: CGFloat = 3, padding: CGFloat = 9
        // The prompt dim, then the title; text the dots can't spell is set in type.
        var dots: [DotFont.Dot] = [], width: CGFloat = 0, typeset: NSAttributedString?
        let prompt = DotFont.glyph(">")
        if DotFont.spells(title) {
            let room = Int((maxWidth - 2 * (card.minX + shell + padding)) / pitch) - (prompt?.width ?? 0) - 4
            let text = DotText(title, width: room, maxLines: 1)
            let shift = (prompt?.width ?? 0) + 4
            dots = (prompt?.dots ?? []).map { DotFont.Dot(x: $0.x, y: $0.y - DotFont.topRow, level: 0.5) }
                + text.dots.map { DotFont.Dot(x: $0.x + shift, y: $0.y, level: $0.level) }
            width = CGFloat(text.width + shift) * pitch
        } else {
            typeset = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: color])
            width = min(maxWidth - 2 * (card.minX + shell + padding), ceil(typeset?.size().width ?? 0))
        }
        // Only the rows in use, centred on the strip (a title with no accents or descenders sits a little higher).
        let top = dots.map(\.y).min() ?? 0, bottom = dots.map(\.y).max() ?? 0
        let rows = bottom - top + 1
        let cardWidth = width + 2 * (shell + padding)
        let size = CGSize(width: cardWidth + 2 * card.minX, height: height)
        let glyphs = dots.map { DotFont.Dot(x: $0.x, y: $0.y - top, level: $0.level) }
        let lit = typeset == nil ? DotPainter.image(glyphs, columns: Int(width / pitch), rows: rows, pitch: pitch, color: color, glow: 1, margin: margin, scale: scale) : nil
        let image = SpeechBubbleView.image(size: size, scale: scale) { _ in
            let strip = CGRect(x: card.minX, y: card.minY, width: cardWidth, height: card.height)
            let shellShape = NSBezierPath(roundedRect: strip, xRadius: strip.height / 2, yRadius: strip.height / 2)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.45 : 0.2); shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1); shadow.set()
            (dark ? NSColor(srgbRed: 0.22, green: 0.23, blue: 0.25, alpha: 1) : NSColor(srgbRed: 0.93, green: 0.93, blue: 0.915, alpha: 1)).setFill(); shellShape.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(dark ? 0.5 : 0.16).setStroke(); shellShape.lineWidth = 0.75; shellShape.stroke()
            let glass = strip.insetBy(dx: shell, dy: shell)
            let glassShape = NSBezierPath(roundedRect: glass, xRadius: glass.height / 2, yRadius: glass.height / 2)
            NSGradient(colors: [NSColor(srgbRed: 0.035, green: 0.05, blue: 0.065, alpha: 1), NSColor(srgbRed: 0.008, green: 0.012, blue: 0.018, alpha: 1)])?.draw(in: glassShape, angle: -90)
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let textHeight = typeset == nil ? CGFloat(rows) * pitch : ceil(typeset?.size().height ?? 0)
            let origin = CGPoint(x: glass.minX + padding, y: (glass.midY - textHeight / 2).rounded())
            if let lit {
                context.draw(lit, in: CGRect(x: origin.x - margin, y: origin.y - margin, width: width + 2 * margin, height: textHeight + 2 * margin))
            } else if let typeset {
                context.setShadow(offset: .zero, blur: 2.5 * scale, color: color.withAlphaComponent(0.85).cgColor)
                typeset.draw(with: CGRect(x: origin.x, y: origin.y, width: width, height: textHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
        return (size, image)
    }
}
