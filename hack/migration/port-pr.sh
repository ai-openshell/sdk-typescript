#!/usr/bin/env bash
# port-pr.sh: port a NVIDIA/OpenShell change that touches the TypeScript SDK into
# this repository, keeping every commit with its original author, date, and
# Signed-off-by trailer.
#
# Usage: port-pr.sh [options] <core-pr-number | core-commit>
#        port-pr.sh --continue [options] <core-pr-number | core-commit>
#
# The argument is one of:
#   a PR number   an open or merged PR: its original commits since the merge
#                 base with its base branch (with --squash, a merged PR's
#                 squash commit instead)
#   a commit      any commit reachable from core's main branch; ported alone
#
# Options:
#   --base <ref>     branch the port starts from (default: origin/main)
#   --core <url>     core repository to fetch from
#                    (default: https://github.com/NVIDIA/OpenShell.git)
#   --squash         port a merged PR's squash commit instead of its original
#                    commits. GitHub authors a squash commit with the merger's
#                    account email, which often does not match the
#                    Signed-off-by trailers, so the DCO check fails.
#   --push           push port/<id> and open the sdk-typescript PR (default: stop
#                    after the local branch and print the PR body for review)
#   --no-test        skip lint, type check, and the unit tests on the result
#   --continue       finish a port after resolving a failed `git am`
#
# Run it from the root of an sdk-typescript clone with a clean working tree. The
# script can live in another checkout (for example a worktree of the
# migration tag); it works on the repository in the current directory.
#
# Steps:
#   1. Fetch the change and core's base branch into refs/port-src/<id>/.
#   2. format-patch the commits limited to the SDK's core paths (see PATHSPECS).
#   3. Qualify bare #N references in the commit messages as
#      NVIDIA/OpenShell#N, and strip the sdk/typescript/ prefix from the paths
#      in the patch headers (see the sed program in map_paths).
#   4. git am --3way onto port/<id> from --base. On a conflict, resolve it,
#      `git add` the files, run `git am --continue`, then rerun with --continue.
#   5. For a merged PR, check that the ported commits make the same SDK change
#      as the squash commit that landed in core.
#   6. Run lint, the type check, and the unit tests.
#   7. With --push: push port/<id> and open a PR with a body from
#      port-pr-body.md.
#
# Files the change touches outside the SDK paths are not ported; that part
# stays in core. The bindings under src/gen are
# never ported: they are generated from the core ref pinned in mise.toml. A
# change that reads proto fields newer than the pin fails the type check until
# the pin moves; port it anyway with --no-test and land it with the core bump.
#
# Core's sdk/typescript later became the @nvidia/openshell-sdk re-export stub
# (NVIDIA/OpenShell#5685). Only port changes made before that: the stub's
# package.json and README.md would map onto this repository's files.
set -euo pipefail

core_repo=NVIDIA/OpenShell
sdk_repo=ai-openshell/sdk-typescript

# Core paths the SDK owns. Core never committed the generated bindings
# (src/gen). Core's e2e/interactive-exec.mjs is not ported: this repository's
# E2E suite (e2e/*.e2e.test.ts) replaced it. The shared fixtures under
# sdk/conformance are vendored from core (mise run vendored:check), not ported.
PATHSPECS=(
  sdk/typescript
  ':(exclude)sdk/typescript/src/gen'
  ':(exclude)sdk/typescript/e2e'
)

base=origin/main
core_url=https://github.com/NVIDIA/OpenShell.git
push=0
squash=0
test=1
cont=0
arg=

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case $1 in
  --base) base=${2:?--base needs a ref}; shift 2 ;;
  --core) core_url=${2:?--core needs a URL}; shift 2 ;;
  --push) push=1; shift ;;
  --squash) squash=1; shift ;;
  --no-test) test=0; shift ;;
  --continue) cont=1; shift ;;
  -h | --help) usage ;;
  -*) echo "ERROR: unknown option $1" >&2; usage ;;
  *) [ -z "$arg" ] || usage; arg=$1; shift ;;
  esac
done
[ -n "$arg" ] || usage

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
body_tmpl="$here/port-pr-body.md"

die() { echo "ERROR: $*" >&2; exit 1; }

for tool in git gh jq mise; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
done
[ -f "$body_tmpl" ] || die "$body_tmpl is missing"
[ "$(git rev-parse --show-toplevel)" = "$(pwd -P)" ] ||
  die "run this from the root of the sdk-typescript clone"

# Rewrites core paths to this repository's layout in the header lines of a
# patch (diff --git, ---, +++, rename, copy): sdk/typescript/ is the root here.
map_paths() {
  sed -E '
    /^(diff --git |--- |\+\+\+ |rename (from|to) |copy (from|to) )/ {
      s#(a/|b/|from |to )sdk/typescript/#\1#g
    }' "$@"
}

# Qualifies bare #N references in the commit message of each patch, which name
# core issues and PRs and would otherwise point at this repository. Same rule
# as message-rules.txt. Only the header and message are touched (up to the
# first `---` line), never the diff.
qualify_refs() {
  sed -E -i '1,/^---$/ s#(^|[^A-Za-z0-9/\#])\#([0-9]+)#\1NVIDIA/OpenShell\#\2#g' "$@"
}

# The id names the branch and state directory: pr-<n> or the short commit.
if [[ $arg =~ ^[0-9]+$ ]]; then
  id=$arg
  kind=pr
else
  kind=commit
fi

if [ "$kind" = commit ]; then
  # Resolve against core's main so a short sha works. A continue run already
  # has the objects.
  [ "$cont" -eq 1 ] || git fetch --quiet --no-tags "$core_url" "+refs/heads/main:refs/port-src/main"
  id=$(git rev-parse --short=10 "$arg^{commit}" 2>/dev/null) ||
    die "commit $arg is not reachable from core's main"
fi

branch="port/$id"
src="refs/port-src/$id"
state_dir="$(git rev-parse --git-path "port-src/$id")"

if [ "$cont" -eq 0 ]; then
  git diff --quiet && git diff --cached --quiet ||
    die "the working tree has changes; commit or remove them first"
  [ ! -d "$(git rev-parse --git-path rebase-apply)" ] ||
    die "a git am is in progress; finish it or run git am --abort"
  git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null &&
    die "branch $branch exists; delete it to port again"
  git rev-parse --verify --quiet "$base^{commit}" >/dev/null ||
    die "base $base is not a commit"
  [ "$(git show "$base:package.json" 2>/dev/null | jq -r .name)" = "@ai-openshell/sdk" ] ||
    die "$base is not the standalone SDK (package.json does not name @ai-openshell/sdk)"

  rm -rf "$state_dir"
  mkdir -p "$state_dir/patches"

  if [ "$kind" = pr ]; then
    meta=$(gh pr view "$arg" -R "$core_repo" \
      --json state,baseRefName,headRefOid,mergeCommit,title,url,author)
    squash_oid=
    state=$(jq -r .state <<<"$meta")
    core_base=$(jq -r .baseRefName <<<"$meta")
    case $state in
    OPEN)
      head_oid=$(jq -r .headRefOid <<<"$meta")
      echo "Fetching $core_repo#$arg ($head_oid) and $core_base ..."
      git fetch --quiet --no-tags "$core_url" \
        "+refs/pull/$arg/head:$src/head" "+refs/heads/$core_base:$src/base"
      [ "$(git rev-parse "$src/head")" = "$head_oid" ] ||
        die "fetched head does not match $head_oid; the PR changed during the fetch, rerun"
      from=$(git merge-base "$src/base" "$src/head")
      to=$src/head
      ;;
    MERGED)
      mc=$(jq -r .mergeCommit.oid <<<"$meta")
      head_oid=$(jq -r .headRefOid <<<"$meta")
      echo "Fetching $core_repo#$arg (merged as $mc, head $head_oid) ..."
      git fetch --quiet --no-tags "$core_url" "+refs/heads/$core_base:$src/base"
      git cat-file -e "$mc^{commit}" 2>/dev/null ||
        die "merge commit $mc is not reachable from $core_base"
      [ "$(git rev-list --parents -n1 "$mc" | wc -w)" -eq 2 ] ||
        die "$mc is a merge commit; only squash or rebase merged PRs with one parent are supported, port the commits one by one"
      if [ "$squash" -eq 1 ]; then
        git update-ref "$src/head" "$mc"
        from=$mc^
        to=$mc
      else
        git fetch --quiet --no-tags "$core_url" "+refs/pull/$arg/head:$src/head"
        [ "$(git rev-parse "$src/head")" = "$head_oid" ] ||
          die "fetched head does not match $head_oid; rerun with --squash to port the squash commit"
        from=$(git merge-base "$mc^" "$src/head")
        to=$src/head
        squash_oid=$mc
      fi
      ;;
    *) die "$core_repo#$arg is $state, only open and merged PRs are ported" ;;
    esac
    title=$(jq -r .title <<<"$meta")
    url=$(jq -r .url <<<"$meta")
    author=$(jq -r .author.login <<<"$meta")
    ref="$core_repo#$arg"
  else
    full=$(git rev-parse "$arg^{commit}")
    git update-ref "$src/head" "$full"
    from=$full^
    to=$full
    title=$(git log -1 --format=%s "$full")
    url="https://github.com/$core_repo/commit/$full"
    author=$(git log -1 --format=%an "$full")
    ref="$core_repo@$(git rev-parse --short "$full")"
    head_oid=$full
  fi
  head_oid=$(git rev-parse "$to")
  jq -n --arg title "$title" --arg url "$url" --arg author "$author" \
    --arg ref "$ref" --arg head "$head_oid" --arg squash "${squash_oid:-}" \
    '{title:$title,url:$url,author:$author,ref:$ref,head:$head,squash:$squash}' >"$state_dir/meta.json"

  # Files the change touches that are not ported.
  git diff --name-only "$from" "$to" >"$state_dir/all.txt"
  git diff --name-only "$from" "$to" -- "${PATHSPECS[@]}" >"$state_dir/ported.txt"
  grep -vxFf "$state_dir/ported.txt" "$state_dir/all.txt" >"$state_dir/outside.txt" || true

  # --no-signoff: a format.signoff=true config would add the porter's sign-off
  # to every commit; only the original trailers are kept.
  git format-patch --quiet --no-signoff -o "$state_dir/patches" \
    "$from..$to" -- "${PATHSPECS[@]}"
  set -- "$state_dir"/patches/*.patch
  [ -e "$1" ] || die "$ref has no commits that touch the TypeScript SDK paths"
  map_paths -i "$@"
  qualify_refs "$@"
  echo "Patches: $# (from $(git rev-parse --short "$from"))"
  if [ -s "$state_dir/outside.txt" ]; then
    echo "Not ported (outside the SDK paths):"
    sed 's/^/  /' "$state_dir/outside.txt"
  fi

  git switch --quiet -c "$branch" "$base"
  git rev-parse HEAD >"$state_dir/start"
  if ! git am --quiet --3way "$@"; then
    again="$0 --continue"
    [ "$base" = origin/main ] || again="$again --base $base"
    [ "$push" -eq 0 ] || again="$again --push"
    cat >&2 <<EOF

git am stopped on a conflict. Resolve it, then:
  git add <files>
  git am --continue
  $again $arg
To give up: git am --abort && git switch - && git branch -D $branch
EOF
    exit 1
  fi
else
  [ -f "$state_dir/meta.json" ] || die "no port of $arg is in progress"
  [ "$(git branch --show-current)" = "$branch" ] || die "switch to $branch first"
  [ ! -d "$(git rev-parse --git-path rebase-apply)" ] ||
    die "git am is still in progress; run git am --continue first"
fi

meta=$(cat "$state_dir/meta.json")
start=$(cat "$state_dir/start")
ncommits=$(git rev-list --count "$start..HEAD")
[ "$ncommits" -gt 0 ] || die "no commits were applied"

# The original commits of a merged PR must add up to the SDK change that
# landed. patch-id ignores line numbers, so drift elsewhere in a file is fine.
squash_oid=$(jq -r '.squash // empty' <<<"$meta")
if [ -n "$squash_oid" ]; then
  want=$(git diff "$squash_oid^" "$squash_oid" -- "${PATHSPECS[@]}" | map_paths | git patch-id --stable | cut -d' ' -f1)
  got=$(git diff "$start" HEAD | git patch-id --stable | cut -d' ' -f1)
  [ "$want" = "$got" ] ||
    die "the ported commits differ from the SDK change in the squash commit $squash_oid; compare them, or port again with --squash"
  echo "The ported commits match the squash commit $(git rev-parse --short "$squash_oid")."
fi

if [ "$test" -eq 1 ]; then
  echo "Checking ..."
  # The bindings are committed, so the checks need no core checkout.
  mise run lint && mise run typecheck && mise run test ||
    die "checks failed on $branch; fix it with a new commit, then rerun with --continue"
fi

# Render the PR body.
title=$(jq -r .title <<<"$meta")
url=$(jq -r .url <<<"$meta")
author=$(jq -r .author <<<"$meta")
ref=$(jq -r .ref <<<"$meta")
head_oid=$(jq -r .head <<<"$meta")
freeze=$(sed -n 's/^sha=//p' "$here/FREEZE" 2>/dev/null || true)
commits=$(git log --reverse --format='- %h %s (%an)' "$start..HEAD")
body="$state_dir/body.md"
CORE_PR="$ref" CORE_URL="$url" AUTHOR="$author" HEAD_OID="$head_oid" \
FREEZE_SHA="${freeze:-unknown}" COMMITS="$commits" \
  awk '{
    while (match($0, /\{\{[A-Z_]+\}\}/)) {
      key = substr($0, RSTART + 2, RLENGTH - 4)
      $0 = substr($0, 1, RSTART - 1) ENVIRON[key] substr($0, RSTART + RLENGTH)
    }
    print
  }' "$body_tmpl" >"$body"

echo
echo "Branch $branch: $ncommits commit(s) on $(git rev-parse --short "$start")"
git log --format='  %h %an <%ae>  %s' "$start..HEAD"
echo
echo "PR title: $title"
echo "PR body ($body):"
sed 's/^/  | /' "$body"

if [ "$push" -eq 0 ]; then
  echo
  echo "Review the branch and body, then rerun with --continue --push to open the PR."
  exit 0
fi

git push --quiet -u origin "$branch"
label=()
gh label list -R "$sdk_repo" --json name --jq '.[].name' | grep -qx port && label=(--label port)
gh pr create -R "$sdk_repo" --base main --head "$branch" \
  --title "$title" --body-file "$body" "${label[@]}"
