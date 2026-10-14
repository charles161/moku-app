import SwiftUI

/// Quiet text on Moku's paper (the welcome, the popover, Your day). SwiftUI's `.secondary` over the paper measured 2.5:1
/// (launch QA, lens 1): the welcome's privacy lines and the popover's captions were hard to read, and Increase Contrast
/// changed nothing. Quiet text is the ink at a strength that reads: at least 4.5:1 normally (WCAG AA for small text), and
/// 7:1 when the person has turned Increase Contrast on. The dimmed level is for what is meant to recede (the story's
/// captions that aren't the current one): at least 3:1, and 4.5:1 with Increase Contrast.
enum Quiet {
    enum Level { case secondary, dimmed }
    /// The ink's opacity for a level.
    static func opacity(_ level: Level, increased: Bool = false) -> Double {
        switch (level, increased) {
        case (.secondary, false): 0.76
        case (.secondary, true): 0.94
        case (.dimmed, false): 0.6
        case (.dimmed, true): 0.78
        }
    }
    /// The contrast ratio of quiet text over the paper (WCAG 2): for tests and the demo's report.
    static func contrast(_ level: Level, increased: Bool = false) -> Double {
        func channel(_ value: Double) -> Double { value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        func luminance(_ rgb: (Double, Double, Double)) -> Double { 0.2126 * channel(rgb.0) + 0.7152 * channel(rgb.1) + 0.0722 * channel(rgb.2) }
        let ink = (0.23, 0.29, 0.23), paper = (0.975, 0.963, 0.934), a = opacity(level, increased: increased)
        let text = (ink.0 * a + paper.0 * (1 - a), ink.1 * a + paper.1 * (1 - a), ink.2 * a + paper.2 * (1 - a))
        let (light, dark) = (max(luminance(text), luminance(paper)), min(luminance(text), luminance(paper)))
        return (light + 0.05) / (dark + 0.05)
    }
}

private struct QuietText: ViewModifier {
    let level: Quiet.Level
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.foregroundStyle(ink.opacity(Quiet.opacity(level, increased: contrast == .increased)))
    }
}

private struct QuietUnless: ViewModifier {
    let level: Quiet.Level
    let active: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.foregroundStyle(active ? ink : ink.opacity(Quiet.opacity(level, increased: contrast == .increased)))
    }
}

extension View {
    /// Text that recedes, but still reads on the paper (see `Quiet`).
    func quiet(_ level: Quiet.Level = .secondary) -> some View { modifier(QuietText(level: level)) }
    /// Quiet unless `active`: then it's the full ink (the current caption, the stage the house has reached).
    func quiet(_ level: Quiet.Level, unless active: Bool) -> some View { modifier(QuietUnless(level: level, active: active)) }
}
