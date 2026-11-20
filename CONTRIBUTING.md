# Contributing to the OpenShell TypeScript SDK

## Setup

Install [mise](https://mise.jdx.dev/), then install the pinned tools and the
npm dependencies:

```shell
mise install
mise run install
```

mise installs Node.js and the tools; npm installs the dependencies from
`package-lock.json`. `mise tasks` lists every task. The ones you need most:

| Task | What it does |
|------|--------------|
| `mise run ci` | Everything CI runs: checks, unit tests, build |
| `mise run check` | Format check, lint, type check, proto check, vendored-file check |
| `mise run format` | Format the code and apply safe fixes |
| `mise run test` | Vitest unit tests with an 80% line-coverage gate |
| `mise run build` | Emit `dist/` and verify the package contents |
| `mise run e2e` | E2E tests against a running gateway; see below for setup |
| `mise run proto:gen` | Regenerate the bindings from core at the pinned ref |
| `mise run core:version` | Print the pinned core version |

CI runs the unit tests on every Node.js version in `mise.toml` (20, 22 and 24).
To run them on one locally, set `MISE_NODE_VERSION`, for example
`MISE_NODE_VERSION=20.20.2 mise run test`.

Formatting and linting use [Biome](https://biomejs.dev) (`biome.json`): 2-space
indent, single quotes, semicolons, 120-column width. The generated `src/gen/`
and the files copied from core are excluded.

## E2E tests

`e2e/` runs against a real gateway; `mise run test` skips it. CI runs it
against the published gateway of the pinned core version, with the Docker
compute driver. To run it locally, you need Docker with the compose plugin:

```shell
scripts/e2e/start-gateway.sh "$(mise run -q core:version)"
OPENSHELL_GATEWAY=e2e mise run e2e
scripts/e2e/stop-gateway.sh
```

Without `OPENSHELL_GATEWAY`, every E2E test is skipped. The suite reads the
gateway registration from `$XDG_CONFIG_HOME/openshell/gateways/<name>`, so it
can also run against another registered gateway.

`start-gateway.sh` is meant for throwaway hosts. It serves the gateway on
`127.0.0.1:8080`, registers `e2e` as the active gateway, and
`stop-gateway.sh` removes every sandbox container labelled with core's default
namespace. Set `XDG_CONFIG_HOME` to keep your own gateway registrations apart.

## Commits and pull requests

- Use [Conventional Commits](https://www.conventionalcommits.org/):
  `<type>(<scope>): <description>`.
- Sign off every commit (`git commit --signoff`) for the [Developer Certificate
  of Origin](https://developercertificate.org/).
- Every change goes through a pull request with an approval from a code owner
  who did not push last.
- New files need only the license line `SPDX-License-Identifier: Apache-2.0`
  in a comment. Keep the existing headers as they are.

## Bindings and core versions

The bindings in `src/gen/` are generated with protoc-gen-es from core's
`proto/` at one core ref, `OPENSHELL_CORE_REF` in `mise.toml`, and committed.
Don't edit generated files; change the pin and run `mise run proto:gen`.
`mise run proto:check` fails when the committed bindings don't match the pin.

Building the package needs neither a core checkout nor network access because
the generated bindings are committed. A change to the core pin makes the
generated API changes visible in the diff. protoc-gen-es stamps its version
into the bindings, so update it together with `mise run proto:gen`; Dependabot
leaves it alone.

### Pinning a core commit

To land SDK support for a proto change that is on core's `main` but in no
core tag yet, pin the full 40-character commit SHA instead of a tag:
`OPENSHELL_CORE_REF = "<sha>"` in `mise.toml`, then `mise run proto:gen`.
Pick a commit that has dev images: core's `release-dev.yml` publishes
`ghcr.io/nvidia/openshell/{gateway,supervisor,sandbox}:<sha>` for batches of
`main` commits, and the E2E job runs those images. A SHA pin is never
released. Core-watch treats every release tag that contains the commit as
newer, and its bump proposal moves the pin back to a tag.

Shared test fixtures come from core's `sdk/conformance/` and are copied into
`test/fixtures/` (listed in `scripts/vendored-core-files.txt`).
`mise run vendored:check` compares them with core at the pinned ref.

The curated API (`src/index.ts`) stays free of generated wire types; the full
generated messages and RPCs are exported from `@ai-openshell/sdk/raw`.

## Core bumps and drift

Automation watches core for new tags and opens a pull request that moves the
pin, labeled `core-bump` plus `stable` or `prerelease`. If a bump needs SDK
changes, push them to the same branch.

A nightly job checks core's `main` for breaking proto changes and RPCs the SDK
doesn't cover yet, and keeps one issue labeled `core-drift` up to date. See
[scripts/README.md](scripts/README.md) for how both work.

## Releases

SDK releases follow core releases: SDK `X.Y.Z` is built from core `vX.Y.Z`, and
there are no SDK-only releases. Pre-release and commit SHA pins are never
released. The
`version` in `package.json` stays `0.0.0`; the release stamps the real one.

Merging a pull request that moves the pin to a stable core tag releases the SDK.
`release.yml` runs on every push to `main` and does nothing unless the pin
changed to a stable tag. Then it:

1. tags `vX.Y.Z` at the merged commit and creates a draft GitHub release, with
   the pull request's description as notes (`scripts/release/tag-release.sh`);
2. builds the package at version `X.Y.Z`, verifies it, and writes its checksum;
3. publishes `@ai-openshell/sdk` to npmjs.org from the `npm` environment with
   trusted publishing, so npm adds provenance;
4. attaches the tarball and the checksum to the draft and publishes it.

If a run fails, re-run only its failed jobs. The tag step skips a tag or draft
that exists already, and a version npm already has is not published again.
To release a commit by hand, start the workflow on `main` with the commit's SHA
(`gh workflow run release.yml -f sha=<commit>`).

To try unreleased changes, build and pack the package, then install the
tarball in your project:

```shell
mise run build
npm pack --ignore-scripts
npm install /path/to/ai-openshell-sdk-0.0.0.tgz
```
