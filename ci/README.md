# UPLC checks

A green `UPLC / Build and reproduce UPLC` check means that the PR merge checkout
builds in its branch's pinned Nix shell, and the complete set of emitted `.uplc`
paths and raw byte hashes matches `ci/expected-outputs.json`. On the nine
revision-2 escrow bases it also means every emitted escrow passed the pinned
CAPE suite. It does not update or certify CAPE metrics. The five legacy bases
check build/reproduction only; revision-2 tests do not apply to their contracts.
Confirm the exact required-check name on the first hosted run.

`profiles.json` records only the invocations CAPE uses for each base: 1.45 uses
the default project, 1.61 uses the separate preview project, and 1.64/1.65 use
both flag variants. All emissions of each selected invocation are checked,
including sibling artifacts. Older preview projects, CPP flags and local output
suffixes are preserved. All builds run sequentially
under one Cabal-index lock. The resolved Cabal plan must contain the declared
GHC and Plutus release, including the plugin; shell-global package precedence
cannot silently change the compiler used. The job preserves shared Nix/Cabal
stores and consumes public Cachix downloads without a write token. It does not
prime or write caches. A hosted cold run depends on public substitutes for GHC
and the Plutus libraries: local store hits do not establish availability. Cold
hosted performance remains a rollout gate.

Run from a clean source checkout after committing changes to compiler inputs or
Haskell. Put results outside that checkout:

```sh
python3 /path/to/ci/check.py record --branch main --source "$PWD" --results /tmp/uplc-record
python3 /path/to/ci/check.py verify --branch main --source "$PWD" --results /tmp/uplc-verify
```

Recording is forbidden in CI. To update an existing manifest intentionally, add
`--replace`, inspect the complete manifest diff, and commit it with the source
change. Normal CI only verifies. A missing manifest fails. New or removed paths,
renamed binders and changed plugin output all require a reviewed manifest update.
Hashes describe raw generator bytes; no formatter rewrites legacy emissions.

For a revision-2 base, also pass `--cape /path/to/cape`. That checkout must be
clean at the exact durable main commit in `profiles.json`, and the escrow test
hash must match. The runner builds its `.#measure` and keeps logs/metrics beside
the emitted artifacts. The staging destination is a private temporary tree,
not the CAPE checkout. A failed build, comparison or evaluator exits nonzero.

## Distribution

The reusable workflow and tools live on `main`. Its workflow checks out the
immutable tools commit named in that file, independently of the caller source.
Tool updates are committed first, then the workflow's tools SHA is updated in
a second commit. Main's caller uses the local reusable workflow so its initial
PR can exercise it. Other bases use the common caller template below.

Each historical base receives its own output manifest and the same thin caller.
The Haskell, Cabal and flake files remain on that branch's compiler line. Future
CI behavior for old branches follows the central workflow on `main`; the
compiler/toolchain and expected outputs remain branch-specific. Do not merge
main's source history into older bases to install CI. Unknown bases fail until
an explicit profile and manifest are added.

For initial rollout after user approval:

1. Publish/review the main CI PR and obtain a real hosted check.
2. On each of the 13 other bases, build and record that base's manifest; add the
   thin caller as a small separate PR, without compiler/source changes. Every
   overlay PR must pass its actual hosted run. Representative local runs do not
   establish coverage for the remaining bases.
3. After all callers exist, confirm the stable context name and request separate
   approval before setting required checks or branch protection.

No push, PR, repository setting change or cache write is implied by these steps.

```yaml
name: UPLC CI
on:
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review]
  workflow_dispatch:
    inputs:
      base:
        description: Branch profile (blank uses the selected branch)
        type: string
        required: false
permissions:
  contents: read
concurrency:
  group: uplc-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true
jobs:
  uplc:
    name: UPLC
    uses: Unisay/plinth-cape-submissions/.github/workflows/uplc-check.yml@main
    with:
      base: ${{ github.base_ref || inputs.base || github.ref_name }}
```

Actions behavior follows the [GitHub reusable-workflow documentation](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows).
PR jobs use `pull_request`, read permissions and no secrets; see
[GitHub's event security documentation](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target).
