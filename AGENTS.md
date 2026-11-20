# Agent Instructions

The OpenShell TypeScript SDK: package `@ai-openshell/sdk` on npm, a client for
the OpenShell gateway. See [CONTRIBUTING.md](CONTRIBUTING.md) for tasks and the
release model.

## Commands

- `mise run ci` runs the full pipeline (format check, lint, type check, proto
  check, vendored-file check, unit tests, build).
- `mise run proto:gen` regenerates `src/gen` from core at the ref pinned in
  `OPENSHELL_CORE_REF` (`mise.toml`). Never edit generated files by hand.
- To generate bindings for another core proto file, add it to both the
  `--path` list of `proto:fetch` in `mise.toml` and `paths` in `buf.gen.yaml`.
- Run tools through mise tasks, which install the dependencies from
  `package-lock.json` first.

## Code conventions

- The SDK supports Node.js 20.3 and newer (`engines` in `package.json`). Don't
  use APIs from later versions.
- The public API is what `src/index.ts` exports. Keep it free of generated wire
  types; the generated messages and RPCs are exported from
  `@ai-openshell/sdk/raw` (`src/raw.ts`), and users import them, so keep those
  exports stable.
- Core's deprecated `@nvidia/openshell-sdk@0.1.10` re-exports `.` and `./raw`
  from this package and depends on `^0.1.0`, so users of the old name receive
  every 0.1.x release. Keep both entry points, and keep 0.1.x releases free of
  breaking changes.
- Unit tests live next to the code as `src/*.test.ts`; fixtures go in
  `test/fixtures/`.
- Files copied from core must stay identical to core at the pin;
  `mise run vendored:check` compares them.
- New files need only the license line `SPDX-License-Identifier: Apache-2.0`
  in a comment. Keep the existing headers as they are.

## Commits

- Use Conventional Commits and sign off every commit (`--signoff`).
- Never mention Claude or any AI agent in commits, pull request descriptions, or
  issues (no author attribution, no Co-Authored-By, no "Generated with"
  footers).
