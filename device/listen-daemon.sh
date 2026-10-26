#!/bin/bash
# Always-on press logger. Keeps hidreader running and appends every event as JSON lines.
#   ./listen-daemon.sh start|stop|tail
set -uo pipefail
cd "$(dirname "$0")"
LOG="logs/presses.jsonl"
PIDF="logs/listen.pid"

case "${1:-start}" in
  start)
    [ -x ./hidreader ] || ./build.sh
    if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
      echo "already running (pid $(cat "$PIDF"))"; exit 0
    fi
    : > "$LOG"
    ( while true; do ./hidreader >> "$LOG" 2>&1; sleep 1; done ) &
    echo $! > "$PIDF"
    sleep 1
    echo "listening (pid $(cat "$PIDF")) -> $LOG"
    ;;
  stop)
    [ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null; rm -f "$PIDF"
    pkill -f hidreader 2>/dev/null; echo "stopped"
    ;;
  tail)
    grep -v '"ready"\|"device"\|"pid"' "$LOG" 2>/dev/null | tail -40
    ;;
esac
