# MokuVisual

Swift 6 / macOS 15 character stage and forest presenter implementing `MokuKit`.

```sh
swift test
scripts/run-demo.sh
```

The script builds release, copies the runtime assets and app icon, bundles and locally signs `.build/MokuVisualDemo.app` as `ai.lightslips.moku.demo`, then opens it. Pass `--build-only` to package without opening it. It signs with the identity in `MOKU_SIGNING_IDENTITY` (a name from `security find-identity -v -p codesigning`), or ad hoc (`-`) when that isn't set. Close the studio window to keep the companion; use **Quit Moku Visual Studio** (⌘Q) to exit.

The controls cover all moods, gestures, cursor attention, movement, hide/show, independent thread labels, speech tones, forest growth and a scripted day. Clicking the bunny opens its world. A head stroke with a horizontal reversal is a pat; it never also generates a click.

## Integration

```swift
let stage = MokuVisualFactory.makeStage()
let world = MokuVisualFactory.makeWorld(model: worldModel)
stage.onClick = { world.openWorld() }
stage.show()
```

Retain both presenters. All contract methods run on the main actor. `move(to:)` suspends until arrival or interruption; a new move cancels the previous waiter and redirects from the current position. Screen coordinates follow AppKit (global, y up).

Assets resolve from an explicit `MOKU_ASSETS_DIR` pin (`MOKU_ASSET_ROOT` is a compatibility alias), `Bundle.main/Contents/Resources/MokuAssets`, then the repository's `assets/`. Character files are the chosen companion's (`Companion.swift`): Moku's are `character/…`, Tetsu's `character/<id>/…` under the same names (the model is `<id>.usdz`), and the day's home is `world/<id>/` once bundled (the cottage otherwise). `MOKU_COMPANION=<id>` starts a process with that companion without touching the saved choice. Paths, joints, blend shapes and clips follow `assets/SPEC.md`. Missing art falls back to the procedural puppet with a log message. When real assets are present, nothing is shown until their first rendered frame; there is no stand-in flash.

- `assets/runtime/materials.json` controls post-import PBR settings. Names and aliases match exactly; imported material identity/UVs survive. Albedo is color data, normals are linear, numeric tints are linearSRGB.
- Optional `assets/runtime/studio.json` overrides the bundled studio. Camera `safeAreaFraction` reserves shared expression room (the app default is 0.74); projected world ground aligns the character and lantern. Camera and punctual lights use `position`, `target` (camera), `fieldOfView` (camera), `color`/`intensity` (lights). `environmentColor` (sRGB triplet) and `environmentIntensityExponent` control soft image-based fill. Optional `environmentCubeSize` bounds the low-frequency studio cubemap (default 64); a light can opt out of shadows with `castsShadow: false`, or set `shadowScale` for its fixed projection.
- Current RealityRenderer imported multipart facial mappings did not deform visibly. The local morph driver copies the USD's sparse authored deltas and retains an immutable generated source mesh with dense morph buffers removed. It installs a separate new skinned mesh when quantized weights change. It never calls `MeshResource.replace(with:)` or mutates its source resource. The runtime entity and cached clip definitions are detached from their original USD import graphs. No dangling blend-shape component remains on the rig.
- Native sampled joint clips play on `Rig`. Their separate sampled face channels are blended with the current mood. The water cup follows `hand_R` using `prop_attachments.json`, including its authored root conversion and visibility interval.

## Rendering and performance

RealityRenderer renders transparent sRGB BGRA frames to a shared Metal target. The exact alpha image supplies hit testing. Core Animation supplies cached breathing, reading saccades and blinks; gaze/mood events briefly wake the real renderer. Explicit gestures and travel use up to 60 fps. Hidden stops timers, monitors, travel, speech and rendering after the short visibility fade.

The world uses supplied transparent forest renders and stage template icons, avoiding a second continuous 3D scene. Growth uses a high-water mark within the presenter so stale snapshots cannot shrink it. Thread/stat updates use Observation, without closed-popover polling.

## Offscreen verification

These commands create no overlay, status item, label, bubble or studio window and exit automatically:

```sh
swift build -c release
.build/release/MokuVisualDemo --offscreen --capture-all "$PWD/screenshots/review"
.build/release/MokuVisualDemo --offscreen --benchmark "$PWD/screenshots/performance.json"
.build/release/MokuVisualDemo --offscreen --stress "$PWD/screenshots/stress-5min.json"
```

The stress test runs for at least 300 seconds, cycles every mood and gesture, exercises attention and thread labels, and records before/after `.ips` lists, frame count, first-visible source, CPU and memory. The benchmark reports resident CPU memory and GPU-inclusive `phys_footprint` separately. It disables the demo's own telemetry and measures process CPU time over 30 seconds idle and 15 seconds hidden, plus resident memory and an isolated eight-mood transition measurement. Hidden records the exact frame-count delta, which must be zero.

From the repository root, `swift app/MokuVisual/scripts/contact-sheets.swift` assembles the untouched render captures with the Blender/concept reference. It writes `color-check.png` and `moods-grid.png`.

Desktop-wide `screencapture` is unavailable in this session. Captures are app-owned renders; they do not prove actual click routing into another app, full-screen Space behavior or physical multi-display placement. Geometry, recognition, expression blending, high-water growth and interruption are tested separately. See `../../lanes/visual.md` for measurements, known gaps and milestone evidence.

For allocation diagnosis, `MOKU_PROFILE_MEMORY=1` logs startup phases. `scripts/renderer-memory-probe.swift` isolates the installed framework using an empty scene; compile it with `swiftc -parse-as-library` and run the result offscreen.

Manual control is shared by the demo and real app:

```swift
let controls = MokuVisualFactory.makeManualControl(
    stage: stage, world: worldModel, presenter: presenter, scenes: scenes)
presenter.onManualControl = { enabled in
    // The app pauses/resumes sensing and mind activity here.
    presenter.setManualControl(enabled)
    if enabled { controls.open() } else { controls.close() }
}
controls.onClose = { presenter.setManualControl(false) /* app resumes sensing */ }
```

The panel owns its chain/scene tasks and cancels them on close. Scene closures must cooperate with cancellation. Recording captures values at button press. A step with wait 0 starts alongside the following step; a positive wait finishes that concurrent group, then sleeps. Loop, Stop, Clear and per-step removal are available. Manual celebrations cue the icon without queuing a replay celebration for a later popover opening.

Brief 2 offscreen verification (does not open or terminate the real app):

```sh
swift build -c release
.build/release/MokuVisualDemo --offscreen --brief2 screenshots/review
.build/release/MokuVisualDemo --offscreen --benchmark screenshots/performance-brief2.json
.build/release/MokuVisualDemo --offscreen --stress screenshots/stress-brief2-5min.json
```

Gaze is normalized to the visible screen. Pupil motion uses named pupil/catchlight materials and measured imported bounds; lighting and plush materials remain configured by the asset JSON. Hover requires 300 ms on the actual silhouette, settles into a cached happy face and recovers in 400 ms. Drift glances use WorkState tiers, hold the last work point, and reject subsequent drift-window look targets. Grace is quiet; noticing permits one glance; later gaps are jittered with a 45 s floor, eight per drift, and an 8 s speech/travel/gesture cooldown. Micros render at 12 fps, with repeated poses cached. Reduced Motion uses brows/blinks only. Disappointed folds paws in its lap; annoyed crosses arms at chest height, using distinct asset-defined entry/release clips.

## v1 P0

`setWorkState(_:)` drives the standing lantern and gaze budget; `celebrateReturn(_:)` drives the small/full silent return beat. All nine states and both returns are recordable in the shared manual controls. Lantern sprites and manpu read asset manifests. The carried lantern reads its hand attachment/hold pose and emissive material names from data. The optional face atlas stays opt-in; this stage uses the complete authored morph face.

A click opens the world. A head stroke with reversal pats. Sustained movement beyond 8 pt (or holding 250 ms before moving) grabs; a fast release flings with damped edge bounces. Landing establishes home, persisted as usable-display-relative coordinates under a stable display UUID. `.home` returns there. The quiet dropdown reset restores the default corner. Offscreen testing uses a separate preferences suite and never alters the real app's home.

```sh
scripts/run-demo.sh --build-only
.build/MokuVisualDemo.app/Contents/MacOS/MokuVisualDemo --offscreen --v1-p0 screenshots/review/v1-p0 --v1-perf screenshots/performance-v1-p0-final.json
python3 scripts/v1-review.py
python3 scripts/verify-v1-p0.py
```

`--v1-perf` measures 35 s of focused idle (cached reading), 150 s of drift (real tiered glances), and 15 s hidden. Run the five-minute stress flag separately to reproduce its crash report. The review gallery is `screenshots/review/v1-p0/index.html`. Its numbered stranger sheets and silhouette test are prepared for Charles; five-person recognition and occupied-desktop hardware checks are not fabricated. P1 is held until that review.
