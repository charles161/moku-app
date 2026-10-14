import Foundation

/// A short recognition window lets a head stroke reverse before a grab commits.
struct GrabRecognizer {
    enum Result: Equatable { case click, pat, grab, cancelled }
    private var origin = CGPoint.zero
    private var previous = CGPoint.zero
    private var started = 0.0
    private var movedAt: Double?
    private var onHead = false
    private var distance = 0.0
    private var direction = 0.0
    private var reversals = 0
    private(set) var grabbed = false
    mutating func begin(at point: CGPoint, onHead: Bool, time: Double) {
        self = Self(); origin = point; previous = point; started = time; self.onHead = onHead
    }
    @discardableResult mutating func update(to point: CGPoint, time: Double) -> Bool {
        let dx = point.x - previous.x, dy = point.y - previous.y
        distance += hypot(dx, dy)
        if hypot(dx, dy) >= 1, movedAt == nil { movedAt = time }
        if abs(dx) >= 2 {
            let next = dx.sign == .minus ? -1.0 : 1.0
            if direction != 0 && next != direction { reversals += 1 }
            direction = next
        }
        previous = point
        let displacement = hypot(point.x - origin.x, point.y - origin.y)
        let heldThenMoved = time - started > 0.25 && movedAt.map { $0 - started > 0.25 } == true
        let sustained = time - (movedAt ?? time) >= (onHead ? 0.18 : 0.08)
        // On the body a grab starts at once, so Moku comes with the pointer; on the head it waits a moment,
        // since a stroke back and forth there is a pat.
        let grabNow = onHead ? (displacement > 8 && sustained) || (displacement > 3 && heldThenMoved) : displacement > 4
        if !grabbed && reversals == 0 && grabNow { grabbed = true }
        return grabbed
    }
    func end(time: Double) -> Result {
        if grabbed { return .grab }
        if onHead && reversals >= 1 && distance >= 22 && time - started < 3 && abs(previous.y - origin.y) < 40 { return .pat }
        if distance < 7 { return .click }
        if reversals == 0 && hypot(previous.x - origin.x, previous.y - origin.y) > 8 { return .grab }
        return .cancelled
    }
}

/// Moku hanging from where you hold it: a damped pendulum (in stage points) that the hand's sideways
/// acceleration swings. Speed up to the right and the body lags left, then swings through and settles.
struct Dangle: Equatable {
    /// Radians, positive with the body swung to the right of the grip.
    var angle: Double = 0
    var spin: Double = 0
    /// A plush is heavy for its size and stuffed: the hand's pull reaches it softened (`coupling`), the swing
    /// stops softly at `limit` (about 29°), and once set down it settles fast (`settleDamping`).
    static let length = 70.0, gravity = 2400.0, damping = 3.2, settleDamping = 9.0, coupling = 0.45, limit = 0.5
    mutating func step(handAcceleration ax: Double, seconds: Double, damping: Double = Self.damping) {
        var remaining = min(0.1, max(0, seconds))
        while remaining > 0 {
            let dt = min(1.0 / 240, remaining); remaining -= dt
            spin += (-(Self.gravity / Self.length) * sin(angle) - (Self.coupling * ax / Self.length) * cos(angle) - damping * spin) * dt
            angle += spin * dt
            if abs(angle) > Self.limit { angle = angle.sign == .minus ? -Self.limit : Self.limit; spin = 0 }
        }
    }
    var isSettled: Bool { abs(angle) < 0.002 && abs(spin) < 0.01 }
}

/// A throw (Charles, 2026-10-04: "when i throw it around, it should snap to the nearest border where i throwed it,
/// calculate direction"): the companion goes straight on along the line it was thrown, from the hand's speed slowing
/// steadily to a third of it, and meets the edge of the screen that line reaches (`StageGeometry.edge`), arriving with
/// enough speed for a little squash: the snap. It stays there (`StageGrab`). Seated: no gravity, no fall, no walk home.
struct Flick: Equatable {
    let from: CGPoint, to: CGPoint
    /// Seconds, and points per second at the start and on arrival.
    let duration: Double, startSpeed: Double, endSpeed: Double
    var elapsed = 0.0
    /// Radians and radians per second: the tumble, easing off as it goes.
    var tumble: Double, tumbleSpin: Double
    /// The fastest a throw starts, the share of its speed it keeps on arrival, and the shortest and longest flight.
    static let maxSpeed = 2400.0, arrivingShare = 0.35, shortest = 0.16, longest = 0.7
    /// A machine's share of the plush's tumble: a rigid body flies straight, with a slight tilt.
    static let machineSpin = 0.3
    init(from: CGPoint, velocity: CGPoint, xs: ClosedRange<CGFloat>, ys: ClosedRange<CGFloat>, tumble: Double = 0) {
        let speed = min(Self.maxSpeed, Double(hypot(velocity.x, velocity.y)))
        self.from = from; to = StageGeometry.edge(from: from, toward: velocity, xs: xs, ys: ys)
        let distance = Double(hypot(to.x - from.x, to.y - from.y))
        // Slowing evenly from v0 to v1 covers d in 2d / (v0 + v1); kept between bounds (a short flick still reads, a long
        // one doesn't crawl), with the speeds that fit the time.
        duration = min(Self.longest, max(Self.shortest, 2 * distance / max(1, speed * (1 + Self.arrivingShare))))
        startSpeed = 2 * distance / duration / (1 + Self.arrivingShare); endSpeed = startSpeed * Self.arrivingShare
        self.tumble = tumble
        tumbleSpin = speed > 0 ? -Double(velocity.x) / Double(hypot(velocity.x, velocity.y)) * speed / 700 : 0
    }
    var finished: Bool { elapsed >= duration }
    /// Where it is now: the share of the way covered, slowing evenly.
    var position: CGPoint {
        let distance = Double(hypot(to.x - from.x, to.y - from.y))
        guard distance > 0 else { return to }
        let t = min(elapsed, duration)
        let covered = min(1, (startSpeed * t - (startSpeed - endSpeed) * t * t / (2 * duration)) / distance)
        return finished ? to : CGPoint(x: from.x + (to.x - from.x) * covered, y: from.y + (to.y - from.y) * covered)
    }
    mutating func step(seconds: Double) {
        let dt = min(0.1, max(0, seconds))
        elapsed += dt
        tumble += tumbleSpin * dt; tumbleSpin *= exp(-4 * dt); tumble = min(0.6, max(-0.6, tumble))
    }
}

/// A damped spring toward a goal, stepped each frame: how Moku eases into your hand, sways as you drag it and
/// settles when set down, instead of snapping.
struct Spring: Equatable {
    var value: Float = 0
    var velocity: Float = 0
    /// Semi-implicit Euler in short steps, so a late frame can't blow it up.
    mutating func step(toward goal: Float, seconds: Double, stiffness: Float, damping: Float) {
        var remaining = Float(min(0.1, max(0, seconds)))
        while remaining > 0 {
            let dt = min(1 / 240, remaining); remaining -= dt
            velocity += (stiffness * (goal - value) - damping * velocity) * dt
            value += velocity * dt
        }
    }
    func isSettled(at goal: Float) -> Bool { abs(value - goal) < 0.002 && abs(velocity) < 0.01 }
}

/// Stored relative to the usable display, so a resolution or Dock change stays safe, and so does a
/// change of Moku's size: at the side stays at the side.
struct SavedHome: Codable, Equatable {
    let x: Double
    let y: Double
    init(origin: CGPoint, visible: CGRect, scale: CGFloat) {
        let xs = StageGeometry.originsX(in: visible, scale: scale), ys = StageGeometry.originsY(in: visible, scale: scale)
        x = min(1, max(0, (origin.x - xs.lowerBound) / max(1, xs.upperBound - xs.lowerBound)))
        y = min(1, max(0, (origin.y - ys.lowerBound) / max(1, ys.upperBound - ys.lowerBound)))
    }
    func origin(in visible: CGRect, scale: CGFloat) -> CGPoint {
        let xs = StageGeometry.originsX(in: visible, scale: scale), ys = StageGeometry.originsY(in: visible, scale: scale)
        let y = ys.lowerBound + y * (ys.upperBound - ys.lowerBound)
        // Settled like a drop, so a home saved a little short of the side still sits at the side.
        return StageGeometry.settled(CGPoint(x: xs.lowerBound + x * (xs.upperBound - xs.lowerBound), y: y), in: visible, scale: scale)
    }
}
