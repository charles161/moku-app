# Moku art package

Brief 4: synchronized hop locomotion, seated rear-up, revised gestures, full-volume ear in-betweens, clean blink closure, an instanced craft home with layered blueprints and 200 forest slots, plus onboarding wave/name-tag art. The exact v0 LOP rest is preserved. Human stranger recognition testing remains pending.

Start with [the before/after sheet](previews/moods-before-after.png), [micro expressions](previews/micro-expressions.png), [the review gallery](previews/index.html), [120 pt concept comparison](previews/compare_sheet.png), and [asset contract](SPEC.md).

## Runtime entry points

- Character: `character/moku_bunny.usdz` — 52,011 triangles (38,984 and 13,027 for the fuzz shell), 21 joints, 80 named morphs.
- Expressions: `character/moods.json`; 34 clips: `character/animations.json` and `character/anims/`.
- Lighting baseline: `runtime/studio.json`. Apply post-import material data from `runtime/materials.json` to retain the intended fabric sheen. Imported color/normal textures and roughness already survive loading.
- Felt (look v2, `docs/specs/moku-look-v2.md`): occlusion is baked at rest into Moku's colour textures (`src/occlusion.py`, called from `species_moku.finish_mesh`): `felt_color.png` (body, arms, feet, ear backs, one packed UV layout), `ivory_felt_albedo.png` (head, spherical layout with the blush), `petal_felt.png` (pads, toes, inner ears), `milk_felt.png` (tail). The body and pink use `felt_normal.png` (eight repeats); the head and tail keep `plush_normal.png`. The eyeball and pupil disc share `eye_iris.png`, mapped flat in eye space. Moving parts (arms, ears) cast no baked shade on the body or head. The fuzzy edge (step 4): `src/fuzz.py` copies the cream felt, the head and the tail 7 mm out (in tufts) where the felt can be the outline, inside the same skinned mesh, so every shape key and joint carries it; materials `Ivory woven fuzz`, `Ivory face fuzz`, `Warm milk fuzz`, coloured and see-through from `felt_fuzz.png`, `face_fuzz.png`, `milk_fuzz.png` (the felt's colour, an alpha of fibres; no sheen or specular). The app keeps the shell only with the GPU face morphs (macOS 27); the CPU path (macOS 15–26) leaves it out. After every export `src/slim_model.py` keeps only the points each blend shape moves and swaps the textures the app reads loose (a species' `LOOSE_TEXTURES`: Moku's felt, eye and fuzz textures, all set by `runtime/materials.json`) for 4×4 stand-ins, so they ship once. Anything that renders `moku_bunny.usdz` without `runtime/materials.json` (Blender imports, `control_probe`) sees plain felt.
- Face atlas: `character/face_atlas.json`; tested native color + scalar opacity setup in `src/face_probe.swift`.
- Ear paths: `character/ear_transitions.json`, revision 3, 17 keyposes per path; see SPEC for the quick-pop timing.
- Onboarding: `onboarding/manifest.json`, hello wave and optional held blank name tag.
- Legacy lantern data remains available but the final product uses only the original contact shadow; no lantern/glow.
- Symbols: `symbols/manifest.json`, six-frame atlases and static sprites at master/@2x/@3x.
- Mood poses: `jointEulerDegrees` in every `moods.json` are joint-local degrees that the app applies as rest·Rx·Ry·Rz (RealityCharacter, the order of Blender's `'ZYX'` Euler), not Blender's `to_euler('XYZ')` (Rz·Ry·Rx). A Blender script that writes or reads them must convert; Tetsu's do (`species_tetsu.app_degrees` and `blender_degrees`), so its held arms match its arm clips' ends. Moku's and Yuzu's were written as XYZ: their small arm angles make the difference small, but it is there.
- Hand props: `character/prop_attachments.json`; drinking cup, home mallet/tea hold, optional name tag and legacy lantern. `build_hammer` and `tea_sit` are seated home-only loops.
- Today's homes: Moku's cottage in `world/dayhouse/` (`src/house_kit.py`), Tetsu's rocket in `world/tetsu/` (`src/rocket_kit.py`) and Yuzu's box castle in `world/yuzu/` (`src/castle_kit.py`). All three keep one contract (`src/companion_home.py`): 24 pieces in stages of 4, 4, 6, 4 and 6, one per 10 focused minutes, six site states, five cameras. The companions' piece and stage names are in their `layout.json` under `homes.<companion>.names`. Review sheets are in `previews/companion-homes/`.
- World: `world/layouts.json` v2 has seven projects, 1,000 units, 200 tree slots and 200 path slots. Low-poly prototypes live in `world/kit/`; layered blueprints in `world/blueprints/`. Original eight forest-stage files remain compatible.
- Low-power compositor: transparent `previews/moods/`, `previews/poses/` and `previews/stage_*.png`. Shared pixel anchors: `previews/compositor.json`; dimensions and alpha bounds: `previews/manifest.json`.
- App icon: `icons/Moku.icon` (Icon Composer layers; the app compiles it with actool), with `icons/AppIcon.png` and `.icns` as flat renders of it; 18 pt black/alpha stage template icons at 1× and 2×. Set `NSImage.isTemplate = true` for menu icons.

## Companions: Tetsu and Yuzu

`character/tetsu/` and `character/yuzu/` hold each companion in Moku's runtime format: `<id>.usdz` (the shared 21 joints in order, Yuzu adds `tail_02`..`tail_04`; every Moku morph name, plus extras), `moods.json`, `ear_transitions.json`, `animations.json` and `anims/` (Moku's 35 clips under the same names, with signature versions, plus `scan` / `push_cup`), `prop_attachments.json` (the shared props as `../../props/…`, and their own water prop: Tetsu's `battery_cell.usdz`, Yuzu's `water_bowl.usdz`), and `materials.json`, whose rules come before `runtime/materials.json`. The eye parts keep Moku's material names (`Cocoa glass eyes`, `Deep cocoa pupil`, `Softbox catchlights`) so the app's face code finds them; `flush: true` marks what warms when cross. Review sheets, rendered by the app's own renderer: `previews/companions/`.

Tetsu is an actual robot (next-wave.md §7): its face is a display, a 30×16 LED matrix behind the visor's dark glass. `src/tetsu_pixels.py` writes `character/tetsu/pixel_face.json` (the matrix, palette and every frame as ASCII pixel art) and `brushed_normal.png`; the app draws the frames from the shared face weights (PixelFace.swift), so its model has no eye shapes, only a hidden carrier per face channel plus `px_boot`, `px_scan`, `px_spin` and `px_heart`. Its clips go through the species' `servo()` (quick moves, a tiny overshoot, no squash). `src/tetsu_hologram.py` draws the hologram of today's rocket (`world/tetsu/hologram/stage-1…5.png`). Review: `previews/companions/tetsu-robot-*.jpg` and `tetsu-old-vs-new.jpg` (the demo's `--robot-look`). Its hands (2026-10-04) are mittens in the boots' language, a brushed shell over a gunmetal grip pad, on arms of brushed segments with recessed joints (`species_tetsu.arm`); water and tea are held in both mittens (`two_hand_hold`), and cross is hands on hips. Review sheets: `previews/tetsu-perfect/`.

## Rebuild

On macOS with Blender 5.2.1, Swift/RealityKit, Python 3 with Pillow, `ffmpeg`, and `iconutil`:

```sh
bash assets/src/rebuild.sh
```

Every Blender process uses `--python-exit-code 1`; failed generators stop the rebuild. Geometry is deterministic. `src/moku_character.blend` is generated, not a hand-edited dependency. The full rebuild regenerates USDZs, textures, clips, frames, icons and acceptance reports. Blender includes NumPy and OpenUSD; no additional Blender add-ons are needed.

Concept images and `src/felt_source.png` are retained image-generation inputs. Their exact built-in image tool prompts are in `src/concept-prompts.json` and `src/felt-prompt.txt`. They are not regenerated by the shell build; doing so would change the art direction/source texture.

Additional P0 generators: `face_atlas.py`, `decal_preview.py`, `lantern_render.py`, `lantern_pack.py`, `p0_review.py`. The native proof is `face_probe.swift` with a frozen copy of the visual lane’s morph adapter for standalone testing.

Companions: `character.py` builds any companion from the shared part (`companion.py`: the 21-joint rig contract, the morph names, joins, skins, morphs, ear in-betweens and export) around a species module (`species_moku.py`, `species_tetsu.py`, `species_yuzu.py`: body, head, ears or antennae, tail, materials and face). `-- --companion=<id>` picks one (Moku by default, at its historic paths); `animate.py` and `motion_v2.py` take the same flag, and a species can replace a clip under its own name (`pose`) or add clips (`EXTRA_CLIPS`). Companions export to `character/<id>/` with `<id>.usdz`. `usd_compare.py` checks a rebuild against an export (Blender numbers the body's faces differently from run to run).

Generators: `character.py`, `derive_mood_ears.py`, `moods.py`, `animate.py`, `world.py`, `icon_render.py`, `icons.py`. `common.py` contains shared USD and rendering utilities. `compositor_camera.py` publishes exact sprite anchors. `compare.py` and `previews.py` produce review artifacts without modifying source concept art.

## Validation and limits

`reports/realitykit-all.json` records actual `Entity(contentsOf:)` imports; `reports/usd-audit.json` records geometry, joints, shape names, animation samples and forward-axis checks. `reports/acceptance.json` checks the full deliverable set and image framing. Every USDZ is self-contained. Each clip duplicates character geometry/textures for straightforward import; load clips as needed and release donor entities after extracting animation resources.

Blender renders are authoring previews. Actual appearance depends on runtime lights, exposure and the material overrides. There are no hair particles; Moku has one see-through fuzz shell (`src/fuzz.py`). PNG pose previews are stills, not sprite-sheet animations. Current desktop art does not use the legacy lantern. Legacy forest stage files are discrete snapshots. The v2 home and forest place shared prototypes into the ordered unit/tree/path slots. The visual lane uses the authored face deltas through its own morph adapter (a GPU mesh deformer on macOS 27, the CPU before) because native component updates did not deform this mesh in its RealityRenderer path (re-tested 2026-10-04 with BlendShapeWeightsComponent and macOS 27's BlendShapeDeformer: no pixel changes). Runtime power use and integration playback remain that lane's responsibility.

Brief 4 review: [all 120 pt strips and MP4s](previews/anim-v2/index.html), [home at 370pt](previews/world-v2/popover-370.png), [house stages](previews/world-v2/house-stages.jpg), [six tree species](previews/world-v2/tree-species.jpg). Native control captures use the actual imported mesh and the visual lane’s morph adapter. The world scenes and animation movies are Blender authoring renders; every shipped USDZ is separately imported in RealityKit.
