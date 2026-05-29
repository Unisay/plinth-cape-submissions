#!/usr/bin/env bash
# Sweep Plinth's inline-unconditional-growth × inline-callsite-growth grid
# for a single scenario module, rebuild the .uplc, measure via cape, and
# record cpu_units.sum / memory_units.sum / script_size / term_size per cell.
#
# Usage:
#   scripts/sweep-inline.sh <module-path> <scenario> [subdir] [output-csv]
#
# Example:
#   scripts/sweep-inline.sh lib/HTLC.hs htlc
#
# Requires CAPE_REPO env var (this repo's normal precondition).

set -euo pipefail

MODULE_PATH="${1:?module path required, e.g. lib/HTLC.hs}"
SCENARIO="${2:?scenario name required, e.g. htlc}"
SUBDIR="${3:-Plinth_1.65.0.0_Unisay}"
OUT="${4:-scripts/sweep-results-${SCENARIO}.csv}"

: "${CAPE_REPO:?CAPE_REPO must be set}"
[[ -f "$MODULE_PATH" ]] || {
  echo "module not found: $MODULE_PATH" >&2
  exit 1
}
SUBMISSION_DIR="$CAPE_REPO/submissions/$SCENARIO/$SUBDIR"
[[ -d "$SUBMISSION_DIR" ]] || {
  echo "submission dir not found: $SUBMISSION_DIR" >&2
  exit 1
}

UNCOND_VALUES=(default 5 10 15 20 30)
CALLSITE_VALUES=(default 5 10 15 20 30)

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

total=$((${#UNCOND_VALUES[@]} * ${#CALLSITE_VALUES[@]}))
i=0
for g_un in "${UNCOND_VALUES[@]}"; do
  for g_cs in "${CALLSITE_VALUES[@]}"; do
    i=$((i + 1))
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
done

echo >&2
echo "Sweep complete. Results in $OUT" >&2
echo >&2
echo "Top 5 cells by cpu_units.sum (ascending):" >&2
(
  head -1 "$OUT"
  tail -n +2 "$OUT" | grep ',ok$' | sort -t, -k3,3n | head -5
) | column -t -s, >&2
