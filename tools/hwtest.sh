#!/bin/sh
# The hardware suite on macOS: builds the audio engine if needed, closes Striso Live (it holds the
# board's console), runs the bench and the hardware tests, writes test-results/hw-<time>.json,
# .txt and .log (gitignored). Nothing plays a sound: the output is opened only for silence, at most
# 30 s per run. Without a Striso the board's parts are skipped and `out` still runs.
#   sh tools/hwtest.sh [soak minutes, default 5] [markers, default 50]
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
SOAK=${1:-5}
N=${2:-50}
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$ROOT/test-results"
mkdir -p "$OUT"
JSON="$OUT/hw-$STAMP.json"
LOG="$OUT/hw-$STAMP.log"
LIB="$ROOT/packages/striso_audio/native/build/macos/libstriso_audio.dylib"
[ -f "$LIB" ] || sh packages/striso_audio/native/build_macos.sh >> "$LOG" 2>&1
pkill -x "Striso Live" 2>/dev/null
cd packages/striso_bench
dart pub get > /dev/null
dart run bin/striso_bench.dart all --n "$N" --minutes "$SOAK" --json "$JSON" > /dev/null 2>> "$LOG"
BENCH=$?
STRISO_BENCH_REPORT="$JSON" dart test -t hardware -r expanded >> "$LOG" 2>&1
TESTS=$?
cd "$ROOT"
{
  echo "Striso hardware suite $STAMP"
  if command -v python3 > /dev/null; then
    python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); [print(("ok  " if c["ok"] else "FAIL")+"  %s: %s (%s)" % (c["name"], c["value"], c["limit"])) for c in r["checks"]]; [print("note: "+n) for n in r["notes"]]' "$JSON"
  fi
  echo "bench exit $BENCH, tests exit $TESTS; report $JSON"
} | tee "$OUT/hw-$STAMP.txt"
[ "$BENCH" -eq 0 ] && [ "$TESTS" -eq 0 ]
