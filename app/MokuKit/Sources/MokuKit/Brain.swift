import Foundation

// Wire types for the local brain (http://127.0.0.1:8020). Mirrored exactly by brain-go/internal/brain/contract.go.

/// The brain's answer for one sample: what the user is doing, never what Moku should do about it.
public struct Verdict: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        /// On a work thread (possibly one created just now).
        case working
        /// Not work: entertainment, social feeds, unrelated browsing.
        case drifting
        /// No input for a while and nothing changing on screen.
        case away
        /// In a call or sharing the screen: Moku must stay quiet and hidden.
        case meeting
        /// The brain could not decide (model failure). Keep the previous state; never escalate on this.
        case unknown
    }

    public enum Source: String, Codable, Sendable {
        /// `local`: the local model answered because Jev was failing.
        case shortcut, jev, local, override, fallback
    }

    public var sampleId: String
    public var state: State
    public var thread: ThreadRef?
    /// True when this sample started a new thread. Its title may be provisional until Luna names it.
    public var isNewThread: Bool
    public var confidence: Double
    public var source: Source
    public var reason: String
    public var latencyMs: Int
    /// What the person knowingly did, in their words ("learning DSA", "writing the onboarding doc",
    /// "scrolling LinkedIn"). Never judging words like "doomscrolling". Nil for away, meeting and unknown.
    public var activity: String?
    /// The general bucket of `activity`.
    public var category: ActivityCategory?
    /// Set when this screen shows a meaningful piece of work just finished (a push, passing tests, "Accepted").
    public var completion: Completion?
    /// Goal-aware judging only (otherwise nil): the goal this work serves, the same line of work as `thread`.
    /// The drift ladder's line names the last one ("Charles, can we get back to writing the onboarding doc?").
    public var goal: ThreadRef?
    /// Goal-aware judging only: working, but on another goal than the current one (or a new one). Calm, never a
    /// nudge: the engine treats it as working.
    public var isSwitch: Bool

    public init(sampleId: String, state: State, thread: ThreadRef?, isNewThread: Bool, confidence: Double,
                source: Source, reason: String, latencyMs: Int, activity: String? = nil, completion: Completion? = nil,
                category: ActivityCategory? = nil, goal: ThreadRef? = nil, isSwitch: Bool = false) {
        self.sampleId = sampleId
        self.state = state
        self.thread = thread
        self.isNewThread = isNewThread
        self.confidence = confidence
        self.source = source
        self.reason = reason
        self.latencyMs = latencyMs
        self.activity = activity
        self.completion = completion
        self.category = category
        self.goal = goal
        self.isSwitch = isSwitch
    }

    enum CodingKeys: String, CodingKey {
        case sampleId, state, thread, isNewThread, confidence, source, reason, latencyMs, activity, category, completion, goal
        case isSwitch = "switch"
    }

    /// A brain without goal-aware judging sends neither `goal` nor `switch`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sampleId: try c.decode(String.self, forKey: .sampleId), state: try c.decode(State.self, forKey: .state),
                  thread: try c.decodeIfPresent(ThreadRef.self, forKey: .thread), isNewThread: try c.decode(Bool.self, forKey: .isNewThread),
                  confidence: try c.decode(Double.self, forKey: .confidence), source: try c.decode(Source.self, forKey: .source),
                  reason: try c.decode(String.self, forKey: .reason), latencyMs: try c.decode(Int.self, forKey: .latencyMs),
                  activity: try c.decodeIfPresent(String.self, forKey: .activity),
                  completion: try c.decodeIfPresent(Completion.self, forKey: .completion),
                  category: try c.decodeIfPresent(ActivityCategory.self, forKey: .category),
                  goal: try c.decodeIfPresent(ThreadRef.self, forKey: .goal),
                  isSwitch: try c.decodeIfPresent(Bool.self, forKey: .isSwitch) ?? false)
    }
}

/// A meaningful piece of work that just finished, seen on screen.
public struct Completion: Codable, Sendable, Equatable {
    public var kind: CompletionKind
    /// Short, specific and neutral: "pushed auth-flow", "all tests passed", "problem 94 accepted".
    public var label: String

    public init(kind: CompletionKind, label: String) {
        self.kind = kind
        self.label = label
    }
}

public enum CompletionKind: String, Codable, Sendable, CaseIterable {
    case codePushed, testsPassed, prMerged, problemAccepted, deployed, messageSent, documentShipped, other
}

/// The general bucket an activity belongs to. Specific activities ("learning DSA") roll up into these,
/// so patterns stay comparable over weeks. Unknown values from a newer brain decode as `.other`.
public enum ActivityCategory: String, Codable, Sendable, CaseIterable {
    // Focus
    case building, learning, working, communicating, career
    // Drift
    case watching, scrolling, chatting, reading, shopping, playing
    case other

    public var isFocus: Bool { [.building, .learning, .working, .communicating, .career].contains(self) }

    public init(from decoder: Decoder) throws {
        self = ActivityCategory(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

public struct ThreadRef: Codable, Sendable, Hashable {
    public var id: String
    /// Short "Area · Topic" name, e.g. "DSA · Trees".
    public var title: String
    /// True while the title is still a placeholder taken from the screen; Luna's real name
    /// arrives a few seconds later on a later verdict for the same id. Don't announce a placeholder.
    public var provisional: Bool

    public init(id: String, title: String, provisional: Bool = false) {
        self.id = id
        self.title = title
        self.provisional = provisional
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        provisional = try container.decodeIfPresent(Bool.self, forKey: .provisional) ?? false
    }
}

public struct ThreadSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    public var focusMinutesToday: Int
    public var focusMinutesTotal: Int
    public var lastActiveAt: Date
    public var category: ActivityCategory?

    public init(id: String, title: String, summary: String, focusMinutesToday: Int, focusMinutesTotal: Int, lastActiveAt: Date,
                category: ActivityCategory? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.focusMinutesToday = focusMinutesToday
        self.focusMinutesTotal = focusMinutesTotal
        self.lastActiveAt = lastActiveAt
        self.category = category
    }
}

/// POST /v1/voice: ask Luna for one short line in Moku's voice.
public struct VoiceRequest: Codable, Sendable, Equatable {
    public var kind: VoiceKind
    public var userName: String
    public var threadTitle: String?
    public var focusMinutes: Int?
    public var driftMinutes: Int?
    /// What the user drifted to, e.g. "YouTube".
    public var distraction: String?
    /// What's being added to the home, for next-piece nudges ("the next book").
    public var nextUnit: String?
    public var minutesToNextUnit: Int?
    /// For `celebrate` after a completion: what was finished ("pushed auth-flow").
    public var completionLabel: String?

    public init(kind: VoiceKind, userName: String, threadTitle: String? = nil, focusMinutes: Int? = nil,
                driftMinutes: Int? = nil, distraction: String? = nil, nextUnit: String? = nil, minutesToNextUnit: Int? = nil,
                completionLabel: String? = nil) {
        self.kind = kind
        self.userName = userName
        self.threadTitle = threadTitle
        self.focusMinutes = focusMinutes
        self.driftMinutes = driftMinutes
        self.distraction = distraction
        self.nextUnit = nextUnit
        self.minutesToNextUnit = minutesToNextUnit
        self.completionLabel = completionLabel
    }
}

public enum VoiceKind: String, Codable, Sendable, CaseIterable {
    /// Long drift, first words: "Hey, weren't we working on the auth flow?"
    case nudge
    /// Stronger threshold: just the name, "Charles."
    case callName
    /// Remind how well it was going: "You were focused for 47 minutes."
    case remindFocus
    /// "Come on, finish this first."
    case comeOn
    /// Back to work after a nudge.
    case welcomeBack
    /// Meaningful work finished.
    case celebrate
    /// Long focused stretch.
    case proud
    case water, stretch, lookAway, walk
    /// First appearance of the day.
    case greeting
}

public struct VoiceLine: Codable, Sendable, Equatable {
    public var text: String
    /// "luna" or "template" (the fallback when Luna is slow or unavailable).
    public var source: String

    public init(text: String, source: String) {
        self.text = text
        self.source = source
    }
}

/// POST /v1/feedback: the user's reactions, which teach the brain what counts as work.
public struct Feedback: Codable, Sendable, Equatable {
    public var ts: Date
    public var kind: FeedbackKind
    public var sampleId: String?
    public var threadId: String?
    /// For Today-window corrections: the segments the person relabeled.
    public var segmentIds: [String]?
    /// For a correction from the companion's right-click: every moment from then until `ts` is relabeled.
    public var since: Date?

    public init(ts: Date, kind: FeedbackKind, sampleId: String? = nil, threadId: String? = nil, segmentIds: [String]? = nil,
                since: Date? = nil) {
        self.ts = ts
        self.kind = kind
        self.sampleId = sampleId
        self.threadId = threadId
        self.segmentIds = segmentIds
        self.since = since
    }
}

public enum FeedbackKind: String, Codable, Sendable {
    /// Pat on the head: "this is fine" — the current app/window counts as work from now on.
    case pat
    /// Came back to work within a short time after a nudge (the nudge was right).
    case returnedAfterNudge
    /// Stayed on the "distraction" long after a nudge (weak signal that it may have been work).
    case ignoredNudge
    /// Today window: "This was work" / "This wasn't work" on a row. The brain treats that context accordingly from now on.
    case markedWork, markedNotWork
}

/// POST /v1/events: what Moku did and what the user earned. The brain logs these and derives the world from them.
public struct CompanionEvent: Codable, Sendable, Equatable {
    public var ts: Date
    public var type: CompanionEventType
    public var threadId: String?
    /// Growth points for growth events; seconds for durations; otherwise nil.
    public var value: Double?

    public init(ts: Date, type: CompanionEventType, threadId: String? = nil, value: Double? = nil) {
        self.ts = ts
        self.type = type
        self.threadId = threadId
        self.value = value
    }
}

public enum CompanionEventType: String, Codable, Sendable, CaseIterable {
    /// Growth from a focused minute (value = points).
    case focusGrowth
    /// Growth from coming back after a short drift (value = points).
    case returnGrowth
    case shortDrift, longDriftStarted, nudged, approached, calledName, annoyed, returned
    case celebrated, breakSuggested, patted
    /// Meaningful work finished (value nil; see the verdict's completion).
    case completed
    /// Tea break started / ended (value = seconds for ended).
    case breakStarted, breakEnded
    /// A new forest stage was reached (value = stage raw value).
    case milestone
}

/// GET /v1/world: everything the world dropdown shows.
public struct WorldSnapshot: Codable, Sendable, Equatable {
    public var growthPoints: Double
    public var todayFocusMinutes: Int
    public var todayReturns: Int
    public var longestFocusMinutesToday: Int
    public var threads: [ThreadSummary]
    /// Home pieces laid today (one per 10 growth points earned today).
    public var unitsToday: Int
    /// The returns since yesterday's midnight, oldest first (nothing shows them now; the brain used to send every one
    /// ever made, and reading them all took seconds and hundreds of MB after months of use).
    public var stones: [StoneMemory]
    /// All focused minutes ever. Every focused hour plants a tree in Moku's forest.
    public var focusMinutesAllTime: Int

    public init(growthPoints: Double, todayFocusMinutes: Int, todayReturns: Int, longestFocusMinutesToday: Int,
                threads: [ThreadSummary], unitsToday: Int = 0, stones: [StoneMemory] = [], focusMinutesAllTime: Int = 0) {
        self.growthPoints = growthPoints
        self.todayFocusMinutes = todayFocusMinutes
        self.todayReturns = todayReturns
        self.longestFocusMinutesToday = longestFocusMinutesToday
        self.threads = threads
        self.unitsToday = unitsToday
        self.stones = stones
        self.focusMinutesAllTime = focusMinutesAllTime
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        growthPoints = try c.decode(Double.self, forKey: .growthPoints)
        todayFocusMinutes = try c.decode(Int.self, forKey: .todayFocusMinutes)
        todayReturns = try c.decode(Int.self, forKey: .todayReturns)
        longestFocusMinutesToday = try c.decode(Int.self, forKey: .longestFocusMinutesToday)
        threads = try c.decode([ThreadSummary].self, forKey: .threads)
        unitsToday = try c.decodeIfPresent(Int.self, forKey: .unitsToday) ?? 0
        stones = try c.decodeIfPresent([StoneMemory].self, forKey: .stones) ?? []
        focusMinutesAllTime = try c.decodeIfPresent(Int.self, forKey: .focusMinutesAllTime) ?? 0
    }

    public var stage: ForestStage { ForestStage.at(points: growthPoints) }
    /// Home pieces laid in total.
    public var unitsTotal: Int { ForestStage.units(points: growthPoints) }
    /// Trees in Moku's forest: one per focused hour, ever.
    public var trees: Int { focusMinutesAllTime / 60 }
    /// Focused minutes toward the next tree.
    public var minutesToNextTree: Int { 60 - focusMinutesAllTime % 60 }

    public static let empty = WorldSnapshot(growthPoints: 0, todayFocusMinutes: 0, todayReturns: 0, longestFocusMinutesToday: 0, threads: [])
}

/// One return, remembered as a stone on the path home.
public struct StoneMemory: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var ts: Date
    public var driftSeconds: Int
    /// Where the person came back from: an app name or site ("x.com").
    public var from: String
    /// Focus that followed the return, until the next drift.
    public var followingFocusMinutes: Int
    public var threadTitle: String?

    public init(id: String, ts: Date, driftSeconds: Int, from: String, followingFocusMinutes: Int, threadTitle: String? = nil) {
        self.id = id
        self.ts = ts
        self.driftSeconds = driftSeconds
        self.from = from
        self.followingFocusMinutes = followingFocusMinutes
        self.threadTitle = threadTitle
    }
}

/// One day's totals, for the Today window's strip of days (GET /v1/days).
public struct DayTotals: Codable, Sendable, Equatable, Identifiable {
    /// Local date, YYYY-MM-DD.
    public var date: String
    public var focusedMinutes: Int
    public var longestFocusMinutes: Int
    public var returns: Int
    /// Returns after a drift of a minute or more: each lights a lantern in Moku's home.
    public var lanterns: Int
    /// Pieces added to Moku's home that day.
    public var pieces: Int
    public var id: String { date }
    public init(date: String, focusedMinutes: Int, longestFocusMinutes: Int = 0, returns: Int = 0, lanterns: Int = 0, pieces: Int = 0) {
        self.date = date; self.focusedMinutes = focusedMinutes; self.longestFocusMinutes = longestFocusMinutes
        self.returns = returns; self.lanterns = lanterns; self.pieces = pieces
    }
}

/// GET /v1/days: every day in the range, oldest first, and the first day with any data (nil before any).
public struct DaysResponse: Codable, Sendable, Equatable {
    public var firstDay: String?
    public var days: [DayTotals]
    public init(firstDay: String?, days: [DayTotals]) { self.firstDay = firstDay; self.days = days }
}

/// GET /v1/today: the Today window.
public struct TodaySummary: Codable, Sendable, Equatable {
    /// Local date, YYYY-MM-DD.
    public var date: String
    /// Moku's note about the day: at most 2 sentences, first person, warm, never scolding. Nil early in the day.
    public var note: String?
    public var focusedMinutes: Int
    public var longestFocusMinutes: Int
    public var returns: Int
    public var unitsToday: Int
    /// The timeline, in order: every state change with what was on screen.
    public var segments: [DaySegment]
    /// Work, grouped by app/site and activity, longest first.
    public var built: [ActivityRow]
    /// Drifts of at least 2 minutes, grouped the same way, longest first.
    public var wandered: [ActivityRow]
    /// Drift rows under 2 minutes folded together ("a few quick checks").
    public var quickCheckMinutes: Int
    public var comebacks: [StoneMemory]
    /// The return followed by the longest focus (ties: the shorter drift).
    public var bestComeback: StoneMemory?
    public var completions: [CompletionMoment]
    /// Minutes per bucket, focus buckets first, each group longest first.
    public var byCategory: [CategoryTotal]
    /// The day by goal: longest first, "Other work" last. Their minutes add up to `focusedMinutes`, give or take rounding.
    public var goals: [GoalDay]

    public init(date: String, note: String?, focusedMinutes: Int, longestFocusMinutes: Int, returns: Int, unitsToday: Int,
                segments: [DaySegment], built: [ActivityRow], wandered: [ActivityRow], quickCheckMinutes: Int,
                comebacks: [StoneMemory], bestComeback: StoneMemory?, completions: [CompletionMoment], byCategory: [CategoryTotal] = [],
                goals: [GoalDay] = []) {
        self.date = date
        self.note = note
        self.focusedMinutes = focusedMinutes
        self.longestFocusMinutes = longestFocusMinutes
        self.returns = returns
        self.unitsToday = unitsToday
        self.segments = segments
        self.built = built
        self.wandered = wandered
        self.quickCheckMinutes = quickCheckMinutes
        self.comebacks = comebacks
        self.bestComeback = bestComeback
        self.completions = completions
        self.byCategory = byCategory
        self.goals = goals
    }
}

/// One goal on Your day (the brain's goals.go), shown as a task: its minutes, the apps it used and what was done in each,
/// its workflow and steps, its longest stretch, the detours that left it and came back, and a line about the work
/// (Luna's, or made from what was done).
public struct GoalDay: Codable, Sendable, Equatable, Identifiable {
    /// The thread's id, or "other" for work without a goal.
    public var id: String
    public var title: String
    public var summary: String?
    public var minutes: Int
    public var longestMinutes: Int
    public var apps: [GoalApp]
    public var detours: Int
    public var detourMinutes: Int
    /// Where most of the detours went.
    public var detourPlace: String?
    public var firstAt: Date
    public var lastAt: Date
    /// How the work went: its apps in the order the work reached them, and the detours where they happened.
    public var workflow: [WorkflowStep]
    /// The separate stretches of the day it was worked on (half an hour apart or more).
    public var sittings: Int
    /// What was done, in plain words, in order ("edited Today.swift", "ran swift test"). Only shown on the Mac.
    public var steps: [String]
    public var isOther: Bool { id == "other" }

    public init(id: String, title: String, summary: String? = nil, minutes: Int, longestMinutes: Int = 0, apps: [GoalApp] = [],
                detours: Int = 0, detourMinutes: Int = 0, detourPlace: String? = nil, firstAt: Date = Date(), lastAt: Date = Date(),
                workflow: [WorkflowStep] = [], sittings: Int = 1, steps: [String] = []) {
        self.id = id; self.title = title; self.summary = summary; self.minutes = minutes; self.longestMinutes = longestMinutes
        self.apps = apps; self.detours = detours; self.detourMinutes = detourMinutes; self.detourPlace = detourPlace
        self.firstAt = firstAt; self.lastAt = lastAt; self.workflow = workflow; self.sittings = sittings; self.steps = steps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary); minutes = try c.decode(Int.self, forKey: .minutes)
        longestMinutes = try c.decode(Int.self, forKey: .longestMinutes); apps = try c.decode([GoalApp].self, forKey: .apps)
        detours = try c.decode(Int.self, forKey: .detours); detourMinutes = try c.decode(Int.self, forKey: .detourMinutes)
        detourPlace = try c.decodeIfPresent(String.self, forKey: .detourPlace)
        firstAt = try c.decode(Date.self, forKey: .firstAt); lastAt = try c.decode(Date.self, forKey: .lastAt)
        // A brain from before Your day by task leaves these out.
        workflow = try c.decodeIfPresent([WorkflowStep].self, forKey: .workflow) ?? []
        sittings = try c.decodeIfPresent(Int.self, forKey: .sittings) ?? 1
        steps = try c.decodeIfPresent([String].self, forKey: .steps) ?? []
    }
}

/// One link of a goal's workflow: one of its apps (`appId` is the GoalApp's id) with its minutes, or the detours that
/// left the goal and came back at that point (`count` of them, `minutes` in all, most of it at `place`).
public struct WorkflowStep: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case app, detour }
    public var kind: Kind
    public var appId: String
    public var minutes: Int
    public var count: Int
    public var place: String?

    public init(kind: Kind, appId: String = "", minutes: Int, count: Int = 0, place: String? = nil) {
        self.kind = kind; self.appId = appId; self.minutes = minutes; self.count = count; self.place = place
    }
    public static func app(_ id: String, _ minutes: Int) -> WorkflowStep { WorkflowStep(kind: .app, appId: id, minutes: minutes) }
    public static func detour(_ place: String, _ minutes: Int, count: Int = 1) -> WorkflowStep { WorkflowStep(kind: .detour, minutes: minutes, count: count, place: place) }
}

/// An app (or a site, in a browser) a goal used: its minutes, what was done there and its windows' titles (both
/// longest first; titles are shown only to the person), and the segments a correction applies to.
public struct GoalApp: Codable, Sendable, Equatable, Identifiable {
    public var app: String
    public var bundleId: String
    public var host: String?
    /// What Your day calls it: the app's name, or the site's ("Stripe docs", "GitHub", else its host).
    public var name: String
    public var minutes: Int
    public var activities: [String]
    public var titles: [String]
    public var segmentIds: [String]
    /// When the goal's work first came to it for a minute or more.
    public var firstAt: Date?
    public var id: String { host.map { "site:\($0)" } ?? "app:\(bundleId)" }

    public init(app: String, bundleId: String, host: String? = nil, name: String? = nil, minutes: Int, activities: [String] = [], titles: [String] = [],
                segmentIds: [String] = [], firstAt: Date? = nil) {
        self.app = app; self.bundleId = bundleId; self.host = host; self.name = name ?? host ?? app; self.minutes = minutes
        self.activities = activities; self.titles = titles; self.segmentIds = segmentIds; self.firstAt = firstAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decode(String.self, forKey: .app); bundleId = try c.decode(String.self, forKey: .bundleId)
        host = try c.decodeIfPresent(String.self, forKey: .host); minutes = try c.decode(Int.self, forKey: .minutes)
        activities = try c.decode([String].self, forKey: .activities); titles = try c.decode([String].self, forKey: .titles)
        segmentIds = try c.decode([String].self, forKey: .segmentIds)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? host ?? app
        firstAt = try c.decodeIfPresent(Date.self, forKey: .firstAt)
    }
}

public struct DaySegment: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var start: Date
    public var end: Date
    public var state: Verdict.State
    public var app: String
    public var bundleId: String
    public var host: String?
    public var threadId: String?
    public var activity: String?
    public var category: ActivityCategory?

    public init(id: String, start: Date, end: Date, state: Verdict.State, app: String, bundleId: String,
                host: String? = nil, threadId: String? = nil, activity: String? = nil, category: ActivityCategory? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.state = state
        self.app = app
        self.bundleId = bundleId
        self.host = host
        self.threadId = threadId
        self.activity = activity
        self.category = category
    }
}

/// One Today row: app or site · activity · duration.
public struct ActivityRow: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// App name, or the site for browsers ("LinkedIn", "x.com").
    public var app: String
    public var bundleId: String
    public var host: String?
    public var activity: String
    public var minutes: Int
    public var segmentIds: [String]
    public var category: ActivityCategory?

    public init(id: String, app: String, bundleId: String, host: String? = nil, activity: String, minutes: Int, segmentIds: [String],
                category: ActivityCategory? = nil) {
        self.id = id
        self.app = app
        self.bundleId = bundleId
        self.host = host
        self.activity = activity
        self.minutes = minutes
        self.segmentIds = segmentIds
        self.category = category
    }
}

/// Minutes per bucket for a day ("Learning 1h 20m · Building 2h 10m · Watching 25m").
public struct CategoryTotal: Codable, Sendable, Equatable {
    public var category: ActivityCategory
    public var minutes: Int

    public init(category: ActivityCategory, minutes: Int) {
        self.category = category
        self.minutes = minutes
    }
}

public struct CompletionMoment: Codable, Sendable, Equatable {
    public var ts: Date
    public var kind: CompletionKind
    public var label: String
    public var threadTitle: String?

    public init(ts: Date, kind: CompletionKind, label: String, threadTitle: String? = nil) {
        self.ts = ts
        self.kind = kind
        self.label = label
        self.threadTitle = threadTitle
    }
}

/// GET /v1/config: every timing lives here so it can be tuned without rebuilding the app.
public struct CompanionConfig: Codable, Sendable, Equatable {
    public var userName: String
    public var sampleIntervalSec: Double
    /// No input and no screen change for this long means away.
    public var awayAfterIdleSec: Double
    /// Drifts up to this long are "short": the focus streak survives and coming back earns growth.
    public var shortDriftMaxSec: Double
    /// The drift ladder (BehaviorLadder.swift): sad and looking at the user after `graceSec`, angry after
    /// `annoyedAfterSec`, standing up a little red after `standUpAfterSec`, and after `askAfterSec`
    /// asking the user to focus, where it stands.
    public var annoyedAfterSec: Double
    public var standUpAfterSec: Double
    public var askAfterSec: Double
    /// During continuous focus, look up at the user and smile every this many seconds of focus.
    public var smileEverySec: Double
    /// Take a long, quiet drink of water every this many seconds of focus (a reminder by example, no words).
    /// 0 turns it off, and leaves water out of the break suggestions.
    public var drinkEverySec: Double
    public var proudAfterSec: Double
    /// Suggest water, a stretch, looking away or a walk after this much continuous work. 0 turns suggestions off.
    public var breakAfterSec: Double
    /// A working or drifting verdict counts as evidence for this long; stale evidence freezes focus and drift clocks.
    public var evidenceWindowSec: Double
    /// Time in the away state before it is a long away: sleepy, back home, streaks reset.
    public var longAwaySec: Double
    /// Still drifting this long after the ask to focus sends `ignoredNudge` feedback once.
    public var ignoredNudgeAfterSec: Double
    /// Announce a thread's label again when returning to it after this long without working on it.
    public var threadLabelGapSec: Double
    /// A tea break is not drift for up to this long.
    public var teaBreakMaxSec: Double
    /// Drifts shorter than this change nothing: no lantern change, no glance, no return.
    public var graceSec: Double
    /// Who keeps the person company (moku or tetsu), so the brain's notes name that companion's home and its
    /// pieces. Nil from a brain that predates companions.
    public var companion: String?

    public init(userName: String, sampleIntervalSec: Double, awayAfterIdleSec: Double, shortDriftMaxSec: Double,
                annoyedAfterSec: Double, standUpAfterSec: Double, askAfterSec: Double,
                smileEverySec: Double, proudAfterSec: Double, breakAfterSec: Double,
                evidenceWindowSec: Double, longAwaySec: Double,
                ignoredNudgeAfterSec: Double, threadLabelGapSec: Double, teaBreakMaxSec: Double,
                graceSec: Double, drinkEverySec: Double = 1800, companion: String? = nil) {
        self.companion = companion
        self.userName = userName
        self.sampleIntervalSec = sampleIntervalSec
        self.awayAfterIdleSec = awayAfterIdleSec
        self.shortDriftMaxSec = shortDriftMaxSec
        self.annoyedAfterSec = annoyedAfterSec
        self.standUpAfterSec = standUpAfterSec
        self.askAfterSec = askAfterSec
        self.smileEverySec = smileEverySec
        self.drinkEverySec = drinkEverySec
        self.proudAfterSec = proudAfterSec
        self.breakAfterSec = breakAfterSec
        self.evidenceWindowSec = evidenceWindowSec
        self.longAwaySec = longAwaySec
        self.ignoredNudgeAfterSec = ignoredNudgeAfterSec
        self.threadLabelGapSec = threadLabelGapSec
        self.teaBreakMaxSec = teaBreakMaxSec
        self.graceSec = graceSec
    }

    public static let standard = CompanionConfig(
        userName: "friend", sampleIntervalSec: 3, awayAfterIdleSec: 300, shortDriftMaxSec: 120,
        annoyedAfterSec: 60, standUpAfterSec: 240, askAfterSec: 600,
        smileEverySec: 60, proudAfterSec: 2700, breakAfterSec: 3000,
        evidenceWindowSec: 60, longAwaySec: 600,
        ignoredNudgeAfterSec: 600, threadLabelGapSec: 1800, teaBreakMaxSec: 1200,
        graceSec: 1
    )
}

/// PUT /v1/config from Settings: only the fields being changed (nil fields are left out of the JSON).
public struct CompanionConfigPatch: Codable, Sendable, Equatable {
    public var drinkEverySec: Double?
    /// How long "Take a break" lasts.
    public var teaBreakMaxSec: Double?
    /// What Moku calls the person.
    public var userName: String?
    /// After this much focus Moku suggests a break.
    public var breakAfterSec: Double?
    /// The companion on show (the app sets it when it changes).
    public var companion: String?

    // The drift ladder's four timings (graceSec, annoyedAfterSec, standUpAfterSec, askAfterSec) were Settings' drift
    // pace, and smileEverySec how often it looks up and smiles. There is one behaviour now, and the brain refuses them,
    // so a patch can't carry them.
    public init(drinkEverySec: Double? = nil, teaBreakMaxSec: Double? = nil,
                userName: String? = nil, breakAfterSec: Double? = nil, companion: String? = nil) {
        self.companion = companion
        self.drinkEverySec = drinkEverySec
        self.teaBreakMaxSec = teaBreakMaxSec
        self.userName = userName
        self.breakAfterSec = breakAfterSec
    }
}

/// JSON coders matching the brain: camelCase keys, dates as whole epoch milliseconds.
public enum MokuJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Whole milliseconds: `.millisecondsSince1970` writes fractions (e.g. 1790000000123.456),
        // which the brain's integer schema rejects.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
