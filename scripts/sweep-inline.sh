#!/usr/bin/env bash
# Sweep Plinth's inliner budget for one scenario module over a grid, rebuild
# the .uplc, measure it, and rank cells by total_fee_lovelace.
#
# See scripts/lib-sweep.sh for why the objective is total_fee and not
# cpu_units.sum, for the fee formula, and for the CAPE_EVAL_REPO knob that
# decides which cost model the ranking comes from.
#
# Usage:
#   scripts/sweep-inline.sh <module-path> <scenario> [variant-subdir] [out-csv]
#
# Example:
#   scripts/sweep-inline.sh lib/HTLC.hs htlc
#
# Env:
#   UNCOND_VALUES    space-separated budgets to try (default: see below).
#   CALLSITE_VALUES  if set, sweeps uncond x callsite instead of uncond alone.
#                    Left at default normally: the Ecd and HTLC notes both
#                    record callsite saturating at a shallow plateau and being
#                    dominated by uncond once uncond is tuned. Set it to
#                    re-test that on a scenario whose fee curve looks off.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/lib-sweep.sh
source scripts/lib-sweep.sh

MODULE_PATH="${1:?module path required, e.g. lib/HTLC.hs}"
SCENARIO="${2:?scenario name required, e.g. htlc}"
SUBDIR="${3:-Plinth_1.67.0.0_Unisay}"
OUT="${4:-scripts/sweep-results-${SCENARIO}.csv}"

read -r -a UNCOND <<< "${UNCOND_VALUES:-default 4 8 12 16 20 24 27 32 40 45 48}"
if [[ -n "${CALLSITE_VALUES:-}" ]]; then
  read -r -a CALLSITE <<< "$CALLSITE_VALUES"
else
  CALLSITE=(default)
fi

init_sweep "$MODULE_PATH" "$SCENARIO" "$SUBDIR" "$OUT"

total=$((${#UNCOND[@]} * ${#CALLSITE[@]}))
for g_un in "${UNCOND[@]}"; do
  for g_cs in "${CALLSITE[@]}"; do
    run_cell "$g_un" "$g_cs" "$total"
  done
done

finish_sweep
