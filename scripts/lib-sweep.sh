#!/usr/bin/env bash
# Shared plumbing for the inliner-budget sweeps (sweep-inline.sh grid,
# sweep-cells.sh explicit cells). Both rank on total_fee_lovelace — keeping
# that in one place is the point, since the objective drifting apart between
# the two tools is what put Ecd at uncond=45 in the first place.
#
# WHY total_fee AND NOT cpu_units.sum
# Since Conway's minFeeRefScriptCostPerByte a reference script is charged on
# every transaction that references it, so script size is a recurring cost in
# the same units as execution — there is nothing to amortise. At mainnet
# parameters one byte costs 15 lovelace and one CPU step 0.0000721, i.e. one
# byte == 208 044 CPU steps == 260 memory units:
#
#   total_fee = ceil(mem_sum * 0.0577 + cpu_sum * 0.0000721) + floor(size * 15)
#
# (valid while size < 25600 bytes; each further 25600-byte tier costs 1.2x the
# previous). Ranking on cpu alone buys CPU with size at a ~29x loss. Nothing
# here recomputes the formula: `measure` already writes total_fee_lovelace into
# metrics.json, so the sweep reads the number it is optimising.
#
# The one legitimate exception: CPU is paid per execution while the ref-script
# fee is paid per transaction, so a validator spending N inputs in one
# transaction sees the byte rate fall to 208044/N steps. If a cell only wins
# under that asymmetry (or under a maxTxExUnits ceiling argument), say so in
# the module Note and give the N it needs — do not let it pass as a plain win.
#
# Env:
#   CAPE_EVAL_REPO  checkout supplying the `measure` binary and the scenario
#                   tests files. Defaults to CAPE_REPO. Point it at a scratch
#                   worktree pinned to the evaluator you want to rank against
#                   — the linked plutus-core version IS the cost model, so
#                   this choice decides the numbers.
#
# Artifacts go to a scratch staging root and metrics to a temp file, so a sweep
# never writes into a live CAPE submissions directory.

CSV_HEADER="g_uncond,g_callsite,total_fee,exec_fee,refscript_fee,cpu_sum,mem_sum,script_size,term_size,status"

# init_sweep <module-path> <scenario> <subdir> <out-csv>
init_sweep() {
  SW_MODULE="${1:?module path required, e.g. lib/HTLC.hs}"
  SW_SCENARIO="${2:?scenario name required, e.g. htlc}"
  SW_SUBDIR="${3:-Plinth_1.67.0.0_Unisay}"
  SW_OUT="${4:?output csv required}"

  SW_EVAL_REPO="${CAPE_EVAL_REPO:-${CAPE_REPO:?CAPE_REPO or CAPE_EVAL_REPO must be set}}"
  [[ -f "$SW_MODULE" ]] || {
    echo "module not found: $SW_MODULE" >&2
    exit 1
  }
  SW_TESTS="$SW_EVAL_REPO/scenarios/$SW_SCENARIO/cape-tests.json"
  [[ -f "$SW_TESTS" ]] || {
    echo "tests file not found: $SW_TESTS" >&2
    exit 1
  }

  # Resolve the measure binary once; invoking it directly avoids paying nix +
  # cabal startup on every cell.
  SW_MEASURE="$(cd "$SW_EVAL_REPO" && nix develop -c cabal list-bin measure 2>/dev/null | tail -1)"
  [[ -x "$SW_MEASURE" ]] || {
    echo "measure binary not built in $SW_EVAL_REPO" >&2
    echo "  run: cd $SW_EVAL_REPO && nix develop -c cabal build measure" >&2
    exit 1
  }

  SW_STAGE="$(mktemp -d -t sweep-stage.XXXXXX)"
  SW_METRICS="$(mktemp -t sweep-metrics.XXXXXX.json)"
  SW_BACKUP="$(mktemp)"
  SW_STRIPPED="$(mktemp)"
  cp "$SW_MODULE" "$SW_BACKUP"
  # Drop pre-existing inline-* pragmas so each cell measures exactly what it
  # sets. Anchored to the pragma form on purpose: a looser match also eats the
  # sweep-table comment that names the same option, which breaks the parse.
  sed -E '/^\{-# *OPTIONS_GHC *-fplugin-opt *Plinth\.Plugin:inline-(unconditional|callsite)-growth=.*#-\}$/d' \
    "$SW_BACKUP" > "$SW_STRIPPED"
  trap sweep_restore EXIT

  mkdir -p "$(dirname "$SW_OUT")"
  echo "$CSV_HEADER" > "$SW_OUT"
  SW_I=0
}

sweep_restore() {
  [[ -n "${SW_BACKUP:-}" && -f "$SW_BACKUP" ]] && cp "$SW_BACKUP" "$SW_MODULE"
  rm -rf "${SW_BACKUP:-}" "${SW_STRIPPED:-}" "${SW_STAGE:-}" "${SW_METRICS:-}"
}

# run_cell <g_uncond> <g_callsite> [total-cells]
run_cell() {
  local g_un="$1" g_cs="$2" total="${3:-?}"
  SW_I=$((SW_I + 1))

  local pragmas=""
  [[ "$g_un" != "default" ]] && pragmas+="{-# OPTIONS_GHC -fplugin-opt Plinth.Plugin:inline-unconditional-growth=$g_un #-}"$'\n'
  [[ "$g_cs" != "default" ]] && pragmas+="{-# OPTIONS_GHC -fplugin-opt Plinth.Plugin:inline-callsite-growth=$g_cs #-}"$'\n'
  { printf '%s' "$pragmas"; cat "$SW_STRIPPED"; } > "$SW_MODULE"

  printf '[%s/%s] uncond=%s callsite=%s ... ' "$SW_I" "$total" "$g_un" "$g_cs" >&2

  # One log per cell, kept only on failure: a single shared log let the next
  # cell overwrite the evidence for the one that just failed.
  local SW_LOG
  SW_LOG="$(mktemp -t "sweep-build.${g_un}-${g_cs}.XXXXXX.log")"

  if ! CAPE_REPO="$SW_STAGE" cabal run -v0 plinth-submissions > "$SW_LOG" 2>&1; then
    echo "BUILD FAILED (log: $SW_LOG)" >&2
    echo "$g_un,$g_cs,,,,,,,,build_failed" >> "$SW_OUT"
    return 0
  fi

  local artifact="$SW_STAGE/submissions/$SW_SCENARIO/$SW_SUBDIR/$SW_SCENARIO.uplc"
  if [[ ! -f "$artifact" ]]; then
    echo "ARTIFACT MISSING: $artifact" >&2
    echo "$g_un,$g_cs,,,,,,,,no_artifact" >> "$SW_OUT"
    return 0
  fi

  if ! "$SW_MEASURE" -i "$artifact" -o "$SW_METRICS" -t "$SW_TESTS" > "$SW_LOG" 2>&1; then
    echo "MEASURE FAILED (log: $SW_LOG)" >&2
    echo "$g_un,$g_cs,,,,,,,,measure_failed" >> "$SW_OUT"
    return 0
  fi

  local fee exec_fee ref_fee cpu mem size term
  read -r fee exec_fee ref_fee cpu mem size term < <(
    jq -r '.measurements | [
      .total_fee_lovelace, .execution_fee_lovelace, .reference_script_fee_lovelace,
      .cpu_units.sum, .memory_units.sum, .script_size_bytes, .term_size
    ] | @tsv' "$SW_METRICS"
  )
  printf 'fee=%s (exec %s + ref %s)  size=%s\n' "$fee" "$exec_fee" "$ref_fee" "$size" >&2
  echo "$g_un,$g_cs,$fee,$exec_fee,$ref_fee,$cpu,$mem,$size,$term,ok" >> "$SW_OUT"
  rm -f "$SW_LOG"
}

finish_sweep() {
  echo >&2
  echo "Sweep complete. Results in $SW_OUT" >&2
  echo >&2
  echo "Top 5 cells by total_fee_lovelace (ascending):" >&2
  (
    head -1 "$SW_OUT"
    # `|| true`: with every cell failed, grep exits 1 and pipefail would
    # abort the caller before the summary prints.
    tail -n +2 "$SW_OUT" | { grep ',ok$' || true; } | sort -t, -k3,3n | head -5
  ) | column -t -s, >&2
}
