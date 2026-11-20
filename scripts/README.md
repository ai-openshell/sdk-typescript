# Scripts

The workflows under `.github/workflows/` run these scripts, most through a mise task, so each job can be run locally first. Scripts that write to GitHub take `--dry-run` and print what they would do instead. They are kept close to the copies in [sdk-python](https://github.com/ai-openshell/sdk-python/tree/main/scripts) and [sdk-go](https://github.com/ai-openshell/sdk-go), so a fix in one applies to the others.

## `core-sync/`: keeping up with core

Move the core pin (`OPENSHELL_CORE_REF` in `mise.toml`) to new core releases, and watch core `main` for changes that will break the SDK.

The workflows use a GitHub App token from the `sdk-bot` environment (secrets `SDK_BOT_CLIENT_ID` and `SDK_BOT_PRIVATE_KEY`), which only `main` can deploy to. They never use `GITHUB_TOKEN`, because pushes and PRs made with it don't trigger CI.

| File | mise task | Purpose |
|------|-----------|---------|
| `core-tags.sh [--all]` | `core:tags` | List NVIDIA/OpenShell release tags newer than the pin: every stable tag, plus the newest pre-release when it is newer than all of them. For a commit SHA pin, the newer tags are those that contain the commit. |
| `open-bump-pr.sh <tag> [--dry-run]` | `core:bump` | Open the update proposal for one core tag: branch `core/<tag>`, pin change, regenerated bindings in `src/gen`, refreshed copies of core files, proto diff in the body, labels `core-bump` plus `stable` or `prerelease`. Closes older pre-release proposals. |
| `bump-pr-body.md` | | PR body template for `open-bump-pr.sh`. |
| `drift-check.sh --out <file>` | `core:drift` | Compare core `main` with the pin: `buf breaking`, regenerate, then run `check` and the unit tests, list the RPCs the curated SDK doesn't call. Writes the markdown report. |
| `update-drift-issue.sh <report.md> [--dry-run]` | `core:drift-issue` | Create, update, or close the single `Core main drift` issue from a report. |
| `report-failure.sh <job> <run-url> [--dry-run]` | `core:report-failure` | Append a dated failure line to the drift issue. Called from `if: failure()` steps. |
| `drift-issue.sh` | | Shared helpers for the two drift issue scripts (sourced, not run). |

| Workflow | Runs (mise tasks) |
|----------|------|
| `core-watch.yml` (hourly) | `core:tags`, then `core:bump` per tag |
| `core-drift.yml` (nightly) | `core:drift`, then `core:drift-issue` |

## `release/`: lockstep releases

| File | Purpose |
|------|---------|
| `tag-release.sh [--dry-run] [--force] [--sha <commit>] [--since <commit>]` | When the pin at a commit on `main` moved to a stable core tag `vX.Y.Z`, create the tag `vX.Y.Z` there and a draft GitHub release. Prints `tag=vX.Y.Z` while the release still has to be published. |

`release.yml` runs on every push to `main`. When `tag-release.sh` prints a tag, it builds the package at that version, publishes it to npmjs.org with trusted publishing from the `npm` environment, and publishes the GitHub release with the tarball and its checksum.

## `e2e/`: E2E gateway

| File | Purpose |
|------|---------|
| `start-gateway.sh <core-version> [--state-dir <dir>] [--default-image <image>]` | Start the published gateway of a core version (a release tag, or a commit SHA with dev images) with core's `deploy/docker` files and register it as `e2e`. Waits up to 15 minutes for the gateway image of a fresh tag. |
| `stop-gateway.sh [--state-dir <dir>]` | Save the gateway log, remove the sandbox containers and the gateway, and remove the `e2e` registration. |

`e2e.yml` runs them around `mise run e2e`, on every CI run and on manual dispatch with any core version.

## Build and checks

| File | mise task | Purpose |
|------|-----------|---------|
| `vendored-core-files.txt` | `vendored:check` | Files copied from core. `vendored:check` compares them with core at the pin; `core-sync/open-bump-pr.sh` refreshes them. |
| `fetch-core.sh <ref> <dir> <path>...` | `vendored:check` | Copy files from core at a ref. |
