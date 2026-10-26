#!/bin/bash
# Open a press-capture window with a visible countdown, so presses land inside it.
#   ./listen.sh 60
set -uo pipefail
cd "$(dirname "$0")"
secs="${1:-60}"
[ -x ./hidreader ] || ./build.sh
echo "listening for ${secs}s — press the keys now"
( ./hidreader "$secs" | tee /tmp/deck-presses.jsonl ) &
reader=$!
for ((i=secs; i>0; i--)); do
  printf "\r  %3ds left   " "$i"
  sleep 1
done
echo
wait $reader 2>/dev/null
echo "--- captured ---"
grep -v '"ready"\|"device"\|"pid"' /tmp/deck-presses.jsonl || echo "(no presses captured)"
