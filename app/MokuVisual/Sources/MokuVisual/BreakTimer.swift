import AppKit
import SwiftUI
import Observation
import MokuKit

/// A break's countdown over Moku's head: a ring that empties as the break runs out, a teacup, and the time left.
@MainActor @Observable final class BreakTimerModel {
    var until: Date?
    var total: TimeInterval = 1
    var now = Date()
    /// The time left when the break ended: the pill fades out showing it, rather than jumping to 0:00.
    var endedWith: TimeInterval?
    var remaining: TimeInterval { endedWith ?? max(0, (until ?? now).timeIntervalSince(now)) }
    var fraction: Double { min(1, remaining / max(1, total)) }
    var text: String {
        let seconds = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct BreakTimerView: View {
    let model: BreakTimerModel
    /// The ✕: ends the break early.
    var onEnd: () -> Void = {}
    @State private var hoveringEnd = false
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color(red: 0.43, green: 0.56, blue: 0.35).opacity(0.18), lineWidth: 3)
                Circle().trim(from: 0, to: model.fraction).stroke(Color(red: 0.43, green: 0.56, blue: 0.35), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90)).animation(.linear(duration: 1), value: model.fraction)
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 9)).foregroundStyle(Color(red: 0.55, green: 0.42, blue: 0.3))
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.text).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("on a break").font(.system(size: 9, weight: .medium)).quiet()
            }
            Button(action: onEnd) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 18, height: 18)
                    .background(Circle().fill(Color.black.opacity(hoveringEnd ? 0.14 : 0.07)))
            }
            .buttonStyle(.plain).onHover { hoveringEnd = $0 }.help("End the break").accessibilityLabel("End the break")
        }
        .padding(.leading, 8).padding(.trailing, 8).padding(.vertical, 6)
        .foregroundStyle(Color(red: 0.25, green: 0.32, blue: 0.27))
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(6).preferredColorScheme(.light)
        .accessibilityElement(children: .contain).accessibilityLabel("On a break, \(model.text) left")
    }
}

/// The pill's host takes the first click (it sits in a panel that never becomes key), so the ✕ works at once.
final class ClickThroughHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension MokuCharacterStage {
    public func setBreakTimer(until: Date?, total: TimeInterval) {
        breakTimer.now = Date()
        guard until != nil else {
            breakTimer.endedWith = breakTimer.remaining; breakTimer.until = nil  // (the ring keeps its total too)
            breakPanel.ignoresMouseEvents = true  // a pill on its way out takes no clicks
            NSAnimationContext.runAnimationGroup({ context in context.duration = 0.3; breakPanel.animator().alphaValue = 0 }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { if self?.breakTimer.until == nil { self?.breakPanel.orderOut(nil) } }
            })
            return
        }
        breakTimer.endedWith = nil; breakTimer.until = until; breakTimer.total = total
        installBreakTimer()
        breakPanel.ignoresMouseEvents = false
        positionBreakTimer()
        breakPanel.alphaValue = 0
        if !rendersOffscreen && !hidden { breakPanel.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.35; breakPanel.animator().alphaValue = 1 }
    }

    /// The pill's view, made once. At launch, while nothing shows: made on the first break, SwiftUI's first view
    /// held up the main thread (60 to 180 ms) just as the tea began.
    func installBreakTimer() {
        // A machine counts its break down in dots on its display glass; the bunny's is a paper capsule with a ring (LEDBreakTimer.swift).
        if (view.real?.companion ?? .current).isMachine {
            guard !(breakPanel.contentView is ClickThroughHost<LEDBreakTimerView>) else { return }
            let content = ClickThroughHost(rootView: LEDBreakTimerView(model: breakTimer, onEnd: { [weak self] in self?.endBreakFromTimer() }))
            breakPanel.setContentSize(content.fittingSize); breakPanel.contentView = content; breakPanel.ignoresMouseEvents = false
            return
        }
        guard !(breakPanel.contentView is ClickThroughHost<BreakTimerView>) else { return }  // (a panel starts with an empty content view)
        let content = ClickThroughHost(rootView: BreakTimerView(model: breakTimer, onEnd: { [weak self] in self?.endBreakFromTimer() }))
        breakPanel.setContentSize(content.fittingSize); breakPanel.contentView = content; breakPanel.ignoresMouseEvents = false
    }

    /// The pill's ✕: ends the break going on, and never starts one. (It reaches the break button's toggle, and the pill
    /// fades for 0.3 s after a break ends: a double-click, or a click as the time ran out, started a new break.)
    func endBreakFromTimer() {
        guard breakTimer.until != nil else { return }
        onTakeBreak?()
    }

    /// Every tick while a break runs: the time left, and the timer kept over Moku's head (it may be carried).
    func tickBreakTimer() {
        guard breakTimer.until != nil else { return }
        breakTimer.now = Date()
        positionBreakTimer()
        guard !hidden else { return }  // (fadeBreakTimerOut took it down)
        if !rendersOffscreen && !breakPanel.isVisible {  // back after the companion was hidden: it fades in with it
            breakPanel.alphaValue = 0; breakPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.25; breakPanel.animator().alphaValue = 1 }
        }
    }
    /// The companion hides (a call, "Hide Moku"): the timer goes with it, over the same 0.18 s.
    func fadeBreakTimerOut() {
        guard breakPanel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in context.duration = 0.18; breakPanel.animator().alphaValue = 0 }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { if self?.hidden == true { self?.breakPanel.orderOut(nil) } }
        })
    }

    func positionBreakTimer() {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: panel.frame.midX, y: panel.frame.midY)) } ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? panel.frame
        let origin = StageGeometry.captionOrigin(panel: panel.frame, caption: breakPanel.frame.size, visible: visible, gap: MokuPreferences.captionGap(in: homeStore))
        if breakPanel.frame.origin != origin { breakPanel.setFrameOrigin(origin) }
    }
}
