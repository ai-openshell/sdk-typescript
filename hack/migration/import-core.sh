#!/usr/bin/env bash
# import-core.sh: import core commits that changed sdk/typescript after the
# existing import, exactly as they are on core's main: same author, committer,
# dates, and message (bare #N qualified as NVIDIA/OpenShell#N, as in the
# history import). Use it for changes that already landed in core; port-pr.sh
# is for open PRs.
#
# Usage: import-core.sh [--base <ref>] <core-clone> <core-commit>
#
#   <core-clone>   a NVIDIA/OpenShell clone whose main contains <core-commit>
#   <core-commit>  the newest core commit to import through, usually the
#                  squash commit of the merged PR
#   --base <ref>   branch the import starts from (default: origin/main)
#
# Run it from the root of an sdk-typescript clone with a clean working tree.
#
# Steps:
#   1. Filter core's history through <core-commit> with extract-history.sh.
#      Filtering is deterministic, so the commits this repository already
#      imported come out with the same ids, and only the newer SDK commits
#      are new.
#   2. Create import/<short-sha> from --base and merge the filtered tip with
#      a signed-off merge commit, as the v0.1.9 history refresh did. Nothing
#      in the imported commits is rewritten.
#
# Afterwards, review the branch, push it, and open a PR. Merge that PR with a
# merge commit: a squash would replace the imported commits. A core commit
# whose Signed-off-by does not match its author fails the DCO check here as it
# would have in core; a maintainer overrides it, as for the history import.
#
# The imported code is checked against the bindings at the current pin. A
# change that reads proto fields newer than the pin fails the type check until
# a commit that moves the pin is added on top.
set -euo pipefail

base=origin/main
args=()
while [ $# -gt 0 ]; do
  case $1 in
  --base) base=${2:?--base needs a ref}; shift 2 ;;
  -h | --help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2; exit 2 ;;
  -*) echo "ERROR: unknown option $1" >&2; exit 2 ;;
  *) args+=("$1"); shift ;;
  esac
done
[ ${#args[@]} -eq 2 ] || { echo "usage: $0 [--base <ref>] <core-clone> <core-commit>" >&2; exit 2; }
core=${args[0]}
commit=${args[1]}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(git rev-parse --show-toplevel)" = "$(pwd -P)" ] ||
  die "run this from the root of the sdk-typescript clone"
git diff --quiet && git diff --cached --quiet ||
  die "the working tree has changes; commit or remove them first"
[ "$(git show "$base:package.json" 2>/dev/null | jq -r .name)" = "@ai-openshell/sdk" ] ||
  die "$base is not the standalone SDK (package.json does not name @ai-openshell/sdk)"
full=$(git -C "$core" rev-parse --verify --quiet "$commit^{commit}") ||
  die "$commit is not a commit in $core"
short=$(git -C "$core" rev-parse --short=10 "$full")
branch="import/$short"
git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null &&
  die "branch $branch exists; delete it to import again"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Filtering core history through $short ..."
"$here/extract-history.sh" "$core" "$full" "$tmp/filtered" >/dev/null
tip=$(git -C "$tmp/filtered" rev-parse HEAD)
git fetch --quiet --no-tags "$tmp/filtered" "+refs/heads/main:refs/import-src/$short"

# The filtered history must extend what is already here. Without a common
# ancestor the filter produced different ids, and merging would duplicate
# the whole history.
git merge-base "$base" "$tip" >/dev/null ||
  die "the filtered history shares no commit with $base; check extract-history.sh and message-rules.txt against the original import"
new=$(git rev-list --count "$base..$tip")
[ "$new" -gt 0 ] || die "$base already contains every SDK commit through $short"
total=$(git rev-list --count "$tip")
[ "$new" -lt "$total" ] || die "every filtered commit is new; the ids differ from the existing import"

echo "New commits ($new):"
git log --reverse --format='  %h %an <%ae>  %s' "$base..$tip"

subject="chore: import TypeScript SDK history through NVIDIA/OpenShell@$short"
git switch --quiet -c "$branch" "$base"
if ! git merge --quiet --no-ff --no-edit --signoff -m "$subject" "$tip"; then
  cat >&2 <<MSG

The merge stopped on a conflict. Resolve it, then:
  git add <files>
  git commit --signoff --no-edit
To give up: git merge --abort && git switch - && git branch -D $branch
MSG
  exit 1
fi
echo
echo "Branch $branch: merged $(git rev-parse --short "$tip") with $(git rev-parse --short HEAD)."
echo "Review it, push it, and open a PR that is merged with a merge commit."
