# Moku privacy policy

*Draft, 2026-09-30. Before it goes on the site, fill in the domain, the contact email and the company name. Last updated: [date].*

Moku is a small companion that sits in the corner of your Mac and notices when you're focused and when you drift. To do that it looks at what's on your screen. This page says exactly what it reads, what it keeps, what leaves your Mac, and what never does.

**The short version:**
- Everything Moku learns about you stays on your Mac.
- Screen text is read, turned into a short description of what you're doing, and deleted within an hour.
- No account, no ads, and we never sell anything about you.

## What Moku reads on your Mac

Every few seconds Moku looks at:
- **The app in front and its window title,** plus the web address when it's a browser.
- **The text on screen** when it changes (never in password managers, authenticator apps, crypto wallets or
  password-vault pages; their window titles aren't sent either). It reads this through macOS Accessibility or, when that isn't enough, by reading the screen with on-device text recognition.
- **How active you are:** keys, clicks and scrolls per minute, and seconds idle. These are counts, never what you type.
- **Whether you're in a call** or sharing your screen, so Moku keeps quiet.

Moku needs two macOS permissions for this: Accessibility and Screen Recording. You can turn either off in System Settings at any time.

## What Moku keeps, and where

Everything is in one folder on your Mac, `~/.moku`, readable only by your macOS user:
- **What Moku worked out from each moment:**
  - whether you were focused, drifting, away or in a meeting
  - a short description ("building the booking flow")
  - a general bucket ("building", "watching")
  - the line of work it belongs to
  - the time spent
- **The app, window title and web address** for each moment, so Moku can show your day and remember what you taught it.
- **The record of Moku's AI requests** (what it asked and what came back; never screen text, which is gone after an hour).
  These three, the moment-by-moment detail, are kept **for 90 days**, then deleted. A day's detail goes once the whole day is
  more than 90 days old; Moku clears it in the background while it runs, one day at a time.
- **Each day's summary, until you delete your data.** Before a day's detail goes, Moku saves what Your day shows for that day:
  the time per goal, with the apps, sites and window titles behind it and what was done in plain words, the detours and
  comebacks, what you finished, the day's ribbon of segments, your house and Moku's note. That is all that is left of a day
  after 90 days, and Your day keeps showing it.
- **What you taught it:** a pat on the head, or "this was work" / "this wasn't work".
- **Your home's progress** and Moku's settings. Your all-time totals (focus minutes, minutes per goal, growth) are kept.
- **Screen text,** for one hour at most. Moku needs it for a few minutes (to tell whether a window changed, and to describe what you're doing), then deletes it. Text still on screen is kept until it's gone from the screen, then deleted within the hour. (Charles's own calibration build, never released, keeps it up to 14 days so his rated moments can be replayed; any other build deletes it after an hour again from its first start.)
- **Logs** of what Moku did (app names and names of your lines of work, never screen text). They're capped in size.

**Settings › Privacy › Delete my data…** (under "Your data") erases all of it at once, the saved summaries too. Uninstalling Moku and deleting `~/.moku` removes everything.

## What leaves your Mac

**1. Moku's cloud brain, when it's on.**
- **What's sent:** to decide whether a moment is focus or drift, Moku sends Jev (our evaluation model) the app name, window title, web address and up to about 1,500 characters of the screen's text. To tell which of your goals it belongs to, and to name a new goal, Jev and Luna also get the short titles and one-line summaries of your recent goals (with goal-aware judging, with every screen Jev judges). To write its short lines and your day's note, Moku sends Luna (a writing model) descriptions like "building the booking flow", never raw screen text.
- **How it travels:** through our relay (a small server on Vercel) to the Vercel AI Gateway, with **zero data retention**: the model providers don't store it or train on it.
- **What the relay logs:** one line per request (your install's anonymous ID, the model, whether it worked, how long it took). It never logs what was sent.
- **Turning it off:** without the cloud brain (no trial, no invite, or offline), Moku uses a small model that runs entirely on your Mac, and nothing is sent.

**2. Your free trial or invite.** On first launch Moku sends our relay a one-way hash of your Mac's hardware ID. That hash can't be turned back into the ID, and it's useless to anyone else. It lets your trial survive a reinstall. We keep the date we first saw that hash. There's no name, email or account.

**3. How Moku is used, always on.** There's no switch. When one of these happens, Moku sends our relay a short note,
with only the details listed (a yes or no, a number in steps, or one of a few fixed words), the Moku version and the
companion on show (Moku or Tetsu):
- Moku opens: first time or not, the macOS major version, memory in steps (8, 16, 24, 32+ GB), opened at login, after
  an update or by the person, whether Accessibility and Screen Recording are on, the companion, how many displays, and
  whether Reduce Motion and Low Power Mode are on. Moku quits: minutes it ran, and how (its menu, logout, an update, a
  relaunch, other).
- Updates (Sparkle's delegate): each check (up to date, found, or an error's kind), a download (the version), the first
  launch of an update (from, to, hours since its release), and why a Mac hasn't updated (download or signature failed,
  waiting a day for the person to step away, no permission, not in Applications, automatic updates off).
- The welcome: each step it reaches (opened or picked up again, the hello, a companion picked, what it reads, each
  Allow, Quit & Reopen, Start or Skip); whether each permission was allowed there, and the seconds since its Allow; whether it was finished or skipped,
  with how many seconds it took; closed early: the last step and the seconds.
- The companion switched (from, to, welcome or Settings); hidden or shown (by the person, or for a call or screen
  sharing; shown after how many seconds).
- The popover opens (from the menu bar or a click on Moku, and the milliseconds it took). The companion appears after
  launch: milliseconds since Moku opened, and whether the stand-in was drawn.
- The same action again within 30 s (`repeat`: Take me there, a setting, Your day, hiding, a break, the popover opened
  and shut at once; how many times). Frustration: three quick clicks on the companion; hiding it, "this was work" or a
  pat, or quitting soon after a nudge; Delete my data. Only which. Your day opens: from where (the popover's button, its house
  or its numbers, a right-click menu, a moku:// link, the "Today counted" card); loaded: milliseconds, and whether the day showed; closes: seconds open, parts unfolded.
- One of the popover's controls is used, or the same item in the icon's right-click menu: which (a break, hide or show,
  Settings, say hi again, put back in the corner, feedback, quit), and whether from the popover or the menu.
- Settings opens: which tab, and each tab switched to. A setting changes: which one, for a switch on or off, never its
  value; then whether it stayed changed for 5 minutes or was changed back, with the seconds. A permission is turned on in
  Settings: which one, and the seconds since "Turn on…".
- The first ten focused minutes: minutes since Moku first opened.
- A detour: each ladder step reached (sad, cross, long, sitting up tall, the ask); after the ask, back within 2 minutes,
  later or not that day, with seconds. A comeback: how long the detour lasted, in steps, and whether it's the first of
  the day. "Where was I?": shown (after a detour or an away; the window already in front or not); "Take me there" used: whether
  the app came forward, and the milliseconds.
- A house piece is earned: how many today. "Today counted": shown, opened, closed, gone by itself or missed; yesterday's
  or a goodbye.
- A break suggested (water, stretch, look away, walk). A break starts, ends or is cut short: which, and how (popover,
  Moku, a moku:// link, the timer, back to work); a start says whether one was suggested in the 10 minutes before, an
  end how many seconds it lasted.
- A correction: a pat, "this was work" or "this wasn't work", not what it was about.
- Something fails inside Moku that it carries on from (`app_error`): a kind from a fixed list (the brain not answering,
  too slow, refusing or failing a request; an answer from the brain or the relay it can't read; Sparkle failing; the
  companion or its home not loading; a file it can't save; an error inside the brain, read from its /health), the
  error's family and number ("url -1004"), where in Moku's code ("BrainClient.swift:today"), and how many times. Never the
  error's message or a path. The relay passes it to PostHog as an `$exception` with level "error". The same kind from the
  same place at most once in 10 minutes, and 30 an hour at most.
- Something goes wrong (`trouble`): a kind from a fixed list (brain restarted or down, relay 401/402/403/429 or down,
  offline, cloud off, the stand-in drawn, a permission lost, the store set aside), a count and seconds; each kind at most
  once in 10 minutes.
- Once a day, the day before in numbers (`day_summary`): minutes at the Mac and focused, comebacks, longest stretch;
  detours by step; pats, hovers, carries, throws and clicks on the companion, clicks on the menu bar icon, popovers
  opened and closed at once; minutes hidden; talents played (scan, hologram, petals, sniff) and water reminders;
  judgments by kind (work, switch, detour, not sure) and corrections; the brain's, Jev's and Luna's answer times (median
  and 95th percentile, in steps); median memory (50 MB steps) and share of a core (in steps); main-thread stalls over
  250 ms and frames dropped during moves; days since Moku first opened; the macOS major version.

The relay checks each note against this list (`proxy/api/_lib/events.js`) and drops anything else, then passes it to
PostHog with the short device id, the plan (trial, or the invite's name) and the approximate country, never the IP
address. Never sent: app names, window titles, addresses, screen text, goals or names of work, the person's name, or
anything typed. Offline, notes wait on the Mac (200 at most, a week at most); the day's counts wait in
~/.moku/usage-day.json until the day is over.

**4. Daily counts, only if you turn them on.** In Settings › "Share daily counts", off by default. Once a day Moku sends numbers about the day before: minutes focused, how many nudges and corrections, whether the cloud brain answered, Moku's version, and its CPU and memory use. The relay passes only numbers on to PostHog, our analytics service. No text, no app or site names, no titles.

**5. The on-device model download.** The first time it's needed, Moku downloads its small local model (about 2 GB) from Hugging Face. Hugging Face sees that download like any other.

**6. Updates.** Moku checks our site once a day for a new version, and also when the relay says its version is too old
(at most once an hour). The check doesn't include anything about you.

**7. Moku's switches.** About every ten minutes Moku asks our relay whether any of its switches have changed (whether
the cloud brain is on, whether Moku should stay calm about drifts, the oldest version to keep). The request carries the
hash of your Mac's hardware ID and Moku's version, with the access token Moku got for its trial or invite. Nothing else.
The relay logs one line (the plan, the short device ID and the version) and keeps nothing else.

**8. The website.** hellomoku.com sets no cookies and has no third-party trackers. It keeps two of the visitor's own
choices in browser storage (`moku:motion-paused`, `moku:work`), which never leave the browser.

It counts visits without cookies (`website/src/visits.js`, the relay's POST /v1/web-visit, `proxy/api/_lib/web-visits.js`).
Each page view gets a UUIDv7 kept only in the page's memory. Four events, each field checked by the relay's allowlist:
`pageview` (the page; `?ref=` or `utm_source` as one word; the referring site's host name; phone, tablet or computer),
`pageleave` (seconds open, seconds in view, how far down it was read), `download_clicked` (which button) and
`companion_picked` (which companion, hero or friends). The relay adds the browser's and system's family and the country
(`x-vercel-ip-country`), and sends it to PostHog under PostHog's Web analytics names, with no person profile, no
location lookup, no IP address and no User-Agent. Nothing is sent when the browser sends Global Privacy Control or Do
Not Track, or off hellomoku.com. Limits in the relay's memory: 300 a day from one address, 50,000 in all.

Downloads: hellomoku.com/download redirects to the relay's GET /get, which counts one `download` (the link's `ref`, or
`site` from the site's buttons, or `direct`; the country; a new random ID), then redirects to the DMG. Bots and link
previews (WhatsApp, Facebook, Slack…) aren't counted.

If the website breaks in your browser, it tells
me what broke: the error's name and message (a web address in it cut to the site and the page, no query), where in the
site's own script (file, line, column), which page, and the browser's and system's family ("Safari on macOS", read
from the User-Agent by the relay, which keeps nothing else of it). It goes to the relay's POST /v1/web-error with
`navigator.sendBeacon`, and on to PostHog as an `$exception` with a new random ID each time, no person profile and no
location; no cookie, no IP address (the per-address limit keys on a hash of it). Errors from other scripts in the
browser (an extension) aren't sent; five a page at most, 20 a day from one address.

## What we never do

- Sell or rent anything about you, or use it for ads.
- Send screen text anywhere except the moment Jev reads it, with zero data retention.
- Keep screen text on your Mac for more than an hour.
- Add third-party trackers or advertising SDKs to Moku.

## Children

Moku isn't made for children under 16, and we don't knowingly collect anything from them.

## Changes and contact

If this policy changes, we'll update the date above and say so in Moku's release notes. Questions or requests: [contact email]. You can also delete everything yourself at any time: Settings › Your data › Delete my data.
