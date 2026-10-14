#!/bin/zsh
# Launch QA, lens 3 (docs/specs/launch-qa.md): performance under the engine's own stream.
#
#   zsh scripts/qa-performance.sh brain [session ...]   # the real engine and the real brain on simulated time; the brain's
#                                                       # memory, goroutines and CPU as the sessions play (default: soak,
#                                                       # switch-work-120, switch-mixed-120)
#   zsh scripts/qa-performance.sh stage [moku|tetsu]    # the stage plays the soak session's stage commands (MOKU_SOAK_HOURS,
#                                                       # MOKU_SOAK_SPEED: 2 simulated hours at 6x by default)
#   zsh scripts/qa-performance.sh check [moku|tetsu]    # the bars, about 8 minutes: memory (median and 95th percentile of the
#                                                       # footprint, the old companion freed after a switch), CPU and frames
#                                                       # hidden and working, and 10 each of pats, hovers, drags and throws.
#                                                       # Exits 1 if one fails. Budgets: MOKU_MEMORY_BUDGET_MIB, MOKU_MEMORY_PEAK_MIB,
#                                                       # MOKU_IDLE_INSTR_BUDGET (billions of instructions a minute while working: 18).
#
# The brain is the QA brain (brain-go/internal/brain/qa_serve_test.go): the real brain with a temporary home and a Jev that
# replays the real Jev's answers, running with the production collector settings. Never touches ~/.moku, /Applications/Moku.app or
# the brain on 8020, and calls no model. The stage mode runs the visual demo offscreen (no window, no Moku of Charles's).
set -eu
root=${0:A:h:h}
mode=${1:-brain}; shift || true
work=${QA_WORK:-$(mktemp -d)}
mkdir -p "$work/home" "$work/out"
echo "working in $work"

case $mode in
brain)
  port=${QA_PORT:-18741}
  rm -f "$work"/home/moku.sqlite*(N)
  (cd "$root/brain-go" && GOTOOLCHAIN=local go test -c -o "$work/brain.test" ./internal/brain)
  (cd "$root/app/MokuMind" && swift build --product mokumind-qa 2>&1 | grep -E 'error|Build complete' || true)
  pid=
  trap '[[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true; [[ -n "${sampler:-}" ]] && kill "$sampler" 2>/dev/null || true' EXIT INT TERM
  (cd "$root/brain-go/internal/brain" && MOKU_QA_PORT=$port MOKU_QA_HOME="$work/home" exec "$work/brain.test" -test.run ServeQABrain -test.v -test.timeout 0 > "$work/brain.log" 2>&1) &
  pid=$!
  for _ in {1..60}; do curl -sf "http://127.0.0.1:$port/health" > /dev/null && break; sleep 0.5; done
  # The brain's process, every 2 s: resident memory (ps), CPU time, and what it says it holds (goroutines, heap).
  echo "t,rssMiB,cpuSeconds,goroutines,heapAllocMiB,heapInuseMiB,sysMiB,gcs" > "$work/out/brain.csv"
  (
    started=$SECONDS
    while kill -0 $pid 2>/dev/null; do
      rss=$(ps -o rss= -p $pid | awk '{printf "%.1f", $1/1024}')
      cpu=$(ps -o time= -p $pid | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }')
      stats=$(curl -s "http://127.0.0.1:$((port + 1))/qa/runtime" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(",".join(str(d[k]) for k in ["goroutines","heapAllocMiB","heapInuseMiB","sysMiB","gcs"]))' 2>/dev/null || echo ",,,,")
      echo "$((SECONDS - started)),$rss,$cpu,$stats" >> "$work/out/brain.csv"
      sleep 2
    done
  ) &
  sampler=$!
  sessions=${*:-soak switch-work-120 switch-mixed-120}
  args=(--sessions "${(j:,:)${=sessions}}")
  "$root/app/MokuMind/.build/debug/mokumind-qa" --brain "http://127.0.0.1:$port" --home "$work/home" \
    --catalog "$root/brain-go/internal/brain/testdata/qa/screens.json" --out "$work/out" --commands "$work/out/commands.tsv" "${args[@]}" | tee "$work/out/summary.txt"
  sleep 3
  python3 - "$work/out/brain.csv" <<'PY'
import csv, sys
rows = [r for r in csv.DictReader(open(sys.argv[1])) if r["rssMiB"]]
rss = [float(r["rssMiB"]) for r in rows]
gor = [float(r["goroutines"]) for r in rows if r["goroutines"]]
cpu = [float(r["cpuSeconds"]) for r in rows]
span = float(rows[-1]["t"]) - float(rows[0]["t"])
print(f"brain over {span:.0f} s: RSS {rss[0]:.0f} -> {rss[-1]:.0f} MiB (max {max(rss):.0f}), goroutines {min(gor):.0f}..{max(gor):.0f} (end {gor[-1]:.0f}), CPU {cpu[-1]-cpu[0]:.1f} s ({(cpu[-1]-cpu[0])/max(span,1)*100:.1f}% of a core)")
PY
  echo "samples in $work/out/brain.csv; the soak session's stage commands in $work/out/commands.tsv"
  ;;
stage)
  companion=${1:-moku}
  commands=${QA_COMMANDS:?QA_COMMANDS: the commands.tsv a brain run wrote (the last session played is the one exported)}
  app=${QA_DEMO:-"$root/app/MokuVisual/.build/MokuVisualDemo.app"}
  MOKU_COMPANION=$companion MOKU_SOAK_COMMANDS=$commands MallocSpaceEfficient=1 \
    "$app/Contents/MacOS/MokuVisualDemo" --offscreen --soak "$work/out/soak-$companion"
  echo "soak.json in $work/out/soak-$companion"
  ;;
check)
  companion=${1:-moku}
  app=${QA_DEMO:-"$root/app/MokuVisual/.build/MokuVisualDemo.app"}
  [[ -x "$app/Contents/MacOS/MokuVisualDemo" ]] || { echo "no demo at $app: zsh app/MokuVisual/scripts/run-demo.sh --build-only"; exit 2; }
  failed=0
  export MOKU_COMPANION=$companion MallocSpaceEfficient=1   # as the app runs
  # One check: its label, the lines of its output worth printing, then the demo's arguments. A failing check exits 1 inside the demo.
  check() {
    local label=$1 show=$2; shift 2
    echo "== $label ($companion)"
    "$app/Contents/MacOS/MokuVisualDemo" --offscreen "$@" > "$work/out/$label.log" 2>&1 || failed=1
    grep -E "$show" "$work/out/$label.log" || true
  }
  check memory '^memory:|failed' --memory-profile "$work/out/memory-$companion"
  MOKU_IDLE_SECONDS=${MOKU_IDLE_SECONDS:-30} MOKU_IDLE_STATES=hidden,working check idle '^(hidden|working)|Idle |failed' --idle-energy "$work/out/idle-$companion"
  MOKU_SPAM_COUNT=${MOKU_SPAM_COUNT:-10} check spam '^spam:|failed' --spam "$work/out/spam-$companion"
  echo "results in $work/out"
  (( failed == 0 )) && echo "performance bars: ok" || echo "performance bars: FAILED"
  exit $failed
  ;;
*) echo "usage: $0 brain [session ...] | stage [moku|tetsu] | check [moku|tetsu]"; exit 2 ;;
esac
