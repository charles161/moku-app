# Moku asset contract — v4.0 — overnight art (2026-09-24)

Status: brief 4 W1–W3 assets delivered and self-reviewed. `docs/specs/v1-final.md` overrides earlier direction: exact v0 LOP rest, no disappointed head shake, no desktop lantern or glow. Earlier lantern files remain compatibility assets only. See `lanes/assets.md` for milestone status and `reports/acceptance.json` for completed artifact validation. Disappointed paws fold low in the lap; annoyed crosses the chest.

## Coordinates, geometry and import

All USDZ files use meters, Y up and **+Z forward**. +X is character-left. Character origin is the floor between the feet. Root `Moku`; RealityKit ModelEntity **`Rig`**; USD skeleton `/Moku/Rig/Armature`. Character: **52,011 triangles (38,984 plus a 13,027-triangle fuzz shell), 21 joints, 80 named morphs**, 16 materials. Forest stages: 21,612–54,860 triangles. Budgets remain <40k character without the fuzz shell (<56k with it) / <60k per forest stage. Character texture maximum 2048² (face atlas; plush textures remain 1024²); no hair, custom shader or runtime subdivision.

Skeleton leaf names (resolve tokens by final path component):

```
root
  hips
    spine
      chest
        neck
          head
            ear_L_01 / ear_L_02
            ear_R_01 / ear_R_02
            eye_L / eye_R
        arm_L / hand_L
        arm_R / hand_R
    leg_L / foot_L
    leg_R / foot_R
    tail
```

**The v0 rest ears are restored exactly.** The lifted folded crown ear and long lop ear are the character's neutral identity. `reports/v0-ear-rest.json` compares both ears' basis vertex coordinates, skin weights and rest joint matrices to `src/history/brief1-character-source.zip`: every maximum difference is zero. Content has zero ear joint offsets and zero ear morph weights. No symmetric replacement rest rig is shipped.

Joint offsets in `character/moods.json` are **joint-local XYZ Euler degrees**, applied relative to imported rest transforms. Convert to radians at the API boundary. Ear bases have different local frames; do not mirror raw Euler values. The authored ear corrective morphs and joint deltas operate together. Load the current base and clips as one version; preserve every original joint/shape/clip name.

## Facial and ear controls

Facial parts are joined into the skinned `Plush` mesh. There are **no individually transformable named eye, lid, brow or mouth entities**. Head, eye and ear articulation uses skeletal joints. Morph controls survive USD/RealityKit as **named blend shapes** on `Rig`; resolve by name, never index.

Original names, unchanged:
`blink_L`, `blink_R`, `eyes_happy`, `eyes_wide`, `brows_up`, `brows_concern`, `brows_angry`, `smile`, `frown`, `mouth_open`, `pout`, `cheeks_puff`.

Additions:

| Name | Purpose / useful range |
|---|---|
| `mouth_smile_open` | Broad pink D-shaped mouth with tongue; hides closed embroidery. Use 0…1. |
| `cheeks_raise` | Lifts cheek volume for a smile, 0…1. |
| `blush_more` | Reveals a feathered pink cheek overlay; happy/proud use 0.9–1. |
| `eyes_look_down` | Downward/averted pupil and catchlight offset, 0…1. |
| `brow_raise_L`, `brow_raise_R` | Independent brow emergence/lift; micros **0.2–0.5**, avoid >0.5. |
| `lips_press` | Flattens and narrows the closed mouth; micros **0.2–0.5**. |
| `eyes_narrow` | Soft eye compression; micros **0.2–0.5**. |
| `arms_fold` | Distal paw reach corrective for the annoyed chest cross. Not a complete pose alone. |
| `paws_lap` | Longer, low-energy reach into the disappointed lap hold, with the published arm angles. |
| `lid_flat` | Flat upper-lid edge for the narrowed annoyed eye. |
| `lid_sad` | Outer-drooping upper lids for disappointment. |
| `lid_smile_lower` | Raises lower lids for an open-eye smile. |
| `eyes_proud` | Closed downward-bowed ‿ eye arcs, distinct from happy ∩ arcs. |
| `ears_curtain` | Expressive delta from v0 to cheek-framing dropped ears; collapses the crown fold. |
| `ears_pinned` | Sweeps ears behind the head/shoulders; no held airplane ear. |
| `nose_twitch` | Small optional nose scrunch, 0…0.5 for micros. |
| `ears_lift` | Both ears into a readable upward V, preserving the v0 basis at zero. |
| `ear_antenna_L`, `ear_antenna_R` | Listening antenna on either side; the other ear retains its original rest. |
| `face_decals` | Hides original 3D mouth/brows/tongue inside the head for atlas mode. Does not change ears or body. |
| `eye_hidden_L`, `eye_hidden_R` | Hide the corresponding 3D eye/pupil/highlights for painted closed-eye cells. |

Unspecified weights are zero. Closed eyes use curved geometry, not held flat dashes. `eyes_happy` and `eyes_proud` are mutually exclusive. `mouth_smile_open` and `mouth_open` are alternatives. Combine blink as `(1 - max(eyes_happy, eyes_proud)) * max(moodBlink, blinkPulse)` per eye. Reduce overlapping `eyes_narrow`/lid/blink amplitude rather than adding several full closures. Micro weights shown in `previews/micro-expressions.png` are on the content baseline.

The visual lane found that imported morph buffers/deltas are present, but setting `BlendShapeWeightsComponent` did not visibly deform this multipart mesh in its `RealityRenderer` path. Its CPU morph adapter evaluates the same named deltas into a generated skinned mesh, retaining immutable source data. This remains an explicit runtime limitation; imported names alone are not proof of native morph playback. The stronger geometry route retains compatibility with that adapter. The opt-in atlas below is now verified in an offscreen RealityRenderer probe, while this morph route remains available during integration.

## Mood recipes

`character/moods.json` schema 2 is authoritative for numerical values. `rigRevision: 5` identifies this expression revision; its rest ears match v0 exactly. The base USDZ also starts with soft partial lids and a small closed smile.

| Mood | Readable channels |
|---|---|
| content | Original crown-and-lop rest; softened open eyes and small closed smile; hidden brows. |
| happy | Upward V ears, ∩ eyes, open pink smile/tongue, raised cheeks, stronger blush, buoyant head tilt. |
| proud | Up/back ears, ‿ eyes, soft raised brows, wide closed smile, raised chin and chest. |
| curious | Lop becomes an antenna; one raised brow, wide eyes, small open mouth and head tilt. |
| concerned | Forward ear deltas, open glossy eyes, raised inner brows, small frown, forward lean. No tears. |
| disappointed | Curtain ears, sad lids/downward gaze, pout, head down/away, slump and paws folded low in the lap. |
| annoyed | Pinned ears, V brows/narrow lids, puffed cheeks, pressed pout, head away and **arms crossed over the chest**. |
| sleepy | Limp dropped ears, one closed curved eye and one heavy lid, small mouth, tilted/nodding head. |

Happy/positive gesture smiles couple eyes, cheeks, mouth and blush. Keep direct neutral eye contact brief; blink or look away. Ears lead the face change; the later feedback-4 timing contract below governs their quick rise and softer descent. Face blends may remain gradual independently of the ear pop. Scheduling, gaze budgets and live CPU measurements belong to the visual lane.

## Animation v2 and crossed paws

**34 clips** under `character/anims/`, with 24 fps joint and facial samples. `character/animations.json` schema 2 gives exact rounded durations and start/end pose contracts. All original names survive. Animated USD exports explicitly retain timeline boundary samples so sparse rest intervals cannot shorten imported joint tracks; native joint and face durations are checked against this manifest. The canonical replacements are:

| Canonical clip | Compatibility alias | Motion |
|---|---|---|
| `hop_cycle` | `walk_cycle` | 13/24 s loop; crouch, simultaneous hind-foot push, .085 m airtime, squash, settle. Stride **.26 m**. |
| `hop_start` | — | .75 s seated takeoff, stride **.16 m**. |
| `hop_stop` | — | .75 s hop into settled sitting, stride **.16 m**. |
| `hop_turn` | — | .75 s in-place small hop with **+30° authored Y yaw**. |
| `sit_up_tall` | `stand_up` | 29/24 s rear-up on planted haunches; chest lengthens slightly and paws lift. |
| `settle_down` | `sit_down` | 29/24 s return from tall sitting. |
| `hello_wave` | — | 3 s little hop, low friendly wave and happy tilt, then seated rest. |
| `build_hammer` | — | 58/24 s seated loop, three soft mallet taps followed by a pause. Home scene only. |
| `tea_sit` | — | 4 s quiet seated mug hold, breathing and one soft blink. Home scene only. |

**Travel synchronization:** hop clips contain vertical root motion only. At normalized time `u`, horizontal distance is `strideLength * smoothstep(clamp((u-.29)/.43,0,1))`. Both grounded ranges `[0,.29]` and `[.72,1]` hold the entity's horizontal position. Advance the wrapper by one stride at each completed cycle. Mean speed is stride/duration; change playback speed and wrapper timing together. Constant-speed wrapper movement through stance causes foot sliding and is unsupported. `hop_turn` already contains yaw: transfer its final 30° into the wrapper before resetting the root, without applying it twice.

All ordinary one-shot gestures start and end in the exact content seated pose. Transition clips deliberately connect named states: tall/settled, lap fold/release and chest cross/release. Sleep and emotion hold loops retain their seated held pose with matching endpoints. Fold/cross take 22/24 s and their releases 19/24 s. `disappointed_hold` is a 4 s quiet breath with **no head shake**. `annoyed_hold` is 4 s. Retired `carry_lantern` stays importable but is not part of the current product scene.

Home-life loops hold their own seated pose with exact matching endpoints. Blend into/out of them over ~0.4 s; hide props during unrelated gestures. `prop_attachments.json` publishes `build_hammer` (new `props/hammer.usdz`) and `tea_sit` (shared `props/water_cup.usdz`) hand_R wrappers. Retain the imported prop root conversion. Hammer sawdust hits are normalized phases **0.141667, 0.370833, 0.600000**; use `tapNormalizedTimes` and the exact 58/24 s clip duration. These props belong to the home, never the desktop.

Extract the named `SampledAnimation<JointTransforms>` resource containing `/Armature/<clip>[` on `Rig`; wrapper animations are not portable between entities. Keep one main character, loading donor clips only to extract resources. Full clips own their sampled morph channels; do not combine them with a held mood by taking maximum weights. Arms-only playback may select arm tracks and leave face/ears to the runtime.

Proof: `previews/anim-v2/index.html`, a fixed-scale **120 px resting figure** in every frame strip, MP4s and profile checks for every clip. Ear lifts may extend above 120 px without a camera refit. These are Blender frames from the exact pose function sampled into the USDZs. Native control proof is separate under `previews/anim-v2/native-controls/`; technical loop, endpoint, alias and planted-foot checks are in `reports/motion-v2-validation.json`.

## Ear in-betweens and blink closure

`character/ear_transitions.json` is the authoritative transition map. Revision 3 supplies **15 intermediate controls per endpoint** at 1/16 phase intervals for `ears_lift`, `ear_antenna_L`, `ear_antenna_R`. Existing eighth-step names (`_125`…`_875`) are retained; half-step additions use four-digit suffixes (`_0625`, `_1875`…`_9375`). Resolve phases from the JSON, never infer them from names or assume eight segments. These 45 additions bring the total to **80 morphs**; topology, triangles and rest bind data are unchanged.

Use a phase in `[0,1]` along the chosen path, find its two adjacent keyposes, and linearly blend their complete weight maps. Clear every `clearControls` entry first. Phase 0 is LOP (empty map); phase 1 is the existing endpoint morph at weight 1. Intermediate morphs **replace** endpoint weights; never add them on top. Ease phase once, and reverse the same path to lower the ears. Keep ear joints at rest during the unfurl, then apply the target mood's final local offsets. The approved rise is a .3–.4 s pop: cover phase .3… .7 in no more than 5/60 s, with an 8% top overshoot implemented through a small ear-joint excursion. Clamp morph phase to 0…1. Descent is softer with a small landing bounce. A horizontal silhouette may pass briefly but must never be held more than five 60Hz frames or at rest. From a different ear state, return to LOP first; on an interrupted reversal retain the current path and phase. Do not linearly mix opposing LOP/LIFT vertex offsets. The root rises ahead of the lower ear, with a counter-bent hanging tip. Intermediate ring-width preservation is measured at 65 phases per ear/path in `reports/motion-v2-validation.json`. The denser half-step keys prevent thinning between the more strongly curled poses. Native proof covers both ears, both antenna paths and 17 blink levels.

Blink closure now compresses the cocoa eye to **2.5%** height, with a thin curved closure; the pupil and catchlight geometry retracts behind it. This removes the old thick closed smudge and bright closure flecks. Do not add full `eyes_happy`/`eyes_proud`/narrowing to full blinks. `mouth_open` now reveals a readable oval interior and hides closed embroidery (yawn/curious); open-smile remains a separate control.

## Materials and lighting

`runtime/materials.json` is authoritative after import, with 35 named entries for the character, craft kit and current hand props. Match each exact `name` or underscore alias, copy the imported PBR material, and preserve existing UV and texture bindings. Apply base tint, roughness, metallic/specular and sheen; preserve unmatched legacy materials. All paths are relative to `assets/`. Numeric tints are linear sRGB; image color textures are sRGB. Normal texture is raw tangent-space OpenGL +Y. Four mirrored felt repeats are already baked in: runtime normal tiling stays `[1,1]`. Character plush normal strength is 0.48; craft materials use their individual published values.

White tint on textured ivory preserves baked plush color and diffuse blush. `sheenRoughness=0.8` is authoring metadata: installed RealityKit exposes sheen color but not sheen roughness; do not substitute clearcoat. `runtime/studio.json` is the visual lane's calibrated +Z camera and lighting baseline, not a literal conversion of Blender light units.

Expression materials: `Expression blush`, `Petal mouth interior`, `Soft pink tongue`, and opt-in `Face decals`. **Expression blush must preserve imported texture alpha**, using `character/expression_blush.png` A channel with alpha blending, not opaque tint or alpha cutout. The manifest publishes `opacityMode: textureAlpha`, `alphaMode: blend` and `preserveImportedOpacity: true`. It is a feathered cheek patch, not fur. Zero `blush_more` hides it inside the head; its texture must not turn into a rectangle when revealed.

## Manpu

`symbols/manifest.json` describes **11 original transparent sprite sets**: sparkles, question, sweat, steam, zzz, heart, bounce, exclamation, sigh, pop_vein and hmph. Each has a six-frame horizontal atlas, a static sprite, and @2x/@3x exports. Master frame 256²; @2x frame 48²; @3x 72². Display canvas 24 pt with roughly 10–14 pt visible glyph. Straight RGBA PNG.

Anchor to the projected head; manifest offsets use top-left screen coordinates normalized by the character canvas. Pivot is center. For the shared 768px previews, read the current neutral head anchor from `previews/compositor.json`; `symbols/manifest.json` mirrors that value. Preserve atlas cell bounds; do not crop individual frames. Use one brief symbol at a time; no manpu during micros. Disappointment can emit one sigh cloud on entry, then none. Reduce Motion uses frame 2 with opacity-only fade. Runtime owns timing and placement; symbols do not replace facial expression.

## Previews and acceptance

Transparent compositor moods and poses remain **768² with identical camera and registration**. Camera revision 2 uses a fixed 1.92-unit orthographic view with extra top padding for the unfurled crown ear. Read ground/head anchors from `previews/compositor.json`, and alpha bounds from `previews/manifest.json`. All moods/poses and v2 authoring movies share this padding; no individual pose is refit. This changes authoring preview registration, not the visual lane’s native camera/studio settings. Never independently crop these runtime frames when crossfading. Pose PNGs are representative stills; USDZs are the animation source.

Review artifacts deliberately normalize each visible figure into **120 pt at @2x**; this review framing is separate from runtime registration:
- `previews/moods-before-after.png`: preserved v0 moods versus revised moods, no symbol assists.
- `previews/moods-unlabelled-120.png`: native 1x, no labels or symbols.
- `previews/micro-expressions.png`: four required controls at 0.2/0.35/0.5.
- `previews/moods_v1.png`: atlas face, front and usual-gaze authoring views. `previews/realitykit-decals/` contains the actual native atlas captures.
- `previews/moods_v1_silhouette.png`: black silhouettes, no face cues.
- `previews/stranger-test-light.png`, `stranger-test-dark.png`: numbered label-free human review sheets; key/protocol in `reports/stranger-test-key.json`.

The five-person real-desktop recognition test has **not been performed** by the asset lane. Self-review observations and any weak pairs are recorded in `reports/expression-self-check.md`; no fabricated recognition percentages. Blender images are authoring previews; actual RealityKit appearance depends on runtime lighting, alpha and material application.

## World kit v2, blueprints and the forest

`world/layouts.json` **schema 2** is authoritative. For compatibility `stages` and `legacyStages` retain the original eight tree-stage records and existing files. New runtime scenes use **`kit`, `projects`, `treeSlots`, `pathSlots`, `blueprintAnchor`, `blueprintPage`, `siteProps`, `tentAnchor` and `characterAnchor`**. The seven projects contain exactly **1,000 ordered units** at the approved thresholds:

| Project | Start points | Units |
|---|---:|---:|
| plot | 0 | 3 stakes/string segments |
| foundation | 30 | 9 stones |
| frame | 120 | 18 beams |
| walls | 300 | 30 planks, round door/window/gables finale |
| roof | 600 | 90 felt shingles, chimney finale |
| garden | 1500 | 250 pickets/carrot/flower units, bench finale |
| lookout | 4000 | 600 deck/rail/ladder units, telescope finale |

At 10,000 points every project is complete (Home). Place all earlier projects, the first N slots of the current project, and at most its next 3 ghosts. Place a project's `finale` when all its units are complete; place optional `structuralBase` supports as soon as its first unit is earned. Show the tent through roof construction, then pack it away. Scaffolding/crane are appropriate during frame/walls/roof. Moku's character is separate.

All placements are **Y-up wrapper transforms**: `translation`, `scale`, `rotationQuaternion` in **xyzw** order. Add the imported prototype as a child and retain its own root conversion. Share mesh/material resources across instances. Do not bake a separate high-poly forest mesh. `kit` reports individual triangle counts; tree models are comfortably below 2k triangles each. The moss plane is Y=.09. The supplied cork island grows in X/Z only using `islandRadiusRule`; published camera values keep its entire rim framed.

**One tree per focused hour:** use `floor(focusMinutesAllTime/60)` independently from growth points. Fill `treeSlots` by ascending index; 200 slots cover five nearest-to-farthest rings with angularly balanced prefixes and a front sightline. Six species: round felt canopy, pine, birch, blossom, autumn maple, small sapling. Display total hours above 200 but cap these slots at 200. Do not grow a tree from return points. Return stones independently fill `pathSlots`, using three low-poly variants.

**Blueprints:** `world/blueprints/<project>_{paper,context,pending,inked}.png` are registered 1024×768 layers. Each `<project>.json` contains individual line groups keyed by the exact project unit index. Composite paper + previously-built context + pale pending lines, then dark ink lines for indices `< completedUnits`. The aggregate inked PNG is the 100% project state, not a partial progress mask. Cache the resulting texture and put it on `Craft blueprint paper` in `blueprint_page.usdz`, at the same transform as the wooden board. The paper plane has full 0…1 UVs. At a 370pt popover, include the flat blueprint at **at least 96pt wide** so progress remains readable; the physical easel provides scene context. Zero hours truthfully shows pending work. At 25 h the roof is complete and the garden has 0/250 units; do not invent partial garden progress.

`previews/world-v2/` includes the required 0/3/25/120-hour scenes, additional 1/5/20/100-tree prefix reviews and each completed house stage. Blueprints match actual progress. Any shown return count is an explicitly illustrative fixture, recorded in `homePreviews`; hours alone do not imply returns. PNG scene renders are transparent 1000×900, suitable for the inexpensive 2D compositor.

## Onboarding and props

`onboarding/manifest.json` provides `hello_wave`, its Reduce Motion alternative and an optional **blank name tag**. The tag's held joint recipe and `character/prop_attachments.json#name_tag_hold` keep it low under the face. Runtime can write the person's name on the paper face or omit it. No personal name is baked in. Transparent held-tag and standalone previews are under `previews/onboarding/`.

`character/prop_attachments.json` also provides the cup hand_R wrapper matrix (16 column-major floats). Drive it with the composed joint world transform and preserve the imported prop root conversion. The drinking still and v2 movie include the attached cup; the rigged clip does not duplicate prop geometry. Existing lantern files are retained only for backwards compatibility. **Current desktop direction is the original soft contact shadow only—no lantern, glow, pool or face light.**

`bash assets/src/rebuild.sh` regenerates and validates the package using Blender 5.2.1, Swift/RealityKit, Python/Pillow and ffmpeg. Every generator fails the build on errors. Native import/geometry/control evidence is in `reports/`; runtime performance and app integration are owned by the visual lane.

## v1 P0 — face atlas integration

`character/face_atlas.png` is 2048², 4×4 cells of 512². `character/face_atlas_opacity.png` is a separate **scalar grayscale opacity mask**. `character/face_atlas.json` gives all 16 cells, material matching, transforms, per-eye hiding and micro-cell recipes. Cells: content, happy, proud, curious, concerned, disappointed, annoyed, sleepy, smile_at_you, wink, lip_press, small_pout, pff, blink, brow_raise_L, blank.

The shell copies the actual head triangles at **0.5 mm normal offset**, skinned 100% to `head`. Head and shell have matching triangulation. It is a material subset of `Rig`, not an additional entity. A small head tessellation reduction keeps the complete model at **38,984 triangles**. Default `Face decals` texture is transparent; the imported model therefore remains compatible with the existing full morph face until the visual lane opts in.

**Tested native setup** (`src/face_probe.swift`):
1. Cache the imported `Face_decals` material slot **before changing its textures**. On this SDK its imported name can disappear after mutation; repeat name lookup is not reliable.
2. Set the color atlas on `baseColor`, white tint. Set the separate opacity atlas on `PhysicallyBasedMaterial.Opacity(scale: 1, texture: ...)`, loaded with semantic **`.scalar`**. Use `.transparent(opacity: ...)` and `opacityThreshold=0.5`.
3. Set texture scale to `[0.25,0.25]`, and offset to the cell's **`uvOffset`**. Those offsets are verified for RealityKit's imported UV convention: `[column/4,rowFromTop/4]`. **`blenderUVOffset` is different** and is for authoring only.
4. Apply `face_decals=1`, then the cell's `eye_hidden_L/R` weights. Retain head/ear/posture and open-eye lid morphs; the morph adapter remains required for these controls.
5. Select a new cell behind the 60 ms blink. Restore the blank texture and zero hide controls to return to full geometry-morph mode.

Base-color alpha alone produced incomplete/dithered facial marks in the native probe; the explicit scalar opacity mask fixes that. Native captures and the tested cell/UV report are `previews/realitykit-decals/` and `reports/face-atlas-realitykit.json`. This is actual `RealityRenderer` output with the authored mesh, not a Blender proxy. It proves the material/UV route; the visual lane still owns product integration and power measurements.

Atlas cells are complete faces, not additive masks. Micro cell names and mirrored-right-brow guidance are in the manifest. For subtle 0.2–0.5 atlas micros, crossfade cached current/micro frames at that strength; eye narrowing can still use the open-eye morph. Keep the existing full morph face if atlas micro compositing is not integrated. A hidden geometric mouth will not respond visibly to `lips_press` alone.

## v1 P0 — named pose libraries

`character/moods.json` schema 2 adds `earPoses`: **LOP, LIFT, ANTENNA_L, ANTENNA_R, FORWARD, CURTAIN, PINNED, MELT**. LOP contains no ear morphs and zero joint offsets. Reset unspecified controls when selecting a complete pose; do not accumulate old ear states.

`bodyPoses` contains **lean_in, slump, chest_out, paws_lap, arms_crossed, three_quarter**. Each publishes blend weights and/or joint-local degree offsets. Mood entries also reference their `faceDecal`. The semantic mood names and all original controls remain unchanged.

## Legacy P0 lantern sprites and carry (disabled by final direction)

`lantern/manifest.json` is authoritative. Three states **lit, low, ember** are rendered from the shipped `props/lantern.usdz`. Display size **26×34 pt**; @2x files are **52×68**, @3x **78×102**. Each state has a body, a separately rendered flame on exactly the same registered canvas, and a ready-composited option. Use body+flame **or** composite, not both. Projected ground, flame and handle anchors are published. `spark@2x.png`/`spark@3x.png` use a 12 pt transparent canvas.

Colors follow the approved amber palette: body flame #F3B04E, core #FFE7B0, low #E6CC98, ember #D9A25A. The intensity floor is **15%**; it never goes out. Glow, pool, face-light mask, return-flare and Reduce Motion parameters are data in the manifest. Runtime performs these with Core Animation; standing lantern sprites require no RealityKit frames. `previews/lantern-states.png` compares registered layers and native sizes.

`character/prop_attachments.json#carry_lantern` gives the **hand_R wrapper matrix** in the same column-major convention as the cup, the arm/hand hold angles, and the `carry_lantern` clip. Keep the imported lantern root transform below the wrapper. Hide the 2D lantern during live carry and restore it after setting down. `previews/poses/carry_lantern.png` shows the attached result. The base model and prop names stay stable.

## Review boundary

Brief 4 supersedes the earlier P0 stop and authorizes W1–W3 overnight. Asset completion does not claim human review, app integration or deployment. Five-person mood recognition scores remain pending; proud remains the weakest semantic label in the earlier expression self-review.
