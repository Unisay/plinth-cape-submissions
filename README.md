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
