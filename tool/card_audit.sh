#!/bin/bash
# Per-still card audit of Watch's reader over the game-night recordings:
# for every labelled card of every labelled still (stills_labels.json),
# read / where it was lost, with the app's reader settings. One JSON per
# recording in $OUT (default ../../../tmp/card-audit, the main checkout's
# tmp/).
#
#   tool/card_audit.sh [--fold DIR] [extra watch_stills args]
#
# --fold DIR: score each recording with DIR/corner_<TAG>.bin, a corner
# model that never trained on that recording (leave-one-recording-out);
# without it, the shipped assets/data/corner_net.bin.
set -e
cd "$(dirname "$0")/.."
OUT=${OUT:-../../../tmp/card-audit}
mkdir -p "$OUT"
FOLD=
if [ "$1" = --fold ]; then FOLD=$2; shift 2; fi
for REC in camera_data/record/*/; do
  REC=${REC%/}
  TAG=${REC##*-}
  ONLY=$(mktemp)
  python3 -I -c "import json,sys; print(' '.join(str(e['n']) for e in json.load(open(sys.argv[1]))))" "$REC/stills_labels.json" > "$ONLY"
  CORN=()
  [ -n "$FOLD" ] && CORN=(--corners "$FOLD/corner_$TAG.bin")
  ~/flutter/bin/dart run tool/watch_stills.dart "$REC" -q --audit --only "$ONLY" "${CORN[@]}" --audit-json "$OUT/$TAG.json" "$@" \
    | grep -E "^peek A|^showdown A|wrong cards kept|ceiling reads" | sed "s/^/$TAG  /" &
  rm -f "$ONLY.keep"
done
wait
