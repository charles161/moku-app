# Changelog

Every Moku release, what changed in it, newest first. `FEATURES.md` says what is live today; this file says when each
thing arrived. The rules:

- Every change that a person would notice, or that changes what Moku stores or sends, gets a line under **Unreleased**
  in the same commit.
- A release moves **Unreleased** under its version and date (`scripts/release.sh` builds from HEAD: commit this first).
- Sections: Added, Changed, Fixed, Removed, Security, Privacy. Plain words, one line each, what a person sees.
- The app's "What's new" and the website's changelog are written from this file.

## Unreleased

## 0.1.13 (2026-10-14)

### Added
- **Moku Pro**, $6 a month or $48 a year, in Settings › Moku’s brain. It opens for buying soon: then the checkout opens
  in your browser, and Pro turns on here by itself once it’s paid. No account and nothing to type. Sold by Dodo
  Payments; cancel any time.

### Fixed
- Moku now hides over a full-screen reel or video in a browser even when the browser doesn't keep the display awake
  (a muted reel on Instagram, say): a full-screen browser on YouTube, Instagram, Netflix, Prime Video, Hotstar and
  other sites for watching counts. Switch that window to a page of work and Moku comes back.

### Privacy
- For Moku Pro, payments go through Dodo Payments, the seller of record. Our relay keeps only your Mac's fingerprint,
  the subscription's ID, its status and until when it's paid; never your card or your email.

## 0.1.12 (2026-10-14)

### Added
- With several screens, Moku follows you: once you've worked on another screen for about 30 seconds, it fades over to
  that screen's corner (seated, no walking). A quick glance at the other screen doesn't move it.
- Right-click Moku to correct it: **This is work** during a drift (the drift counts as work and Moku settles), or
  **This isn't work** (counted as a detour from when that window came up, with no sad move). Moku learns the app or
  site either way. In Your day, the **…** to correct a line now shows faintly, so it's easy to find.
- Moku hides itself while a video plays full screen on its display (in a browser, QuickTime, IINA, VLC, TV…) and comes
  back when full screen ends; pausing doesn't bring it back over the film, and neither does a break. An editor or any
  other app in full screen doesn't hide it. Another display's full-screen video doesn't hide it, and neither does a
  call ending nor "Hide Moku" bring it back early.
- Settings › Privacy › **Apps where Moku steps aside**: pick any number of apps, from the ones open now or from
  Applications. Moku hides while one is in front. For each, choose **Hide Moku** (the work you do there still counts)
  or **Hide, don't watch** (Moku reads nothing from it, judges nothing and sends nothing; a call is still noticed, so
  Moku stays hidden on a shared screen). Remove one with the minus button.

### Fixed
- Crash reports could be lost: Moku marked one as sent even when it hadn't gone through, looked only once at launch, and
  skipped the brain's own reports. Now a report is kept until PostHog has answered, and Moku looks again a minute after
  launch and every hour.
- Moku wrote about 2 GB a day to your disk without need: macOS kept a copy of every answer from Moku's own brain, a
  few seconds apart. Moku's calls now keep nothing, and the old copies are cleared at launch.
- A crash right after Moku reopened itself quietly (after you change companions) was counted as a normal quit.

### Removed
- **"Where was I?"** and its **Take me there**. Friends found it named the wrong thing too often.
- Words over the companion's head, except **What's new**, the end of a break and the care prompts (drink water, rest
  your eyes, stretch, walk). Coming back, a celebration, the ten-minute mark and the morning hello are all said with
  moves now: no ask, no "welcome back", no greeting or celebration lines. Moku asks its online writer for fewer lines.

### Changed
- No more task labels popping up beside Moku ("launching moku desktop app"). It nods when you start on something, and
  resting the pointer on it shows what you're on and your minutes on it today.
- Sharper Moku and Tetsu: they're drawn at 1.75 times the pixels your screen shows, then scaled down, so the eyes,
  the mouth and the outline have smooth edges instead of pixel steps. It costs a little more only while they move.
- In a corner, Moku and Tetsu turn their heads only a little toward your work; their eyes do more of the looking. The
  head used to turn almost to a profile.
- The welcome asks only for Accessibility. Screen Recording is optional: Moku goes by the app, the window's name and
  the address, and Settings can let it read a few words from the window too.
- Moku and Tetsu are smaller: what Settings calls 1× is 87% of the old size ("cuteness wins"). Your chosen size keeps
  its number, so it's 13% smaller too.
- When you drift, Moku shows its sadness once: a sigh with a sad face, then its eyes go back to your work and its face
  back to normal, all within three seconds. It no longer stares at you, folds its arms or stays sad for the whole drift. It
  shows its sadness at most once every three minutes: a quick second drift is watched calmly, and coming back from it
  doesn't flip the face to happy.
- Moku's online brain now has a fair daily share for each Mac on a trial, so it stays affordable however many people
  join. A Mac that uses its share is judged by Moku's own rules until midnight UTC. Invited friends aren't limited.
- The popover says so plainly ("Moku's thinking offline for the rest of today"), and Moku asks again only when the
  day turns. When a trial ends, Moku waits hours before asking again, and an invite code typed in turns the online
  brain back on at once.

### Privacy
- Moku no longer leaves a copy of its answers from the relay in your Mac's cache folder
  (~/Library/Caches/ai.lightslips.moku). That copy included this Mac's relay token in plain text. It's cleared at launch.
- When our relay asks (it doesn't yet), a trial's first request carries Apple's App Attest statement: a throwaway key and
  Apple's signed word that it came from a real Mac running Moku, so trials can't be made up for Macs that don't exist.
  An invite skips it, and a Mac that can't do it (macOS 26 or older) carries on without. The relay keeps only the key's
  ID. Never anything about your screen, files or account.
- Each launch also says whether the last one ended with a normal quit or not (a crash, a force quit, a power cut),
  one word, so a crash is still noticed when its report can't be sent. Nothing else is added.
- Once a day our relay records how many Macs used Moku's online brain the day before and each one's share for the new
  day: two counts, nothing about any one Mac.
- When an update check fails, Moku also sends the network's error number, the server's answer code and which of its
  two update servers it was, so a Mac that can't update can be helped. Never the address.

## 0.1.11 (2026-10-08)

### Changed
- Drifting, Moku and Tetsu look sad, never angry: no cross brows or folded arms a minute in.
- Moku closes its eyes happily only when you pat it or rest the pointer on it. The look-up while you work is a smile
  with its eyes open, and so is its proud face after a long stretch of focus.

### Privacy
- The day's summary counts the minutes the companion was hidden as they pass, split into hidden by you and hidden for
  calls (it used to add them only when it came back, so a hide still on at midnight counted nothing), and Moku's
  opening says whether you had put the companion away. Detours while you've hidden the companion aren't counted as
  nudges: you didn't see them.
- When Your day's numbers disagree about today, Moku sends which two views and by how many minutes
  (`numbers_disagree`), so we can fix it. Never what you worked on.
- When you answer "What's new", Moku also sends how many seconds its bubble stayed up (`whats_new`). Never what you worked
  on.

### Fixed
- The popover's "···" menu opens on the first click. It used to vanish at once the first time, and open on the second.
- A call that drops for a moment no longer flashes the companion back for a few seconds: it stays hidden until the
  call has been over for half a minute.
- The welcome shows its companion even if you had hidden it. "Say hi again" (or installing again) after hiding Moku or
  Tetsu opened the welcome with an empty stage; now the companion comes out for it and stays out.
- Your day's numbers agree everywhere. The tasks line counts Other work too ("8 tasks and other work, 4h 3m", not
  "8 tasks, 2h 59m" under a header of 4h 3m); the tasks and the work rows add up to the header to the minute; the week
  strip shows the day on show as its header does; the house's pieces are one per 10 focused minutes in every view; and
  a morning Moku couldn't judge, after last night's work, counts the same in the popover and in Your day.
- Your day says what the popover says. Opened again while it was open, or left open while you worked, it kept the day as
  it was when it first opened (2h 51m and 6 returns beside the popover's 3h 30m and 9). Now it asks again, and the
  numbers change in place.
- The usage numbers no longer count a relaunch, an update or a logout of Moku as quitting after a nudge. Only your own
  quit counts.

## 0.1.10 (2026-10-06)

### Changed
- Updates are much smaller: a new version usually comes as just what changed (about 1 MB rather than 48), so it gets
  through on slow and mobile networks. A Mac whose copy doesn't match downloads the whole update instead.
- An update whose download fails is tried again after 10 minutes, 30 minutes and 2 hours, rather than the next day.
  Settings says how the last check went and, when it failed, when Moku tries again.

### Fixed
- From this version, a Mac that installed Moku from the download gets the small updates too: the download's app is now
  exactly the one updates are made from.
- "Say hi again" during a break ends the break: the timer over the companion goes and the popover's button says
  "Break" again. Before, the button still said "End break" and pressing it started a new break.
- moku://day, moku://break and moku://settings work when Moku isn't running: Moku opens and does what the link says.
  Before, it only opened.
- Delete my data empties the menu bar's house and the popover at once. Before, they showed today's house for up to a
  minute more.
- Opening Moku again while it runs (from Applications, Spotlight or Launchpad) opens its popover, so you can see it's
  there. Before, nothing happened.
- The ✕ on the break timer only ends the break. A double-click, or a click as the time ran out, started a new one.
- Opening Your day or Settings brings only that window forward. Before, Moku's other windows left behind your apps came
  forward with it.
- Opening Your day while it's open brings it forward where you put it, at today. Before, it jumped back to the middle
  of the screen, faded in again and rebuilt the house from nothing.
- After "Say hi again", macOS's Quit & Reopen for Screen Recording brings the welcome back where it was. Before, Moku
  reopened without it, though the welcome had said it would pick up right there.
- After you change companions, Moku reopens itself (to free memory) only when you're away, the screen is locked or the
  Mac sleeps. Before, two minutes without touching the Mac was enough, so it could vanish and come back while you watched
  a video or read.
- In the welcome, the companion stays in its window: it can't be dragged out, and a display change leaves it there.
  Before, a drag moved its home, and the welcome ended with it there.
- Opening Settings again while you type your name keeps what you typed. Before, it went back to the saved name.
- From this version on, going back to an older Moku (after a newer one) keeps your name and your breaks and water.
  Before, one setting it didn't know made it ignore all of them.
- "What's new" and "Where was I?" stay while the pointer is on them, so they never vanish as you go to click. Before,
  they went when their time ran out, even under the pointer.
- Quitting with ⌘Q while the popover is open closes it first, so the day's goodbye card shows alone.
- An invite link that opens Moku for the first time no longer opens Settings over the welcome: Settings shows the invite
  once the welcome is over.
- In the welcome, right-clicking the companion does nothing. Before, its menu could hide it from the welcome or open
  Settings over it.
- Delete my data also clears an open Your day, which went on showing the days just deleted.
- A pat plays its little reaction once. Before, a pat while the companion moved home played it again when it arrived.
- "What's new" counts as seen only once its bubble has been up. Before, a call starting at that moment meant it was
  never shown; now it's shown at the next launch.
- Your day's work rows add up to its focused minutes. A stretch Moku couldn't judge right after work (a neutral app)
  counted as focus but had no row.
- The menu bar's house fills as much as the popover says. Before, it filled in eighths rounded up and counted the
  empty space around the house, so at 69% built it looked 93% full.

### Privacy
- When something inside Moku fails and it carries on (its brain not answering, an update that fails, a file it can't
  save), Moku tells us what kind and where in its own code, from a fixed list, at most once every 10 minutes. Never the
  error's message, a file path or anything on your screen. Listed on /privacy.

### Security
- The relay checks every token's end date, takes an invite's two Macs one at a time, counts an IPv6 address by its
  network, answers a model error with a short code rather than the gateway's words, and allows each model only for its
  own job. A release's brain can't turn on calibration.

## 0.1.9 (2026-10-06)

### Added
- **What's new after an update**: at the first calm moment after Moku updates, the companion says so in its bubble (Moku:
  "I updated! See what's new"; Tetsu: "> updated: see what's new"). A click opens that version on hellomoku.com/changelog;
  ✕ or 15 s closes it. Once per version, never in a meeting, a call, a break or the first minutes of focus.

### Fixed
- Switching between Moku and Tetsu in the welcome is instant (it took 1.2 to 1.6 s with the screen frozen for most of
  it). Every companion load also holds the screen about 40% less, at launch too.
- The menu bar icon opens the popover and nothing else. Settings, Your day or an alert left open behind your apps no
  longer jumps forward with it.
- Moku's little moves are spread across the minute: the ear about 20 s after the look-up and smile, a paw or foot about
  40 s after. They no longer all come together with the smile. Blinks are unchanged.

### Privacy
- Moku tells us more about how it's used, still in numbers and fixed words only: each welcome step, the companion
  switched, hidden and shown, how far detours go and whether the ask works, breaks suggested and taken, what went
  wrong, how quickly things open, what you try again, signs Moku got in the way, updates, whether "What's new" was
  opened, and once a day the day before in numbers. Never your apps, windows, sites, screen, goals or typing. Every
  note is listed on /privacy.

## 0.1.8 (2026-10-05)

### Added
- **Tetsu**, a small desk robot, as a second companion: an LED face, servo moves, a scan beam over your window, a
  hologram of today's rocket, a dot-matrix speech bubble. Choose in the welcome or Settings.
- **"Today counted"**: once a day, as work winds down, a card with today's house, your focused time, how often you came
  back and your longest stretch. A missed day shows the next morning as "Yesterday counted".
- **"Where was I?"**: coming back from a drift of 2 minutes or more, or 10 minutes away, Moku names the task and the
  window you left, with **Take me there**. Never in a meeting, a call or a break.
- **A new welcome**: the live companion greets you by name, shows what it reads, and the screen darkens round the menu
  bar's house, which pulses in place where macOS put it.
- **Your day by task**: the workflow in order, the detours where they happened, the steps in plain words.
- Settings: water and break reminders, easy to find and to switch off.
- A throw sends the companion along its line to the screen's edge, where it stays.

### Changed
- **One behaviour** for everyone: Calm, Lively and the other choices are gone; saved choices are cleared.
- Companions stay seated (no standing or walking for now) and never jump.
- Moku looks like the first version again: whiter, evenly lit, round dark eyes with two sparkles.
- About a third fewer AI calls an hour (343 to 130 in our sessions): a window keeps its answer, lectures and reference
  pages aren't drifts.
- Energy: face shapes on the GPU (about 10% of a core instead of 21.5%), fewer little moves after 10 minutes of
  unbroken focus, faces at 30 Hz on older macOS, a quiet relaunch after a companion change to free memory.

### Fixed
- Permission prompts no longer come back at every launch; Moku asks only in the welcome.
- The popover stays open when clicked from a Mac that holds focus.
- The brain falls back to ports 8021–8029 when 8020 is taken; one Moku runs at a time.

### Removed
- The confetti. Yuzu the cat (kept in git at the `yuzu-archive` tag).

### Security
- Only Moku can talk to its brain (a token); `~/.moku` is readable by you alone.
- The relay passes only the brain's own fields to the AI gateway, sets zero data retention itself, and keeps its daily
  limits under a flood of requests. A wrong flag name can't crash it.
- Invites can be revoked and work on two Macs each; new trials are capped per day.

### Privacy
- **Delete my data** now erases everything at once, including the database's write-ahead log, the logs and the window
  "Where was I?" was keeping.
- Password managers, authenticators, wallets and vault pages are never read.
- History: screen text an hour, the moment-by-moment detail 90 days, each day's summary until you delete it.
- No location in crash reports or model calls; crash reports never name your home folder.
- The privacy page says Your day sends a summary of the day to the AI for its note.

## 0.1.7 (2026-10-02)

### Changed
- The brain's world snapshot no longer burns CPU; Moku's window is sRGB (no colour conversion every frame).
- A behind-the-scenes test of how many AI calls could be skipped (measured only, never acted on; removed in 0.1.8).

## 0.1.6 (2026-10-01)

### Added
- Crash reports to PostHog's error tracking (no screen content).

### Removed
- The TypeScript brain: the Go brain is the only one.

## 0.1.5 (2026-10-01)

### Added
- A beta badge and a Feedback button.

### Changed
- No "thinks on your Mac" anywhere without the local model.

## 0.1.4 (2026-10-01)

### Fixed
- The welcome carries on after macOS's Quit & Reopen; System Settings comes to the front for permissions.

### Added
- Move to Applications.

## 0.1.3 (2026-10-01)

### Added
- Auto-update with Sparkle: a daily check, a quiet download, installed while you're away.
- The app icon: Moku hugging its little house.
- Moku dozes on a break and wakes gently; blinks open slowly.
- Your day grouped by app, with what you did under each.

### Fixed
- Cancelling a break no longer snaps Moku.

## Before 0.1.3

- 2026-09-23, **v0** (`d431760`, tag `v0`): the first Moku. It notices drift and rewards the return, builds a house
  from focused minutes, and lives in the corner of the screen.
