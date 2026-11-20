# Migration tooling

These files record how the TypeScript SDK history was extracted from
NVIDIA/OpenShell. They are the Python SDK's scripts (ai-openshell/sdk-python,
branch `migration/v0.1.7`) with one change: the SDK always lived in one core
directory, `sdk/typescript`, so the extraction uses
`git filter-repo --subdirectory-filter`, as the Go SDK did, instead of a paths
file.

| File | Purpose |
|------|---------|
| `FREEZE` | The core commit the import was taken at. |
| `message-rules.txt` | Rewrites bare `#N` in commit messages to `NVIDIA/OpenShell#N`. |
| `port-pr.sh` | Port a core PR (open or squash-merged) or commit that touches the SDK into this repository, with original commits and authors. |
| `port-pr-body.md` | PR body template for `port-pr.sh`. |
| `extract-history.sh` | Produces the filtered repository from a core clone at the freeze commit. |
| `verify-tree.sh` | Checks the filtered tip against core and prints commit, author, and sign-off counts. |

Core's mise tasks (`tasks/typescript.toml`), their Windows wrappers, and
`sdk-typescript-publish.yml` stay in core. The standalone build replaces them.

## Reproduce

```shell
git clone https://github.com/NVIDIA/OpenShell core
hack/migration/extract-history.sh core "$(sed -n 's/^sha=//p' hack/migration/FREEZE)" /tmp/sdk-typescript-history
hack/migration/verify-tree.sh core "$(sed -n 's/^sha=//p' hack/migration/FREEZE)" /tmp/sdk-typescript-history
```

Both scripts need `git-filter-repo` (`uv tool install git-filter-repo`).

Fixes over the Python copies: `extract-history.sh` sets `main` with
`git update-ref`, because `git branch --force` refuses the branch a
no-checkout clone already has as `HEAD`, and it tolerates a core clone whose
only branch is `main`.

## Port a core change

Core froze `sdk/typescript/` (`TypeScript SDK Freeze` check), so a core change that still edits it has to land here instead. `port-pr.sh` is sdk-python's script (`migration/v0.1.7`) with this repository's paths: it strips the `sdk/typescript/` prefix, and it runs `mise run lint`, `typecheck`, and `test`. From a clean sdk-typescript clone, with this branch checked out elsewhere (for example `git worktree add ../migration migration/v0.1.9`):

```shell
../migration/hack/migration/port-pr.sh <core-pr-number | core-commit>
```

For a merged PR the script ports its original commits, whose authors match their `Signed-off-by` trailers, and checks that together they make the same SDK change as the squash commit that landed in core. `--squash` ports the squash commit instead; GitHub authors it with the merger's account email, which often fails the DCO check. The script builds `port/<id>` from `origin/main`, qualifies bare `#N` in commit messages as `NVIDIA/OpenShell#N`, applies the commits with `git am --3way`, runs the checks, and prints the PR body. Nothing is pushed until you rerun with `--continue --push`. On a conflict, resolve it, `git add` the files, run `git am --continue`, then rerun with `--continue`.

Not ported: everything outside `sdk/typescript/`, and core's `sdk/typescript/e2e/`, which this repository's E2E suite replaced. The bindings under `src/gen` are generated from the core ref in `mise.toml`, so a change that reads newer proto fields fails the type check until the pin moves. Port it with `--continue --no-test --push` and land it with the core bump.

Core later replaced `sdk/typescript/` with the `@nvidia/openshell-sdk` re-export stub (NVIDIA/OpenShell#5685). Only port changes made before that.

## Current freeze

The import now includes core through `v0.1.9` (`ce58cf8e9b953281352d98a637e41616295b1318`). Filtering produces 39 commits from 20 authors, with tree `07965ecfa951d5ccb9e18454e5f154a002f72322`. The refresh preserves the original import and merges the additional filtered commit without rewriting its history.
