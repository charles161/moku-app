#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
ART="${MOKU_ASSETS_DIR:-${MOKU_ASSET_ROOT:-$PWD/../../assets}}"
OUT="${1:-$PWD/.build/look-review}"
mkdir -p "$OUT"
# Run the just-built binary directly. Never activate a window or touch Moku.app.
.build/release/MokuVisualDemo --offscreen --audit "$OUT/audit" --feedback3 "$OUT/candidate" --transitions "$OUT/transitions"
python3 scripts/verify-render-audit.py "$OUT/audit/clipping.json" "$ART"
python3 scripts/golden-look.py "$OUT/candidate"

python3 scripts/verify-transitions.py "$OUT/transitions/transitions.json"
