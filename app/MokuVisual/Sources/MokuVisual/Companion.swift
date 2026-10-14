import Foundation
import MokuKit
import Synchronization

/// Who keeps you company (docs/specs/moku-and-friends.md): Moku the bunny or Tetsu the desk robot (Yuzu the cat was
/// retired on 2026-10-04; a saved choice of her falls back to Moku). Each is a whole world: its character in `assets/character/<id>/` and its day's home in `assets/world/<id>/`. Moku's are
/// today's paths (`character/`, `world/dayhouse/`). MokuMind never knows which one it is.
///
/// A companion is offered only when its character is bundled. Its home falls back to the cottage until that's bundled
/// too, so a build with only Moku looks exactly as before.
public enum Companion: String, CaseIterable, Identifiable, Sendable {
    case moku, tetsu
    public var id: Self { self }
    public var name: String { rawValue.capitalized }
    /// What it is, in a word or two (the welcome and Settings).
    public var kind: String {
        switch self { case .moku: "bunny"; case .tetsu: "desk robot" }
    }
    /// How far its wave reaches left and right of its centre, in stage points (the demo's --wave-check): Moku's raised
    /// paw and swinging lop ear go well past its body (`StageGeometry.bodyLeft` 48, `bodyRight` 60).
    var waveReach: (left: CGFloat, right: CGFloat) {
        switch self { case .moku: (78, 81); case .tetsu: (40, 61) }
    }
    /// Your day's first line before anything has happened: what the companion does meanwhile.
    var emptyDayLine: String { self == .tetsu ? "Nothing yet. Tetsu’s warming up." : "Nothing yet. Moku’s got the kettle on." }
    /// Manga marks (symbols/) this companion draws on itself instead: Tetsu's visor shows its own "z" when it dozes.
    var ownMarks: Set<String> { self == .tetsu ? ["zzz"] : [] }
    /// The character's model: the file whose presence makes the companion available.
    var modelPath: String { self == .moku ? "character/moku_bunny.usdz" : "character/\(rawValue)/\(rawValue).usdz" }
    var isBundled: Bool { MokuAssets.exists(modelPath) }
    /// The day's home: the companion's own once it's bundled, otherwise the cottage.
    var homeLayoutPath: String { homeKey == rawValue ? "world/\(rawValue)/layout.json" : "world/dayhouse/layout.json" }
    /// The layout's key for the home (and the folder its pieces are in).
    var homeKey: String { self != .moku && MokuAssets.exists("world/\(rawValue)/layout.json") ? rawValue : "dayhouse" }

    /// A character file for this companion. Moku's are where they always were; another companion's live in its own
    /// folder with the same names, and its model is `<id>.usdz`. Nothing falls back to Moku's: a companion's clips,
    /// poses and props only fit its own skeleton. Paths outside `character/`, or already in a companion's folder, are
    /// left as they are.
    func resolve(_ path: String) -> String {
        guard self != .moku, path.hasPrefix("character/") else { return path }
        let rest = path.dropFirst("character/".count)
        if let folder = rest.split(separator: "/", maxSplits: 1).first, rest.contains("/"), Companion(rawValue: String(folder)) != nil { return path }
        if path == Companion.moku.modelPath { return modelPath }
        return "character/\(rawValue)/\(rest)"
    }

    /// The companions this build can show, Moku first. Moku is always offered (without its files the stand-in plays).
    public static var available: [Companion] { allCases.filter { $0 == .moku || $0.isBundled } }
    /// Whether there's a choice to make: the welcome's question and Settings' picker show only then.
    public static var hasChoice: Bool { available.count > 1 }
    /// The companion on show: the chosen one while it's bundled, Moku otherwise.
    public static var current: Companion {
        let chosen = CompanionChoice.chosen
        return chosen == .moku || chosen.isBundled ? chosen : .moku
    }
}

extension Notification.Name {
    /// The companion changed (Settings, the welcome): the character and the day's home load again.
    public static let mokuCompanionChanged = Notification.Name("MokuVisual.companionChanged")
}

/// Which companion the person chose, kept in UserDefaults (`MokuVisual.companion`). Checks keep it in memory instead:
/// the demo shares its defaults with the real Moku, so it must never write the choice there. `MOKU_COMPANION=<id>` in
/// the environment starts a process with that companion, in memory.
public enum CompanionChoice {
    static let key = "MokuVisual.companion"
    private struct State { var inMemory: Bool; var value: Companion? }
    private static let state: Mutex<State> = {
        let pinned = ProcessInfo.processInfo.environment["MOKU_COMPANION"]
        return Mutex(State(inMemory: pinned != nil, value: pinned.flatMap(Companion.init(rawValue:))))
    }()

    /// The choice as saved (Moku when nothing is).
    public static var chosen: Companion {
        state.withLock { state in
            state.inMemory ? state.value : UserDefaults.standard.string(forKey: key).flatMap(Companion.init(rawValue:))
        } ?? .moku
    }
    /// From now on the choice lives only in this process (checks and the demo).
    public static func keepInMemory(starting companion: Companion? = nil) {
        state.withLock { state in
            if !state.inMemory { state = State(inMemory: true, value: companion ?? state.value) } else if let companion { state.value = companion }
        }
    }
    /// Chooses a companion. When the one on show changes, the character and the home load again.
    @MainActor public static func choose(_ companion: Companion) {
        let before = Companion.current
        state.withLock { state in
            if state.inMemory { state.value = companion } else { UserDefaults.standard.set(companion.rawValue, forKey: key) }
        }
        guard Companion.current != before else { return }
        DayHouse.useNames(of: .current)  // before anyone redraws: the popover, Your day and MokuMind's lines
        NotificationCenter.default.post(name: .mokuCompanionChanged, object: nil)
    }
}
