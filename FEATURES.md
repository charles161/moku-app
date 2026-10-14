# What Moku does today

The features that are live, in which version, and how they're switched. `CHANGELOG.md` says when each arrived. Update
this file in the same commit as any change to what's live, and at every release.

Status: **live** (in the latest release), **next** (merged on `home`, in the next release), **calibration** (only in
Charles's `MOKU_CALIBRATE=1` build), **off** (built, switched off), **planned** (specced, not built).

Latest release: **0.1.13** (2026-10-14). Apple silicon, macOS 15 or later.

## The companion

| Feature | Status | Since | Notes |
|---|---|---|---|
| Moku the bunny | live | v0 | The first version's look again since 0.1.8 |
| Tetsu the desk robot | live | 0.1.8 | LED face, servo moves, scan beam, hologram |
| Choose your companion (welcome, Settings) | live | 0.1.8 | |
| Seated only, no standing, walking or jumping | live | 0.1.8 | Walking is a later project |
| Drag and throw to a screen edge | live | 0.1.8 | |
| Little moves spread across the minute | live | 0.1.9 | The ear about 20 s after the look-up, a paw or foot about 40 s after |
| Sad on a drift, glad on the return, the ask | live | v0 | One behaviour for everyone since 0.1.8; sad only, never angry, since 0.1.11. **Next:** one sad move (a sigh, a look at you), then the normal face and its eyes back on the work; the ask has no words |
| Look-up and smile every minute of focus | live | v0 | Eyes open since 0.1.11 (closed happy eyes are a pat's or a hover's) |
| Dozes on a break, wakes gently | live | 0.1.3 | |
| Hides for full-screen video | live | 0.1.12 | A window spanning the display with no menu bar (`FullScreenRules`) whose app keeps the display awake (a power assertion: playing) or is for watching (QuickTime, IINA, VLC, TV…), or a browser in front on a site for watching (YouTube, Instagram, Netflix…: `MediaPlayback.isMediaPage`, from the address already read); a pause keeps it hidden until full screen ends, or until that browser moves to a page of work (`FullScreenMedia`). A full-screen editor doesn't hide it. Watched through a break too. Not for another display's film, the welcome, or over a call or "Hide Moku" |
| Apps where Moku steps aside | live | 0.1.12 | Settings › Privacy: any number, from open apps or Applications. In front, Moku hides. Per app: "Hide Moku" (still watched, the work counts) or "Hide, don't watch" (nothing read, judged or sent; calls still noticed from the mic, camera and other windows). `IgnoredApps` in MokuKit (cached, reloaded on save), read by SenseHub |
| Trial only for a real Mac running Moku (Apple App Attest) | next, **dark** | | Built and tested, off until Apple's portal gives a Developer ID profile (docs/specs/app-attest.md). The relay's `attestation` flag: `off`, `observe`, `require`. Install asks Apple only when the relay does; invites and Macs seen before are never refused. `scripts/check-attest.sh` proves a profile works |
| Follows you across screens | live | 0.1.12 | One companion; after 30 s of work on another display it fades (seated) to that display's home, which becomes its home display. Only while focused; a glance back resets the wait (`ScreenFollow`) |
| Correct Moku from its right-click | live | 0.1.12 | "This is work" in a drift (relabeled from the drift's start, learned, settles like a pat), "This isn't work" while working (relabeled from when the window came up, learned, no sad move for 3 minutes); the brain's correction takes `since` |
| The task you're on | live | 0.1.8 | **Next:** no automatic label; a nod when you start on a task, and a hover shows the task and its minutes today |
| Speech bubbles in each companion's style | live | 0.1.8 | Tetsu: dot-matrix LED. **Next:** only What's new, the break's end and the care prompts (water, eyes, stretch, walk); no ask, welcome back, greeting or celebration lines (the friends, 2026-10-14) |

## Your work and your day

| Feature | Status | Since | Notes |
|---|---|---|---|
| Judging work or drift (Jev, through the relay) | live | v0 | Zero data retention on every call |
| Goal-aware judging | calibration | | Ships to friends after Charles's 200 ratings pass the bar (`/calibrate`) |
| A house a day, a piece per 10 focused minutes | live | v0 | Moku's cottage, Tetsu's rocket |
| Your day by task | live | 0.1.8 | |
| "Today counted" | live | 0.1.8 | Once a day, from 4 pm |
| "Where was I?" and Take me there | live | 0.1.8 | **Next: removed** (the friends, 2026-10-14: "100% inaccurate") |
| Breaks and water reminders | live | v0 | Their controls in Settings since 0.1.8 |

## The Mac app

| Feature | Status | Since | Notes |
|---|---|---|---|
| The welcome (A + C) with the menu bar spotlight | live | 0.1.8 | Shown once; finished or skipped. **Next:** asks only for Accessibility; Screen Recording is optional, offered in Settings |
| The menu bar icon opens only the popover | live | 0.1.9 | |
| The menu bar house fills as the popover's percent | live | 0.1.10 | By the house's own shape (MenuBarHouse.swift) |
| Your day's numbers agree everywhere | live | 0.1.11 | One source per number, checked by numbers_agree_test.go; the app reports what's left (numbers_disagree) |
| Hidden for a call until it's been over 30 s | live | 0.1.11 | A call that drops for a moment no longer flashes the companion back |
| Auto-update (Sparkle) | live | 0.1.3 | Daily check, installs while you're away; small updates (deltas) and retries after 10 min, 30 min and 2 h since 0.1.10; Settings shows the last check |
| Crash reports (PostHog) | live | 0.1.6 | **Next:** a report counts as sent only when PostHog answers, and is tried again (launch, a minute later, hourly); the brain's own reports (`moku-brain-…`) are found; `app_opened` says how the last launch ended (`previous_exit`: clean or unclean), through the relay |
| Errors Moku carries on from (app and brain, to PostHog) | live | 0.1.10 | Kind and place only, rate limited; website errors since 2026-10-06 |
| Usage events (always on) | live | 0.1.8 | 38 events since 0.1.9, listed on /privacy |
| Deeper analytics (19 metrics, task success, repeats, frustration, lags, updates; 12 dashboards) | live | 0.1.9 | Charted in PostHog |
| "What's new" after an update | live | 0.1.9 | Once per version, at the first calm moment; links to /changelog#<version> |
| Local model fallback | off | | Release builds ship none (`MOKU_LOCAL_MODEL=0`) |

## Data and privacy

| Feature | Status | Since | Notes |
|---|---|---|---|
| Screen text kept an hour | live | 0.1.8 | 14 days in the calibration build |
| Detail kept 90 days, each day's summary until deleted | live | 0.1.8 | |
| Delete my data erases everything | live | 0.1.8 | Your name and settings stay |
| No password managers, authenticators, wallets or vault pages read | live | 0.1.8 | |

## The relay (moku-proxy)

| Feature | Status | Notes |
|---|---|---|
| Model calls with the gateway key held server side | live | Rebuilds each request from the brain's own fields; each model only on its endpoint; gateway errors as a code word |
| Trials, invites (revocable, 2 Macs each), new trials capped 20 a day | live | Upstash Redis; the 2-Mac cap atomic, tokens' end dates checked, IPv6 limits by /64 (2026-10-06) |
| Remote flags and the kill switch | live | cloudJudging, cloudVoice, forceCalm, minVersion, limits |
| Usage events allowlist, download counts | live | |
| Moku Pro through Dodo ($6 a month, $48 a year) | next, **test mode** | `/v1/checkout` (a hosted checkout with the Mac's id), `/v1/dodo` (verified webhooks, each once), Pro tokens on `/v1/renew` to the paid end plus 3 days; Pro capped at 3,000 calls a day. The app's button (Settings › Moku’s brain) and its renewals (daily, and every 30 s for 15 minutes after a checkout) ship in 0.1.13; the button answers "isn’t open yet" until Dodo's keys are set |

## The website (hellomoku.com)

| Feature | Status | Notes |
|---|---|---|
| The live hero demo: one camera, it notices you | live | Real work windows, a visible drift, state labels; stills first on slow networks |
| The house section on slow networks | live | The house you scroll to at once (thumbnails), sharp in seconds (`check:house`) |
| Checked in Chromium and WebKit on seven screens | live | `check:browsers`; Firefox not yet (its test browser doesn't start on this macOS) |
| Phones and tablets layout | live | |
| Moku and Tetsu, a daily home, Your day, questions | live | |
| /privacy, the policy of record | live | Matches 0.1.10 |
| Security headers (CSP, nosniff, no framing) | live | |
| /changelog, written from CHANGELOG.md | live | An anchor per version for "What's new"; `npm run changelog`, a test fails when it's stale |
| Visits and downloads counted, without cookies | live | Since 2026-10-09. `visits.js` → relay /v1/web-visit → PostHog (its Web analytics view, and Moku · Website); /download through /get (docs/specs/web-analytics.md) |
| Vercel Web Analytics and Speed Insights | live | Since 2026-10-10. `src/vercel-insights.js`, after the page loads, on hellomoku.com only, not for Global Privacy Control or Do Not Track. Vercel's dashboard: Analytics and Speed Insights (docs/specs/web-analytics.md) |
