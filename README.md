# plinth-cape-submissions

Plinth (PlutusTx) source for benchmark scenarios measured by
[UPLC-CAPE](https://github.com/IntersectMBO/UPLC-CAPE). Builds `.uplc`
artefacts that are committed into a sibling `UPLC-CAPE` checkout under
`submissions/<scenario>/Plinth_<ver>_Unisay/`.

## Branches

- **`main`** — tracks the latest released Plinth (currently 1.64.0.0 once
  bumped); production line.
- **`plinth-1.45`** — frozen snapshot that produces byte-identical UPLC for
  every `Plinth_1.45.0.0_Unisay/*.uplc` currently in UPLC-CAPE.
- **`plinth-1.61`** — frozen snapshot that produces byte-identical UPLC for
  every `Plinth_1.61.0.0_Unisay/*.uplc` currently in UPLC-CAPE.

Each scenario's `source/README.md` in UPLC-CAPE pins a specific commit on
one of these branches.

## Build

A sibling UPLC-CAPE checkout is required because `.uplc` outputs are
written into it. Set `CAPE_REPO` if the checkout is not at `../UPLC-CAPE`.

```sh
nix develop

# Production (Plinth 1.45 on plinth-1.45 branch; Plinth 1.64 on main)
CAPE_REPO=../UPLC-CAPE cabal run plinth-submissions

# Preview (Plinth 1.61 with BuiltinCasing on plinth-1.61 branch;
# Plinth 1.64 with BuiltinCasing on main via -f preview)
CAPE_REPO=../UPLC-CAPE cabal run \
  --project-file=cabal.project.preview -f preview plinth-submissions-preview
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
