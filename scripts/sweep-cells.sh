#!/usr/bin/env bash
# Run a list of explicit (g_uncond, g_callsite) cells against a scenario.
# Same plumbing and same objective as sweep-inline.sh — see
# scripts/lib-sweep.sh — but cells are passed instead of a grid, for probing a
# specific region without paying for the whole sweep.
#
# Usage:
#   scripts/sweep-cells.sh <module-path> <scenario> <output-csv> <cell1> [cell2 ...]
# Each cell is "g_uncond:g_callsite", with "default" allowed for either side.
#
# Example:
#   scripts/sweep-cells.sh lib/HTLC.hs htlc scripts/sweep-extra-htlc.csv \
#     40:default 75:default 150:default 40:30 75:30
#
# Env:
#   SWEEP_SUBDIR  variant subdir to read the artifact from
#                 (default Plinth_1.67.0.0_Unisay).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/lib-sweep.sh
source scripts/lib-sweep.sh

MODULE_PATH="${1:?module path required}"
SCENARIO="${2:?scenario required}"
OUT="${3:?output csv required}"
shift 3
[[ $# -gt 0 ]] || {
  echo "at least one cell required, e.g. 32:default" >&2
  exit 1
}

init_sweep "$MODULE_PATH" "$SCENARIO" "${SWEEP_SUBDIR:-Plinth_1.67.0.0_Unisay}" "$OUT"

total=$#
for cell in "$@"; do
  run_cell "${cell%%:*}" "${cell##*:}" "$total"
done

finish_sweep
