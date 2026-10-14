# Moku: architecture for the first version (runs entirely on Charles's Mac)

Product: `docs/ideas/bunny.md`. Everything runs locally for now. The only network calls are to Jev and Luna on the Vercel AI Gateway (key: `JEV_VERCEL` in `bunny/.env`). Every call asks for zero data retention (`GATEWAY_PRIVACY` in `brain/src/gateway.ts`): the gateway only uses providers that keep nothing and never train on it (the team is on Vercel Pro, which it needs).

## Shape

```
 Moku.app (Swift, app/): the body                  brain-go/ (Go, http://127.0.0.1:8020): the mind  
 ┌─────────────────────────────────────┐          ┌──────────────────────────────────────────┐
 │ MokuSense   sensors → SenseEvent     │  sample  │ POST /v1/judge   quick checks in code,   │
 │ MokuMind    behavior engine, world   │ ───────▶ │                  then Jev (which thread? │
 │             growth, brain client     │ ◀─────── │                  or none), Luna names    │
 │ MokuVisual  bunny overlay, speech,   │ verdict  │ POST /v1/voice   Luna writes one line    │
 │             menu bar world dropdown  │          │ POST /v1/feedback, /v1/events            │
 │ MokuKit     shared contract          │          │ GET  /v1/world, /v1/config, /v1/threads  │
 │ Moku        app shell: wiring        │          │ SQLite ~/.moku/moku.sqlite               │
 └─────────────────────────────────────┘          └──────────────────────────────────────────┘
```

**Rule:** the brain decides *what the user is doing*. The app decides *what Moku does about it*. Reactions (eyes, returns, escalation timing) are local and instant, and never wait on the network. If the brain is unavailable, Moku stays calm: missing data never counts as drift.

## Lanes and ownership

Each lane owns its folder and edits nothing else. Contract changes are requested in `lanes/<lane>.md` and applied by the integrator (Claude, main session).

| Lane | Folder | Builder | Tested on its own by |
|---|---|---|---|
| Contract | `app/MokuKit`, `brain-go/internal/brain/contract.go` | Claude (integrator) | `swift test` |
| Visual: character, micro-interactions, forest, menu bar | `app/MokuVisual` | Astra (Codex, `gpt-6-astra`, high effort, tmux session `moku-visual`) | the `MokuVisualDemo` app: a control panel that triggers every mood, gesture, move, speech bubble and forest stage |
| Sense: what the user is doing on screen | `app/MokuSense` | Claude worker | unit tests plus the `moku-sense` CLI, which prints live `SenseEvent`s as JSON lines |
| Mind: behavior engine, world growth, brain client | `app/MokuMind` | Claude worker | unit tests with a simulated clock, plus a scripted "day" replay |
| Brain: judging, threads, voice, store | `brain-go/` (one native binary in Moku.app) | Claude worker | `go test ./...`: a fake gateway, and the model requests byte for byte against `testdata/` |
| Wiring | `app/Moku` | Claude (integrator) | the whole app on Charles's Mac |

## Contracts

- **Swift:** `app/MokuKit`:
  - `ActivitySample`, `SenseEvent`, `Verdict`, `VoiceRequest`/`VoiceLine`, `Feedback`, `CompanionEvent`, `WorldSnapshot`, `CompanionConfig`.
  - `CharacterStage` and `WorldPresenter`: the protocols MokuVisual implements.
  - `WorldModel`, `ForestStage`.
- **Go:** `brain-go/internal/brain/contract.go` is the same wire types. (The first brain was TypeScript; it was removed on 2026-10-01.)
- **JSON:** camelCase keys, dates as epoch milliseconds (`MokuJSON` coders).
- **Screen points:** AppKit global coordinates (origin at the bottom-left of the primary display, y up).
- **Bundle identifier for every Mac build:** `ai.lightslips.moku`, signed with the local "Apple Development" identity. macOS then keeps the Screen Recording and Accessibility grants across rebuilds.

## Brain judging pipeline (reuses Threads' Understand logic)

1. **Quick checks in code:**
   - In a call or sharing the screen → `meeting`.
   - Long idle with an unchanged screen → `away`.
   - Same app, window and text hash as a recently judged sample → reuse that verdict.
   - A context the user patted → `working` (`override`).
2. **Jev, one item per call** (5 s timeout, 1 retry, at most 8 in flight). One call asks two questions about the same state:
   - Which of the user's active threads does this screen belong to, or `none`?
   - Is it work or a distraction?
3. **`none` + work:** create a thread with a provisional title. Luna names it `"Area · Topic"` in the background.
4. **A model failure** → `unknown`. The engine keeps its previous state and never escalates on `unknown`.
5. **Logging:** every sample, verdict, event and piece of feedback is stored. That's the eval set now and the training data for an on-device model later.

## Behavior defaults (served by `GET /v1/config`)

| Drift length | Moku | Forest |
|---|---|---|
| under 2 min | eyes follow the other window, nothing else | coming back earns return growth |
| 2–5 min | stops smiling, posture shifts (concerned) | growth pauses |
| 5 min | nudge: "Hey, weren't we working on the auth flow?" | |
| 8 min | walks to the center of the screen | |
| 12 min | calls the user's name | |
| 15 min | annoyed; reminds how long the focus lasted ("You were focused for 47 minutes.") | |
| back to work | softens, smiles or nods, walks home | growth resumes |

Growth: about 1 point per focused minute, plus return growth after a short drift (scaled by the focus before it). Stages are in `ForestStage`. Nothing ever shrinks or dies.

## Commands

```bash
cd app/MokuKit && swift test
cd brain && npm install && npm test && npm run dev    # brain on 127.0.0.1:8020
cd app/MokuSense && swift test && swift run moku-sense --duration 30
cd app/MokuMind && swift test
cd app/MokuVisual && swift run MokuVisualDemo
```
