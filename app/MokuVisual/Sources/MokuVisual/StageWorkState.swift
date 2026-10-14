import AppKit
import MokuKit

extension MokuCharacterStage {
    public func setWorkState(_ state: WorkState) {
        VisualSessionState.shared.workState = state
        guard state != workState else { return }
        cancelDirectedBeat()
        workDirection.set(state, now: CACurrentMediaTime())
        focusClock.became(state, now: CACurrentMediaTime())
        view.real?.setDrifting(state.isDrift)
        // Four minutes into a drift (the .drifting tier) Moku is a little red, until the drift ends.
        view.real?.setFlushed(state == .drifting || state == .longDrift)
        view.real?.setAsking(state == .longDrift)  // Tetsu's display: a cursor waiting for you
        view.lantern.apply(state, reduced: reduced)
        view.real?.setLanternBrightness(view.lantern.phase.brightness)
        // A new drift tier keeps a look at the user under way (the sad move's); otherwise the eyes rest on the screen.
        if state == .focused || (state.isDrift && attention != .user) { restingGaze() }
        refreshWorkLayers()
        if !hidden, state.isDrift, state != .grace, workDirection.glanceCount == 0,
           let expression = workDirection.claim(now: CACurrentMediaTime(), busy: false, reduced: reduced, choice: 0, jitter: 1) {
            glance(expression, withExpression: false)
        }

    }
    func refreshWorkLayers() {
        view.lantern.setHidden(hidden)
        view.real?.setReading(!hidden && !grabbing && workState == .focused && attention != .user)
        // Moku breathes whenever it's there to see, dozing through a break too.
        view.real?.setBreathing(!hidden && !grabbing && (view.lantern.phase.breath || workState.isDrift || workState == .onBreak))
        view.manpu.setSuppressed(hidden || isGlancing || grabbing)
    }
    /// Where Moku looks when nothing else is going on: the screen, in focus and in a drift alike. Only the engine's own
    /// look at the user (the sad move's) turns it to the user (Charles, 2026-10-14: "during drift instead of watching me,
    /// it can be sad and then go on to look the screen like the focus used to").
    func restingGaze() {
        attention = .wander; watchScreenCenter()
    }
    func lookAtUser() {
        attention = .user; view.puppet.look(x: 0, y: 0, reduced: reduced); view.real?.noticeUser(); view.real?.setReading(false)
    }
    func cancelGlance() {
        glanceTask?.cancel(); glanceTask = nil
        if isGlancing { isGlancing = false; view.real?.suppressExpressions(); restingGaze() }
        view.manpu.setSuppressed(hidden)
    }
    func cancelDirectedBeat() {
        cancelGlance(); returnTask?.cancel(); returnTask = nil; returning = false
        if let image = view.real?.imageLayer, image.animation(forKey: "returnHop") != nil {
            let height = (image.presentation() ?? image).transform.m42
            image.removeAnimation(forKey: "returnHop")
            let settle = CABasicAnimation(keyPath: "transform.translation.y")
            settle.fromValue = height; settle.toValue = 0; settle.duration = 0.35
            settle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            image.add(settle, forKey: "returnHop")
        }
    }
    func glance(_ expression: MicroExpression, withExpression: Bool = true) {
        guard !hidden else { return }
        isGlancing = true; if expression != .smile { caughtDuringGlance = false }; view.manpu.setSuppressed(true)
        glanceTask = Task { [weak self] in
            guard let self else { return }
            do {
                // A drift's little moves stay on the screen: no glance at the user first.
                if !reduced, !workState.isDrift { view.real?.noticeUser(); try await Task.sleep(for: .milliseconds(650)) }
                if withExpression { view.real?.microExpression(expression) }
                try await Task.sleep(for: .seconds(max(0.5, expression.duration)))
                if !reduced { restingGaze(); try await Task.sleep(for: .milliseconds(1300)) }
            } catch { return }
            isGlancing = false; glanceTask = nil; view.manpu.setSuppressed(hidden)
        }
    }
    public func celebrateReturn(_ size: ReturnSize) {
        cancelDirectedBeat(); dismissSpeech()
        VisualSessionState.shared.workState = .focused
        workDirection.set(.focused, now: CACurrentMediaTime()); view.real?.setDrifting(false); attention = .wander
        focusClock.became(.focused, now: CACurrentMediaTime())  // a return starts unbroken focus over
        view.real?.setFlushed(false)  // the red is the drift's; the engine's following .focused is already the state
        guard !hidden else { view.lantern.apply(.focused, reduced: reduced, instant: true); return }
        view.lantern.celebrate(size, reduced: reduced); view.real?.setLanternBrightness(1)
        // A character already out in the screen comes home; the walk is the beat.
        if currentSpot != .home {
            returnTask = Task { [weak self] in
                guard let self else { return }
                await travel.run { [weak self] in await self?.returnWalkHome() }
                guard !Task.isCancelled else { return }
                setMood(.content); watchScreenCenter(); refreshWorkLayers(); returnTask = nil
            }
            return
        }
        returning = true; view.real?.setReading(false)
        returnTask = Task { [weak self] in
            guard let self else { return }
            do {
                if size == .full {
                    try await Task.sleep(for: .milliseconds(100))
                    view.real?.noticeUser()
                    setMood(.happy)
                    if !reduced, let real = view.real, real.companion == .moku {
                        // Moku's talent (next-wave.md §2), seated: the smile leads, then a happy bounce on the spot, and a
                        // little twirl of petals at the top of it.
                        try await Task.sleep(for: .milliseconds(150))
                        real.happyBounce()
                        try await Task.sleep(for: .milliseconds(220))
                        view.petals.play(in: view.stage, centre: CGPoint(x: real.imageLayer.frame.midX, y: StageGeometry.feet.y), reduced: reduced)
                        count?(.talent(.petals))
                        try await Task.sleep(for: .milliseconds(730))
                    } else if !reduced, let real = view.real, real.companion.isMachine {
                        // Tetsu's comeback: a happy double beep (its antenna LEDs blip twice) and a quick servo bob.
                        try await Task.sleep(for: .milliseconds(150))
                        real.machineComeback()
                        try await Task.sleep(for: .milliseconds(950))
                    } else {
                        if !reduced, let image = view.real?.imageLayer {
                            let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
                            hop.values = [0, 0, 2.5, 0]; hop.keyTimes = [0, 0.25, 0.6, 1]; hop.duration = 0.95
                            hop.timingFunctions = (0..<3).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
                            image.add(hop, forKey: "returnHop")
                        }
                        try await Task.sleep(for: .milliseconds(1100))
                    }
                    view.real?.microExpression(.slowBlink); view.real?.returnNod()
                    try await Task.sleep(for: .milliseconds(1000))
                } else {
                    // Back from a doze (the end of a break): the eyes open and the head comes up first, then the happy look.
                    if view.real?.justWoke == true { setMood(.happy); try await Task.sleep(for: .milliseconds(1300)) }
                    setMood(.happy); view.real?.noticeUser(); view.real?.returnNod(); try await Task.sleep(for: .milliseconds(1200))
                }
                // Still saying "Welcome back!": keep the happy face on the user; the engine settles both when the line ends.
                if speechTask == nil { setMood(.content); watchScreenCenter() }
                returning = false; returnTask = nil
                workDirection.pause(now: CACurrentMediaTime()); refreshWorkLayers()
            } catch { return }
        }
    }
    private func returnWalkHome() async { await walk(to: .home) }
}
