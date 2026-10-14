#!/bin/bash
set -euo pipefail
ASSET_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ASSET_DIR/.."
BLENDER_BIN="${BLENDER_BIN:-/Applications/Blender.app/Contents/MacOS/Blender}"
python3 assets/src/face_atlas.py
python3 assets/src/materials.py
"$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/character.py > assets/reports/character-build.log 2>&1
"$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/derive_mood_ears.py > assets/reports/mood-ears.log 2>&1
python3 assets/src/moods.py
"$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/animate.py > assets/reports/animation-build.log 2>&1
# The other companions (character/<id>/): model, moods (arm and antenna/ear/tail angles), every clip.
for companion in tetsu; do  # Yuzu, retired 2026-10-04, is at the yuzu-archive tag
  "$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/character.py -- --companion=$companion --quick > assets/reports/$companion-build.log 2>&1
  "$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/derive_mood_ears.py -- --companion=$companion > assets/reports/$companion-moods.log 2>&1
  "$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/animate.py -- --companion=$companion --exports-only > assets/reports/$companion-animation.log 2>&1
done
# Tetsu's LED face (pixel_face.json) and brushed-metal normal map, with Pillow.
python3 assets/src/tetsu_pixels.py
"$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/world.py > assets/reports/world-build.log 2>&1
"$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/icon_render.py > assets/reports/icon-build.log 2>&1
python3 assets/src/icons.py
python3 assets/src/compare.py
"$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/expression_previews.py > assets/reports/micro-build.log 2>&1
"$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/creative_previews.py > assets/reports/creative-build.log 2>&1
python3 assets/src/symbols.py
"$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/lantern_render.py > assets/reports/lantern-build.log 2>&1
python3 assets/src/lantern_pack.py
swiftc -parse-as-library assets/src/face_probe.swift assets/src/ProbeFacialMorphs.swift -o assets/src/face_probe
assets/src/face_probe > assets/reports/face-probe.log 2>&1
python3 assets/src/expression_review.py
python3 assets/src/p0_review.py
"$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/world_v2.py > assets/reports/world-v2-build.log 2>&1
python3 assets/src/blueprints.py
python3 assets/src/blueprint_progress.py
"$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/world_v2_preview.py > assets/reports/world-v2-preview.log 2>&1
"$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/trees_preview.py > assets/reports/tree-preview.log 2>&1
python3 assets/src/world_pack.py
"$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/onboarding.py > assets/reports/onboarding-build.log 2>&1
python3 assets/src/materials.py
"$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/anim_review.py > assets/reports/anim-v2-render.log 2>&1
"$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/validate_motion.py > assets/reports/motion-validation.log 2>&1
"$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/validate_prop_clearance.py > assets/reports/prop-clearance.log 2>&1
swiftc -parse-as-library assets/src/control_probe.swift assets/src/ProbeFacialMorphs.swift -o assets/src/control_probe
assets/src/control_probe > assets/reports/control-probe.log 2>&1
python3 assets/src/anim_pack.py
python3 assets/src/previews.py
"$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/verify_rest_ears.py > assets/reports/rest-verification.log 2>&1
swiftc -parse-as-library assets/src/verify.swift -o assets/src/verify_realitykit
assets/src/verify_realitykit assets/character/moku_bunny.usdz assets/character/anims/*.usdz assets/world/*.usdz assets/world/kit/*.usdz assets/props/*.usdz > assets/reports/realitykit-all.json 2> assets/reports/realitykit-all.log
"$BLENDER_BIN" --background --factory-startup --python-exit-code 1 --python assets/src/audit_usd.py > assets/reports/usd-audit.log 2>&1
python3 assets/src/brief4_checks.py
python3 assets/src/acceptance.py
