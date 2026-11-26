# plinth-cape-submissions

Plinth (PlutusTx) source for benchmark scenarios measured by
[UPLC-CAPE](https://github.com/IntersectMBO/UPLC-CAPE). Builds `.uplc`
artefacts that are committed into a sibling `UPLC-CAPE` checkout under
`submissions/<scenario>/Plinth_<ver>_Unisay/`.

## Build

This branch uses Plinth 1.45.0.0. Enter the pinned shell and set the
destination before running the generator:

```sh
nix develop
export CAPE_REPO="$HOME/src/UPLC-CAPE"
cabal run plinth-submissions
```

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
not retune the compiler.
