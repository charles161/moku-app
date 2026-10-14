# Moku's rules

*How Moku decides. The brain runs two separate pipelines: "Focus" decides whether you're working right now, and "Labeling" decides what it is, in your words. "Learned rules" and "Threads" are what you can teach and fix. "Behavior ladder" covers the Mac app (what Moku does about it). "Testing a change" is at the end.*

## Two pipelines

*The source of truth is one file, `brain/src/rules.ts`. It holds two rulebooks, as plain data, in order, with their numbers: the focus rulebook (executed by `brain/src/focus.ts`) and the labeling rulebook (executed by `brain/src/labeler.ts`). `GET /v1/rules` lists both (each rule says its `pipeline`) and everything you've taught.*

Every few seconds the app sends a sample: the app in front, its window title and URL, the text on screen (only when it changed), input rhythm, and whether you're in a call.

- **Focus** answers one question, *is this work or a distraction?*, and gives the verdict its `state`: working, drifting, away, meeting or unknown. It runs while the app waits, it never asks about threads, activities or buckets, and it never waits for labeling. Every verdict's `reason` starts with the focus rule that decided it, e.g. `[known-feed] linkedin.com/feed is a feed`.
- **Labeling** answers *what is it?*: the thread, the activity pill and the bucket. It runs in the background, one context at a time, and never changes the state. A verdict carries the labels already known for its context; for a new context they're empty at first and filled in a moment later (the Today window and the threads read them from there). Each label's reason starts with the labeling rule that chose it, e.g. `[on-thread] p=0.93 "learning DSA"`.

The state is the same whether labeling runs, fails or never runs at all.

## Focus: is this work?

The first rule that applies decides.

| # | Rule | When | State | Numbers (in `rules.ts` unless noted) |
|---|---|---|---|---|
| 1 | `meeting` | In a call or sharing the screen | meeting (Moku hides) | |
| 2 | `system-screen` | System Settings, a permission prompt, Spotlight, the Dock… | unknown: changes nothing | `systemScreen.bundleIds` |
| 3 | `away` | The screen is locked (at once), or no input for a while, even if the screen changes by itself (an AI agent or a build streaming text, a chat, a clock). Only watchable media that is changing (a feed or streaming page, a YouTube or Vimeo video, a video player like VLC, IINA, QuickTime or TV, and the places people attend lectures and classes: Coursera, Udemy, edX, Khan Academy, Panopto, Zoom, Teams, Meet and the like) falls through, so watching hands-free still counts. A lecture whose slides stay put for minutes (a Zoom class) still reads as an unchanged screen: away, which earns no focus but never a nudge | away | `away.lockedScreen`; `awayAfterIdleSec` (config, 300 s); `away.watchable` |
| 4 | `learned` | A context you taught (see "Learned rules") | working or drifting, with no model call. Wins over every rule below | |
| 5 | `neutral-app` | Finder, Preview, Activity Monitor, Calculator, Wispr Flow | unknown: the state before stands | `neutralApp.bundleIds` |
| 6 | `known-feed` | A feed or home page (the YouTube home, the X home, the LinkedIn feed, a Reddit front page, …) or any streaming site (Netflix, Prime Video, Disney+, Hotstar, Twitch, Spotify on the web, …) | drifting, with no model call | `knownFeed.feedPages`, `knownFeed.streaming` |
| 7 | `front-page` | A news site's front page (cnn.com, bbc.com/news, news.google.com, timesofindia.indiatimes.com, …) or a shop's home page (amazon.in, flipkart.com, ebay.com, …). Articles and product pages go on to Jev: you may be researching | drifting, with no model call | `frontPage.news`, `frontPage.shopping` (exact hosts) |
| 8 | `same-screen` | The exact same screen Jev judged in the last 10 min | the same state again | `sameScreen.windowMinutes` (10) |
| 8b | `reuse` | The same window (app, title, address) with at least 50% of the same words as Jev's last answer for it, within 5 min of that call. A page on the fence must not flip between work and drift as its text scrolls (launch QA, 2026-10-04: the real Jev gave 0.60 then 0.22 for a Product Hunt page with half its text), and a video's ticking clock needn't be a new call every 3 s. Another chat or page in the same window has other words and asks again at once | the same state again | `Rules.Goal.Reuse` (50%, 5 min) |
| 9 | `work-app` | A tool people work in, whatever it shows: AI assistants (Claude, ChatGPT, Codex, Gemini); editors, terminals, Xcode, Docker, TablePlus, Postman; Slack, Teams, Zoom, Mail, Outlook, Calendar; Notion, Linear, Jira, Asana, Figma; Keynote, Pages, Numbers, Word, Excel, PowerPoint; Google Docs, Sheets and Slides, Gmail and Google Calendar on the web | working, with no model call | `workApp.bundleIds`, `workApp.sites` |
| 10 | `drift-app` | A game (Steam, Minecraft, League of Legends, Unity games, …), or a video or music app in front (Apple TV, Prime Video, Spotify, Music) | drifting, with no model call | `driftApp.games`, `driftApp.video`, `driftApp.music` |
| 11 | `media` | A video or social site (YouTube, X, Reddit, Instagram, Hacker News, …) | working only when Jev says work with p ≥ 0.8 (a tutorial your work needs); otherwise drifting | `media.sites`, `media.minWorkP` |
| 12 | `jev` | Everything else (any other app or site) | Jev says work → working; distraction → drifting | |
| 12b | `no-info` | Nothing but the app's name: no window title, address or words (neither Accessibility nor Screen Recording, or a screen Moku never reads). The real Jev said "drifting" for a bare Google Chrome, and that held for ten minutes | unknown: changes nothing, and earns nothing | |
| 13 | `jev-failed` | Jev timed out, failed or answered malformed | unknown: Moku keeps its state; never a guess | 5 s per try, 1 retry (2 on 503/429), 7 s in all, 8 in flight |

Only the frontmost app is judged, so music or a video playing in the background never counts. Any rule from 5 on can be overridden for your own use with a learned rule: a pat on a Spotify focus playlist, or "This wasn't work" on a Slack channel.

**What Jev sees for focus.** One call per new screen, with one question (`kind`: work or distraction) about a flat, readable state (`focusState` in `rules.ts`): `user_app`, `window`, `site` (host and path, browsers only; never the query), and `screen_contents` (the first 1,500 characters). The screen alone: no threads, no buckets, no history, so the same screen always gets the same question. The question's exact text is `QUESTIONS.kind` in `rules.ts`, and it defines work, distraction and a feed:
- Scrolling a feed is a distraction even when some posts touch your work.
- News, reviews, commentary, reaction and comparison videos are a distraction even on topic. Only a tutorial or lecture your current work needs is work.
- A personal chat with friends is a distraction, even in a work messaging app.
- Looking up something specific for a task (a profile, a job post, a particular article or video) is work.

## Goal-aware judging (Charles's calibration build)

*`brain-go/internal/brain/goaljudge.go`, `reuse.go`; spec: `docs/specs/goal-aware-judging.md`. Off unless the brain starts with `MOKU_GOAL_JUDGING=1` or `MOKU_CALIBRATE=1` (the calibration build); everyone else gets the focus pipeline above.*

The question becomes **"does this screen serve one of your goals right now?"**. A goal is a thread (below). One Jev call answers the state and the goal together, so an unclear screen costs one call, not judge plus label.

| Answer | State | Moku |
|---|---|---|
| The current goal | working | quiet; the house grows |
| Another goal, or a new one | working, `switch: true` | calm, never a nudge; focus keeps counting |
| No goal | drifting | the drift ladder; its ask names the goal left: "Charles, can we get back to writing the onboarding doc? I want my house built." |

**Order:** the rules as above (meeting, system screen, away, learned, neutral app, known feed, front page, **work app**, drift app), then **reuse**, then **the goal call**. Rule same-screen is folded into reuse.

- **Reuse** (`Rules.Goal.Reuse`): the same window (app, title, address) with at least 50% of the same words (Jaccard) reuses its last answer for up to 5 minutes from the call; the exact same screen for 10. Another chat or page asks again at once. Reasons read `[reuse] mostly the same words as 42s ago: …`.
- **The goal call** (`[goal]`, or `[media]` on media sites): Jev sees the flat screen plus `current_goal` (the title of the goal of the last work in 60 minutes), and one choice question: the current goal first, then recent goals (8 in all, active in 14 days), each as "title: summary", plus `new` and `none`. Working when P(not none) ≥ 0.5; on the most likely goal at p ≥ 0.5 (ties go to the current goal); else a new goal at P(new) ≥ 0.5; else work with no goal sure enough (calm, no guess). **Media sites** keep their bar: work at p ≥ 0.8, a goal at p ≥ 0.8, never a new goal. A failed call is `[jev-failed]`, unknown, as before (no local fallback for this question).
- **Buckets** aren't asked, to keep the call small: a drift's comes from the labeler as before (well-known places at once, others asked once per context and cached); work takes its goal's.
- **Work the rules decide** (editors, terminals, Gmail…) only needs its goal: the labeler asks it once per window and caches it for an hour (`Rules.Goal.LabelFreshMinutes`; a drift's bucket per place too). Its first verdict has no goal yet; the next one does, and the first is filled in.
- **A new goal** is provisional until Luna names it. Then one Jev call (names and summaries only) asks whether it repeats an existing goal, and its bucket: at p ≥ 0.7 it folds into the goal it repeats (`MergeThread`), which keeps its name.
- **The verdict** gains `goal` (the thread) and `switch` (another goal than the current one, or a new one). The app treats a switch as working.

**Calibration** (`calibrate.go`, Charles's build only): `http://127.0.0.1:8020/calibrate`, "Calibrate…" in Moku's right-click menu. Moments (a run of time on one site or app with one answer) are rated ✓ or ✗; every drift, switch and new goal is shown, plus a fifth of the rest. Scores are the spec's exit bar. The build keeps screen text 14 days so `go run ./cmd/moku-replay` (from `brain-go`) can replay the rated moments through a new version and score it before it reaches his Mac.

## Labeling: what is it?

Labeling works per **context**: the scope a learned rule would have there (an app window, a site, or one page of a content site), in one state. A context is labeled once and its labels are reused for 10 minutes, or for as long as its text doesn't change (`label-cache`). A failed labeling call leaves the labels empty and is tried again a minute later.

| Rule | When | Label | Numbers |
|---|---|---|---|
| `label-cache` | The context was labeled in the last 10 min, or its text is unchanged | the same labels, no model call | `labelCache.freshMinutes` (10) |
| `learned-thread` | Work in a context you taught as work on a thread (a pat, "This was work") | that thread, with no thread question | |
| `on-thread` | Jev puts the working screen on one of your threads with p ≥ 0.5 | that thread | `onThread.minP`; Jev is offered your 8 most recent threads from the last 14 days, plus the one last used on this site |
| `media-thread` | On video and social sites, work joins a thread only at p ≥ 0.8, and never starts one | that thread, or none | `mediaThread.minP` |
| `new-thread` | Jev is sure it's none of your threads (p ≥ 0.5), or there are none yet | a new thread; Luna names it in your words ("learning DSA") a few seconds later. Named the same as an older thread (case and spacing aside), it folds into the oldest one, which keeps its name; repeats already there fold in at startup | `newThread.minNoneP` |
| `unclear-thread` | Work, but no thread is sure enough | no thread (no guess, no duplicate thread). It's still working time | |
| `category` | Always | the bucket. Work gets a focus bucket, drift a drift bucket. Well-known places decide a drift's bucket (a feed → scrolling, YouTube or a video app → watching, a chat app → chatting, a news front page → reading, a shop → shopping, a game → playing, Spotify → other: "on Spotify"); otherwise Jev picks it in the same labeling call | `category.focus`, `category.drift` (each with a one-line description), `category.driftBySite`, `category.frontPages`, `category.driftApps`, `category.chatApps` |
| `activity` | Always | the pill (see "Activity words") | |
| `completion` | A work screen that just changed matches a finish pattern (a push, a green test run, "Accepted", a merge, a deploy, an important email), and Jev confirms it with p ≥ 0.9 | a completion on the verdict; at most once per screen, and once per 10 min per kind and thread or app. It runs with the verdict (it's rare) and never changes the state | `completion.minP`, `completion.repeatAfterMinutes`; the patterns are `COMPLETION_PATTERNS` |

**What Jev sees for labeling.** For work, one call per context with two questions: which thread (or none), and which bucket. For a drift on a site that doesn't decide its own bucket, one question: which bucket. The state (`labelState` in `rules.ts`) is the same flat screen as for focus, plus `your_work` (your thread titles) when there are threads. The thread question also says what belongs to a thread: tutorials its goal needs do; news, commentary and feeds about its topic don't.

**Buckets.** Every labeled verdict rolls up into one bucket, and the Today window totals them (`byCategory`, focus buckets first).
- **Focus:** building, learning, working, communicating, and career. Your own job search is career; recruiting for your company is working.
- **Drift:** watching, scrolling, chatting, reading, shopping, playing, and other.

**Activity words.** Every labeled verdict carries an activity: what you'd say you were doing, in your words, at most 4 words, never judging. The Today window and the info pills show it.
- **Drift:** the bucket and the place: "watching YouTube", "scrolling LinkedIn", "chatting on WhatsApp".
- **Work:** the thread's phrase ("learning DSA", "job search"), which Luna writes once, when naming the thread; work without a thread gets one Luna phrase per context. A thread's phrase that names an app or site other than the screen's ("using ChatGPT" on Claude) doesn't label that screen: it gets its context's own phrase, or "working" (2026-10-04: Your day said "Claude · using ChatGPT").
- **In a call:** "in a call".
- **Never:** "doomscrolling", "wasted", "distracted" or anything that judges. The list is `NEUTRAL_WORDS.banned`, and it's also enforced on Moku's lines and note.

## Learned rules

A pat ("this is fine"), "This was work" and "This wasn't work" in the Today window all create a **learned rule**. Learned rules are focus rules: they decide the state (rule `learned`). A work rule also remembers the thread you were on, and labeling puts that context on it (rule `learned-thread`); teaching a context makes labeling label it again. Each one has:
- **Scope:** the app and site, where one learned rule covers the whole site. On content sites (YouTube, X, Reddit, LinkedIn, Instagram, Hacker News, …: `learned.params.contentSites`), a rule covers only that page, by its title (a YouTube video) or its path (`linkedin.com/feed`, `linkedin.com/in/someone`, `reddit.com/r/leetcode`). So patting one tutorial doesn't whitelist all of YouTube, and "This wasn't work" on the LinkedIn feed doesn't touch profiles. In an app without a URL, the window title is the scope.
- **Effect:** work (on the thread you were on then) or not work. "Not work" judges that context drifting from then on, with no model call.
- **When and why:** its created time and its source.

Teaching the same scope again replaces the old rule, and the most specific rule wins. Corrections from the Today window also relabel the segments you pointed at, so today's numbers change right away.

Every call to the brain but `/health` needs the brain token Moku and its brain share (`~/.moku/brain-token`, owner-only); without it the brain answers 401.

**See them:** `curl -s -H "authorization: Bearer $(cat ~/.moku/brain-token)" http://127.0.0.1:8020/v1/rules` returns the built-in rules with their descriptions, plus your learned rules with their ids.

**Remove one:** `curl -X DELETE -H "authorization: Bearer $(cat ~/.moku/brain-token)" http://127.0.0.1:8020/v1/rules/<id>`. The screen goes back to Jev on its next sample. Built-in rules can't be removed; edit `rules.ts` instead.

## Threads

A thread is an ongoing goal, named the way you'd say it: "job search", "learning DSA", "building Moku". Threads belong to labeling: they're found automatically (labeling rule `new-thread`) and named by Luna. Nothing about a thread (its name, its bucket, forgetting it) changes a state. Reading job descriptions, applications or career pages makes a job search, unless the screen is a recruiting tool (an applicant tracking system, Workday recruiting, LinkedIn Recruiter). A thread's bucket is the one most of its verdicts have.
- **Renamed once:** threads named before this ("Hiring · Backend Eng") are renamed once, in your words, from the screens they were seen on. That happens the first time the brain starts with this version, and the brain's log shows old → new.
- **See them:** `curl -s -H "authorization: Bearer $(cat ~/.moku/brain-token)" http://127.0.0.1:8020/v1/threads` lists them, most recent first, with today's and total focus minutes.
- **Rename one in your own words:** `curl -X PATCH -H "authorization: Bearer $(cat ~/.moku/brain-token)" http://127.0.0.1:8020/v1/threads/<id> -H 'content-type: application/json' -d '{"title": "building Moku"}'`.
  - A title you set is final: Luna's naming and the one-time rename never overwrite it.
  - It's a label edit: labeling routes on the new title from then on, and no state changes.
  - When it's 4 words or fewer, it also becomes the thread's activity.
- **Its bucket:** the one most of its verdicts have. A thread made before buckets existed gets one from Jev, from its name and screens, once, when the brain starts.
- **Forget a junk one** (say, one started by a settings screen or a video): `curl -X DELETE -H "authorization: Bearer $(cat ~/.moku/brain-token)" http://127.0.0.1:8020/v1/threads/<id>`. It's a label edit: its verdicts keep their state (working time stays working) and learned rules keep deciding the state; both just lose the link to the thread. Jev stops offering it. To undo a learned rule itself, remove it (see "Learned rules").

## Behavior ladder

*What Moku does as a drift goes on, and around it. The source of truth is one table in `app/MokuMind/Sources/MokuMind/BehaviorLadder.swift`; the engine only executes it. Change a row there to change what Moku does; change a number in the config to change when.*

### Where the numbers live

- **Served config (`CompanionConfig`):** the brain's `GET /v1/config` serves these, read from `~/.moku/config.json` on every request. The app re-reads it every 60 s, so a change applies within a minute, without a restart.
- **App-local (`EngineTuning`):** a few pacing values live in `app/MokuMind/Sources/MokuMind/EngineTypes.swift`. Changing them needs a rebuild.

### The drift ladder

The **drift clock** only runs while the last "drifting" verdict is at most `evidenceWindowSec` (60 s) old. Unsure verdicts, silence and a brain that's down all freeze it, so nothing below can happen without real evidence. Each step fires once per drift, in order. A step never fires before the steps above it, and steps that are due at the same moment fire together.

| Drift clock (standard) | Step | Tier (`WorkState`) | What Moku does | What it says | Logged | A return from here is | Tuned by |
|---|---|---|---|---|---|---|---|
| 0 s | Grace | grace | Nothing changes. Its eyes stay on the work. | | | not a return | |
| 1 s | Sad | noticing | Sad (the disappointed mood: soft brows, paws in the lap), and a look at you. No gesture: the mood blends in | | | small; a stone only from 30 s | `graceSec` (never later than `shortDriftMaxSec`) |
| 7 s | Look back | noticing | Its eyes go back to where the work was (never the distracting window). The face stays sad until the drift ends | | | small | `LadderStep.sadLookSec` (6 s after the sad step, never later than `shortDriftMaxSec`) |
| 2 min | Long drift | concerned | Nothing shows. The focus streak ends, so no return bonus | | `longDriftStarted` (with the drift length) | small | `shortDriftMaxSec` |
| 4 min | Stand up | drifting | Sits up tall (companions stay seated for now), a little red (the plush warms), still sad | | | full | `standUpAfterSec` |
| 10 min | Ask | longDrift | Asks you to focus, standing where it is (no walking for now) | "Charles, can we focus? I want my house built." (without a name before onboarding) | `nudged` | full | `askAfterSec` |

Charles, 2026-09-28: "when i drift away it shouldnt see the screen and be sad, it should just look at me and feel sad, not angry kinda, and 1 minute of continuous drifting it should be angry and look at me, after 4 minutes of continuous drifting, it should stand up and grow a little red and be angry, after 10 minutes, it should walk to the center of the screen, look at me and ask me to focus so that it has a house built."

Charles, 2026-10-08: "i dont like the angry face on moku and tetsu, lets remove it kinda - make it simple only with sad face for both". The angry step (a minute in: V brows, arms crossed) is gone; both companions stay sad for the whole drift. `annoyedAfterSec` is still in the config, unused.

That ask is Moku's only line in a drift: fixed, never Luna's, and it names no task. Its bubble stays up until you come back (or the drift ends another way: a pat, a break, a meeting), not a 6 s bubble that's easy to miss (Charles, 2026-10-04). Moku says nothing more, sad and red, until then. The four timings are also in Settings › When you drift.

**After the ladder:**
- **Nudge feedback:** still drifting 10 minutes after the ask (`ignoredNudgeAfterSec`) sends `ignoredNudge` feedback, once. Coming back before that sends `returnedAfterNudge`.

### Coming back

- **Body:** a return is celebrated with a nod (a little hop and a slow blink for a full one); the red fades and Moku sits back down. It looks at you, happy, until its line ends, then goes back to watching the screen.
- **Size:** a drift still in grace isn't a return at all (nothing happens, nothing is logged). Up to standing up it's a small celebration, with no words. From standing up on it's a full one, plus one short, positive line, and Moku sits back down.

**How standing moves:** standing is a pose, not a clip. `stand_poses.usdz` holds the rig from seated (frame 0) to standing (frame 24), with the feet planted at every frame; the app blends along it (`RealityCharacter.stand`). Getting up is a small crouch, the push up and a soft overshoot, with the ears dragging then flopping; sitting lifts a touch, lets down and lands. Mood, gaze and the red stay live throughout, and frames stay at 60 fps while it moves.
- **"Where was I?"** (docs/specs/next-three.md §2): coming back to work from a drift of 2 minutes or more (wall time since you left the work), or from 10 minutes or more away (counted from your last input), the welcome names what you were doing: the task and the last thing you were in. "Welcome back. You were building Moku: SettingsWindow.swift in Cursor." The last moment of work is noted on each working verdict (with the window that sample was taken of), a pat, and a switch to another window of the same app while working; never from a site remembered as work (youtube.com is a lecture one minute and a game the next). The words come from the window's title cleaned up the way Your day's steps are (a file, a command, a page without its site's name, a chat; mail says nothing). The bubble offers "Take me there" when that window isn't in front, and goes on a click, on typing (after its first 1.5 s) or after 10 s. Built in, never Luna: no model call, nothing new leaves the Mac. Never after a meeting, a call or a break; not for work more than 16 hours old; not when there's neither a task nor a telling title.
- **The words after a long drift with nothing to name** come from a fixed pool, in rotation and never the same twice in a row: "Welcome back! Let's do it.", "There you are. Let's go!", "Back together. Let's make something.", "Hey, welcome back! Ready when you are.", "Yay, you're back. Let's do this." The pool is built in, not asked of Luna.
- **Stones:** a return from a drift of at least 30 s (on the drift clock) logs `returned`, which lays a stone. A shorter one is a glance: Moku still nods, but nothing is laid and no bonus is paid, so the focus behind it waits for the next real return (`Stones.afterDriftSec`; Charles, 2026-10-04: 63 returns a day, mostly glances, filled the path in three days).
- **Bonus:** a short drift (30 s up to `shortDriftMaxSec`) also earns a return bonus, `clamp(focus minutes since the last credited return ÷ 10, 0.5, 5)` points. It needs at least 5 focused minutes, so drifting on purpose can't farm it. Long drifts earn no bonus.
- **Fast returns:** switching straight to an app or site last judged "working" counts as a return at once, without waiting for the next verdict. Switching to one last judged "drifting" waits for a fresh verdict.
- **Pat:** a pat during a drift means "this is fine". Moku softens and goes home. It's not a return: no stone, no bonus.

### Eyes during a drift: one look at you, then the work

After grace Moku shows its sadness once: it looks at you for a few seconds (`LadderStep.sadLookSec`), then its eyes go back to where the work was and stay there, with the sad face, until the drift ends. It never follows the cursor to the distracting window, and it doesn't look at you again in that drift (not at the stand-up, not at the ask, not after a rest). Charles, 2026-10-12: "the sad animation is too much, maybe moku can show its sadness once and then go back to watching my screen with a sad face"; this replaces 2026-09-28's "it should just look at me". Its head turns to you once and then holds still (no head shaking); when a mood lowers its head, the eyes look up to meet yours. Its small reactions in a drift (a brow, a blink, a lip press, a squint, a pout, a puff, a sigh) are face-only, and hovering over it doesn't light it up. Dragged, dropped or patted while standing, it stays standing (after a pat it stands back up).

### Everything else

| State | What happens | Tuned by |
|---|---|---|
| Working | Eyes on the middle of the screen. One growth point per focused minute. Proud after 45 min of continuous focus. A break suggestion after 50 min (water, then stretch, look away, walk; the walk gets a wave, never standing up). Once a minute of focus Moku looks up at you (see below) | `smileEverySec`, `proudAfterSec`, `breakAfterSec` |
| A neutral app in front (Finder, Preview, a system screen) | The state before stands, as in Your day: the focus before it goes on being credited while its `neutral-app` verdicts keep coming, for 30 min at most (`neutralHoldSec`, app-local). A PDF read in Preview is work, and the day and the house must agree. A drift isn't held: it rests after a minute as below | `neutralHoldSec` |
| No fresh evidence (just launched, brain unsure or down) | Idle: calm, no signal. Nothing escalates. In a drift, a minute without a drifting verdict calms Moku fully: seated, content, eyes on the work, the ask down, no red (not standing red and still; Charles, 2026-10-04). The drift isn't over: coming back is still a return, and fresh drifting evidence shows the drift again where the ladder left it | `evidenceWindowSec` |
| Away (brain: the screen locked, or idle for `awayAfterIdleSec`; engine: the Mac asleep, seen as no tick for `longAwaySec`) | Clocks freeze. After 10 min away (or waking from a sleep that long), Moku sits and gets sleepy, any drift is dropped, and the break timer resets. Coming back then earns a wave and a greeting (which names the work: "Where was I?"), even when the first thing heard after waking is the person's app and not the next tick | `longAwaySec` |
| Meeting or screen sharing | Moku hides, and every clock freezes. Afterwards any drift is dropped without judgment: a meeting never counts as drift | |
| Tea break ("Taking a break") | Nothing counts as drift (the popover's home shows Moku with tea; the desktop Moku just sits calm). It ends by coming back to work: "Back to work", switching to a work app, or working with the cursor moving again. That logs `breakEnded` and `returned` (a stone, no bonus). After the maximum, the break just ends, and a drift afterwards starts from zero | `teaBreakMaxSec` (20 min); `backAtDeskAfterSec` (app-local, 10 s) |
| A new home stage | The menu bar cue and `milestone` right away. Moku's own celebration waits for the next return or break | |
| Work finished (a push, tests passing) | `completed` right away. Moku celebrates once the cursor and caret have been still for 5 s, or at the next return or break. Luna writes the line from the label; the built-in one is used if Luna takes over 5 s | `calmAfterQuietSec` (app-local) |
| Manual control | Nothing is watched, judged or sent. Leaving it starts fresh: calm, at home | |

### Looking up at you while you work

Charles: "When I'm focusing, occasionally it should see me and smile, sometimes close its eyes, feel happy, and then go back to seeing the window."

- **How often:** Charles: "make it once per minute - on continuous focus". Exactly every `smileEverySec` of continuous focus, 60 s by default, with no jitter and no floor. A drift starts the count again, so the first look-up after coming back is a full minute of focus later. Change it in Settings › While you focus (every 1 to 30 min).
- **What:** Moku looks at you and smiles, its eyes open. It holds about 2.5 s, then goes back to watching the window. It used to close its eyes happily two times in five; Charles, 2026-10-08: "moku seems to close his eyes kinda even without me patting it". Closed happy eyes are a pat's (and a hover's). The proud face after 45 minutes of focus keeps its eyes open too.
- **Never during** a line, a walk, a meeting, an away, a drift, a tea break or manual control. A look-up that comes due waits until the current gesture settles. A due break goes first, and may cut a look-up short.
- **Where:** the hold, the weights and the rule are in the `FocusMoments` table, next to the ladder in `BehaviorLadder.swift`. The randomness is seeded, so tests and the simulator are repeatable.

## Testing a change

- **Timings** (anything in the ladder's "Tuned by" column that's served config, including `graceSec`, 1 s by default): change them in Settings › When you drift, or put the key in `~/.moku/config.json`, e.g. `{"standUpAfterSec": 180, "graceSec": 45}`. `GET /v1/config` re-reads it on every request and the app picks it up within a minute. An unknown key or a bad value ignores the whole file, with a warning in the brain's log.
- **From the app:** onboarding sets your name with `PUT /v1/config` and a partial config body, e.g. `curl -X PUT -H "authorization: Bearer $(cat ~/.moku/brain-token)" http://127.0.0.1:8020/v1/config -H 'content-type: application/json' -d '{"userName": "Charles"}'`. Every key is validated (400 on an unknown key or a bad value), it's merged into `config.json` atomically (the other keys stay), and `GET /v1/config` serves it at once. Before onboarding the name is "friend", and Moku asks "Can we focus? I want my house built." without it.
- **The drift, without waiting:** Settings › Test it now jumps straight to a step (sad, standing and red, asking you to focus) and holds it, plays the return from there ("Come back to work"), or plays the whole drift 30× faster. "Smile at me" plays the look-up you get while focusing. It runs a fresh engine through the real ladder and your timings; Moku stops watching the screen until "Stop testing".
- **Judging rules** (`brain/src/rules.ts`): change the number or the sentence, then run three checks, all from `brain/`:
  1. `npm test`: every rule, with a fake Jev. Fast, free, no network.
  2. `npm run smoke`: live Jev and Luna on known screens, with automatic must-pass cases, and it exits 1 if one fails. It costs well under a cent. Each case is checked twice: the state the focus pipeline returned, and the labels the labeling pipeline stored. The cases:
     - The DSA screens must be "learning", and the Morris traversal tutorial working (focus) on the DSA thread (labeling).
     - Claude building Moku must be working, in "building".
     - Job descriptions must be working, in "career".
     - The four HR screens must share one thread, and a LinkedIn profile must be working.
     - The LinkedIn feed must be drifting, in "scrolling"; the X timeline drifting; and Minecraft drifting, in "watching".
     It also prints the focus path's latency on its own.
  3. `npm run rejudge [-- --site linkedin.com] [--limit 50]`: your real day. It copies `~/.moku/moku.sqlite` (the live file is only read), clears the verdicts and learned rules in the copy, re-judges every distinct real screen with the current rules, and prints the focus state before → after per screen and per site, the focus path's latency before and after, and then the buckets and pills labeling stored. That's how a rule change is checked against what actually happened. It also checks the real-day must-pass cases:
     - focus: the YouTube home page and every YouTube video drifting; the LinkedIn feed drifting; every Claude, Telegram, Cursor and chatgpt.com screen you were at working; personal WhatsApp chats drifting; every screen idle for 5 minutes or more away (unless it's a changing video or feed), even when the screen changed by itself;
     - labeling: YouTube videos in "watching"; the LinkedIn feed in "scrolling"; WhatsApp chats in "chatting".
     It exits 1 on a miss. The copy is deleted afterwards.
- **Restart the brain** to apply a rule change: the running brain loaded `rules.ts` when it started.
