import AppKit
import MokuKit

/// "What's new" in each companion's bubble (docs/specs/next-0-1-9.md §1). Moku says it on its paper, "I updated! See what’s
/// new", the last words set as a link with a stitched underline that turns solid under the pointer. Tetsu puts it on its
/// display the way it talks, "> updated: see what’s new", with a row of dim dots under the link that light under the
/// pointer. A click anywhere on the bubble opens the changelog; the ✕ in the corner (in Tetsu's dots, where its status
/// light was) closes it. Either way the bubble goes, and so it does after its time.
enum WhatsNewLook {
    /// The words that are the link.
    static let link = "See what’s new"
    /// Tetsu's display: the prompt, what happened, and the link.
    static let ledText = "> updated: see what’s new"
    /// Where the link starts among the display's glyphs (one a character: the words are spelt in dots, a space each).
    static var ledLinkFirstGlyph: Int { ledText.distance(from: ledText.startIndex, to: ledText.range(of: "see what’s new")?.lowerBound ?? ledText.startIndex) }
    /// The ✕ takes clicks this far beyond its drawing.
    static let closeReach: CGFloat = 4

    // MARK: Moku's paper

    /// The link's ink: the line's accent, deepened on light paper and lifted on dark, like "Take me there".
    static func paperLinkInk(accent: NSColor, dark: Bool) -> NSColor {
        dark ? accent.blended(withFraction: 0.25, of: .white) ?? accent : accent.blended(withFraction: 0.3, of: .black) ?? accent
    }

    /// The link's underline, a picture the size of the whole view (`size`): the paper's own text laid out again in `textRect`
    /// with every glyph clear and only the link's underline inked, so it sits exactly under the words. Stitched at rest,
    /// solid under the pointer.
    @MainActor static func paperUnderline(_ body: NSAttributedString, link: NSRange, in textRect: CGRect, size: CGSize, ink: NSColor,
                                          scale: CGFloat) -> BubbleButton {
        let contrast = ContrastPreference.increased
        func image(hovered: Bool) -> CGImage? {
            let marked = NSMutableAttributedString(attributedString: body)
            marked.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: 0, length: marked.length))
            let style: NSUnderlineStyle = hovered ? .single : [.single, .patternDot]
            marked.addAttributes([.underlineStyle: style.rawValue, .underlineColor: ink.withAlphaComponent(hovered || contrast ? 0.95 : 0.6)], range: link)
            return SpeechBubbleView.image(size: size, scale: scale) { _ in
                marked.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
            }
        }
        return BubbleButton(size: size, resting: image(hovered: false), hovered: image(hovered: true))
    }

    /// Moku's ✕: two soft strokes in the paper's ink, on a round patch of the accent under the pointer.
    @MainActor static func paperClose(accent: NSColor, dark: Bool, scale: CGFloat) -> BubbleButton {
        let size = CGSize(width: 18, height: 18)
        let contrast = ContrastPreference.increased
        func draw(hovered: Bool) -> CGImage? {
            SpeechBubbleView.image(size: size, scale: scale) { rect in
                if hovered {
                    accent.withAlphaComponent(dark ? 0.30 : 0.18).setFill()
                    NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
                }
                let inset: CGFloat = 5.75, cross = NSBezierPath()
                cross.move(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset)); cross.line(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
                cross.move(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset)); cross.line(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset))
                cross.lineWidth = 1.5; cross.lineCapStyle = .round
                SpeechInk.paperText(dark: dark).withAlphaComponent(contrast ? 0.95 : hovered ? 0.85 : 0.5).setStroke(); cross.stroke()
            }
        }
        return BubbleButton(size: size, resting: draw(hovered: false), hovered: draw(hovered: true))
    }

    // MARK: Tetsu's display

    /// The dots under the link, in the text's grid: one row under the words' baseline, every other dot at rest (dim), every
    /// dot lit under the pointer.
    @MainActor static func ledUnderline(_ text: DotText, linkFrom first: Int, columns: Int, color: NSColor, scale: CGFloat) -> BubbleButton? {
        let link = text.glyphs.dropFirst(first).filter { !$0.isSpace }
        guard let start = link.first, let end = link.last, start.line == end.line else { return nil }
        let row = start.line * DotFont.lineRows + 8 - DotFont.topRow
        let span = start.x..<(end.x + end.glyph.width)
        let margin = DotPainter.glowMargin, contrast = ContrastPreference.increased
        let rows = text.rows
        let resting = DotPainter.image(span.filter { ($0 - start.x).isMultiple(of: 2) }.map { DotFont.Dot(x: $0, y: row) }, columns: columns, rows: rows,
                                       pitch: 2, color: color.withAlphaComponent(contrast ? 0.9 : 0.45), glow: 0, margin: margin, scale: scale)
        let lit = DotPainter.image(span.map { DotFont.Dot(x: $0, y: row) }, columns: columns, rows: rows, pitch: 2, color: color, glow: 0.9, margin: margin, scale: scale)
        return BubbleButton(size: .zero, resting: resting, hovered: lit)
    }

    /// Tetsu's ✕: five dots each way, dim like its name at rest and lit with a glow under the pointer.
    @MainActor static func ledClose(color: NSColor, scale: CGFloat) -> BubbleButton {
        let size = CGSize(width: 15, height: 15), margin = DotPainter.glowMargin
        let cross = (0..<5).flatMap { [DotFont.Dot(x: $0, y: $0), DotFont.Dot(x: 4 - $0, y: $0)] }.reduce(into: [DotFont.Dot]()) { if !$0.contains($1) { $0.append($1) } }
        let contrast = ContrastPreference.increased
        func draw(hovered: Bool) -> CGImage? {
            let dots = DotPainter.image(cross, columns: 5, rows: 5, pitch: 1, color: color.withAlphaComponent(hovered || contrast ? 1 : 0.6),
                                        glow: hovered ? 0.9 : 0, margin: margin, scale: scale)
            return SpeechBubbleView.image(size: size, scale: scale) { rect in
                guard let dots, let context = NSGraphicsContext.current?.cgContext else { return }
                context.draw(dots, in: CGRect(x: rect.midX - 2.5 - margin, y: rect.midY - 2.5 - margin, width: 5 + 2 * margin, height: 5 + 2 * margin))
            }
        }
        return BubbleButton(size: size, resting: draw(hovered: false), hovered: draw(hovered: true))
    }
}

// MARK: The stage: one answer per bubble

extension MokuCharacterStage {
    /// The "What's new" bubble up now is over: clicked (`opened`) or not (its ✕, its time, another line, or hiding). The app
    /// hears once per bubble.
    func answerWhatsNew(opened: Bool) {
        guard let version = whatsNewUp else { return }
        whatsNewUp = nil
        onWhatsNew?(version, opened)
    }
}
