import Foundation
import MokuKit
import MokuMind

/// The sessions: a writer, a designer, a coder, a student, back-to-back calls, dictation, research that looks like
/// browsing, real drifts, and the stress levels (docs/specs/launch-qa.md, lens 2). Each is a list of beats: where the person
/// is, for how long, how their hands move, and what they are really doing (the catalogue says by default).
enum Personas {
    static var all: [Session] {
        [writer, designer, coder, student, meetings, dictation, research, drifts, daywithbreaks, midnight, sleepAcrossMidnight, overlap]
            + stressSwitching + [soak] + network + [pat]
    }

    static func named(_ names: [String]) -> [Session] {
        names.isEmpty ? all : all.filter { names.contains($0.name) }
    }

    // MARK: The five people

    static let writer = Session(name: "writer", summary: "A magazine essay on the printing press: long typing, research tabs, a song, two real detours, lunch.",
                                date: "2026-09-21", start: "09:00", beats: [
        B.work("w-docs", 14), B.work("w-wiki", 3, .reading), B.work("w-docs", 8),
        B.work("w-search", 1.5, .browsing), B.work("w-cambridge", 4, .reading), B.work("w-docs", 12),
        B.work("w-nyt", 3, .reading), B.work("w-docs", 10),
        B.glance("w-thesaurus", 25, .browsing, truth: .work), B.work("w-docs", 6),
        B.glance("w-spotify", 12, .browsing), B.work("w-docs", 15),
        B.work("w-yt-lecture", 8, .watching), B.work("w-notion", 6, .editing),
        B.work("w-reddit-ask", 2, .reading), B.work("w-docs", 10),
        B.work("w-slack", 1.5, .editing), B.work("w-gmail", 2, .browsing),
        B.drift("w-x-home", 4), B.work("w-docs", 10),
        B.glance("w-bbc-front", 25, truth: .drift), B.work("w-docs", 3),
        B.work("w-substack", 5, .reading), B.work("w-docs", 20),
        B.work("w-hemingway", 4, .editing), B.work("w-preview", 5, .reading), B.work("w-docs", 12),
        B.drift("w-ig-feed", 8), B.work("w-docs", 10),
        B.lock(40), B.work("w-docs", 25),
    ])

    static let designer = Session(name: "designer", summary: "A coffee roaster's brand: Figma and Photoshop, reference sites and image boards, a tutorial, crit in Slack.",
                                  date: "2026-09-22", start: "09:30", beats: [
        B.work("d-figma", 20, .editing), B.work("d-pinterest", 4, .browsing), B.work("d-figma", 12, .editing),
        B.work("d-ps", 15, .editing), B.work("d-dribbble", 3, .browsing), B.work("d-behance", 3, .browsing),
        B.work("d-ps", 10, .editing), B.work("d-gfonts", 2, .browsing), B.work("d-coolors", 3, .browsing),
        B.work("d-figma", 14, .editing), B.work("d-yt-tut", 9, .watching), B.work("d-figma", 18, .editing),
        B.work("d-dribbble-home", 3, .browsing), B.work("d-awwwards", 3, .browsing), B.work("d-arena", 3, .browsing),
        B.work("d-sketch", 12, .editing), B.work("d-slack", 2, .editing), B.work("d-ai", 15, .editing),
        B.work("d-ig-studio", 3, .browsing), B.work("d-canva", 6, .editing), B.work("d-blender", 20, .editing),
        B.drift("d-yt-home", 5), B.work("d-figma", 12, .editing),
        B.lock(35), B.work("d-figma", 25, .editing), B.work("d-pinterest", 6, .browsing), B.work("d-ps", 20, .editing),
    ])

    static let coder = Session(name: "coder", summary: "A Go rate limiter: editor, terminal, docs, Stack Overflow, GitHub, an AI chat, a Hacker News thread, lunch.",
                               date: "2026-09-23", start: "09:30", beats: [
        B.work("c-cursor", 18), B.work("c-term", 2, .editing), B.work("c-cursor", 10), B.work("c-so", 2, .reading),
        B.work("c-cursor", 14), B.work("c-gh-pr", 4, .reading), B.work("c-cursor", 8), B.work("c-claude", 6, .editing),
        B.work("c-cursor", 15), B.work("c-mdn", 3, .reading), B.work("c-cursor", 12), B.work("c-localhost", 3, .browsing),
        B.work("c-term", 3, .editing), B.work("c-cursor", 10), B.work("c-sentry", 3, .reading), B.work("c-slack", 2, .editing),
        B.work("c-hn-item", 4, .reading), B.work("c-cursor", 12), B.work("c-reddit-golang", 3, .reading),
        B.work("c-cursor", 10), B.drift("c-hn-front", 3), B.work("c-cursor", 8), B.work("c-yt-talk", 12, .watching),
        B.work("c-obsidian", 5, .editing), B.work("c-pkggo", 2, .reading), B.work("c-cursor", 20),
        B.work("c-alacritty", 15), B.work("c-medium", 4, .reading), B.work("c-leetcode", 10, .editing),
        B.lock(35), B.work("c-cursor", 25),
    ])

    static let student = Session(name: "student", summary: "Organic chemistry and CS 101: a PDF, a lecture video, notes, flashcards, a Zoom lecture, a chat with friends.",
                                 date: "2026-09-24", start: "10:00", beats: [
        B.work("s-pdfexpert", 15, .reading), B.work("s-notes", 8), B.work("s-yt-mit", 30, .watching), B.work("s-notes", 10),
        B.work("s-anki", 8, .editing), B.work("s-canvas", 2, .browsing), B.work("s-quizlet", 10, .browsing),
        B.work("s-obsidian", 12), B.work("s-coursera", 20, .watching), B.work("s-scholar", 4, .reading),
        B.work("s-overleaf", 15), B.work("s-preview-pdf", 10, .reading), B.work("s-wolfram", 3, .browsing),
        B.work("s-zoom-lecture", 45, .slides), B.work("s-whatsapp-class", 2, .editing), B.work("s-discord-study", 6, .editing),
        B.drift("r-whatsapp-friends", 6, .editing), B.work("s-obsidian", 10), B.drift("r-yt-gaming", 15, .watching),
        B.work("s-obsidian", 20), B.work("s-yt-crash", 12, .watching), B.work("s-zotero", 5, .browsing), B.work("s-word", 20),
    ])

    // MARK: Calls, dictation, research, drifts

    static let meetings = Session(name: "meetings", summary: "A manager's morning: calendar, Zoom, Meet, Teams, a Slack huddle, a screen share, a listen-only all-hands, a muted Meet tab.",
                                  date: "2026-09-25", start: "10:00", beats: [
        B.work("m-gcal", 2, .browsing), B.call("m-zoom", 25), B.work("c-slack", 2, .editing), B.work("m-gmail", 3, .browsing),
        B.call("m-meet", 45), B.work("m-gmail", 2, .browsing), B.call("m-teams", 50), B.work("m-notion-notes", 4, .editing, truth: .work),
        B.call("m-slack-huddle", 20, camera: false), B.share("m-zoom", 30),
        B.call("m-meet-listen", 40, camera: false, profile: .slides),
        B.work("c-slack", 3, .editing),
        Beat(screen: "m-meet", seconds: 30 * 60, profile: .watching, truth: .meeting, call: .flapping(periodSec: 60, offSec: 8)),
        B.work("m-gmail", 5, .browsing), B.call("m-zoom", 1), B.work("m-gmail", 4, .browsing), B.call("m-zoom", 25),
    ])

    static let dictation = Session(name: "dictation", summary: "Talking to Wispr Flow: Notes, Docs, Medium, Word, a long think; hands still, mic live, no call.",
                                   date: "2026-09-26", start: "09:00", beats: dictationBeats)

    private static var dictationBeats: [Beat] {
        var beats: [Beat] = []
        for _ in 0..<6 { beats += [B.dictate("dict-notes", 3), B.glance("dict-wispr", 3, .still, truth: .neutral)] }
        beats += [B.dictate("dict-docs", 10), B.glance("dict-wispr", 3, .still, truth: .neutral), B.dictate("dict-docs", 10)]
        beats += [B.dictate("dict-medium", 15), B.work("dict-notes", 4, .typing), B.dictate("dict-word", 10)]
        beats += [Beat(screen: "dict-notes", seconds: 6 * 60, profile: .still, truth: .dictation, call: .none, note: "a long think, hands still, then more talking")]
        beats += [B.dictate("dict-substack", 12), B.dictate("dict-notes", 6)]
        return beats
    }

    static let research = Session(name: "research", summary: "A product manager's research that looks like browsing: pricing pages, reviews, threads, a profile, a job post, a demo video, a desk.",
                                  date: "2026-09-27", start: "10:00", beats: [
        B.work("m-gmail", 3, .browsing), B.work("x-stripe-pricing", 4, .reading), B.work("x-g2", 3, .reading),
        B.work("x-reddit-saas", 4, .reading), B.work("x-tweet", 2, .reading), B.work("x-yt-demo", 8, .watching),
        B.work("c-slack", 2, .editing), B.work("x-techcrunch", 4, .reading), B.work("x-producthunt", 3, .browsing),
        B.work("x-linkedin-profile", 2, .reading), B.work("x-linkedin-job", 2, .reading), B.work("x-amazon-desk", 3, .reading),
        B.work("m-notion-notes", 6, .typing, truth: .work), B.work("x-g2", 4, .reading), B.work("x-reddit-saas", 5, .reading),
        B.work("x-techcrunch", 5, .reading), B.work("m-notion-notes", 10, .typing, truth: .work), B.drift("r-x-home", 6),
        B.work("m-notion-notes", 10, .typing, truth: .work),
    ])

    static let drifts = Session(name: "drifts", summary: "Real drifts of every length, from a 5 s glance to a 30 min game: feeds, videos, shopping, news, chats, a game.",
                                date: "2026-09-28", start: "10:00", beats: [
        B.work("c-cursor", 8), B.drift("r-x-home", 5 / 60.0), B.work("c-cursor", 6),
        B.drift("r-ig-feed", 12 / 60.0), B.work("c-cursor", 6), B.drift("r-reddit-funny", 25 / 60.0), B.work("c-cursor", 6),
        B.drift("r-yt-gaming", 45 / 60.0, .watching), B.work("c-cursor", 7), B.drift("r-reddit-front", 2), B.work("c-cursor", 8),
        B.drift("r-netflix", 4.5, .watching), B.work("c-cursor", 8), B.drift("r-x-home", 6), B.drift("r-x-status", 5, .reading),
        B.work("c-cursor", 8), B.drift("r-steam", 30, .editing), B.work("c-cursor", 8),
        B.drift("r-amazon-product", 18, .reading), B.work("c-cursor", 8), B.drift("r-cnn-article", 10, .reading),
        B.work("c-cursor", 8), B.drift("r-whatsapp-friends", 3, .editing), B.work("c-cursor", 6), B.drift("r-wordle", 6, .editing),
        B.work("c-cursor", 8), B.drift("r-yt-gaming", 30, .watching), B.drift("r-amazon-home", 5), B.work("c-cursor", 15),
    ])

    static let daywithbreaks = Session(name: "daywithbreaks", summary: "A coder's day with a break suggestion, a tea break ended by the button and one that ran out, water, lunch, a closed lid.",
                                       date: "2026-09-29", start: "09:00", beats: [
        B.work("c-cursor", 55), B.teaBreak(on: "c-cursor", 12), B.work("c-cursor", 40), B.lock(45), B.work("c-cursor", 60),
        B.sleep(30), B.work("c-cursor", 30), B.teaBreak(on: "c-cursor", 25, button: false), B.work("c-cursor", 20),
        B.work("c-term", 3, .editing), B.work("c-cursor", 50),
    ])

    static let midnight = Session(name: "midnight", summary: "A late night: coding from 22:30 to 01:30, across midnight.",
                                  date: "2026-09-30", start: "22:30", beats: [
        B.work("c-cursor", 40), B.work("c-so", 3, .reading), B.work("c-cursor", 30), B.drift("r-yt-gaming", 6, .watching),
        B.work("c-cursor", 45), B.work("c-term", 4, .editing), B.work("c-cursor", 50),
    ])

    static let sleepAcrossMidnight = Session(name: "sleepmidnight", summary: "Working till 23:50, the lid closed overnight, back at 07:20.",
                                             date: "2026-09-18", start: "22:50", beats: [
        B.work("c-cursor", 60), B.sleep(7 * 60 + 30), B.work("c-cursor", 5), B.work("c-slack", 2, .editing), B.work("c-cursor", 40),
    ])

    /// Break, water, calls and dictation, overlapping and back to back (parameter 11).
    static let overlap = Session(name: "overlap", summary: "A break asked for in the middle of a call, a call that starts on a break, dictation in a call, a drift cut off by a call.",
                                 date: "2026-09-12", start: "09:00", beats: [
        B.work("c-cursor", 30),
        Beat(screen: "m-zoom", seconds: 10 * 60, profile: .watching, truth: .meeting, call: .on(camera: true), inputs: [.startBreak]),
        B.work("c-cursor", 5),
        B.teaBreak(on: "c-cursor", 4, button: false),
        B.call("m-zoom", 8),
        Beat(screen: "m-zoom", seconds: 3 * 60, profile: .still, truth: .teaBreak, call: .on(camera: false), inputs: [.startBreak]),
        B.work("c-cursor", 20),
        B.drift("r-x-home", 3.5), B.call("m-meet", 6), B.work("c-cursor", 12),
        B.dictate("dict-notes", 6), B.call("m-zoom", 3), B.dictate("dict-notes", 4),
        B.drift("r-yt-gaming", 9, .watching), B.call("m-zoom", 5), B.drift("r-yt-gaming", 3, .watching), B.work("c-cursor", 10),
    ])

    // MARK: Teaching Moku (a pat on a page the brain called a drift)

    static let pat = Session(name: "pat", summary: "A writer reads an essay Jev calls a drift, pats Moku (\"this is fine\"), and comes back to it later: the lesson should hold.",
                             date: "2026-08-25", start: "09:00", beats: [
        B.work("w-docs", 6), B.work("w-nyt", 20 / 60.0, .reading),
        Beat(screen: "w-nyt", seconds: 100, profile: .reading, inputs: [.pat]),
        B.work("w-docs", 6), B.work("w-nyt", 3, .reading), B.work("w-docs", 4),
    ])

    // MARK: The network (parameter 6)

    static var network: [Session] {
        let down = Beat(screen: "d-ps", seconds: 10 * 60, profile: .editing, inputs: [.network("down")])
        let up = Beat(screen: "d-ps", seconds: 10 * 60, profile: .editing, inputs: [.network("up")])
        return [
            Session(name: "net-down", summary: "The model goes away (cloudJudging off, the relay failing, no network) for twenty-five minutes of work, a video and a feed, then comes back.",
                    date: "2026-08-20", start: "09:00", beats: [
                B.work("d-ps", 8, .editing), down, B.work("c-gh-pr", 4, .reading), B.work("d-ps", 3, .editing),
                B.drift("r-yt-gaming", 8, .watching), B.drift("r-x-home", 3), B.work("c-sentry", 3, .reading), up,
                B.drift("r-yt-gaming", 4, .watching), B.work("d-ps", 6, .editing),
            ]),
            Session(name: "net-flap", summary: "Every other model call fails for half an hour of Photoshop, references and a drift.",
                    date: "2026-08-21", start: "09:00", beats: [
                Beat(screen: "d-ps", seconds: 10 * 60, profile: .editing, inputs: [.network("flap")]), B.work("d-pinterest", 4, .browsing),
                B.work("d-ps", 10, .editing), B.drift("r-yt-gaming", 6, .watching), B.work("d-ps", 8, .editing), up,
            ]),
            Session(name: "force-calm", summary: "The relay's forceCalm switch on: two long drifts with Moku showing nothing, then off for a third.",
                    date: "2026-08-22", start: "09:00", beats: [
                B.work("c-cursor", 10), Beat(screen: "c-cursor", seconds: 60, profile: .typing, inputs: [.forceCalm(true)]),
                B.drift("r-yt-gaming", 12, .watching), B.work("c-cursor", 5), B.drift("r-x-home", 6),
                Beat(screen: "c-cursor", seconds: 120, profile: .typing, inputs: [.forceCalm(false)]), B.drift("r-yt-gaming", 6, .watching), B.work("c-cursor", 5),
            ]),
        ]
    }

    // MARK: Stress: app switches per minute (parameter 1), the soak (parameter 2)

    static var stressSwitching: [Session] {
        let work = ["c-cursor", "c-term", "c-slack", "c-claude", "c-linear", "c-postman", "c-iterm", "c-docker", "c-vscode", "c-tableplus"]
        let mixed = ["c-cursor", "c-term", "c-slack", "c-claude", "r-x-home", "r-yt-gaming", "r-ig-feed", "c-linear"]
        var sessions: [Session] = []
        for (index, rate) in [6.0, 30.0, 60.0, 120.0].enumerated() {
            sessions.append(Session(name: "switch-work-\(Int(rate))", summary: "\(Int(rate)) app switches a minute among ten work tools, for ten minutes.",
                                    date: "2026-08-\(10 + index * 2)", start: "09:00",
                                    beats: [B.work("c-cursor", 2), Beat(screen: "c-cursor", seconds: 600, profile: .editing, truth: nil, storm: Storm(perMinute: rate, among: work)), B.work("c-cursor", 2)]))
            sessions.append(Session(name: "switch-mixed-\(Int(rate))", summary: "\(Int(rate)) switches a minute between work and feeds (a third of the screens are drifts).",
                                    date: "2026-08-\(11 + index * 2)", start: "11:00",
                                    beats: [B.work("c-cursor", 2), Beat(screen: "c-cursor", seconds: 600, profile: .editing, truth: nil, storm: Storm(perMinute: rate, among: mixed)), B.work("c-cursor", 2)]))
        }
        return sessions
    }

    /// Ten hours in one go: seeded random work across every kind of screen, meetings, lunch, a break, a closed lid.
    static var soak: Session {
        var random = MokuRandom(seed: 2026)
        func pick(_ ids: [String]) -> String { ids[Int(random.next() % UInt64(ids.count))] }
        func minutes(_ low: Double, _ high: Double) -> Double { low + Double(random.next() % 1000) / 1000 * (high - low) }
        let code = ["c-cursor", "c-vscode", "c-term", "c-iterm", "c-warp"]
        let docs = ["c-so", "c-mdn", "c-pkggo", "c-gh-pr", "c-gh-actions", "c-sentry", "c-localhost", "c-claude", "c-slack", "c-linear"]
        let writing = ["w-docs", "w-pages", "w-notion", "w-hemingway"]
        let research = ["w-wiki", "w-search", "w-cambridge", "s-scholar", "s-pdfexpert", "d-gfonts", "x-stripe-pricing"]
        let drifts = ["r-x-home", "r-yt-gaming", "r-ig-feed", "r-reddit-funny", "r-netflix", "r-amazon-product", "r-cnn-article", "r-wordle"]
        var beats: [Beat] = []
        var clock = 0.0
        while clock < 10 * 60 {
            let lunch = clock >= 4 * 60 && !beats.contains { $0.truth == .away && !$0.asleep }
            if lunch { beats.append(B.lock(40)); clock += 40; continue }
            switch random.next() % 10 {
            case 0...4:
                let length = minutes(8, 35)
                beats.append(B.work(pick(code + writing), length)); clock += length
            case 5, 6:
                let length = minutes(1, 5)
                beats.append(B.work(pick(docs + research), length, .reading)); clock += length
            case 7:
                let length = minutes(10, 40)
                beats.append(B.call(pick(["m-zoom", "m-meet", "m-teams"]), length)); clock += length
            case 8:
                let length = minutes(0.2, 12)
                beats.append(B.drift(pick(drifts), length)); clock += length
            default:
                let length = minutes(1, 3)
                beats.append(B.work("c-slack", length, .editing)); clock += length
            }
            if clock > 6 * 60, !beats.contains(where: { $0.asleep }) { beats.append(B.sleep(25)); clock += 25 }
            if clock > 3 * 60, !beats.contains(where: { $0.truth == .teaBreak }) { beats.append(B.teaBreak(on: "c-cursor", 10)); clock += 10 }
        }
        return Session(name: "soak", summary: "Ten hours: random work, calls, drifts, lunch, a break and a closed lid.", date: "2026-09-15", start: "08:00", beats: beats)
    }
}
