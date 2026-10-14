#!/bin/zsh
# Run Moku locally: ./scripts/moku.sh [start|stop|restart|logs]
# Moku.app starts and supervises its own brain (see app/Moku/Sources/Moku/BrainSupervisor.swift).
set -euo pipefail
root=${0:A:h:h}

start() {
  "$root/scripts/build-app.sh" release || { echo "Build failed; not launching the previous Moku.app."; exit 1; }
  open "$root/build/Moku.app"
  echo "Moku: running. Logs: ~/.moku/app.log and ~/.moku/brain.log"
}

stop() {
  pkill -x Moku 2>/dev/null || true   # quits cleanly (SIGTERM) and stops the brain it started
  echo "Moku stopped."
}

case ${1:-start} in
  start) start ;;
  stop) stop ;;
  restart) stop; sleep 2; start ;;
  logs) tail -f ~/.moku/app.log ~/.moku/brain.log ;;
  *) echo "usage: $0 [start|stop|restart|logs]"; exit 2 ;;
esac
