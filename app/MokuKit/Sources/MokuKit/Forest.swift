import Foundation
import Synchronization

/// How the forest grows with points. One focused minute is worth about one point, so each
/// stage is a visible step on a normal day early on and a real achievement later. Nothing ever shrinks.
public enum ForestStage: Int, Codable, CaseIterable, Sendable, Comparable {
    case seed, sprout, sapling, youngTree, tree, grove, forest, ancientForest

    /// Points needed to reach this stage.
    public var threshold: Double {
        switch self {
        case .seed: 0
        case .sprout: 30
        case .sapling: 120
        case .youngTree: 300
        case .tree: 600
        case .grove: 1_500
        case .forest: 4_000
        case .ancientForest: 10_000
        }
    }

    public static func at(points: Double) -> ForestStage {
        allCases.last { points >= $0.threshold } ?? .seed
    }

    /// Progress from this stage toward the next, 0...1 (1 at the final stage).
    public static func progress(points: Double) -> Double {
        let current = at(points: points)
        guard let next = ForestStage(rawValue: current.rawValue + 1) else { return 1 }
        return min(1, max(0, (points - current.threshold) / (next.threshold - current.threshold)))
    }

    public static func < (lhs: ForestStage, rhs: ForestStage) -> Bool { lhs.rawValue < rhs.rawValue }

    // The home Moku is building (docs/specs/v1.md): the stages keep their thresholds, and each one is a
    // project laid one unit per 10 growth points (about 10 focused minutes).

    public static let pointsPerUnit: Double = 10

    /// The room this stage makes in Moku's home (docs/specs/home.md): the same in the burrow and the treehouse.
    public var homeTitle: String {
        switch self {
        case .seed: "The door"
        case .sprout: "The entry nook"
        case .sapling: "The study"
        case .youngTree: "The kitchen"
        case .tree: "The bedroom"
        case .grove: "The library"
        case .forest: "The garden"
        case .ancientForest: "The observatory"
        }
    }

    /// The room in a sentence ("Moku's making the study").
    public var room: String { homeTitle.prefix(1).lowercased() + homeTitle.dropFirst() }

    /// What each 10 focused minutes adds in this stage, singular and plural.
    public var unitName: (one: String, many: String) {
        switch self {
        case .grove: ("book", "books")
        case .forest: ("plant", "plants")
        case .ancientForest: ("star", "stars")
        default: ("piece for " + (self == .sprout ? "the entry" : room), "pieces")
        }
    }

    /// Units in this stage's project (nil for the open-ended final stage).
    public var unitCount: Int? {
        guard let next = ForestStage(rawValue: rawValue + 1) else { return nil }
        return Int((next.threshold - threshold) / Self.pointsPerUnit)
    }

    public static func units(points: Double) -> Int { Int(max(0, points) / pointsPerUnit) }

    /// Units laid in the current stage's project so far.
    public static func unitsInStage(points: Double) -> Int {
        Int((max(0, points) - at(points: points).threshold) / pointsPerUnit)
    }

    /// The next piece to lay and roughly how many focused minutes away it is.
    public static func nextUnit(points: Double) -> (name: String, minutes: Int) {
        let remaining = pointsPerUnit - max(0, points).truncatingRemainder(dividingBy: pointsPerUnit)
        return (at(points: points).unitName.one, max(1, Int(remaining.rounded(.up))))
    }
}

/// Today's house (assets/src/house_kit.py): 24 pieces, one per 10 focused minutes, finished at 4 hours. Every
/// companion's home has the same pieces in the same stages; only their names differ (Tetsu builds a rocket), set
/// by the visual layer with `use(_:)`.
public enum DayHouse {
    public static let minutesPerPiece = 10.0
    public static let pieces = 24
    public static var goalMinutes: Double { minutesPerPiece * Double(pieces) }
    /// The piece each of the five stages starts at.
    public static let stageStarts = [0, 4, 8, 14, 18]

    /// What a day's home and its parts are called.
    public struct Names: Equatable, Sendable {
        /// "Today’s house".
        public var home: String
        /// The five stages ("The ground"), and the 24 pieces in order ("the stakes and string").
        public var stages: [String]
        public var pieces: [String]
        /// The line once it's finished, when the home has its own.
        public var finished: String?
        public init(home: String, stages: [String], pieces: [String], finished: String? = nil) {
            self.home = home; self.stages = stages; self.pieces = pieces; self.finished = finished
        }
    }
    /// Moku's cottage.
    public static let cottage = Names(home: "Today’s house", stages: ["The ground", "The frame", "The walls", "The roof", "The home"],
                                      pieces: ["the stakes and string", "the stone footings", "the floor joists", "the floor",
                                               "the corner posts", "the top beams", "the rafters", "the ridge beam",
                                               "the back wall", "the left wall", "the right wall", "the front wall", "the round door", "the windows",
                                               "the left roof", "the right roof", "the roof trim", "the chimney",
                                               "the porch", "the flower boxes", "the porch lamp", "the fence", "the garden", "the finishing touches"])
    private static let current = Mutex(cottage)
    /// The names in use: the cottage's, or the chosen companion's home's.
    public static var names: Names { current.withLock { $0 } }
    /// Uses a home's names. Ignored unless there are five stages and a name for every piece.
    public static func use(_ names: Names) {
        guard names.stages.count == stageStarts.count, names.pieces.count == pieces else { return }
        current.withLock { $0 = names }
    }
    /// The five stages and the piece each starts at.
    public static var stages: [(name: String, first: Int)] { zip(names.stages, stageStarts).map { (name: $0, first: $1) } }
    public static var pieceNames: [String] { names.pieces }
    public static func built(_ minutes: Double) -> Int { max(0, min(pieces, Int(minutes / minutesPerPiece))) }
    public static func fraction(_ minutes: Double) -> Double { max(0, min(1, minutes / goalMinutes)) }
    public static func percent(_ minutes: Double) -> Int { Int((fraction(minutes) * 100).rounded(.down)) }
    public static func stage(_ minutes: Double) -> Int { stages.lastIndex { built(minutes) >= $0.first } ?? 0 }
    /// The next piece and the focused minutes until it's up; nil once the house is finished.
    public static func next(_ minutes: Double) -> (name: String, minutes: Int)? {
        let done = built(minutes)
        guard done < pieces else { return nil }
        return (pieceNames[done], max(1, Int((Double(done + 1) * minutesPerPiece - minutes).rounded(.up))))
    }
}
