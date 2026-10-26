#!/bin/bash
# Always-on unfiltered report logger (press AND release edges).
set -uo pipefail
cd "$(dirname "$0")"
LOG="logs/raw-reports.jsonl"; PIDF="logs/raw.pid"
case "${1:-start}" in
  start)
    [ -x ./hidraw ] || echo "build hidraw first"; 
    if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then echo "already running"; exit 0; fi
    : > "$LOG"
    ( while true; do ./hidraw >> "$LOG" 2>&1; sleep 1; done ) & echo $! > "$PIDF"
    sleep 1; echo "logging (pid $(cat "$PIDF")) -> $LOG"; head -2 "$LOG" ;;
  stop) [ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null; rm -f "$PIDF"; pkill -f hidraw 2>/dev/null; echo stopped ;;
  show) cat "$LOG" ;;
esac
