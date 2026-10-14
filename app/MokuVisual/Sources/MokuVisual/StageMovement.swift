import AppKit
import SwiftUI
import MokuKit

/// Seated only for now (Charles, 2026-10-04: "the body looks weird when these stand, seated positions are great for
/// now, we will focus on walking later"). A move fades out where the companion sits and fades in where it's going, and
/// the drift ladder's stand-up is sitting up tall. False brings back the hop and the stand.
enum Posture { static let seatedOnly = true }

extension MokuCharacterStage {
    public func move(to spot: StageSpot) async {
        cancelGrab(); cancelDirectedBeat(); workDirection.pause(now: CACurrentMediaTime())
        await travel.run { [weak self] in await self?.walk(to: spot) }
    }
    func walk(to spot: StageSpot) async {
        guard !hidden, let primary = NSScreen.screens.first else { return }
        currentSpot = spot; moveGeneration += 1; let generation = moveGeneration
        let destination: CGPoint
        let screen: NSScreen
        switch spot {
        case .home: screen = homeScreen() ?? primary; destination = homeOrigin(on: screen)
        case .center:
            screen = primary; destination = CGPoint(x: primary.visibleFrame.midX - StageGeometry.characterFrame.midX * view.scale, y: primary.visibleFrame.midY - StageGeometry.restingCenter.y * view.scale)
        case .near(let point):
            screen = NSScreen.screens.first { $0.frame.contains(point) } ?? primary
            destination = CGPoint(x: point.x + 24, y: point.y - 75)
        }
        let target = StageGeometry.clamped(destination, to: screen.stageFrame, scale: view.scale)
        let origin = panel.frame.origin; let distance = hypot(target.x - origin.x, target.y - origin.y)
        guard distance > 1 else {
            moving = false; view.real?.walk(false)
            for name in ["foot_L", "foot_R"] { view.puppet.joints[name]?.removeAnimation(forKey: "transform.translation.y") }
            view.puppet.body.removeAnimation(forKey: "transform.translation.y")
            return
        }
        if Posture.seatedOnly { await fade(to: target, generation: generation); return }
        moving = true; view.real?.suppressExpressions()
        await view.real?.prepareForMovement()
        await view.real?.setCarrying(false); view.lantern.setCarried(false)
        guard !Task.isCancelled, generation == moveGeneration, !hidden else { if generation == moveGeneration { moving = false }; return }
        let hop = HopTravel.load(companion: view.real?.companion ?? .current)
        let stride = max(1,hop.strideLength*(view.real?.pointsPerWorldUnit ?? 100)*view.scale)
        if !reduced { guard await view.real?.beginHopping(direction: target.x >= origin.x ? 1 : -1) == true else { moving = false; return } }
        guard !Task.isCancelled, generation == moveGeneration else { return }
        let duration = reduced ? 0.5 : hop.travelDuration(distance: distance,stridePoints: stride)
        let start = CACurrentMediaTime()
        while !hidden && generation == moveGeneration && !Task.isCancelled {
            let elapsed = min(duration,CACurrentMediaTime()-start)
            let amount = reduced ? Double(MoodTiming.progress(age: elapsed,duration: duration))*distance : hop.position(elapsed: elapsed,distance: distance,stridePoints: stride)
            if !reduced { let phase = (elapsed/hop.duration).truncatingRemainder(dividingBy: 1); view.real?.sampleHop(phase) }
            panel.setFrameOrigin(CGPoint(x: origin.x+(target.x-origin.x)*amount/distance,y: origin.y+(target.y-origin.y)*amount/distance))
            positionSpeech(); positionLabel(); updateHit()
            if elapsed >= duration { break }
            do { try await Task.sleep(for: .milliseconds(reduced ? 33 : 16)) } catch { break }
        }
        guard generation == moveGeneration else { return }
        if Task.isCancelled { return } // The redirect owns the live pose and starts here.
        moving = false
        if !reduced { await view.real?.finishHopping() }
        else { view.real?.walk(false) }
        workDirection.pause(now: CACurrentMediaTime())
        if attention == .user { lookAtUser() } else { watchScreenCenter() }  // a walk or a drop faces the way it was
        refreshWorkLayers()
        for name in ["foot_L", "foot_R"] { view.puppet.joints[name]?.removeAnimation(forKey: "transform.translation.y") }
        view.puppet.body.removeAnimation(forKey: "transform.translation.y")
    }
    /// A seated move: the companion, its speech and its label fade out where it sits and fade in where it's going.
    /// Whatever takes over halfway (a grab, a redirect) finds it visible again; hiding owns the fade itself.
    private func fade(to target: CGPoint, generation: Int) async {
        moving = true; view.real?.suppressExpressions()
        // A machine doesn't fade: a scan line erases it where it sits and prints it where it's going (StageBeam.swift), so its
        // own window stays opaque. Reduce Motion keeps the soft fade for both.
        let machine = view.real?.companion.isMachine == true && !reduced
        // The break timer goes with it: it follows the companion's window, so it would otherwise cross the screen on its own.
        // (An offscreen panel is never "visible", so the demo's checks name it.)
        let candidates: [NSPanel] = [panel, speechPanel, labelPanel, breakPanel]
        let windows = candidates.filter { ($0.isVisible || ($0 === panel && rendersOffscreen)) && !(machine && $0 === panel) }, shown = windows.map(\.alphaValue)
        func show(_ amount: [CGFloat], over seconds: Double) async {
            guard !windows.isEmpty else { try? await Task.sleep(for: .seconds(seconds)); return }  // (the beam alone)
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = seconds; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for (window, alpha) in zip(windows, amount) { window.animator().alphaValue = alpha }
            }
        }
        defer {
            if generation == moveGeneration { moving = false }
            view.beam.finish(stage: view.stage)  // a grab or a redirect halfway finds it whole again
            if !hidden { for (window, alpha) in zip(windows, shown) where window.alphaValue < alpha { window.alphaValue = alpha } }
        }
        let out = machine ? StageBeam.outSeconds : 0.3, arrive = machine ? StageBeam.inSeconds : 0.45
        if machine, let host = view.layer { view.beam.erase(stage: view.stage, host: host, scale: view.scale, seconds: out) }
        await show(shown.map { _ in 0 }, over: out)
        guard !Task.isCancelled, generation == moveGeneration, !hidden else { return }
        panel.setFrameOrigin(target); positionSpeech(); positionLabel(); updateHit()
        if machine, let host = view.layer { view.beam.reveal(stage: view.stage, host: host, scale: view.scale, seconds: arrive) }
        await show(shown, over: arrive)
        guard !Task.isCancelled, generation == moveGeneration else { return }
        if machine { view.beam.finish(stage: view.stage); view.real?.playDisplayMoment("px_wake") }  // its display starts up as it lands
        workDirection.pause(now: CACurrentMediaTime())
        if attention == .user { lookAtUser() } else { watchScreenCenter() }
        refreshWorkLayers()
    }
    /// The wave reaches past the body (Moku's raised paw and lop ear), and at home by the screen's side its ear went
    /// past the edge. So by a side Moku scoots in for the wave, just enough to keep `edgePadding`, and back once it's
    /// played (the 2026-09-28 audit; docs/specs/next-wave.md §6). A walk, a grab or hiding takes over at once.
    func makeRoomToWave() {
        guard !moving, !grabbing, carry == nil, let companion = view.real?.companion,
              let visible = (NSScreen.screens.first { $0.frame.contains(CGPoint(x: panel.frame.midX, y: panel.frame.midY)) })?.stageFrame else { return }
        let shift = StageGeometry.roomToWave(panel: panel.frame, visible: visible, reach: companion.waveReach)
        guard abs(shift) >= 1 else { return }
        let from = panel.frame.minX, generation = moveGeneration
        Task { [weak self] in
            guard let self, await scoot(from: from, to: from + shift, generation: generation) else { return }
            // The wave starts once any folded arms are down, and Moku goes back when it's over.
            let asked = CACurrentMediaTime()
            while view.real?.playingClip != "wave" && CACurrentMediaTime() - asked < 1.5 {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            while view.real?.playingClip == "wave" {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            guard generation == moveGeneration else { return }
            await scoot(from: from + shift, to: from, generation: generation)
        }
    }
    /// Slides the panel sideways, eased, unless a walk, a grab or hiding takes over. Returns whether it got there.
    @discardableResult private func scoot(from: CGFloat, to: CGFloat, generation: Int, seconds: Double = 0.45) async -> Bool {
        let start = CACurrentMediaTime()
        while generation == moveGeneration {
            let k = CGFloat(MoodTiming.progress(age: CACurrentMediaTime() - start, duration: seconds))
            panel.setFrameOrigin(CGPoint(x: from + (to - from) * k, y: panel.frame.minY))
            positionSpeech(); positionLabel(); updateHit()
            if k >= 1 { return true }
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return false }
        }
        return false
    }
    public func say(_ line: SpeechLine) {
        cancelDirectedBeat(); workDirection.pause(now: CACurrentMediaTime())
        guard !hidden, !line.text.isEmpty, line.duration > 0 else { dismissSpeech(); return }
        showBubble(.line(line), for: line.duration)
    }
    /// A line is being written (Luna's celebration): a thinking bubble until it's said, or dismissed.
    public func think() {
        guard !hidden else { return }
        showBubble(.thinking, for: SpeechBubbleView.thinkingTimeout)
    }
    /// The companion's own bubble (SpeechBubble.swift). A bubble replacing a thinking one, or another line, takes its
    /// place without fading the window; its own entrance carries it.
    private func showBubble(_ content: SpeechContent, for seconds: TimeInterval) {
        answerWhatsNew(opened: false)  // a bubble taking the place of "What's new" closes it
        (speechPanel.contentView as? SpeechBubbleView)?.releasePointer()
        speechTask?.cancel(); speechGeneration += 1
        let showing = speechPanel.isVisible && speechPanel.alphaValue > 0.5
        let bubble = SpeechBubbleView(content: content, style: SpeechStyle(companion ?? .current), name: (companion ?? .current).name,
                                      dark: appearsDark, scale: backingScale, reduced: reduced)
        if let version = bubble.whatsNew {
            // "What's new": a click opens the changelog (the app does), the ✕ closes; either way the bubble's done.
            whatsNewUp = version
            bubble.onActivate = { [weak self] in self?.answerWhatsNew(opened: true); self?.dismissSpeech() }
            bubble.onClose = { [weak self] in self?.dismissSpeech() }
        }
        // Clicks pass through a bubble, except "What's new".
        speechPanel.setContentSize(bubble.frame.size); speechPanel.contentView = bubble; speechPanel.ignoresMouseEvents = bubble.onActivate == nil
        positionSpeech()
        if !showing { speechPanel.alphaValue = 0; if !rendersOffscreen { speechPanel.orderFrontRegardless() } }
        // Always animated, so it takes over from a fade-out still under way.
        NSAnimationContext.runAnimationGroup { context in context.duration = showing ? 0.1 : 0.22; speechPanel.animator().alphaValue = 1 }
        bubble.play()
        view.real?.suppressExpressions()
        speechTask = Task { [weak self] in
            guard seconds.isFinite else { return }  // up until it's dismissed (the ask)
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            // A bubble you can click ("What's new") never goes from under the pointer reaching for it: its time runs out
            // once the pointer has left it.
            while bubble.pointerInside {
                do { try await Task.sleep(for: BubbleButton.pointerCheckEvery) } catch { return }
            }
            self?.dismissSpeech()
        }
    }
    /// Takes the bubble down with a short fade; a new bubble in the meantime keeps the window.
    public func dismissSpeech() {
        answerWhatsNew(opened: false)
        (speechPanel.contentView as? SpeechBubbleView)?.releasePointer()
        speechTask?.cancel(); speechTask = nil
        speechPanel.ignoresMouseEvents = true  // a bubble on its way out takes no clicks
        guard speechPanel.isVisible else { return }
        speechGeneration += 1
        let generation = speechGeneration
        NSAnimationContext.runAnimationGroup({ context in context.duration = 0.18; speechPanel.animator().alphaValue = 0 }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.speechGeneration else { return }
                self.speechPanel.orderOut(nil)
            }
        })
    }
    /// Whether bubbles and labels are drawn for dark mode.
    var appearsDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    /// Pixels per point where the companion sits, so bubbles and labels are drawn crisp for that display.
    var backingScale: CGFloat { panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    /// Settings › Size. Moku grows or shrinks where it sits: at home it stays at home (at the screen's
    /// side, with the same little padding); anywhere else its feet stay put.
    func resize(to scale: CGFloat) {
        guard scale != view.scale else { return }
        travel.cancel(); moveGeneration += 1; cancelGrab(); moving = false; view.real?.walk(false)
        let old = view.scale, frame = panel.frame
        let feet = CGPoint(x: frame.minX + StageGeometry.feet.x * old, y: frame.minY + StageGeometry.feet.y * old)
        view.setScale(scale); view.real?.setResolution(for: scale)
        var origin = CGPoint(x: feet.x - StageGeometry.feet.x * scale, y: feet.y - StageGeometry.feet.y * scale)
        if currentSpot == .home, let screen = homeScreen() {
            origin = homeOrigin(on: screen)
        } else if let screen = NSScreen.screens.first(where: { $0.frame.contains(feet) }) ?? homeScreen() {
            origin = StageGeometry.clamped(origin, to: screen.stageFrame, scale: scale)
        }
        panel.setFrame(CGRect(origin: origin, size: StageGeometry.panelSize(scale: scale)), display: true)
        positionSpeech(); positionLabel(); updateHit(refreshPointer: true)
        if attention == .user { lookAtUser() } else { watchScreenCenter() }
    }
    func positionSpeech() {
        let visible = (NSScreen.screens.first { $0.frame.contains(CGPoint(x: panel.frame.midX, y: panel.frame.midY)) } ?? NSScreen.screens.first)?.visibleFrame ?? panel.frame
        let caption = captionShowing ? labelPanel.frame : nil
        speechPanel.setFrameOrigin(StageGeometry.speechOrigin(panel: panel.frame, bubble: speechPanel.frame.size, visible: visible,
                                                              gap: MokuPreferences.speechGap(in: homeStore), caption: caption))
    }
}
