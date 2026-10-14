#!/bin/zsh
# Launch QA, lens 2 (docs/specs/launch-qa.md): realistic sessions through the real engine and a real brain.
#
#   zsh scripts/qa-behaviour.sh [session ...]      # no names: every session (--list shows them)
#
# Starts the QA brain (brain-go/internal/brain/qa_serve_test.go: the real brain on port 18731 with a temporary home and a
# Jev that replays testdata/qa/jev-tape.json, the real Jev's answers), plays the sessions on simulated time
# (app/MokuMind/Sources/mokumind-qa), prints what Moku did against what the person was doing, and stops the brain.
# Never touches ~/.moku, /Applications/Moku.app or the brain on 8020, and calls no model.
set -eu
root=${0:A:h:h}
port=${QA_PORT:-18731}
work=${QA_WORK:-$(mktemp -d)}
out=${QA_OUT:-$work/out}
mkdir -p "$work/home" "$out"
rm -f "$work/home"/moku.sqlite*(N)   # every run starts from an empty store: Your day adds events, it never replaces them

(cd "$root/brain-go" && GOTOOLCHAIN=local go test -c -o "$work/brain.test" ./internal/brain)
(cd "$root/app/MokuMind" && swift build --product mokumind-qa 2>&1 | grep -E 'error|Build complete' || true)

pid=
cleanup() { [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

(cd "$root/brain-go/internal/brain" && MOKU_QA_PORT=$port MOKU_QA_HOME="$work/home" exec "$work/brain.test" -test.run ServeQABrain -test.v -test.timeout 0 > "$work/brain.log" 2>&1) &
pid=$!
for _ in {1..60}; do curl -sf "http://127.0.0.1:$port/health" > /dev/null && break; sleep 0.5; done

args=()
(( $# )) && args=(--sessions "${(j:,:)argv}")
[[ -n "${QA_TRACE:-}" ]] && args+=(--trace "$QA_TRACE")   # one line per verdict: when, screen, truth, state, why
"$root/app/MokuMind/.build/debug/mokumind-qa" --brain "http://127.0.0.1:$port" --home "$work/home" \
  --catalog "$root/brain-go/internal/brain/testdata/qa/screens.json" --out "$out" "${args[@]}" | tee "$out/summary.txt"
echo "reports in $out"
curl -s "http://127.0.0.1:$((port + 1))/qa/stats"; echo
