# Copilot Cloud Agent Instructions

## What this repository produces

This repository contains Plinth (PlutusTx / Haskell) source code for the benchmark scenarios measured by [UPLC-CAPE](https://github.com/IntersectMBO/UPLC-CAPE). The sole output is a set of `.uplc` text artefacts — one per scenario — that are written into a **sibling UPLC-CAPE checkout**, not into this repo.

The generator executable (`plinth-submissions`) compiles each scenario's `CompiledCode`, converts it from DeBruijn to named form, pretty-prints it with `prettyPlcClassic`, and writes it to:

```
<CAPE_REPO>/submissions/<scenario>/Plinth_<ver>_Unisay[_builtincasing]/<file>.uplc
```

There are **no automated tests** in this repo. Correctness is verified externally by UPLC-CAPE's `cape submission measure/verify` commands run against the committed `.uplc` files.

## Build environment — critical constraints

### Nix is required

The project uses [haskell.nix](https://github.com/input-output-hk/haskell.nix) and pins all Haskell dependencies to **Plutus 1.65** (GHC 9.6.7). Building outside the Nix dev shell will pick up whatever GHC/plutus-tx is globally installed, which will almost certainly be the wrong version.

```sh
nix develop          # enter the pinned shell
# or, with direnv installed and `direnv allow` run once:
cd <repo>            # shell activates automatically via .envrc
```

### CAPE_REPO environment variable

`CAPE_REPO` **must** point to a local UPLC-CAPE checkout before running the generator. `Cape.WritePlc` hard-aborts if it is unset. Set it in `.envrc.local` (gitignored):

```sh
export CAPE_REPO="$HOME/path/to/UPLC-CAPE"
```

The `.envrc.local.template` file in the repo root is the versioned reference.

### Cloud agent limitation

**The cloud agent cannot build this project** without a pre-configured Nix environment and the IOG binary cache (`cache.iog.io`). Code changes can be made and reviewed, but the `.uplc` artefacts can only be regenerated in a local environment with `nix develop` + `CAPE_REPO` set. Do not attempt `cabal build` or `nix build` in CI without this setup.

## Build commands (inside `nix develop`)

```sh
# Production submission → Plinth_1.65.0.0_Unisay/
cabal run plinth-submissions

# Preview submission (BuiltinCasing datatypes) → Plinth_1.65.0.0_Unisay_builtincasing/
cabal run --flags=preview plinth-submissions

# Format all files (fourmolu, cabal-fmt, nixfmt, prettier, shfmt, pretty-uplc)
treefmt
```

## Code layout

```
lib/
  Cape/WritePlc.hs          — shared .uplc writer (reads CAPE_REPO, normalises trailing newline)
  Ecd.hs                    — ECD scenario
  Factorial.hs              — Factorial scenario
  Fibonacci.hs              — naive-recursive Fibonacci
  FibonacciIterative.hs     — iterative Fibonacci
  HTLC.hs                   — HTLC validator (asData types, lazy field extraction)
  HTLC/Fixture.hs           — datum/redeemer test fixtures
  LinearVesting.hs          — LinearVesting validator
  LinearVesting/Fixture.hs  — datum/redeemer test fixtures
  TwoPartyEscrow.hs         — TwoPartyEscrow validator
  TwoPartyEscrow/Fixture.hs — datum/redeemer test fixtures

plinth-submissions-app/
  Main.hs                   — generator entry point; writes all scenarios
```

### Important: splice placement in Main.hs

The `PlutusTx.compile` splices for `linearVestingValidator` and `htlcValidator` live in `plinth-submissions-app/Main.hs` rather than in their respective modules. This is a deliberate workaround for a PlutusTx plugin interaction first observed on the `plinth-1.45` branch. **Do not move these splices back into the validator modules** without confirming the generated UPLC is byte-for-byte identical.

## The `preview` cabal flag

The flag does two things in lockstep — **both must always be toggled together**:

1. Passes `-fplugin-opt Plinth.Plugin:datatypes=BuiltinCasing` to the library.
2. Defines the `PREVIEW` CPP macro in `plinth-submissions-app/Main.hs`, redirecting writes to the `*_builtincasing` submission directory.

These are wired together in `plinth-cape-submissions.cabal`. Never set one without the other.

## Plinth plugin options (cabal `library` stanza)

```
-fplugin Plinth.Plugin
-fplugin-opt Plinth.Plugin:target-version=1.1.0
-fplugin-opt Plinth.Plugin:defer-errors
-fplugin-opt Plinth.Plugin:no-conservative-optimisation
-fplugin-opt Plinth.Plugin:no-preserve-logging
-fplugin-opt Plinth.Plugin:remove-trace
```

**These are part of the public contract of the submission.** Changing any option changes the compiled UPLC for every scenario and therefore invalidates every `metrics.json` in UPLC-CAPE that is pinned to a commit on this branch. Treat them as immutable unless a deliberate re-benchmarking is planned.

## Branch model

Four long-lived branches each produce byte-identical UPLC for a specific Plinth release:

| Branch | Plinth version | Preview mechanism |
|---|---|---|
| `main` | 1.65.0.0 | `--flags=preview` cabal flag |
| `plinth-1.64` | 1.64.0.0 | `--flags=preview` cabal flag |
| `plinth-1.45` | 1.45.0.0 | parallel `lib/Preview/` source tree |
| `plinth-1.61` | 1.61.0.0 | `cabal.project.preview` + `plinth-submissions-preview` exe |

**Do not "modernize" older branches.** Their sole job is to keep reproducing the exact UPLC that UPLC-CAPE pins by commit hash. Build invocations differ between branches — always consult the branch's `README.md` before running.

## Formatting conventions

All formatting is automated via `treefmt`. Formatters used:

- **Haskell** — `fourmolu` (config in `fourmolu.yaml`): 2-space indent, 80-column limit, leading commas, trailing function arrows.
- **Cabal** — `cabal-fmt --inplace`
- **Nix** — `nixfmt`
- **Markdown / YAML / JSON** — `prettier --prose-wrap never`
- **Shell** — `shfmt` (2-space indent, case-indent, binary-next-line)
- **UPLC** — `pretty-uplc` (matches `Cape.WritePlc` output format exactly)

Run `treefmt` before committing. Do not manually reformat files that are already formatted.

## Workflow for landing a change

1. Edit `lib/<Scenario>.hs` (and/or `lib/<Scenario>/Fixture.hs`).
2. Inside `nix develop` with `CAPE_REPO` set, run `cabal run plinth-submissions` to regenerate `.uplc` artefacts. Run with `--flags=preview` too if the scenario has a preview submission.
3. Confirm the new `.uplc` files landed correctly in the sibling UPLC-CAPE checkout.
4. In the UPLC-CAPE checkout, run `cape submission measure --all` to refresh `metrics.json`.
5. Open a PR against UPLC-CAPE with the new `.uplc`, updated `metrics.json`, and a `source/README.md` commit pointer back to the commit in this repo.

## Known errors and workarounds

| Error | Cause | Workaround |
|---|---|---|
| `CAPE_REPO is not set` | `CAPE_REPO` env var missing | Copy `.envrc.local.template` to `.envrc.local`, set the path, run `direnv allow` |
| Wrong plutus-tx version picked up | Building outside Nix shell | Always run `nix develop` first; never use a globally installed GHC for this project |
| UPLC diffs after formatting | `treefmt`'s `pretty-uplc` formatter | Run `treefmt` before committing; do not hand-edit `.uplc` files |
| Splice compile error for HTLC/LinearVesting | Plugin interaction if splice is in validator module | Keep splices in `Main.hs` as documented |
