#!/usr/bin/env bash
# Run a list of explicit (g_uncond, g_callsite) cells against a scenario.
# Same plumbing as sweep-inline.sh, but cells are passed instead of a grid.
#
# Usage:
#   scripts/sweep-cells.sh <module-path> <scenario> <output-csv> <cell1> [cell2 ...]
# Each cell is "g_uncond:g_callsite", with "default" allowed for either side.
#
# Example:
#   scripts/sweep-cells.sh lib/HTLC.hs htlc scripts/sweep-extra-htlc.csv \
#     40:default 75:default 150:default 300:default 40:30 75:30 150:30 300:30 30:100

set -euo pipefail

MODULE_PATH="${1:?module path required}"
SCENARIO="${2:?scenario required}"
OUT="${3:?output csv required}"
shift 3

: "${CAPE_REPO:?CAPE_REPO must be set}"
SUBDIR="Plinth_1.65.0.0_Unisay"
SUBMISSION_DIR="$CAPE_REPO/submissions/$SCENARIO/$SUBDIR"

BACKUP="$(mktemp)"
STRIPPED="$(mktemp)"
BUILD_LOG="$(mktemp -t sweep-build.XXXXXX.log)"
MEASURE_LOG="$(mktemp -t sweep-measure.XXXXXX.log)"
cp "$MODULE_PATH" "$BACKUP"
# Drop any pre-existing inline-* pragmas so each cell measures exactly the
# pragmas it sets — otherwise a stale pragma in the source would shadow
# "default" cells or stack with cell values.
sed -E '/\{-# *OPTIONS_GHC.*Plinth\.Plugin:inline-(unconditional|callsite)-growth=.*#-\}/d' \
  "$BACKUP" > "$STRIPPED"
restore() {
  cp "$BACKUP" "$MODULE_PATH"
  rm -f "$BACKUP" "$STRIPPED"
}
trap restore EXIT

mkdir -p "$(dirname "$OUT")"
echo "g_uncond,g_callsite,cpu_sum,mem_sum,script_size,term_size,status" > "$OUT"

total=$#
i=0
for cell in "$@"; do
  i=$((i + 1))
  IFS=':' read -r g_un g_cs <<< "$cell"
  for v in "$g_un" "$g_cs"; do
    if [[ -z "$v" || ( "$v" != "default" && ! "$v" =~ ^[0-9]+$ ) ]]; then
      echo "invalid cell '$cell' — expected 'g_uncond:g_callsite', each 'default' or a non-negative integer" >&2
      exit 1
    fi
  done
  cp "$STRIPPED" "$MODULE_PATH"
  pragmas=""
  [[ "$g_un" != "default" ]] && pragmas+="{-# OPTIONS_GHC -fplugin-opt Plinth.Plugin:inline-unconditional-growth=$g_un #-}"$'\n'
  [[ "$g_cs" != "default" ]] && pragmas+="{-# OPTIONS_GHC -fplugin-opt Plinth.Plugin:inline-callsite-growth=$g_cs #-}"$'\n'
  if [[ -n "$pragmas" ]]; then
    {
      printf '%s' "$pragmas"
      cat "$STRIPPED"
    } > "$MODULE_PATH"
  fi

  printf '[%d/%d] g_uncond=%s g_callsite=%s ... ' "$i" "$total" "$g_un" "$g_cs" >&2

  if ! cabal run -v0 plinth-submissions > "$BUILD_LOG" 2>&1; then
    echo "BUILD FAILED (log: $BUILD_LOG)" >&2
    echo "$g_un,$g_cs,,,,,build_failed" >> "$OUT"
    continue
  fi
  if ! (cd "$CAPE_REPO" && direnv exec . scripts/cape.sh submission measure "submissions/$SCENARIO/$SUBDIR") > "$MEASURE_LOG" 2>&1; then
    echo "MEASURE FAILED (log: $MEASURE_LOG)" >&2
    echo "$g_un,$g_cs,,,,,measure_failed" >> "$OUT"
    continue
  fi

  METRICS="$SUBMISSION_DIR/metrics.json"
  cpu_sum=$(jq -r '.measurements.cpu_units.sum' "$METRICS")
  mem_sum=$(jq -r '.measurements.memory_units.sum' "$METRICS")
  script_size=$(jq -r '.measurements.script_size_bytes' "$METRICS")
  term_size=$(jq -r '.measurements.term_size' "$METRICS")
  echo "cpu_sum=$cpu_sum  script_size=$script_size  term_size=$term_size" >&2
  echo "$g_un,$g_cs,$cpu_sum,$mem_sum,$script_size,$term_size,ok" >> "$OUT"
done

echo >&2
echo "Done. Results in $OUT" >&2
(
  head -1 "$OUT"
  tail -n +2 "$OUT" | grep ',ok$' | sort -t, -k3,3n
) | column -t -s, >&2
