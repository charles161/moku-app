import AppKit
import SwiftUI
import MokuKit

/// The welcome window's two pages (Onboarding.swift). Moku's is paper; Tetsu's is a dark screen where everything it
/// says is in its own dots (the speech bubble's DotFont, typed on). The companion itself isn't drawn here: the live
/// character sits over the window in its own panel, on the floor this view draws for it.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    var size = CGSize(width: WelcomeLayout.width, height: 700)
    static let footerHeight = WelcomeLayout.footer
    static func width(choosing: Bool) -> CGFloat { WelcomeLayout.width }
    var layout: WelcomeLayout { WelcomeLayout(size: size) }
    var body: some View {
        ZStack(alignment: .topLeading) {
            WelcomeBackground(machine: model.machine)
            if model.page == .hello { HelloPage(model: model, layout: layout).transition(.opacity) }
            else { ReadPage(model: model, layout: layout).transition(.opacity) }
            WelcomeFooter(model: model).frame(width: size.width, height: WelcomeLayout.footer).offset(y: size.height - WelcomeLayout.footer)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading).clipped()
        .foregroundStyle(model.machine ? Color.white : ink)
        .preferredColorScheme(model.machine ? .dark : .light)
        .ignoresSafeArea()  // the transparent title bar sits over the top padding
    }
}

/// Colours of the two windows.
enum WelcomeInk {
    static let forest = Color(red: 0.204, green: 0.275, blue: 0.2)            // #344633, the site's green
    static let mark = Color(red: 0.43, green: 0.55, blue: 0.36)               // the marks on the drawn window
    static let night = Color(red: 0.071, green: 0.094, blue: 0.078)
    static let cyan = Color(nsColor: SpeechInk.cyan)
    static let amber = Color(nsColor: SpeechInk.amber)
}

private struct WelcomeBackground: View {
    let machine: Bool
    var body: some View {
        ZStack {
            paper
            WelcomeInk.night.overlay(RadialGradient(colors: [Color(red: 0.13, green: 0.17, blue: 0.15), .clear], center: .init(x: 0.5, y: 0.25), startRadius: 0, endRadius: 420))
                .opacity(machine ? 1 : 0)
        }
    }
}

/// Where the companion sits: a soft pool of light and a shadow on the window's floor.
private struct Floor: View {
    let at: CGPoint
    let scale: CGFloat
    let machine: Bool
    var body: some View {
        ZStack {
            Ellipse().fill(RadialGradient(colors: [machine ? WelcomeInk.cyan.opacity(0.16) : Color(red: 1, green: 0.95, blue: 0.86).opacity(0.95), .clear], center: .center, startRadius: 0, endRadius: 210 * scale))
                .frame(width: 420 * scale, height: 300 * scale).position(x: at.x, y: at.y - 100 * scale)
            Ellipse().fill(RadialGradient(colors: [(machine ? Color.black : Color(red: 0.43, green: 0.5, blue: 0.38)).opacity(machine ? 0.5 : 0.26), .clear], center: .center, startRadius: 0, endRadius: 90 * scale))
                .frame(width: 180 * scale, height: 26 * scale).position(x: at.x, y: at.y)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

// MARK: Hello

private struct HelloPage: View {
    @Bindable var model: OnboardingModel
    let layout: WelcomeLayout
    var body: some View {
        ZStack(alignment: .topLeading) {
            Floor(at: CGPoint(x: layout.size.width / 2, y: layout.helloFloor), scale: layout.helloScale, machine: model.machine)
            if model.choosing, let other = Companion.available.first(where: { $0 != model.companion }) {
                let frame = layout.peek(in: model.reduced || model.peeking == other)  // Reduce Motion: it fades in where it leans, no slide
                PeekPicture(companion: other).frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
                    .opacity(model.reduced ? (model.peeking == other ? 1 : 0) : 1)
            }
            VStack(alignment: .leading, spacing: 0) {
                if model.machine { machineHello } else { mokuHello }
                Spacer(minLength: 12)
                if model.choosing { CompanionNames(model: model) }
            }
            .padding(.horizontal, 40).padding(.bottom, 22)
            .frame(width: layout.size.width, height: WelcomeLayout.words, alignment: .topLeading)
            .offset(y: layout.stageHeight)
        }
    }
    private var mokuHello: some View {
        VStack(alignment: .leading, spacing: 9) {
            RisingWords(text: model.hello, since: model.greetedAt, reduced: model.reduced, delay: 0, oneLine: true)
                .font(.system(size: 40, weight: .medium, design: .serif)).foregroundStyle(WelcomeInk.forest)
            RisingWords(text: model.introduction, since: model.greetedAt, reduced: model.reduced, delay: 0.35, stagger: 0.03)
                .font(.system(size: 14)).quiet().frame(maxWidth: 480, alignment: .leading)
        }.accessibilityElement(children: .ignore).accessibilityLabel(model.greeting + " " + OnboardingModel.whatItDoes)
    }
    private var machineHello: some View {
        VStack(alignment: .leading, spacing: 10) {
            TypedDots(lines: [("TETSU-01 · ONLINE", 1.2, WelcomeInk.cyan.opacity(0.55))], since: model.greetedAt, reduced: model.reduced, width: 300)
            TypedDots(lines: [(model.hello, DotsText.fitting(model.hello, width: layout.size.width - 80, largest: 3.4, smallest: 1.6), WelcomeInk.cyan)], since: model.greetedAt.map { $0.addingTimeInterval(0.6) }, reduced: model.reduced, width: layout.size.width - 80)
            TypedDots(lines: [(model.introduction, 1.6, WelcomeInk.cyan.opacity(0.85))], since: model.greetedAt.map { $0.addingTimeInterval(1.3) }, reduced: model.reduced, width: layout.size.width - 80, glyphsPerSecond: 140)
        }.accessibilityElement(children: .ignore).accessibilityLabel(model.greeting + " " + OnboardingModel.whatItDoes)
    }
}

/// The other companion, leaning in from the edge while its name is hovered: the app's own render of it, curious.
private struct PeekPicture: View {
    let companion: Companion
    var body: some View {
        Group {
            if let image = Bundle.module.url(forResource: "peek-\(companion.rawValue)", withExtension: "png").flatMap(NSImage.init(contentsOf:)) {
                Image(nsImage: image).resizable().interpolation(.high)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// "Or work with": the companions as names, the one on show marked. Hovering the other makes it lean in; a click swaps.
private struct CompanionNames: View {
    @Bindable var model: OnboardingModel
    var body: some View {
        HStack(spacing: 10) {
            Text("Or work with").font(.system(size: 12.5, weight: .medium)).foregroundStyle(model.machine ? Color.white.opacity(0.62) : ink.opacity(Quiet.opacity(.secondary)))
                .padding(.trailing, 2)
            ForEach(Companion.available) { companion in
                let picked = companion == model.companion
                Button { model.choose(companion) } label: {
                    HStack(spacing: 9) {
                        Portrait(companion: companion).frame(width: 30, height: 30)
                        Text(companion.name).font(.system(size: 17, weight: .medium, design: .serif))
                        Text(companion.kind).font(.system(size: 11.5)).foregroundStyle(model.machine ? Color.white.opacity(0.6) : ink.opacity(Quiet.opacity(.secondary)))
                    }
                    .padding(.leading, 6).padding(.trailing, 16).frame(height: 42)
                    .background(Capsule().fill(picked ? (model.machine ? WelcomeInk.cyan.opacity(0.14) : WelcomeInk.mark.opacity(0.16)) : (model.machine ? Color.white.opacity(0.05) : ink.opacity(0.045))))
                    .overlay(Capsule().strokeBorder(picked ? (model.machine ? WelcomeInk.cyan : WelcomeInk.mark) : (model.machine ? Color.white.opacity(0.16) : ink.opacity(0.12)), lineWidth: picked ? 1.5 : 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { inside in model.hover(inside ? companion : nil) }
                .accessibilityLabel("\(companion.name), the \(companion.kind)")
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
    }
}

private struct Portrait: View {
    let companion: Companion
    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.5))
            if let image = Bundle.module.url(forResource: "companion-\(companion.rawValue)", withExtension: "png").flatMap(NSImage.init(contentsOf:)) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            }
        }.clipShape(Circle()).accessibilityHidden(true)
    }
}

/// Words rising in one after another (each a 12-point rise and a fade, `stagger` apart); all at once with Reduce
/// Motion, or before the hello has begun.
private struct RisingWords: View {
    let text: String
    let since: Date?
    let reduced: Bool
    var delay: Double
    var stagger = 0.07
    /// The hello: one line, made smaller to fit a long name; a long one rises in as one line, not word by word.
    var oneLine = false
    var body: some View {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let total = delay + Double(words.count) * stagger + 0.5
        if oneLine && (words.count > 3 || text.count > 24) {
            let shown = since.map { reduced ? 1 : WelcomeMotion.easeOut((Date().timeIntervalSince($0) - delay) / 0.45) } ?? (reduced ? 1 : 0)
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: shown >= 1 || since == nil)) { context in
                let k = since.map { reduced ? 1 : WelcomeMotion.easeOut((context.date.timeIntervalSince($0) - delay) / 0.45) } ?? (reduced ? 1 : 0)
                Text(text).lineLimit(1).minimumScaleFactor(0.4).opacity(k).offset(y: CGFloat(1 - k) * 12)
            }
        } else if let since, !reduced, Date().timeIntervalSince(since) < total + 0.2 {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                let t = context.date.timeIntervalSince(since)
                FlowText(words: words) { index in
                    let k = WelcomeMotion.easeOut((t - delay - Double(index) * stagger) / 0.45)
                    return (k, CGFloat(1 - k) * 12)
                }
            }
        } else {
            Group {
                if oneLine { Text(text).lineLimit(1).minimumScaleFactor(0.4) } else { Text(text).fixedSize(horizontal: false, vertical: true) }
            }
            .opacity(since == nil && !reduced ? 0 : 1)
            .animation(.easeInOut(duration: 0.35), value: since)
        }
    }
}

/// Words laid out like a paragraph, each with its own opacity and drop.
private struct FlowText: View {
    let words: [String]
    let style: (Int) -> (Double, CGFloat)
    var body: some View {
        WordFlow(spacing: 0) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                let (opacity, drop) = style(index)
                Text(word + (index == words.count - 1 ? "" : " ")).opacity(opacity).offset(y: drop)
            }
        }
    }
}

/// A flow layout: left to right, wrapping at the proposed width.
private struct WordFlow: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 480
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width; line = max(line, size.height); widest = max(widest, x)
        }
        return CGSize(width: min(width, widest), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width; line = max(line, size.height)
        }
    }
}

// MARK: Tetsu's dots

/// Text in Tetsu's dots (DotFont, the speech bubble's lettering), `pitch` points a dot, wrapped to `width`; `typed`
/// glyphs only while it types on. Text the dots can't spell (right to left, CJK) is set in type, lit the same.
struct DotsText: View {
    let text: String
    var pitch: CGFloat = 1.6
    var width: CGFloat
    var color: Color = WelcomeInk.cyan
    var typed: Int?
    var body: some View {
        let columns = max(8, Int(width / pitch))
        if DotFont.spells(text) {
            let layout = DotsCache.layout(text, columns: columns)
            let margin = DotPainter.glowMargin
            let shown = min(typed ?? Int.max, layout.glyphs.count)
            let image = DotsCache.image(text, columns: columns, pitch: pitch, color: NSColor(color), typed: shown == layout.glyphs.count ? nil : shown)
            Group {
                if let image { Image(decorative: image, scale: 2).resizable().interpolation(.none) } else { Color.clear }
            }
            .frame(width: CGFloat(layout.width) * pitch + 2 * margin, height: CGFloat(layout.rows) * pitch + 2 * margin)
            .padding(-margin)
            .accessibilityLabel(text)
        } else {
            Text(text).font(.system(size: max(11, pitch * 8), weight: .medium, design: .monospaced)).foregroundStyle(color)
                .shadow(color: color.opacity(0.6), radius: 3).frame(maxWidth: width, alignment: .leading)
                .lineLimit(pitch >= 3 ? 1 : nil).minimumScaleFactor(pitch >= 3 ? 0.4 : 1).fixedSize(horizontal: false, vertical: pitch < 3)
                .opacity(typed == 0 ? 0 : 1)
        }
    }
}

extension DotsText {
    /// The largest pitch (up to `largest`, down to `smallest`) at which `text` fits one line `width` wide.
    @MainActor static func fitting(_ text: String, width: CGFloat, largest: CGFloat, smallest: CGFloat) -> CGFloat {
        let natural = CGFloat(DotsCache.layout(text, columns: 10_000).width)
        return natural > 0 ? max(smallest, min(largest, (width / natural * 10).rounded(.down) / 10)) : largest
    }
}

/// Dot layouts and pictures, drawn once each (a typed-on line draws a few dozen as it goes; only finished ones are kept).
@MainActor enum DotsCache {
    private static var layouts: [String: DotText] = [:]
    private static var images: [String: CGImage] = [:]
    static func layout(_ text: String, columns: Int) -> DotText {
        let key = "\(columns)|\(text)"
        if let layout = layouts[key] { return layout }
        let layout = DotText(text, width: columns, maxLines: 30)
        layouts[key] = layout
        return layout
    }
    static func image(_ text: String, columns: Int, pitch: CGFloat, color: NSColor, typed: Int?) -> CGImage? {
        let layout = self.layout(text, columns: columns)
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let key = "\(columns)|\(pitch)|\(rgb.redComponent),\(rgb.greenComponent),\(rgb.blueComponent),\(rgb.alphaComponent)|\(text)"
        if typed == nil, let image = images[key] { return image }
        let dots = typed.map { layout.dots(typed: $0) } ?? layout.dots
        let image = DotPainter.image(dots, columns: max(1, layout.width), rows: layout.rows, pitch: pitch, color: color, glow: 0.8, margin: DotPainter.glowMargin, scale: 2)
        if typed == nil { images[key] = image }
        return image
    }
    static func release() { layouts = [:]; images = [:] }
}

/// Lines of dots typing on one after another from `since` (`glyphsPerSecond`), all at once with Reduce Motion. The
/// timeline stops once everything's out.
private struct TypedDots: View {
    let lines: [(text: String, pitch: CGFloat, color: Color)]
    let since: Date?
    let reduced: Bool
    let width: CGFloat
    var glyphsPerSecond = 60.0
    var body: some View {
        let counts = lines.map { DotsCache.layout($0.text, columns: max(8, Int(width / $0.pitch))).glyphs.count }
        let total = Double(counts.reduce(0, +)) / glyphsPerSecond
        let typing = since.map { !reduced && Date().timeIntervalSince($0) < total + 0.1 } ?? false
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !typing)) { context in
            let out = since.map { reduced ? Int.max : Int(context.date.timeIntervalSince($0) * glyphsPerSecond) } ?? (reduced ? Int.max : 0)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    let before = counts.prefix(index).reduce(0, +)
                    DotsText(text: line.text, pitch: line.pitch, width: width, color: line.color, typed: max(0, out - before))
                }
            }
        }
    }
}

// MARK: What it reads

private struct ReadPage: View {
    @Bindable var model: OnboardingModel
    let layout: WelcomeLayout
    var body: some View {
        ZStack(alignment: .topLeading) {
            Floor(at: CGPoint(x: layout.readX, y: layout.readFloor), scale: layout.readScale, machine: model.machine)
            DrawnWindow(model: model, layout: layout)
                .frame(width: layout.sample.width, height: layout.sample.height)
                .offset(x: layout.sample.minX, y: layout.sample.minY)
            ScrollView(.vertical, showsIndicators: false) {
                Group { if model.machine { SelfTest(model: model, width: layout.size.width - 72) } else { MokuAccount(model: model) } }
                    .padding(.horizontal, 36).padding(.top, 10).padding(.bottom, 16)
                    .frame(width: layout.size.width, alignment: .leading)
            }
            .frame(width: layout.size.width, height: layout.size.height - layout.readBand - WelcomeLayout.footer)
            .offset(y: layout.readBand)
        }
    }
}

/// A window drawn for the welcome, never a real screen: a page in a browser. The companion shows on it what each
/// permission lets it read (the marks), one after another; Tetsu's scan beam sweeps across it. Everything sits at fixed
/// places (WelcomeLayout.mark) so the marks fit what they mark.
private struct DrawnWindow: View {
    @Bindable var model: OnboardingModel
    let layout: WelcomeLayout
    var body: some View {
        let accent = model.machine ? WelcomeInk.cyan : WelcomeInk.mark, w = layout.sample.width, h = layout.sample.height
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Color.white
                Color(red: 0.95, green: 0.94, blue: 0.92).frame(width: w, height: 28)
                HStack(spacing: 6) {
                    ForEach([Color(red: 0.93, green: 0.42, blue: 0.37), Color(red: 0.96, green: 0.75, blue: 0.3), Color(red: 0.45, green: 0.75, blue: 0.4)], id: \.self) { Circle().fill($0).frame(width: 8, height: 8) }
                }.offset(x: 10, y: 10)
                Text("Browser").font(.system(size: 11)).foregroundStyle(Color(white: 0.44)).frame(width: 54).offset(x: 46, y: 7)
                Text("Q3 launch plan").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(white: 0.22)).frame(width: 104).offset(x: w / 2 - 52, y: 7)
                Text("docs.example.com/q3-launch-plan").font(.system(size: 11)).foregroundStyle(Color(white: 0.42)).padding(.leading, 9)
                    .frame(width: w - 20, height: 22, alignment: .leading).background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.945, green: 0.937, blue: 0.914)))
                    .offset(x: 10, y: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Q3 launch plan").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(white: 0.17))
                    Text("Ship the welcome on Monday. Friends first, then the private beta. Measure the first week’s drift.")
                        .font(.system(size: 11)).foregroundStyle(Color(white: 0.42)).fixedSize(horizontal: false, vertical: true)
                }.frame(width: w - 32, alignment: .leading).offset(x: 16, y: 66)
            }
            .frame(width: w, height: h).clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(model.machine ? 0.5 : 0.13), radius: 12, y: 6)
            if model.machine { ScanSweep(since: model.scanAt, reduced: model.reduced).frame(width: w, height: h) }
            ForEach(1..<5) { index in
                if index <= model.readStep {
                    let mark = layout.mark(index), current = index == model.readStep && model.readStep < 4
                    RoundedRectangle(cornerRadius: 6).strokeBorder(accent, lineWidth: current ? 2 : 1.5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(accent.opacity(current ? 0.1 : 0.04)))
                        .frame(width: mark.width, height: mark.height).offset(x: mark.minX, y: mark.minY)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .overlay(alignment: .topLeading) { label(1, accent).offset(x: layout.mark(1).minX - 2, y: -22) }
        .overlay(alignment: .topTrailing) { label(2, accent).offset(y: -22) }
        .overlay(alignment: .topTrailing) { label(3, accent).offset(x: -8, y: layout.mark(3).minY - 11) }
        .overlay(alignment: .bottomTrailing) { label(4, accent).offset(x: -8, y: 9) }
        .animation(model.reduced ? nil : .easeOut(duration: 0.3), value: model.readStep)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A drawn window: what \(model.companion.name) reads from the window you're in. The app, the window’s name, the address, and, if you allow it, a few words, read on this Mac.")
    }
    @ViewBuilder private func label(_ index: Int, _ accent: Color) -> some View {
        if index <= model.readStep {
            HStack(spacing: 5) {
                Text("\(index)").font(.system(size: 11, weight: .bold)).frame(width: 15, height: 15).background(Circle().fill(model.machine ? WelcomeInk.night.opacity(0.85) : Color.white.opacity(0.9)))
                    .foregroundStyle(accent)
                Text(PlainAccount.marks[index - 1]).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(model.machine ? WelcomeInk.night : .white)
            .padding(.leading, 3).padding(.trailing, 8).padding(.vertical, 2).background(Capsule().fill(accent)).fixedSize()
            .transition(.opacity)
        }
    }
}

/// Tetsu's beam crossing the drawn window: a bright edge with a fading trail, left to right, as its display scans.
private struct ScanSweep: View {
    let since: Date?
    let reduced: Bool
    var body: some View {
        let seconds = ScanBeam.seconds
        let active = since.map { !reduced && Date().timeIntervalSince($0) < seconds } ?? false
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { context in
            GeometryReader { geometry in
                let t = since.map { context.date.timeIntervalSince($0) / seconds } ?? 1
                if t >= 0 && t < 1 {
                    let x = geometry.size.width * CGFloat(WelcomeMotion.ease(t))
                    LinearGradient(colors: [WelcomeInk.cyan.opacity(0), WelcomeInk.cyan.opacity(0.28), WelcomeInk.cyan.opacity(0.9)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 70, height: geometry.size.height).offset(x: x - 70)
                        .opacity(sin(.pi * min(1, t * 1.1)))
                        .blendMode(.plusLighter)
                }
            }.clipShape(RoundedRectangle(cornerRadius: 11))
        }.allowsHitTesting(false)
    }
}

/// Moku's account, word for word: what it reads (each permission's Allow under why), where it's kept, how it's processed.
private struct MokuAccount: View {
    @Bindable var model: OnboardingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Here’s what I read.").font(.system(size: 24, weight: .medium, design: .serif)).foregroundStyle(WelcomeInk.forest)
            VStack(alignment: .leading, spacing: 0) {
                row(.accessibility, marks: [1, 2, 3])
                // Screen Recording isn't asked for here (the friends, 2026-10-14): optional, and on in Settings.
                if model.permissions.screenRecording { row(.screenRecording, marks: [4]) } else { optionalScreenRecording }
                if model.waitingForReopen { reopen.padding(.top, 8) }
            }
            Text(PlainAccount.never).font(.system(size: 12.5)).quiet()
            fact(PlainAccount.kept.title, PlainAccount.kept.text)
            fact(PlainAccount.processed.title, PlainAccount.processed.text)
            Link(PlainAccount.more, destination: URL(string: "https://hellomoku.com/privacy")!).font(.system(size: 12)).foregroundStyle(WelcomeInk.forest)
        }
    }
    private func row(_ kind: PermissionKind, marks: [Int]) -> some View {
        let text = PlainAccount.permission(kind)
        let granted = kind == .accessibility ? model.permissions.accessibility : model.permissions.screenRecording
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(text.title).font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 3) {
                        ForEach(marks, id: \.self) { n in
                            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).frame(width: 15, height: 15).background(Circle().fill(WelcomeInk.mark))
                        }
                    }.accessibilityHidden(true)
                }
                Text(text.why).font(.system(size: 12.5)).quiet().fixedSize(horizontal: false, vertical: true)
                if !granted { Text(text.without).font(.system(size: 11.5)).quiet().fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            if granted { Label("Allowed", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(WelcomeInk.mark).accessibilityLabel("\(text.title) allowed") }
            else {
                Button("Allow") { model.request(kind) }.buttonStyle(WelcomeButtonStyle(kind: .line, machine: false))
                    .accessibilityLabel("Allow \(text.title)").accessibilityHint(text.why)
            }
        }
        .padding(.vertical, 9).overlay(alignment: .top) { Rectangle().fill(ink.opacity(0.1)).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
    private var optionalScreenRecording: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(PlainAccount.screenRecording.title).font(.system(size: 13, weight: .semibold))
                Text("4").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).frame(width: 15, height: 15)
                    .background(Circle().fill(WelcomeInk.mark)).accessibilityHidden(true)
            }
            Text(PlainAccount.screenRecordingOptional).font(.system(size: 12.5)).quiet().fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9).overlay(alignment: .top) { Rectangle().fill(ink.opacity(0.1)).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
    private var reopen: some View {
        HStack(spacing: 10) {
            Text(PlainAccount.reopen).font(.system(size: 11.5)).quiet().fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Quit & Reopen", action: model.relaunch).buttonStyle(WelcomeButtonStyle(kind: .line, machine: false))
        }.padding(.horizontal, 10).padding(.vertical, 7).background(sage.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
    }
    private func fact(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 12.5)).lineSpacing(1.5).quiet().fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}

/// The self-test's lines: every one a true fact, in the same words as Moku's page.
enum SelfTestLines {
    struct Line { var label: String; var text: String; var status: Status }
    enum Status: Equatable { case ok, allow(PermissionKind), never, none }
    @MainActor static func lines(_ model: OnboardingModel) -> [Line] {
        var lines: [Line] = []
        let optics = PlainAccount.accessibility, sees = model.permissions.accessibility
        lines.append(Line(label: "OPTICS", text: optics.why + (sees ? "" : " " + optics.without), status: sees ? .ok : .allow(.accessibility)))
        // Screen Recording isn't asked for here (the friends, 2026-10-14): optional, and on in Settings.
        lines.append(model.permissions.screenRecording
            ? Line(label: "READER", text: PlainAccount.screenRecording.why, status: .ok)
            : Line(label: "READER", text: PlainAccount.screenRecordingOptional, status: .none))
        lines.append(Line(label: "NEVER", text: PlainAccount.never, status: .never))
        lines.append(Line(label: "KEPT", text: PlainAccount.kept.text, status: .ok))
        lines.append(Line(label: "SENT", text: PlainAccount.processed.text, status: .ok))
        return lines
    }
}

/// Tetsu's account: a self-test, typed on in its dots. Every line is a true fact in the same words as Moku's page, with
/// the permission's Allow on its line (OK once macOS says so), and what it never touches.
private struct SelfTest: View {
    @Bindable var model: OnboardingModel
    let width: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        let lines = SelfTestLines.lines(model), textWidth = width - 74 - 74, pitch: CGFloat = 1.6
        let counts = lines.map { DotsCache.layout($0.text, columns: Int(textWidth / pitch)).glyphs.count + 6 }
        let perSecond = 150.0, total = Double(counts.reduce(0, +)) / perSecond
        let since = model.readStartedAt
        let typing = since.map { !model.reduced && Date().timeIntervalSince($0) < total + 0.1 } ?? false
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !typing)) { context in
            let out = since.map { model.reduced ? Int.max : Int(context.date.timeIntervalSince($0) * perSecond) } ?? Int.max
            VStack(alignment: .leading, spacing: 11) {
                DotsText(text: "SELF-TEST · WHAT I READ, WHERE IT’S KEPT", pitch: 1.3, width: width, color: dim, typed: out)
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    let before = counts.prefix(index).reduce(0, +), shown = out - before
                    HStack(alignment: .top, spacing: 0) {
                        DotsText(text: line.label, pitch: pitch, width: 74, color: line.status == .never ? WelcomeInk.amber : dim, typed: shown).frame(width: 74, alignment: .leading)
                        DotsText(text: line.text, pitch: pitch, width: textWidth, color: WelcomeInk.cyan, typed: max(0, shown - 6)).frame(width: textWidth, alignment: .leading)
                        status(line.status, shown: shown >= counts[index]).frame(width: 74, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
                if model.waitingForReopen {
                    VStack(alignment: .trailing, spacing: 8) {
                        DotsText(text: PlainAccount.reopen, pitch: pitch, width: width - 20, color: WelcomeInk.cyan).frame(maxWidth: .infinity, alignment: .leading)
                        Button(action: model.relaunch) { DotsText(text: "QUIT & REOPEN", pitch: 1.4, width: 140) }
                            .buttonStyle(WelcomeButtonStyle(kind: .line, machine: true)).accessibilityLabel("Quit & Reopen")
                    }.padding(10).background(WelcomeInk.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
                Link(PlainAccount.more, destination: URL(string: "https://hellomoku.com/privacy")!).font(.system(size: 12, design: .monospaced)).foregroundStyle(dim)
            }
        }
    }
    private var dim: Color { WelcomeInk.cyan.opacity(contrast == .increased ? 1 : 0.62) }
    @ViewBuilder private func status(_ status: SelfTestLines.Status, shown: Bool) -> some View {
        switch status {
        case .ok: DotsText(text: "OK", pitch: 1.6, width: 40, color: WelcomeInk.cyan).opacity(shown ? 1 : 0).accessibilityLabel("OK")
        case .never: DotsText(text: "NEVER", pitch: 1.6, width: 60, color: WelcomeInk.amber).opacity(shown ? 1 : 0)
        case .allow(let kind):
            Button { model.request(kind) } label: { DotsText(text: "ALLOW", pitch: 1.5, width: 50) }
                .buttonStyle(WelcomeButtonStyle(kind: .line, machine: true)).opacity(shown ? 1 : 0)
                .accessibilityLabel("Allow \(PlainAccount.permission(kind).title)").accessibilityHint(PlainAccount.permission(kind).why)
        case .none: EmptyView()
        }
    }
}

// MARK: The footer

private struct WelcomeFooter: View {
    @Bindable var model: OnboardingModel
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(model.machine ? WelcomeInk.cyan.opacity(0.14) : ink.opacity(0.1)).frame(height: 1)
            HStack(spacing: 14) {
                Button("Skip for now", action: model.skip).buttonStyle(.plain).font(.system(size: 12.5))
                    .foregroundStyle(model.machine ? Color.white.opacity(0.6) : ink.opacity(Quiet.opacity(.secondary))).keyboardShortcut(.cancelAction)
                Spacer()
                if model.page == .read {
                    Toggle("Start with your Mac", isOn: $model.startWithMac).toggleStyle(.switch).controlSize(.mini).font(.system(size: 12.5))
                        .tint(model.machine ? WelcomeInk.cyan : WelcomeInk.mark)
                    Button(action: model.start) { label("Start") }.buttonStyle(WelcomeButtonStyle(kind: .primary, machine: model.machine))
                        .keyboardShortcut(.defaultAction).disabled(model.starting).accessibilityLabel("Start")
                } else {
                    Button(action: model.next) { label("Next") }.buttonStyle(WelcomeButtonStyle(kind: .primary, machine: model.machine))
                        .keyboardShortcut(.defaultAction).accessibilityLabel("Next: what \(model.companion.name) reads")
                }
            }.padding(.horizontal, 26).frame(maxHeight: .infinity)
        }
    }
    @ViewBuilder private func label(_ text: String) -> some View {
        if model.machine { DotsText(text: text.uppercased(), pitch: 1.7, width: 80, color: WelcomeInk.night) } else { Text(text) }
    }
}

/// The welcome's buttons: the primary is a pill in the site's green (on Tetsu's screen, lit cyan); `line` is an outline.
struct WelcomeButtonStyle: ButtonStyle {
    enum Kind { case primary, line }
    let kind: Kind
    let machine: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(.system(size: kind == .primary ? 14 : 12, weight: .semibold))
            .foregroundStyle(kind == .primary ? (machine ? WelcomeInk.night : paper) : (machine ? WelcomeInk.cyan : WelcomeInk.forest))
            .padding(.horizontal, kind == .primary ? 22 : 13).frame(height: kind == .primary ? 36 : 26)
            .background(Capsule().fill(kind == .primary ? (machine ? WelcomeInk.cyan : WelcomeInk.forest) : Color.clear))
            .overlay(Capsule().strokeBorder(kind == .line ? (machine ? WelcomeInk.cyan.opacity(0.8) : WelcomeInk.forest.opacity(0.4)) : .clear, lineWidth: 1))
            .shadow(color: machine && kind == .primary ? WelcomeInk.cyan.opacity(0.45) : .clear, radius: 8)
            .opacity(enabled ? (pressed ? 0.8 : 1) : 0.5)
            .contentShape(Capsule())
    }
}
