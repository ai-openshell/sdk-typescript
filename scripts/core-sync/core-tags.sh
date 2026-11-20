#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

# core-tags.sh: print NVIDIA/OpenShell release tags newer than the pin,
# oldest first.
#
# Usage: core-tags.sh [--all] [--pin <tag>]
#
# Release tags are vX.Y.Z and vX.Y.Z-pre.N; a pre-release sorts below its
# stable version. By default every newer stable tag is printed, plus the
# newest pre-release when it is newer than all of them: one proposal for the
# current release train instead of one per pre-release. --all prints every
# newer tag. --pin overrides the pin, OPENSHELL_CORE_REF in mise.toml.
#
# The pin is a release tag or a full commit SHA on core's main. For a SHA pin,
# the newer tags are the release tags that contain the commit, found with the
# GitHub compare API from the newest tag down.
set -euo pipefail

repo=${CORE_REPO:-NVIDIA/OpenShell}
all=0
pin=

while [ $# -gt 0 ]; do
  case $1 in
  --all) all=1; shift ;;
  --pin) pin=${2:?--pin needs a tag or commit SHA}; shift 2 ;;
  *) echo "usage: $0 [--all] [--pin <tag>]" >&2; exit 2 ;;
  esac
done

[ -n "$pin" ] || pin=$(sed -n 's/^OPENSHELL_CORE_REF = "\(.*\)"$/\1/p' mise.toml)
[ -n "$pin" ] || { echo "ERROR: no OPENSHELL_CORE_REF in mise.toml" >&2; exit 1; }

tag_re='^v[0-9]+\.[0-9]+\.[0-9]+(-pre\.[0-9]+)?$'
sha_re='^[0-9a-f]{40}$'
[[ "$pin" =~ $tag_re || "$pin" =~ $sha_re ]] ||
  { echo "ERROR: pin '$pin' is neither a release tag (vX.Y.Z or vX.Y.Z-pre.N) nor a full commit SHA" >&2; exit 1; }

# key <tag>: "major minor patch rank pre" with rank 1 for stable, 0 for pre.
key() {
  awk -v t="$1" 'BEGIN {
    s = t; sub(/^v/, "", s)
    pre = ""; rank = 1
    if (index(s, "-pre.")) { pre = substr(s, index(s, "-pre.") + 5); s = substr(s, 1, index(s, "-pre.") - 1); rank = 0 }
    split(s, v, ".")
    printf "%d %d %d %d %d\n", v[1], v[2], v[3], rank, (pre == "" ? 0 : pre)
  }'
}

# All release tags, oldest first.
release_tags() {
  gh api --paginate "repos/$repo/git/matching-refs/tags/v" --jq '.[].ref' |
    sed 's#^refs/tags/##' |
    { grep -E "$tag_re" || true; } |
    while read -r t; do echo "$(key "$t") $t"; done |
    sort -n -k1,1 -k2,2 -k3,3 -k4,4 -k5,5 |
    awk '{ print $6 }'
}

# contains <tag> <sha>: true when the tag's commit is the SHA or descends from
# it. An API failure stops the run.
contains() {
  local status
  status=$(gh api "repos/$repo/compare/$2...$1" --jq .status) ||
    { echo "ERROR: comparing $2 with $1 failed" >&2; exit 1; }
  [ "$status" = ahead ] || [ "$status" = identical ]
}

tags=$(release_tags)
if [[ "$pin" =~ $sha_re ]]; then
  # Tags are cut from main in order, so walk down from the newest and stop at
  # the first one that doesn't contain the commit.
  newer=$(
    tac <<<"$tags" | while read -r t; do
      [ -n "$t" ] || continue
      contains "$t" "$pin" || break
      echo "$t"
    done | tac
  )
else
  p=$(key "$pin")
  newer=$(
    while read -r t; do
      [ -n "$t" ] || continue
      echo "$(key "$t") $t"
    done <<<"$tags" |
      awk -v p="$p" '
        BEGIN { split(p, k, " ") }
        {
          for (i = 1; i <= 5; i++) {
            if ($i + 0 > k[i] + 0) { print $6; next }
            if ($i + 0 < k[i] + 0) next
          }
        }'
  )
fi

[ -n "$newer" ] || exit 0
if [ "$all" -eq 1 ]; then
  echo "$newer"
  exit 0
fi

# Stable tags, then the last tag if it is a pre-release (newer than every stable).
grep -v -- '-pre\.' <<<"$newer" || true
last=$(tail -1 <<<"$newer")
case $last in *-pre.*) echo "$last" ;; esac
