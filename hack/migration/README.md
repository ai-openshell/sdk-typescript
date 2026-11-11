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
