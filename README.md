# Moku

Moku is a small 3D companion that lives in the corner of your Mac while you work. It notices what you're doing. It
gets a little sad when you drift and is glad when you come back. It suggests breaks. Every 10 focused minutes it adds
a piece to a little house, and a new house starts each day. There are two companions: Moku the bunny and Tetsu the
desk robot.

There are no timers and no task lists.

- Website and download: https://hellomoku.com
- Needs an Apple silicon Mac with macOS 15 or later.
- This repository is a snapshot of Moku's source. You can read what Moku reads and sends, build it yourself, and send
  fixes.

## How it works

```
 Moku.app (Swift, app/)                  brain-go/ (Go, 127.0.0.1:8020)            proxy/ (the relay, Vercel)
 ┌──────────────────────────────┐ sample ┌──────────────────────────────┐  token  ┌───────────────────────────┐
 │ MokuSense   what's on screen │ ─────▶ │ rules first, then the model: │ ──────▶ │ to the Vercel AI Gateway; │
 │ MokuMind    behaviour engine │ ◀───── │ work or drift? which goal?   │ ◀────── │ the gateway key stays     │
 │ MokuVisual  companion and UI │verdict │ SQLite in ~/.moku            │         │ on the relay              │
 └──────────────────────────────┘        └──────────────────────────────┘         └───────────────────────────┘
```

- **The app** looks at the app in front, its window title, the web address in a browser, and a short piece of
  on-screen text. It counts typing rhythm, never the keys. It draws the companion with RealityKit and shows Your day
  and Settings.
- **The brain** runs on your Mac and listens on 127.0.0.1 only. It keeps your history in SQLite in `~/.moku`. Its
  rules decide the clear cases: feeds, video, games, the apps people work in, and your corrections. For the rest it
  asks Jev, a cloud model, whether the moment is work or a drift. Luna, a second model, names what you work on and
  writes short lines.
- **The relay** sits between the brain and the Vercel AI Gateway, so no Mac holds the gateway key. It gives each Mac
  a trial token, takes invite codes, holds daily limits and remote switches, and passes on the usage events listed on
  the privacy page. Every model call asks for zero data retention.

The brain decides what you're doing. The app decides what the companion does about it, at once, without waiting for
the network. When the cloud models aren't available (no token, a trial that has ended, the day's share used, or no
network), the brain decides by its rules alone.

Release builds ship no local model (`MOKU_LOCAL_MODEL=0`). The brain has code to run a small model through llama.cpp
while the cloud fails. A build from source includes it only if you run `scripts/fetch-llama-runtime.sh` before you
build; the brain then downloads the model (about 2.1 GB) on its first run.

More: [`docs/architecture.md`](docs/architecture.md) (how the parts fit) and [`docs/rules.md`](docs/rules.md) (how a
moment is judged).

## Repository layout

| Path | What it is |
|---|---|
| `app/Moku` | The app shell: launch, menus, the brain's supervisor, Sparkle updates, crash reports (Swift 6, AppKit) |
| `app/MokuKit` | Shared contracts: the brain's wire types and the protocols the visual layer implements |
| `app/MokuSense` | What's on screen: the app and window (Accessibility), screen text (ScreenCaptureKit and Vision), typing rhythm, calls |
| `app/MokuMind` | The behaviour engine: focus, drifts, breaks, water, celebrations, the brain's client |
| `app/MokuVisual` | Everything you see (RealityKit, SwiftUI). `MokuVisualDemo` is a studio app for the companion |
| `brain-go` | The brain: a local HTTP server (pure Go, SQLite through `modernc.org/sqlite`, no cgo). See `brain-go/README.md` |
| `proxy` | The relay: Node.js 22 functions on Vercel, no dependencies. See `proxy/README.md` |
| `website` | hellomoku.com (Vite, three.js, Motion) |
| `assets` | The companions, houses, icons, and the Blender scripts in `assets/src` that make them. Not MIT licensed: see below |
| `scripts` | Build, sign, notarize, release and check scripts (zsh, Python) |
| `eval` | Results of the evaluation that picked the local fallback model |
| `docs` | The architecture, the judging rules, and a privacy explainer |

Some comments refer to internal notes (`docs/specs/…`, `ACTIONS.md`) that aren't in this repository.

## Building and testing

You need an Apple silicon Mac with macOS 15 or later, Xcode 26 or later (Swift 6; `actool` compiles the app icon),
Go 1.25.5 or later, Node.js 22 or later, Python 3, and zsh (the macOS default).

The tests:

```bash
(cd app/MokuKit && swift test); (cd app/MokuSense && swift test); (cd app/MokuMind && swift test); (cd app/MokuVisual && swift test)
(cd brain-go && GOTOOLCHAIN=local go test ./...)
(cd proxy && npm test)
(cd website && npm test && npm run build)
```

Run `npm ci` in `website/` once before its tests. The brain's tests include its model requests, byte for byte
against `brain-go/internal/brain/testdata/`. The tests that call the real models are skipped unless you ask for them
(`MOKU_LIVE=1`).

The app:

```bash
scripts/build-app.sh          # builds build/Moku.app, with the brain built from the last commit
scripts/moku.sh start         # builds and opens it; scripts/moku.sh logs follows ~/.moku/app.log and brain.log
```

`build-app.sh` signs with your Developer ID Application identity, or your Apple Development identity when there is
none, so you need one of the two in your keychain (Xcode makes an Apple Development certificate for any Apple ID).

Moku asks for Accessibility in its welcome. Screen Recording is optional and Settings offers it. macOS keeps both
grants across rebuilds while the bundle id and the signing identity stay the same. If you fork Moku, change the bundle
id (`ai.lightslips.moku`: `scripts/build-app.sh`, `SenseHub.swift`, `IgnoredApps.swift`) so your build doesn't share
grants and settings with an installed Moku.

The brain on its own, the relay and the website have their own READMEs: `brain-go/README.md`, `proxy/README.md`,
`website/README.md`. `app/MokuVisual/README.md` describes the companion's studio app. Releases (`scripts/release.sh`)
need the maintainers' Developer ID, notarization profile and update signing key.

## Configuration

A development build talks to the same relay as releases (`https://moku-proxy.vercel.app`, set in
`scripts/build-app.sh` and `RelayAccess.swift`). Without a model key of its own, it gets a trial token on its first
launch, like any new Mac. It sends the usage events listed on the privacy page. Only release builds send crash
reports.

To use your own models or your own relay instead, copy [`.env.example`](.env.example) to `.env` (git-ignored). The
main settings:

| Variable | Read by | What it does |
|---|---|---|
| `JEV_VERCEL` | the brain | Your own Vercel AI Gateway key: the brain calls the models directly |
| `MOKU_GATEWAY_URL`, `MOKU_ACCESS_TOKEN` | the brain | Your own relay and its token |
| `MOKU_MODEL_JUDGE`, `MOKU_MODEL_WRITER` | the brain | Other models (defaults `typesafe-ai/jev` and `openai/gpt-6-luna`) |
| `MOKU_HOME` | the app, the brain | Where Moku keeps its data (default `~/.moku`) |
| `MOKU_LOCAL_MODEL` | the brain, `build-app.sh` | `off` stops the brain from using a local model; `0` leaves llama.cpp out of a build |
| `MOKU_SIGNING_IDENTITY` | `app/MokuVisual/scripts/run-demo.sh` | The identity that signs the studio app (default: ad hoc) |

To run your own relay, deploy `proxy/` to Vercel with the variables in [`proxy/.env.example`](proxy/.env.example),
and change the relay address in `scripts/build-app.sh` and `RelayAccess.swift`.

## Privacy

Moku reads your screen, so this matters most. What it learns stays on your Mac, in `~/.moku`. Screen text is deleted
within an hour. What goes to the models is sent with zero data retention, and nothing is sold or used for training.
The policy of record is https://hellomoku.com/privacy (its source is `website/privacy.html`).
[`docs/privacy.md`](docs/privacy.md) is a working draft that goes into more detail; where the two differ, the
website's policy applies.

Questions: hello@hellomoku.com.

## Contributing

Issues and pull requests are welcome. This repository is a snapshot of a private one. The maintainers apply an accepted
change to the private source, and it appears here in the next snapshot. By contributing, you agree that your
contribution is licensed under this repository's license.

Keep secrets out of commits: `.env` files are ignored, and CI runs [gitleaks](https://github.com/gitleaks/gitleaks) on
every push and pull request. To report a security problem privately, see [`SECURITY.md`](SECURITY.md).

## License

The source code is under the [MIT license](LICENSE).

The art is not: the companions, their models, animations and textures, the houses, the icons and the concept art
(everything in `assets/` except the scripts that make it, and the companion and house media in `website/public/`) are
all rights reserved. See [`assets/LICENSE-ASSETS.md`](assets/LICENSE-ASSETS.md). The names Moku and Tetsu and the app
icon are reserved too.

Third-party components keep their own licenses: see [`NOTICE`](NOTICE).
