# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo produces

Plinth (PlutusTx) source for the benchmark scenarios measured by
[UPLC-CAPE](https://github.com/IntersectMBO/UPLC-CAPE). The `plinth-submissions`
executable pretty-prints each scenario's `CompiledCode` and writes one `.uplc`
artefact per scenario **into a sibling UPLC-CAPE checkout** at
`<CAPE_REPO>/submissions/<scenario>/Plinth_<ver>_Unisay/<file>.uplc`.
There are no tests in this repo — correctness is verified by UPLC-CAPE's
`cape submission measure` against the committed `.uplc` files.

`CAPE_REPO` is **required**: `Cape.WritePlc` aborts with an error if it is
unset (no hardcoded path). Set it in `.envrc.local` (gitignored) so direnv
picks it up automatically. Missing destination directories under it are
created on demand.

## Build / run

Enter the haskell.nix dev shell first; cabal pins are constrained to plutus
1.67, which would otherwise lose to whatever is globally installed. The repo
ships an `.envrc` (`use flake`), so with `direnv` installed and `direnv allow`
run once, the shell is loaded automatically on `cd` — no explicit
`nix develop` needed. Otherwise:

```sh
nix develop

# CAPE_REPO must be set (typically via .envrc.local); commands abort otherwise.

# The submission ( -> Plinth_1.67.0.0_Unisay/ )
cabal run plinth-submissions

# Formatting (runs fourmolu, cabal-fmt, nixfmt, prettier, shfmt, pretty-uplc)
treefmt
```

There is no preview variant on this branch. 1.67 removed the `BuiltinCasing`
value of the plugin's `datatypes` option ([plutus#7859][7859]), so the
`preview` cabal flag, its `PREVIEW` CPP define, and the `dropList` gap
emission it also gated are all gone. The 1.65 preview submissions stay
reproducible from the `plinth-1.65` branch.

[7859]: https://github.com/IntersectMBO/plutus/pull/7859

## Branch model (important)

Five long-lived branches, each producing byte-identical UPLC for a specific
Plinth release that's referenced from UPLC-CAPE's per-scenario
`source/README.md`:

- `main` — Plinth **1.67.0.0**. No preview variant (see above).
- `plinth-1.65` — frozen at 1.65.0.0; preview is a cabal flag. Reproduces
  every `Plinth_1.65.0.0_Unisay/*.uplc` and `*_Unisay_preview/*.uplc`.
- `plinth-1.64` — frozen at 1.64.0.0; same shape as `plinth-1.65` (preview is
  a cabal flag). Reproduces every `Plinth_1.64.0.0_Unisay/*.uplc`.
- `plinth-1.45` — frozen at 1.45.0.0; has a parallel `lib/Preview/` tree.
- `plinth-1.61` — frozen at 1.61.0.0; uses `cabal.project.preview` +
  `plinth-submissions-preview` executable.

Build invocations differ per branch — consult the branch's README before
running. **Do not "modernize" the older branches**: their job is to keep
reproducing the exact UPLC that UPLC-CAPE pins by commit hash.

## Code layout

- `lib/<Scenario>.hs` — one validator/program per UPLC-CAPE benchmark
  (`Ecd`, `Factorial`, `Fibonacci`, `FibonacciIterative`, `HTLC`,
  `LinearVesting`, `TwoPartyEscrow`). Each module hosts its own
  `PlutusTx.compile` splice so per-module `OPTIONS_GHC` pragmas (notably
  the inliner tunings `inline-unconditional-growth` /
  `inline-callsite-growth`) reach the plugin invocation. The shared
  `-fplugin` and global plugin opts live in the cabal `library` stanza.
- `lib/<Scenario>/Fixture.hs` — datums/redeemers/contexts used by the
  validator and (where present) `asData` matchers.
- `lib/Cape/WritePlc.hs` — shared pretty-printer + writer. Converts the
  DeBruijn program back to named form via `unDeBruijnTerm`, prints with
  `prettyPlcClassic`, and normalises to exactly one trailing newline so
  generated files don't diff under `treefmt`'s `pretty-uplc` formatter.
- `plinth-submissions-app/Main.hs` — the generator. Imports each
  scenario's pre-spliced `*Code` value and writes the corresponding
  `.uplc` file.

## Plinth plugin options (in cabal `library`)

```
-fplugin Plinth.Plugin
-fplugin-opt Plinth.Plugin:target-version=1.1.0
-fplugin-opt Plinth.Plugin:defer-errors
-fplugin-opt Plinth.Plugin:no-conservative-optimisation
-fplugin-opt Plinth.Plugin:no-preserve-logging
-fplugin-opt Plinth.Plugin:remove-trace
```

Changing any of these will change every `.uplc` artefact and therefore every
UPLC-CAPE metrics file pinned to a commit on this branch. Treat as part of
the public contract of the submission.

## Workflow for landing a change

1. Edit `lib/<Scenario>.hs` (and/or its `Fixture.hs`).
2. `cabal run plinth-submissions` (and the `--flags=preview` variant if the
   scenario has a preview submission) — confirm new `.uplc` lands in the
   sibling UPLC-CAPE checkout.
3. In UPLC-CAPE: `cape submission measure --all` to refresh `metrics.json`.
4. Open a PR against UPLC-CAPE with the new `.uplc`, updated `metrics.json`,
   and the matching `source/README.md` commit pointer back to this repo.

## PR and Issue Text Style

Keep public texts (PR descriptions, issue bodies, review replies) compact — reviewers rewrite wordy descriptions (cf. review of IntersectMBO/plutus#7838).

- Open with the essence in 2–3 plain sentences: what changed, the key assumption or limitation, the consequence. No `## What` / `## Why` scaffolding around content that fits in one paragraph.
- State every fact exactly once; don't re-derive in a later section what the opening already said.
- Include measurements only when they justify the change (a perf claim needs numbers); present them as a table, with no narrative repeating what the table shows.
- No Coverage/testing section by default — the diff shows the tests.
- Skip background the maintainers already know.
- One line of provenance: which issue, request, or discussion motivated the change.
- Deletion test: if removing a sentence loses nothing a reviewer needs, remove it.
