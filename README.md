# plinth-cape-submissions

Plinth (PlutusTx) source for benchmark scenarios measured by
[UPLC-CAPE](https://github.com/IntersectMBO/UPLC-CAPE). Builds `.uplc`
artefacts that are committed into a sibling `UPLC-CAPE` checkout under
`submissions/<scenario>/Plinth_<ver>_Unisay/`.

## Branches

- **`main`** — Plinth 1.64.0.0. Preview (BuiltinCasing) is a cabal flag,
  not a parallel source tree. Production writes to
  `Plinth_1.64.0.0_Unisay/`; preview writes to
  `Plinth_1.64.0.0_Unisay_builtincasing/`.
- **`plinth-1.45`** — frozen at Plinth 1.45.0.0 with the original
  parallel `lib/Preview/` tree. Produces byte-identical UPLC for every
  `Plinth_1.45.0.0_Unisay/*.uplc` currently in UPLC-CAPE.
- **`plinth-1.61`** — same shape, frozen at the source state that
  produces byte-identical UPLC for every `Plinth_1.61.0.0_Unisay/*.uplc`.

Each scenario's `source/README.md` in UPLC-CAPE pins a specific commit on
one of these branches.

## Build

A UPLC-CAPE checkout is required because `.uplc` outputs are written into
it. Point `CAPE_REPO` at that checkout — the build aborts if the variable
is unset. The recommended place is `.envrc.local` (gitignored), e.g.:

```sh
export CAPE_REPO="$HOME/src/UPLC-CAPE"
```

```sh
nix develop

# main (Plinth 1.64.0.0)
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
