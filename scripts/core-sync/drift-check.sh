#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

# drift-check.sh: compare core main with the pinned core tag or commit.
#
# Usage: drift-check.sh --out <report.md>
#
# Run from the root of an sdk-typescript clone. Three checks:
#   1. buf breaking: core main against the pinned tag (FILE rules), for the
#      proto files the SDK generates (what `mise run proto:fetch` exports)
#   2. regenerate and test: bindings from core main in a temporary
#      worktree, then `mise run check` (type check, lint, proto and
#      vendored-file checks) and the unit tests
#   3. uncovered RPCs: methods of the services in the regenerated src/gen
#      that no curated SDK code under src calls (bindings and tests
#      excluded; client.raw reaches every RPC); informational, it does not
#      fail the check
# Writes a markdown report with the header
# "Pin: <tag> | Core main: <sha> | Result: pass|fail" and one section per
# check. Exits 0 when checks 1 and 2 pass, 1 otherwise.
set -euo pipefail

core_url=${CORE_URL:-https://github.com/NVIDIA/OpenShell.git}
out=
while [ $# -gt 0 ]; do
  case $1 in
  --out) out=${2:?--out needs a file}; shift 2 ;;
  *) echo "usage: $0 --out <report.md>" >&2; exit 2 ;;
  esac
done
[ -n "$out" ] || { echo "usage: $0 --out <report.md>" >&2; exit 2; }
[ "$(git rev-parse --show-toplevel)" = "$(pwd -P)" ] || {
  echo "ERROR: run this from the root of the sdk-typescript clone" >&2
  exit 1
}
case $out in /*) ;; *) out="$(pwd)/$out" ;; esac

pin_of() { sed -n 's/^OPENSHELL_CORE_REF = "\(.*\)"$/\1/p'; }
pin=$(pin_of <mise.toml)
[ -n "$pin" ] || { echo "ERROR: no OPENSHELL_CORE_REF in mise.toml" >&2; exit 1; }
# A release tag, or a full commit SHA on core's main.
if [[ "$pin" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-pre\.[0-9]+)?$ ]]; then
  pin_input="tag=${pin}"
elif [[ "$pin" =~ ^[0-9a-f]{40}$ ]]; then
  pin_input="ref=${pin}"
else
  echo "ERROR: pin '$pin' is neither a release tag nor a full commit SHA" >&2
  exit 1
fi
main_sha=$(git ls-remote "$core_url" refs/heads/main | cut -f1)
[ -n "$main_sha" ] || { echo "ERROR: cannot resolve core main" >&2; exit 1; }

# buf comes from the package's devDependencies, like in proto:fetch.
mise run --quiet install
buf() { npx --no-install buf "$@"; }

work=$(mktemp -d)
cleanup() { git worktree remove --force "$work/wt" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
result=pass
fence() { printf '```text\n%s\n```\n' "$1"; }

# 1. buf breaking for the files the SDK generates: the roots of proto:fetch
# and their imports, as exported at the pin. Keep the roots in step with
# proto:fetch in mise.toml.
buf export "${core_url}#ref=${pin},depth=1,subdir=proto" \
  --path openshell.proto --path sandbox.proto --path datamodel.proto --path options.proto \
  --output "$work/pinned"
files=$(cd "$work/pinned" && find . -name '*.proto' | sed 's#^\./##' | sort)
path_args=()
for f in $files; do path_args+=(--path "proto/$f"); done
# Core's root buf.yaml has two modules; this config keeps only proto/, so
# its imports resolve the same way buf export sees them.
if breaking=$(buf breaking "${core_url}#ref=${main_sha}" \
  --against "${core_url}#${pin_input}" \
  --config '{"version":"v2","modules":[{"path":"proto"}],"breaking":{"use":["FILE"]}}' \
  "${path_args[@]}" 2>&1); then
  breaking_section="No breaking changes in $(echo $files | sed 's/ /, /g') between \`$pin\` and main."
else
  result=fail
  breaking_section="Breaking changes between \`$pin\` and main:

$(fence "$breaking")"
fi

# 2. Regenerate from main, then run the checks and the unit tests. The type
# check matters: a new enum value can pass buf breaking and the tests but
# break an exhaustive map.
git worktree add --quiet --detach "$work/wt" HEAD
# proto:check compares the bindings with the last commit, so commit the
# regenerated ones in the throwaway worktree before running check.
commit_regenerated() {
  git add -A &&
    git -c user.name=core-drift -c user.email=core-drift@localhost -c commit.gpgsign=false \
      commit --quiet --no-verify --allow-empty -m "regenerate from core main"
}
if build=$(
  cd "$work/wt" &&
    sed -i.bak "s/^OPENSHELL_CORE_REF = \".*\"$/OPENSHELL_CORE_REF = \"$main_sha\"/" mise.toml &&
    rm -f mise.toml.bak &&
    mise trust --quiet mise.toml &&
    mise run --quiet proto:gen 2>&1 &&
    commit_regenerated 2>&1 &&
    mise run --quiet check 2>&1 &&
    mise run --quiet test 2>&1
); then
  changed=$(git -C "$work/wt" diff --stat HEAD~1 HEAD -- src/gen | tail -1 | sed 's/^ *//')
  build_section="Bindings from main pass the checks and the unit tests (${changed:-no generated files change})."
else
  result=fail
  build_section="Regenerating from main, checking or testing against it fails:

$(fence "$(tail -n 60 <<<"$build")")"
fi

# 3. RPCs the SDK does not call yet. protoc-gen-es writes each method as
#   * @generated from rpc openshell.v1.OpenShell.CreateSandbox
#   */
#  createSandbox: {
# and Connect clients call it as client.createSandbox(...).
uncovered=""
methods=$(awk '
  /@generated from rpc / { n = split($NF, p, "."); service = p[n - 1]; want = 1; next }
  want && /^  [A-Za-z0-9_]+: \{$/ { sub(/^  /, ""); sub(/: \{$/, ""); print service " " $0; want = 0 }
  ' "$work/wt"/src/gen/*_pb.ts | sort -u)
while read -r service method; do
  [ -n "$method" ] || continue
  if ! grep -rqE "\.${method}\(" src --include='*.ts' --exclude-dir=gen --exclude='*.test.ts'; then
    uncovered+="- ${service}.${method}"$'\n'
  fi
done <<<"$methods"
if [ -z "$uncovered" ]; then
  uncovered_section="Every RPC in the regenerated stubs is called by the SDK."
else
  uncovered_section="RPCs in core main that the SDK does not call yet ($(grep -c . <<<"$uncovered")):

${uncovered%$'\n'}"
fi

cat >"$out" <<EOF
Pin: $pin | Core main: $main_sha | Result: $result

## buf breaking

$breaking_section

## Regenerate and test

$build_section

## Uncovered RPCs

$uncovered_section
EOF

echo "Drift check against core main $main_sha: $result (report: $out)"
[ "$result" = pass ]
