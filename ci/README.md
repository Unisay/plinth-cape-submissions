# UPLC checks

For each build in the base branch's profile, CI runs the submission generator
in the branch's pinned Nix shell. It checks the GHC and Plutus versions in the
resolved Cabal plan, then uses the branch's Plutus parser to read every emitted
`.uplc` file and check that every variable is bound. The build must produce at
least one program. Changed and newly added programs go through the same checks.

`benchmarks/profiles.json` in the pinned tools checkout declares the build
commands and CAPE suites for each base branch. For each configured suite, CI
checks out the pinned CAPE commit, verifies the suite file's hash, builds
`measure` and runs the suite against every matching output of each build.
A missing output or failed evaluation fails the check. The job archives build
logs, generated files and evaluation results.

Run the same check locally from a clean source checkout. Use a fresh results
directory outside the checkout:

```sh
python3 /path/to/ci/check.py verify --branch main --source "$PWD" --results /tmp/uplc-verify
```

For a profile with suites, also pass `--cape /path/to/cape` pointing to a clean
checkout at the configured commit. Builds and evaluations run sequentially
under the same Cabal-index lock.

## Using the workflow on another branch

The reusable workflow on `main` checks out its tools and profiles by commit.
When changing them, commit the changes first, then point the workflow at that
commit. The caller on `main` uses the local workflow so a PR can exercise its
own changes.

For a compiler branch, add its profile to the central configuration and add the caller below. Each branch
builds with its own Cabal and flake files. Hosted runs use public Cachix
substitutes and may build dependencies from source on a cache miss.

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
