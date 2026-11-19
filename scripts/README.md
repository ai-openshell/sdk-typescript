# Scripts

The workflows under `.github/workflows/` run these scripts, most through a mise task, so each job can be run locally first. Scripts that write to GitHub take `--dry-run` and print what they would do instead.

## Core sync and release tagging (shared)

The core-sync scripts and the `core-watch` and `core-drift` workflows are shared with the other SDKs through [ai-openshell/workflows](https://github.com/ai-openshell/workflows/tree/main/core-sync), which documents them and the contract this repository implements. `mise.toml` pins the scripts as remote tasks, and `core-watch.yml` and `core-drift.yml` call the shared workflows at the same commit; update the two refs together.

| mise task | Runs |
|-----------|------|
| `core:tags`, `core:bump`, `core:drift`, `core:drift-issue`, `core:report-failure`, `release:tag` | The shared scripts. |
| `proto:fetch`, `proto:gen`, `proto:buf`, `check`, `test` | This repository's parts of the contract. |
| `core:uncovered-rpcs` | `uncovered-rpcs.sh`: RPCs in `src/gen` the curated SDK doesn't call, for the drift report. |

| Workflow | Runs |
|----------|------|
| `core-watch.yml` (hourly) | `core:tags`, then `core:bump` per tag |
| `core-drift.yml` (nightly) | `core:drift`, then `core:drift-issue` |
| `release.yml` (push to `main`) | `release:tag`; when it prints a tag, builds the package at that version, publishes it to npmjs.org with trusted publishing from the `npm` environment, and publishes the GitHub release with the tarball and its checksum. |

The shared workflows use a GitHub App token from the `sdk-bot` environment (secrets `SDK_BOT_CLIENT_ID` and `SDK_BOT_PRIVATE_KEY`), which only `main` can deploy to.

## `e2e/`: E2E gateway

| File | Purpose |
|------|---------|
| `start-gateway.sh <core-version> [--state-dir <dir>] [--default-image <image>]` | Start the published gateway of a core version with core's `deploy/docker` files and register it as `e2e`. Waits up to 15 minutes for the gateway image of a fresh tag. |
| `stop-gateway.sh [--state-dir <dir>]` | Save the gateway log, remove the sandbox containers and the gateway, and remove the `e2e` registration. |

`e2e.yml` runs them around `mise run e2e`, on every CI run and on manual dispatch with any core version.

## Build and checks

| File | mise task | Purpose |
|------|-----------|---------|
| `vendored-core-files.txt` | `vendored:check` | Files copied from core. `vendored:check` compares them with core at the pin; `core:bump` refreshes them. |
| `fetch-core.sh <ref> <dir> <path>...` | `vendored:check` | Copy files from core at a ref. |
