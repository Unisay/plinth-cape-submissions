# plinth-cape-submissions

Plinth (PlutusTx) source for benchmark scenarios measured by
[UPLC-CAPE](https://github.com/IntersectMBO/UPLC-CAPE). Builds `.uplc`
artefacts that are committed into a sibling `UPLC-CAPE` checkout under
`submissions/<scenario>/Plinth_<ver>_Unisay/`.

## Branches

- **`main`** — Plinth 1.65.0.0. Preview (BuiltinCasing) is a cabal flag,
  not a parallel source tree. Production writes to
  `Plinth_1.65.0.0_Unisay/`; preview writes to
  `Plinth_1.65.0.0_Unisay_preview/`.
- **`plinth-1.64`** — frozen at the source state that produces
  byte-identical UPLC for every `Plinth_1.64.0.0_Unisay/*.uplc` currently
  in UPLC-CAPE. Same shape as `main` (preview is a cabal flag).
- **`plinth-1.45`** — frozen at Plinth 1.45.0.0 with the original
  parallel `lib/Preview/` tree. Produces byte-identical UPLC for every
  `Plinth_1.45.0.0_Unisay/*.uplc` currently in UPLC-CAPE.
- **`plinth-1.61`** — same shape, frozen at the source state that
  produces byte-identical UPLC for every `Plinth_1.61.0.0_Unisay/*.uplc`.

Each scenario's `source/README.md` in UPLC-CAPE pins a specific commit on
one of these branches.

UPLC-CAPE has since retired the preview track: every `*_Unisay_preview`
directory was deleted and those artefacts moved under the plain directory
name. Nothing on this branch changed, so a `_preview` path above is where the
build *writes* locally, not where the artefact *lives* in UPLC-CAPE, and which
of the two builds feeds a given submission is a per-row fact rather than a rule.
Read that row's own `source/README.md`, which names the command and the output
path its pinned commit produces.

## Build

A UPLC-CAPE checkout is required because `.uplc` outputs are written into
it. Point `CAPE_REPO` at that checkout — the build aborts if the variable
is unset. The recommended place is `.envrc.local` (gitignored), e.g.:

```sh
export CAPE_REPO="$HOME/src/UPLC-CAPE"
```

```sh
nix develop

# main (Plinth 1.65.0.0)
cabal run plinth-submissions                      # production
cabal run --flags=preview plinth-submissions      # preview

# plinth-1.64 (same shape as main, frozen at 1.64.0.0)
cabal run plinth-submissions                      # production
cabal run --flags=preview plinth-submissions      # preview

# plinth-1.45 (production line, no preview)
cabal run plinth-submissions

# plinth-1.61 (preview line, parallel project file)
cabal run --project-file=cabal.project.preview -f preview plinth-submissions-preview
```

Missing destination directories are created automatically.

## Workflow

1. Edit a validator in `lib/<Scenario>.hs`.
2. Rebuild with the command above; the sibling UPLC-CAPE checkout now has
   updated `.uplc` files.
3. In the UPLC-CAPE checkout, run `cape submission measure --all` to
   refresh `metrics.json`.
4. Open a PR against UPLC-CAPE with the new `.uplc`, updated
   `metrics.json`, and the matching `source/README.md` commit pointer.

## Two-party escrow revision 2

This escrow branch implements the thread-token contract from
[UPLC-CAPE issue 272](https://github.com/IntersectMBO/UPLC-CAPE/issues/272).
One script handles both minting and spending: minting redeemer 0 creates a
75 ADA escrow with one `escrow` token; redeemer 1 or 2 burns that token.
Spending redeemer 1 pays the seller, while redeemer 2 refunds the buyer
strictly after the deposit time plus 1,800,000 milliseconds.

The inline datum is `Constr 0 [I depositTime]`, where depositTime is the
finite deposit validity upper bound minus one. The script reads its own
hash from the minting purpose or the spending input; no script address is
compiled into it. Address checks compare payment credentials, payments
sum all receiver outputs, and extra staking credentials or assets do not
change the protocol rules.

Use the compiler and build invocation pinned on this branch. The escrow
changes retain its existing plugin options and inliner budgets; they do
not retune the compiler. Local output directory suffixes such as
`_monadic`, `_builtincasing` and `_preview` remain build-specific and may
differ from the corresponding CAPE submission directory.
